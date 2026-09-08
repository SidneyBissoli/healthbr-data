#!/usr/bin/env node
// Registro de cada build dos cubos em data/controle_versao_sih_cubos.csv —
// o mesmo papel que os demais controle_versao_*.csv têm para as pipelines de
// microdados (docs/policy-reproducibility-pt.md): quem gerou o quê, quando,
// com que versão e commit, a partir de que safra do espelho. UMA linha por
// (ano, build); o ano reconstruído entra como linha nova, a anterior fica —
// o CSV é histórico, o canal é o estado.
//
// Uso:
//   node controle.mjs append --csv data/controle_versao_sih_cubos.csv \
//        --data data/sih-cubos --years 2025,1992 [--run <url>] [--reason "<texto>"]
//   node controle.mjs seed --csv data/controle_versao_sih_cubos.csv --sidecars state/sidecars
//        (carga inicial a partir dos sidecars já publicados no canal — usado
//        uma vez em 2026-09-08, na migração do produtor para este repositório)
import { existsSync, readdirSync, readFileSync, writeFileSync, appendFileSync } from "node:fs";
import { join } from "node:path";

const args = process.argv.slice(2);
const cmd = args[0];
const opt = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};

const HEADER = [
  "cube_year", "built_at", "builder_version", "builder_git_commit", "healthbr_version",
  "ufs_arquivo", "partitions", "window_complete", "records_read", "records_in_cube",
  "manifest_last_updated", "run_url", "reason",
];

const q = (v) => {
  const s = v == null ? "" : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

function rowFromSidecar(side, runUrl, reason) {
  return [
    side.cube_year,
    side.built_at,
    side.builder?.version,
    side.builder?.git_commit,
    side.builder?.healthbr_version,
    Array.isArray(side.ufs_arquivo) ? side.ufs_arquivo.length : "",
    Array.isArray(side.partitions) ? side.partitions.length : "",
    side.window?.complete,
    side.totals?.records_read,
    side.totals?.records_in_cube,
    side.distributor?.manifest_last_updated,
    runUrl ?? "",
    reason ?? "",
  ].map(q).join(",");
}

const csv = opt("--csv");
if (!csv) {
  console.error("controle: --csv é obrigatório");
  process.exit(2);
}
if (!existsSync(csv)) writeFileSync(csv, HEADER.join(",") + "\n");

if (cmd === "append") {
  const dataDir = opt("--data") ?? "data/sih-cubos";
  const years = (opt("--years") ?? "").split(",").map((s) => Number(s.trim())).filter(Boolean);
  if (years.length === 0) {
    console.error("controle append: --years vazio");
    process.exit(2);
  }
  const runUrl =
    opt("--run") ??
    (process.env.GITHUB_SERVER_URL && process.env.GITHUB_REPOSITORY && process.env.GITHUB_RUN_ID
      ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}`
      : "");
  const reason = opt("--reason") ?? "";
  let lines = "";
  for (const y of years) {
    const p = join(dataDir, `sih_provenance_${y}.json`);
    if (!existsSync(p)) {
      console.error(`controle append: sem sidecar ${p}`);
      process.exit(1);
    }
    lines += rowFromSidecar(JSON.parse(readFileSync(p, "utf8")), runUrl, reason) + "\n";
  }
  appendFileSync(csv, lines);
  console.log(`controle: ${years.length} linha(s) em ${csv}`);
} else if (cmd === "seed") {
  const dir = opt("--sidecars");
  if (!dir) {
    console.error("controle seed: --sidecars <pasta> é obrigatório");
    process.exit(2);
  }
  const files = readdirSync(dir).filter((f) => /^sih_provenance_\d{4}\.json$/.test(f)).sort();
  let lines = "";
  for (const f of files) {
    lines += rowFromSidecar(JSON.parse(readFileSync(join(dir, f), "utf8")), "", "carga inicial: sidecar publicado no canal antes da migração do produtor (sih-br-mcp rebuild-cubes.yml)") + "\n";
  }
  appendFileSync(csv, lines);
  console.log(`controle: seed com ${files.length} linha(s) em ${csv}`);
} else {
  console.error("controle: uso: controle.mjs append|seed ...");
  process.exit(2);
}
