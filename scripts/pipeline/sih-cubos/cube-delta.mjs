#!/usr/bin/env node
// Delta entre dois sidecars do MESMO cubo (sih_provenance_<ano>.json publicado
// no canal antes do rebuild e o recém-gerado) — o gate que o golden do
// consumidor não é. O golden e o smoke do sih-br-mcp rodam sobre a FIXTURE
// dele (2023/RR), não sobre o cubo real: um cubo regenerado com partição a
// menos, ou com 20% menos internações, passaria por eles sem tocar num número. Este script olha o que o rebuild de fato mudou e
// REPROVA (exit 1) quando a mudança tem cara de perda, não de reedição:
//
//   - o cubo perdeu partição que o manifesto do espelho NÃO retirou
//     (retirada legítima vem em `--freshness <estado>`, lista `removed`);
//   - `records_in_cube` caiu mais de 1% sem nenhuma partição retirada;
//   - a janela regrediu (`window.complete` era true e virou false);
//   - o escopo mudou (`ufs_arquivo` ou `cube_year`) sem `--allow-scope-change`
//     — mudar o escopo de um cubo é decisão de quem dispara, não efeito
//     colateral de rebuild.
//
// Tudo o mais é RELATADO, não julgado: partições reeditadas pelo MS (MD5 ou
// tamanho do .dbc mudou), regeneradas no espelho (SHA-256 do Parquet mudou),
// novas na janela, contagens antes/depois de cada cubo. O relatório sai em
// Markdown (`--md <arquivo>`, vai para o summary do job e para as notas da
// release) e em JSON (`--json <arquivo>`).
//
//   node cube-delta.mjs --before <sidecar-antes> --after <sidecar-depois>
//        [--freshness <estado.json>] [--allow-scope-change] [--md <out.md>] [--json <out.json>]
//   node cube-delta.mjs --selftest --fixtures <pasta com sih_provenance_2023.json>
//        OFFLINE (o job `decide` roda antes de cada rebuild, sobre o sidecar de
//        2023 baixado do canal): sidecar contra si mesmo tem de dar delta zero;
//        cópias adulteradas têm de reprovar pelo motivo certo.
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const args = process.argv.slice(2);
const opt = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};
const has = (flag) => args.includes(flag);

const DROP_TOLERANCE = 0.01; // queda de records_in_cube tolerada sem partição retirada

const fmt = (n) => (typeof n === "number" ? n.toLocaleString("pt-BR") : String(n ?? "—"));
const pct = (a, b) => (a ? `${(((b - a) / a) * 100).toFixed(2).replace(".", ",")}%` : "—");

/** Compara dois sidecars do mesmo cubo. Puro: não lê arquivo, não sai do processo. */
export function cubeDelta(before, after, { freshness = null, allowScopeChange = false } = {}) {
  const problems = [];
  const warnings = [];

  if (before.cube_year !== after.cube_year) {
    problems.push(`cube_year mudou: ${before.cube_year} → ${after.cube_year}`);
  }
  const ufsBefore = [...before.ufs_arquivo].sort().join(",");
  const ufsAfter = [...after.ufs_arquivo].sort().join(",");
  if (ufsBefore !== ufsAfter) {
    (allowScopeChange ? warnings : problems).push(`escopo (ufs_arquivo) mudou: ${ufsBefore || "∅"} → ${ufsAfter || "∅"}`);
  }

  const pb = new Map(before.partitions.map((p) => [p.partition, p]));
  const pa = new Map(after.partitions.map((p) => [p.partition, p]));
  const removedInMirror = new Set(
    (freshness?.cubes ?? []).filter((c) => c.cube_year === before.cube_year).flatMap((c) => c.removed ?? []),
  );

  const lost = [];
  const removed = [];
  const reedited = [];
  const reprocessed = [];
  const unchanged = [];
  for (const [k, p] of pb) {
    const q = pa.get(k);
    if (!q) {
      (removedInMirror.has(k) ? removed : lost).push(k);
      continue;
    }
    if (q.source_hash_md5 !== p.source_hash_md5 || q.source_size_bytes !== p.source_size_bytes) reedited.push(k);
    else if (p.parquet_sha256 && q.parquet_sha256 && q.parquet_sha256 !== p.parquet_sha256) reprocessed.push(k);
    else unchanged.push(k);
  }
  const added = [...pa.keys()].filter((k) => !pb.has(k));

  if (lost.length) {
    problems.push(`${lost.length} partição(ões) sumiram do cubo sem o espelho tê-las retirado: ${lost.join(", ")}`);
  }

  const recBefore = before.totals?.records_in_cube ?? null;
  const recAfter = after.totals?.records_in_cube ?? null;
  if (recBefore != null && recAfter != null && recBefore > 0) {
    const drop = (recBefore - recAfter) / recBefore;
    if (drop > DROP_TOLERANCE && removed.length === 0) {
      problems.push(
        `records_in_cube caiu ${(drop * 100).toFixed(2).replace(".", ",")}% (${fmt(recBefore)} → ${fmt(recAfter)}) sem partição retirada no espelho`,
      );
    }
  }

  const completeBefore = before.window?.complete ?? null;
  const completeAfter = after.window?.complete ?? null;
  if (completeBefore === true && completeAfter === false) {
    problems.push("window.complete regrediu de true para false");
  }

  const changed = lost.length + removed.length + reedited.length + reprocessed.length + added.length > 0;
  const countsChanged = ["records_read", "records_in_cube", "causas_rows", "series_rows", "icsap_rows"].some(
    (k) => (before.totals?.[k] ?? null) !== (after.totals?.[k] ?? null),
  );
  if (!changed && countsChanged) {
    warnings.push("mesmas partições, mesmos hashes de origem, mas as contagens mudaram — o builder mudou de regra?");
  }

  return {
    cube_year: after.cube_year,
    ok: problems.length === 0,
    problems,
    warnings,
    identical: !changed && !countsChanged,
    partitions: {
      before: pb.size,
      after: pa.size,
      unchanged: unchanged.length,
      reedited,
      reprocessed,
      added,
      removed,
      lost,
    },
    window: { before: completeBefore, after: completeAfter },
    scope: { before: before.ufs_arquivo, after: after.ufs_arquivo },
    totals: { before: before.totals ?? {}, after: after.totals ?? {} },
    manifest_last_updated: {
      before: before.distributor?.manifest_last_updated ?? null,
      after: after.distributor?.manifest_last_updated ?? null,
    },
    retrieved_at: { before: before.retrieved_at ?? null, after: after.retrieved_at ?? null },
    builder: { before: before.builder?.version ?? null, after: after.builder?.version ?? null },
    built_at: after.built_at ?? null,
  };
}

