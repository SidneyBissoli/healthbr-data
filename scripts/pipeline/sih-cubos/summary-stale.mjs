#!/usr/bin/env node
// Os pré-agregados publicados estão FRESCOS frente aos cubos publicados?
//
// É a pergunta que decide se build-sih-summary.yml precisa rodar depois de um
// rebuild de cubos. O contrato de frescor é o mesmo do assinador
// (cubes-manifest.mjs) e do consumidor (sih-br-mcp, summaryFreshYears): o
// bloco `icsap_summary` / `causas_summary` guarda em `derived_from` o sha256
// do cubo-fonte por ano, e um ano cujo cubo publicado tem outro sha está com
// o resumo VELHO — o consumidor ignora os estratos daquele ano e cai no cubo.
//
// Por que existe (16/09/2026). O rebuild de 15/09 republicou o cubo de 2025 e
// o assinador avisou, no log do run, "icsap_summary herdado está VELHO para
// 2025; rode build-sih-summary.yml". Ninguém leu o log; o consumidor ficou no
// caminho lento e a imagem do sih-br-mcp reprovou no aquecimento. Aviso em log
// não é acionamento. Agora build-sih-summary.yml corre encadeado ao rebuild
// (workflow_run) e este script decide se há o que derivar — sem rebaixar 34
// anos de cubo (1,25 GB) quando nada mudou.
//
// Uso:
//   node summary-stale.mjs [--manifest <url|arquivo>] [--github-output]
//   node summary-stale.mjs --selftest
// Saída: uma linha por bloco; com --github-output, `run=true|false` e
// `stale=<anos por bloco>` em $GITHUB_OUTPUT. Sai com 0 mesmo quando velho —
// velho é resposta, não erro; manifesto ilegível é erro (exit 1).

import { appendFileSync, readFileSync } from "node:fs";

const DEFAULT_MANIFEST = "https://data.sidneybissoli.com/sih/cubos/manifest.json";
const BLOCKS = [
  ["icsap_summary", "icsap"],
  ["causas_summary", "causas"],
];

/**
 * Anos com resumo velho, por bloco. Bloco ausente conta como velho em TODOS
 * os anos (nunca foi derivado); ano sem cubo publicado não conta (não há de
 * que derivar).
 */
export function staleYears(manifest) {
  const years = Object.keys(manifest?.years ?? {}).sort();
  const out = {};
  for (const [block, cube] of BLOCKS) {
    const b = manifest?.[block];
    out[block] = years.filter((y) => {
      const sha = manifest.years[y]?.files?.[cube]?.sha256;
      if (!sha) return false;
      return !b || b.derived_from?.[y] !== sha;
    });
  }
  return out;
}

export function needsRun(stale) {
  return Object.values(stale).some((ys) => ys.length > 0);
}

async function loadManifest(src) {
  if (/^https?:\/\//.test(src)) {
    const res = await fetch(src, { signal: AbortSignal.timeout(20000) });
    if (!res.ok) throw new Error(`manifesto ${src}: HTTP ${res.status}`);
    return res.json();
  }
  return JSON.parse(readFileSync(src, "utf8"));
}

function selftest() {
  const A = "a".repeat(64), B = "b".repeat(64), C = "c".repeat(64);
  const m = {
    years: {
      2024: { files: { icsap: { sha256: A }, causas: { sha256: A } } },
      2025: { files: { icsap: { sha256: B }, causas: { sha256: B } } },
      1992: { files: { series: { sha256: C } } }, // sem cubo de icsap/causas: não conta
    },
    icsap_summary: { derived_from: { 2024: A, 2025: C } },
    causas_summary: { derived_from: { 2024: A, 2025: B } },
  };
  const s = staleYears(m);
  const casos = [
    ["icsap: 2025 derivado de outro cubo é velho; 2024 é fresco", JSON.stringify(s.icsap_summary) === '["2025"]'],
    ["causas: tudo fresco", JSON.stringify(s.causas_summary) === "[]"],
    ["ano sem cubo do bloco não conta como velho", !s.icsap_summary.includes("1992")],
    ["um bloco velho basta para rodar", needsRun(s) === true],
    ["tudo fresco → não roda", needsRun({ icsap_summary: [], causas_summary: [] }) === false],
    ["bloco ausente é velho em todos os anos com cubo", JSON.stringify(staleYears({ years: m.years }).causas_summary) === '["2024","2025"]'],
    ["manifesto vazio não quebra e não roda", needsRun(staleYears({})) === false],
  ];
  let falhas = 0;
  for (const [rotulo, ok] of casos) {
    console.log(`  ${ok ? " ok  " : "FALHA"}  ${rotulo}`);
    if (!ok) falhas++;
  }
  if (falhas) {
    console.error(`summary-stale: selftest FALHOU em ${falhas} caso(s)`);
    process.exit(1);
  }
  console.log("summary-stale: selftest ok");
}

const args = process.argv.slice(2);
const opt = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};

if (args.includes("--selftest")) {
  selftest();
} else {
  const src = opt("--manifest") ?? DEFAULT_MANIFEST;
  let manifest;
  try {
    manifest = await loadManifest(src);
  } catch (e) {
    console.error(`summary-stale: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  }
  const stale = staleYears(manifest);
  const run = needsRun(stale);
  for (const [block, ys] of Object.entries(stale)) {
    console.log(`summary-stale: ${block} ${ys.length ? `VELHO para ${ys.join(", ")}` : "fresco"} (manifesto ${manifest.generated_at ?? "?"})`);
  }
  const resumo = Object.entries(stale)
    .filter(([, ys]) => ys.length)
    .map(([b, ys]) => `${b}: ${ys.join(",")}`)
    .join("; ");
  if (args.includes("--github-output") && process.env.GITHUB_OUTPUT) {
    appendFileSync(process.env.GITHUB_OUTPUT, `run=${run}\nstale=${resumo}\n`);
  }
  console.log(run ? `summary-stale: há o que derivar (${resumo})` : "summary-stale: nada a derivar");
}
