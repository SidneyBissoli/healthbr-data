#!/usr/bin/env node
// Gera (ou atualiza) o manifesto público dos cubos — `sih/cubos/manifest.json`
// no bucket healthbr-data, servido em https://data.sidneybissoli.com/sih/cubos/.
//
// O manifesto é o contrato entre quem publica (rebuild-sih-cubes.yml, via
// publish-cubes.sh) e quem consome (o sih-br-mcp, ao baixar um ano para o
// cache local; o healthbR): nome, tamanho e SHA-256 de cada arquivo, mais o
// resumo do sidecar do ano. Anos não incluídos em --years vêm do manifesto
// anterior (--previous), então cada run só recalcula o que construiu. Desde a
// 1.1.0 (2026-09-08) o manifesto também assina as TABELAS de classificação
// (`tables`: tables/*.json desta pipeline, publicadas em sih/cubos/tables/) —
// é por esse sha256 que o consumidor confere as cópias que embarca. Desde a
// 1.2.0 (2026-09-08, sih:populacao-no-canal) assina também os DENOMINADORES
// POPULACIONAIS (`population`: pop_uf, pop_uf_agregado, pop_municipios e o
// sidecar pop_provenance.json, de build-population.R, publicados ao lado dos
// cubos) — o consumidor baixa os três pelo mesmo caminho dos cubos.
//
// Uso:
//   node cubes-manifest.mjs --data data/sih-cubos --years 2024,2022 \
//     --previous previous-manifest.json --verify --tables tables \
//     --base-url https://data.sidneybissoli.com/sih/cubos/ --out cubes-manifest.json
//   node cubes-manifest.mjs --years none --population data/sih-population \
//     --previous previous-manifest.json --verify --out cubes-manifest.json
//
//   --years all      todos os anos com sidecar E os três Parquet em --data
//   --years none     nenhum ano recalculado (só tabelas e/ou população; os
//                    anos vêm todos do manifesto anterior)
//   --tables <dir>   assina os *.json da pasta; sem a flag, mantém o bloco
//                    `tables` do manifesto anterior
//   --population <dir>  assina pop_*.parquet + pop_provenance.json da pasta;
//                    sem a flag, mantém o bloco `population` do anterior
//   --verify         confere cada cubo com DuckDB antes de assinar: soma de `n`
//                    em causas e séries = records_in_cube do sidecar; UFs
//                    distintas = ufs_arquivo do sidecar; e cada arquivo de
//                    população contra o pop_provenance.json (linhas, anos,
//                    UFs, total do Brasil no último ano). Falha = exit 1.
import { createHash } from "node:crypto";
import { createReadStream, existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const args = Object.fromEntries(
  process.argv.slice(2).map((a, i, all) => (a.startsWith("--") ? [a.slice(2), all[i + 1] && !all[i + 1].startsWith("--") ? all[i + 1] : true] : [])).filter((p) => p.length),
);
const dataDir = String(args.data ?? "data/sih-cubos");
const tablesDir = args.tables ? String(args.tables) : null;
const populationDir = args.population ? String(args.population) : null;
const outPath = String(args.out ?? "cubes-manifest.json");
const baseUrl = String(args["base-url"] ?? "https://data.sidneybissoli.com/sih/cubos/");
const verify = args.verify === true;
const CUBES = ["causas", "series", "icsap"];

function fail(msg) {
  console.error(`cubes-manifest: ${msg}`);
  process.exit(1);
}

function yearsFromDir() {
  return readdirSync(dataDir)
    .map((f) => f.match(/^sih_provenance_(\d{4})\.json$/)?.[1])
    .filter(Boolean)
    .map(Number)
    .filter((y) => CUBES.every((c) => existsSync(join(dataDir, `sih_${c}_${y}.parquet`))))
    .sort((a, b) => a - b);
}

const years =
  args.years === "none"
    ? []
    : !args.years || args.years === "all"
      ? yearsFromDir()
      : String(args.years).split(",").map((s) => Number(s.trim())).filter(Boolean);
if (years.length === 0 && !tablesDir && !populationDir) fail("nenhum ano para publicar (sidecar + 3 Parquet em " + dataDir + ") e nem --tables/--population");

async function sha256(path) {
  return new Promise((resolve, reject) => {
    const h = createHash("sha256");
    createReadStream(path).on("data", (d) => h.update(d)).on("end", () => resolve(h.digest("hex"))).on("error", reject);
  });
}

async function duckdb() {
  const { DuckDBInstance } = await import("@duckdb/node-api");
  const inst = await DuckDBInstance.create(":memory:");
  const conn = await inst.connect();
  const q = async (sql) => (await conn.runAndReadAll(sql)).getRowObjectsJS();
  return { conn, q };
}

async function verifyYear(year, side) {
  const { conn, q } = await duckdb();
  const expected = Number(side.totals?.records_in_cube);
  const ufs = Array.isArray(side.ufs_arquivo) ? side.ufs_arquivo.length : null;
  for (const cube of ["causas", "series"]) {
    const p = join(dataDir, `sih_${cube}_${year}.parquet`).replace(/\\/g, "/");
    const [r] = await q(`SELECT sum(n) AS n, count(DISTINCT uf) AS ufs, count(*) AS rows FROM read_parquet('${p}')`);
    if (Number(r.n) !== expected) fail(`${year}/${cube}: soma de n ${r.n} != records_in_cube ${expected} do sidecar`);
    if (ufs !== null && Number(r.ufs) !== ufs) fail(`${year}/${cube}: ${r.ufs} UFs no cubo != ${ufs} no sidecar`);
    const rowsKey = `${cube}_rows`;
    if (side.totals?.[rowsKey] != null && Number(r.rows) !== Number(side.totals[rowsKey])) {
      fail(`${year}/${cube}: ${r.rows} linhas != ${side.totals[rowsKey]} do sidecar`);
    }
  }
  const p = join(dataDir, `sih_icsap_${year}.parquet`).replace(/\\/g, "/");
  const [r] = await q(`SELECT count(*) AS rows FROM read_parquet('${p}')`);
  if (side.totals?.icsap_rows != null && Number(r.rows) !== Number(side.totals.icsap_rows)) {
    fail(`${year}/icsap: ${r.rows} linhas != ${side.totals.icsap_rows} do sidecar`);
  }
  conn.closeSync?.();
}

let previous = { years: {} };
if (args.previous && existsSync(String(args.previous))) {
  try {
    const p = JSON.parse(readFileSync(String(args.previous), "utf8"));
    if (p && typeof p.years === "object") previous = p;
  } catch {
    console.error("cubes-manifest: manifesto anterior ilegível — recomeçando do zero");
  }
}

const manifest = {
  manifest_version: "1.2.0",
  dataset: "sih/cubos",
  description:
    "Cubos agregados do SIH/SUS (internações por causa, séries mensais e ICSAP por município) derivados dos microdados RD de sih/rd/ pela pipeline sih-cubos do healthbr-data (scripts/pipeline/sih-cubos/). Um sidecar de proveniência por ano; tabelas de classificação em tables/; denominadores populacionais (IBGE Projeção 2024 por UF; DATASUS POPBR/POPSVS por município) em pop_*.parquet com sidecar pop_provenance.json.",
  generated_at: new Date().toISOString(),
  base_url: baseUrl,
  producer: {
    repository: "https://github.com/SidneyBissoli/healthbr-data",
    pipeline: "scripts/pipeline/sih-cubos",
    workflow: process.env.GITHUB_WORKFLOW ?? null,
    run_url:
      process.env.GITHUB_SERVER_URL && process.env.GITHUB_REPOSITORY && process.env.GITHUB_RUN_ID
        ? `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}`
        : null,
  },
  license: "CC-BY-4.0",
  tables: previous.tables ?? {},
  population: previous.population ?? null,
  years: { ...previous.years },
};

// Tabelas de classificação: um sha256 por arquivo, servidas em <base_url>tables/<nome>
if (tablesDir) {
  if (!existsSync(tablesDir)) fail(`--tables: pasta ${tablesDir} não existe`);
  const names = readdirSync(tablesDir).filter((f) => f.endsWith(".json")).sort();
  if (names.length === 0) fail(`--tables: nenhum .json em ${tablesDir}`);
  manifest.tables = {};
  for (const name of names) {
    const p = join(tablesDir, name);
    manifest.tables[name] = { name: `tables/${name}`, size_bytes: statSync(p).size, sha256: await sha256(p) };
  }
  console.error(`cubes-manifest: ${names.length} tabela(s) assinada(s) de ${tablesDir}`);
}

// Denominadores populacionais (build-population.R): três Parquet + sidecar,
// servidos em <base_url><nome>, ao lado dos cubos. `--verify` confere cada
// arquivo com DuckDB contra o sidecar (linhas, anos, UFs, Brasil no último ano
// do arquivo — sexo 'total' fora da soma, pop_municipios tem M/F/total).
const POP_FILES = ["pop_uf", "pop_uf_agregado", "pop_municipios"];
if (populationDir) {
  if (!existsSync(populationDir)) fail(`--population: pasta ${populationDir} não existe`);
  const provPath = join(populationDir, "pop_provenance.json");
  if (!existsSync(provPath)) fail(`--population: sem ${provPath}`);
  const prov = JSON.parse(readFileSync(provPath, "utf8"));
  if (!prov.built_at || !Number.isInteger(prov.last_year) || !prov.files) fail("--population: pop_provenance.json sem built_at/last_year/files");
  const files = {};
  for (const key of POP_FILES) {
    const name = `${key}.parquet`;
    const p = join(populationDir, name);
    if (!existsSync(p)) fail(`--population: falta ${name}`);
    const exp = prov.files[key];
    if (!exp) fail(`--population: pop_provenance.json sem files.${key}`);
    if (verify) {
      const { conn, q } = await duckdb();
      const [r] = await q(
        `SELECT count(*) AS rows, CAST(min(year) AS INTEGER) AS first_year, CAST(max(year) AS INTEGER) AS last_year,
                count(DISTINCT year) AS years, count(DISTINCT uf) AS ufs,
                sum(CASE WHEN year = ${Number(exp.last_year)} AND sex <> 'total' THEN population ELSE 0 END) AS brasil_last_year
         FROM read_parquet('${p.replace(/\\/g, "/")}')`,
      );
      conn.closeSync?.();
      for (const k of ["rows", "first_year", "last_year", "years", "ufs"]) {
        if (Number(r[k]) !== Number(exp[k])) fail(`${name}: ${k} ${r[k]} != ${exp[k]} do pop_provenance.json`);
      }
      if (exp.brasil_last_year != null && Number(r.brasil_last_year) !== Number(exp.brasil_last_year)) {
        fail(`${name}: Brasil ${exp.last_year} = ${r.brasil_last_year} != ${exp.brasil_last_year} do pop_provenance.json`);
      }
    }
    files[key] = { name, size_bytes: statSync(p).size, sha256: await sha256(p) };
  }
  if (Number(prov.files.pop_uf.last_year) !== Number(prov.last_year)) fail(`--population: pop_uf vai até ${prov.files.pop_uf.last_year}, last_year diz ${prov.last_year}`);
  files.provenance = { name: "pop_provenance.json", size_bytes: statSync(provPath).size, sha256: await sha256(provPath) };
  manifest.population = {
    built_at: prov.built_at,
    builder_version: prov.builder?.version ?? null,
    last_year: prov.last_year,
    rule: prov.rule ?? null,
    sources: (prov.sources ?? []).map((s) => ({ file: s.file, name: s.name, agency: s.agency ?? null, url: s.url ?? null, years: s.years ?? null })),
    files,
  };
  console.error(`cubes-manifest: população assinada de ${populationDir} (${POP_FILES.length} Parquet + sidecar; último ano ${prov.last_year}${verify ? ", verificada com DuckDB" : ""})`);
}

for (const year of years) {
  const sidePath = join(dataDir, `sih_provenance_${year}.json`);
  if (!existsSync(sidePath)) fail(`${year}: sem sidecar ${sidePath}`);
  const side = JSON.parse(readFileSync(sidePath, "utf8"));
  if (verify) await verifyYear(year, side);
  const files = {};
  for (const cube of CUBES) {
    const name = `sih_${cube}_${year}.parquet`;
    const p = join(dataDir, name);
    if (!existsSync(p)) fail(`${year}: falta ${name}`);
    files[cube] = { name, size_bytes: statSync(p).size, sha256: await sha256(p) };
  }
  files.provenance = { name: `sih_provenance_${year}.json`, size_bytes: statSync(sidePath).size, sha256: await sha256(sidePath) };
  manifest.years[String(year)] = {
    built_at: side.built_at ?? null,
    builder_version: side.builder?.version ?? null,
    records_in_cube: side.totals?.records_in_cube ?? null,
    window_complete: side.window?.complete ?? null,
    ufs: Array.isArray(side.ufs_arquivo) ? side.ufs_arquivo.length : null,
    manifest_last_updated: side.distributor?.manifest_last_updated ?? null,
    files,
  };
  console.error(`cubes-manifest: ${year} ok (${Object.values(files).reduce((s, f) => s + f.size_bytes, 0)} bytes)`);
}

// Anos em ordem no JSON final
manifest.years = Object.fromEntries(Object.entries(manifest.years).sort(([a], [b]) => Number(a) - Number(b)));
writeFileSync(outPath, JSON.stringify(manifest, null, 2) + "\n");
console.error(`cubes-manifest: ${Object.keys(manifest.years).length} ano(s)${manifest.population ? `, população até ${manifest.population.last_year}` : ", sem população"} em ${outPath}`);