export function renderMarkdown(d) {
  const L = [];
  L.push(`### Cubo ${d.cube_year} — ${d.ok ? (d.identical ? "idêntico ao anterior" : "reconstruído") : "REPROVADO"}`);
  L.push("");
  if (d.problems.length) {
    for (const p of d.problems) L.push(`- ❌ ${p}`);
    L.push("");
  }
  for (const w of d.warnings) L.push(`- ⚠️ ${w}`);
  if (d.warnings.length) L.push("");
  L.push("| | antes | depois | Δ |");
  L.push("|---|---:|---:|---:|");
  for (const k of ["records_read", "records_other_year", "records_in_cube", "causas_rows", "series_rows", "icsap_rows"]) {
    const a = d.totals.before[k];
    const b = d.totals.after[k];
    L.push(`| ${k} | ${fmt(a)} | ${fmt(b)} | ${typeof a === "number" && typeof b === "number" ? pct(a, b) : "—"} |`);
  }
  L.push(`| partições | ${d.partitions.before} | ${d.partitions.after} | |`);
  L.push(`| janela completa | ${d.window.before} | ${d.window.after} | |`);
  L.push(`| UFs de arquivo | ${d.scope.before.join(" ")} | ${d.scope.after.join(" ")} | |`);
  L.push(`| manifesto do espelho | ${d.manifest_last_updated.before ?? "—"} | ${d.manifest_last_updated.after ?? "—"} | |`);
  L.push(`| retrieved_at | ${d.retrieved_at.before ?? "—"} | ${d.retrieved_at.after ?? "—"} | |`);
  L.push(`| builder | ${d.builder.before ?? "—"} | ${d.builder.after ?? "—"} | |`);
  L.push("");
  const lista = (xs) => (xs.length <= 8 ? xs.join(", ") : `${xs.slice(0, 8).join(", ")} e mais ${xs.length - 8}`);
  const P = d.partitions;
  L.push(
    `Partições: ${P.unchanged} inalteradas` +
      (P.reedited.length ? `; ${P.reedited.length} reeditadas pelo MS (${lista(P.reedited)})` : "") +
      (P.reprocessed.length ? `; ${P.reprocessed.length} regeneradas no espelho (${lista(P.reprocessed)})` : "") +
      (P.added.length ? `; ${P.added.length} novas (${lista(P.added)})` : "") +
      (P.removed.length ? `; ${P.removed.length} retiradas do espelho (${lista(P.removed)})` : "") +
      (P.lost.length ? `; ${P.lost.length} PERDIDAS (${lista(P.lost)})` : "") +
      ".",
  );
  if (d.built_at) L.push(`Build: ${d.built_at}.`);
  return L.join("\n") + "\n";
}

// =============================================================================
// AUTOTESTE OFFLINE
// =============================================================================

