#!/usr/bin/env node
// Baixa o ESTADO dos cubos do canal público — o manifesto de sih/cubos/ e os
// sidecars de proveniência (sih_provenance_<ano>.json) — para uma pasta local.
//
// Desde 2026-09-08 o estado dos cubos é o canal, não o git: nenhum sidecar é
// versionado neste repositório. O job `decide` do rebuild-sih-cubes.yml lê
// esses sidecars para medir o frescor de cada cubo frente ao espelho sih/rd/;
// o job `build` usa o sidecar anterior do ano como `before/` (gate de delta) e
// como origem das UFs de arquivo (rebuild-cubes.R).
//
// Uso:
//   node canal-state.mjs --out state [--years 2025,1992 | all] [--base <url>]
//
// Escreve <out>/manifest.json e <out>/sidecars/sih_provenance_<ano>.json.
// `?v=<ts>` nas URLs fura o cache de 300 s do domínio (Cache Rule). Se o
// domínio falhar, tenta o r2.dev. Ano pedido que não existe no manifesto é
// avisado e pulado (é um cubo NOVO: o build precisa de --ufs).
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const args = process.argv.slice(2);
const opt = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};
const outDir = opt("--out") ?? "state";
const base = (opt("--base") ?? "https://data.sidneybissoli.com/sih/cubos/").replace(/\/?$/, "/");
const fallback = "https://pub-99d9e1a3f5c542178d04efbddf1bba97.r2.dev/sih/cubos/";
const yearsArg = opt("--years") ?? "all";

async function get(name) {
  const bust = `?v=${Date.now()}`;
  for (const b of [base, fallback]) {
    try {
      const r = await fetch(b + name + bust, { signal: AbortSignal.timeout(60_000) });
      if (r.ok) return await r.text();
      if (r.status === 404) return null;
      console.error(`canal-state: ${b}${name} → HTTP ${r.status}`);
    } catch (e) {
      console.error(`canal-state: ${b}${name} → ${e.message}`);
    }
  }
  throw new Error(`canal-state: não consegui baixar ${name}`);
}

mkdirSync(join(outDir, "sidecars"), { recursive: true });
const manifestText = await get("manifest.json");
if (manifestText === null) {
  console.error("canal-state: sem manifest.json no canal (primeira publicação?) — estado vazio");
  writeFileSync(join(outDir, "manifest.json"), JSON.stringify({ years: {} }, null, 2) + "\n");
  process.exit(0);
}
writeFileSync(join(outDir, "manifest.json"), manifestText);
const manifest = JSON.parse(manifestText);
const published = Object.keys(manifest.years ?? {}).map(Number).sort((a, b) => a - b);
const wanted =
  yearsArg === "all"
    ? published
    : yearsArg.split(",").map((s) => Number(s.trim())).filter(Boolean);

let n = 0;
for (const y of wanted) {
  if (!published.includes(y)) {
    console.error(`canal-state: ${y} não está no manifesto (cubo novo) — sem sidecar anterior`);
    continue;
  }
  const text = await get(`sih_provenance_${y}.json`);
  if (text === null) throw new Error(`canal-state: ${y} está no manifesto mas o sidecar deu 404`);
  writeFileSync(join(outDir, "sidecars", `sih_provenance_${y}.json`), text);
  n++;
}
console.log(`canal-state: manifesto (${published.length} ano(s), gerado em ${manifest.generated_at ?? "?"}) + ${n} sidecar(s) em ${outDir}/`);