function selftest(fixtures) {
  const path = resolve(fixtures, "sih_provenance_2023.json");
  const base = JSON.parse(readFileSync(path, "utf8"));
  const fail = (msg) => {
    console.error(`CUBE-DELTA SELFTEST FALHOU: ${msg}`);
    process.exit(1);
  };
  const clone = () => structuredClone(base);
  const first = base.partitions[0].partition;
  const last = base.partitions.at(-1).partition;

  // 1. Contra si mesmo: delta zero, aprovado.
  let d = cubeDelta(base, clone());
  if (!d.ok || !d.identical) fail(`sidecar contra si mesmo deveria ser idêntico e ok: ${JSON.stringify(d.problems)}`);
  console.log("selftest 1/6: idêntico → ok");

  // 2. Perdeu a última partição sem o espelho tê-la retirado: reprova.
  let a = clone();
  a.partitions.pop();
  d = cubeDelta(base, a);
  if (d.ok || !d.partitions.lost.includes(last)) fail(`partição perdida deveria reprovar: ${JSON.stringify(d)}`);
  console.log(`selftest 2/6: partição perdida (${last}) → reprova`);

  // 3. A mesma perda, mas o manifesto retirou a partição: aprova, relata como retirada.
  a = clone();
  a.partitions.pop();
  a.totals.records_in_cube = Math.round(base.totals.records_in_cube * 0.9);
  const fresh = { cubes: [{ cube_year: base.cube_year, removed: [last], reedited: [], reprocessed: [], new_in_window: [], behind: true }] };
  d = cubeDelta(base, a, { freshness: fresh });
  if (!d.ok || !d.partitions.removed.includes(last) || d.partitions.lost.length) fail(`retirada legítima deveria aprovar: ${JSON.stringify(d.problems)}`);
  console.log("selftest 3/6: retirada legítima (freshness.removed) → ok, mesmo com queda de 10%");

  // 4. Mesmas partições, records_in_cube 5% menor: reprova.
  a = clone();
  a.totals.records_in_cube = Math.round(base.totals.records_in_cube * 0.95);
  d = cubeDelta(base, a);
  if (d.ok || !d.problems.some((p) => p.startsWith("records_in_cube caiu"))) fail(`queda de 5% deveria reprovar: ${JSON.stringify(d.problems)}`);
  console.log("selftest 4/6: records_in_cube −5% sem retirada → reprova");

  // 5. Reedição pelo MS na 1ª partição, com 2% a mais de internações: aprova e relata.
  a = clone();
  a.partitions[0] = { ...a.partitions[0], source_hash_md5: "0".repeat(32), source_size_bytes: a.partitions[0].source_size_bytes + 1 };
  a.totals.records_in_cube = Math.round(base.totals.records_in_cube * 1.02);
  d = cubeDelta(base, a);
  if (!d.ok || !d.partitions.reedited.includes(first) || d.identical) fail(`reedição deveria aprovar e relatar: ${JSON.stringify(d)}`);
  console.log(`selftest 5/6: reedição do MS (${first}) → ok, relatada`);

  // 6. Janela regrediu; escopo mudou sem permissão; e com permissão.
  a = clone();
  a.window.complete = false;
  d = cubeDelta(base, a);
  if (d.ok) fail("janela regredida deveria reprovar");
  a = clone();
  a.ufs_arquivo = [...a.ufs_arquivo, "AC"];
  d = cubeDelta(base, a);
  if (d.ok) fail("mudança de escopo sem --allow-scope-change deveria reprovar");
  d = cubeDelta(base, a, { allowScopeChange: true });
  if (!d.ok || d.warnings.length === 0) fail("mudança de escopo com --allow-scope-change deveria aprovar com aviso");
  console.log("selftest 6/6: janela regredida → reprova; escopo mudado → reprova sem flag, aviso com flag");

  // O Markdown tem de renderizar sem lançar.
  renderMarkdown(cubeDelta(base, a, { allowScopeChange: true }));
  console.log("CUBE-DELTA SELFTEST OK");
}

// =============================================================================
// CLI
// =============================================================================

if (has("--selftest")) {
  const fx = opt("--fixtures");
  if (!fx) {
    console.error("cube-delta: --selftest exige --fixtures <pasta com sih_provenance_2023.json>");
    process.exit(2);
  }
  selftest(fx);
} else {
  const beforePath = opt("--before");
  const afterPath = opt("--after");
  if (!beforePath || !afterPath) {
    console.error("uso: cube-delta.mjs --before <sidecar> --after <sidecar> [--freshness <estado.json>] [--allow-scope-change] [--md <out>] [--json <out>]");
    process.exit(2);
  }
  const before = JSON.parse(readFileSync(beforePath, "utf8"));
  const after = JSON.parse(readFileSync(afterPath, "utf8"));
  const freshnessPath = opt("--freshness");
  const freshness = freshnessPath ? JSON.parse(readFileSync(freshnessPath, "utf8")) : null;
  const d = cubeDelta(before, after, { freshness, allowScopeChange: has("--allow-scope-change") });
  const md = renderMarkdown(d);
  if (opt("--md")) writeFileSync(opt("--md"), md);
  if (opt("--json")) writeFileSync(opt("--json"), JSON.stringify(d, null, 2) + "\n");
  process.stdout.write(md);
  process.exit(d.ok ? 0 : 1);
}
