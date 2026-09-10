#!/usr/bin/env node
// Deriva os artefatos PRÉ-AGREGADOS da ICSAP a partir dos cubos PUBLICADOS no
// canal — PLAN-005 do sih-br-mcp (sih:serie-pre-agregada, decisão do usuário
// em 09/09/2026). Função pura dos cubos: não toca FTP nem microdados.
//
// Por quê: o custo dominante da consulta ICSAP no servidor remoto é o
// DISTINCT dos estratos (~700 mil/ano) refeito a cada chamada — 26,5 s dos
// 28 s da série de 34 anos em máquina local com 1 thread; 310 s na borda
// (container `basic`, 1/4 vCPU). Pré-gravar o resultado uma vez derruba a
// série para 0,1 s local (resumo) e o denominador fino para 5,9 s (estratos).
//
// Artefatos (publicados em sih/cubos/ ao lado dos cubos, bloco
// `icsap_summary` do manifesto):
// - sih_icsap_resumo.parquet (UM arquivo, todos os anos, ~295 KB): grão
//   universe × year × uf × cid_revision × csap_group com n_icsap, total_days,
//   total_value (DECIMAL 18,2 — soma determinística), deaths e n_total (o
//   denominador do universe × year × uf × cid_revision, repetido nas linhas
//   de grupo; linhas com csap_group NULO existem onde há estrato sem ICSAP).
//   Os DOIS universos (csapaih e all) já computados.
// - sih_icsap_estratos_YYYY.parquet (por ano, ~2,5 MB/ano recente): um
//   registro por estrato (chaves CRUAS do cubo + n_total) — o DISTINCT
//   gravado uma vez, denominador para qualquer filtro fino.
// - icsap_summary_provenance.json: built_at, versão, derived_from (sha256 do
//   cubo-fonte POR ANO — o contrato de frescor: quem assina o manifesto
//   recusa resumo derivado de cubo que não é o publicado) e contagens para
//   verificação.
//
// Uso:
//   node derive-icsap-summary.mjs --out data/sih-summary \
//     [--manifest https://data.sidneybissoli.com/sih/cubos/manifest.json] \
//     [--work .derive-cache] [--years 1992,1993 | all]
//   node derive-icsap-summary.mjs --selftest
//
// Determinismo: todo COPY tem ORDER BY completo (lição do golden que se
// reproduz: GROUP BY sem ORDER BY sai na ordem das threads) e `value` soma
// como DECIMAL(18,2) (soma paralela de DOUBLE muda o último dígito).
// A máquina de baixar cubo conferindo hash, abrir o DuckDB e escrever o
// sidecar mora em summary-lib.mjs, compartilhada com derive-causas-summary.mjs
// (PLAN-006): o mesmo `.derive-cache` serve os dois derivadores.
import { mkdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { duckdb, ensureCube, ensureDirs, failWith, loadManifest, parseArgs, posix, wantedYears, writeProvenance } from "./summary-lib.mjs";

const VERSION = "1.1.0";

const args = parseArgs();
const fail = failWith("derive-icsap-summary");

// ---------------------------------------------------------------------------
// SQL — o MESMO desenho do consumidor (sih-br-mcp src/db/duckdb.ts): chaves do
// estrato year, uf, municipality_code, cid_revision, sex, age, race,
// exclusion (+ n_total); universo csapaih = exclusion IS NULL.
// ---------------------------------------------------------------------------
const ESTRATO_COLS = "year, uf, municipality_code, cid_revision, sex, age, race, exclusion, n_total";

function sqlEstratos(cubePath, outPath) {
  return `COPY (
    SELECT DISTINCT ${ESTRATO_COLS}
    FROM read_parquet('${posix(cubePath)}')
    ORDER BY ${ESTRATO_COLS}
  ) TO '${posix(outPath)}' (FORMAT PARQUET, COMPRESSION ZSTD)`;
}

function sqlResumo(cubeGlob, outPath) {
  return `COPY (
    WITH base AS (SELECT * FROM read_parquet('${posix(cubeGlob)}', union_by_name = true)),
    universos(universe) AS (VALUES ('csapaih'), ('all')),
    estr AS (SELECT DISTINCT year, uf, municipality_code, COALESCE(cid_revision, 10) AS cid_revision, sex, age, race, exclusion, n_total FROM base),
    den AS (
      SELECT u.universe, e.year, e.uf, e.cid_revision, SUM(e.n_total) AS n_total
      FROM estr e CROSS JOIN universos u
      WHERE u.universe = 'all' OR e.exclusion IS NULL
      GROUP BY 1, 2, 3, 4
    ),
    num AS (
      SELECT u.universe, b.year, b.uf, COALESCE(b.cid_revision, 10) AS cid_revision, b.csap_group,
             SUM(b.n) AS n_icsap, SUM(b.days) AS total_days,
             SUM(CAST(b.value AS DECIMAL(18,2))) AS total_value, SUM(b.deaths) AS deaths
      FROM base b CROSS JOIN universos u
      WHERE b.csap_group IS NOT NULL AND (u.universe = 'all' OR b.exclusion IS NULL)
      GROUP BY 1, 2, 3, 4, 5
    )
    SELECT d.universe, d.year, d.uf, d.cid_revision, n.csap_group,
           n.n_icsap, n.total_days, n.total_value, n.deaths, d.n_total
    FROM den d LEFT JOIN num n USING (universe, year, uf, cid_revision)
    ORDER BY d.universe, d.year, d.uf, d.cid_revision, n.csap_group
  ) TO '${posix(outPath)}' (FORMAT PARQUET, COMPRESSION ZSTD)`;
}

// ---------------------------------------------------------------------------
// Selftest: mini-cubo embutido cobrindo estrato com dois grupos (n_total
// repetido), estrato sem ICSAP (grupo nulo), estrato EXCLUÍDO (parto),
// cid_revision 9 e nula, dois anos e duas UFs. Deriva e confere que o
// percentual pelo RESUMO bate com o recomputado direto do cubo (semântica do
// servidor), e que os estratos têm exatamente as linhas do DISTINCT.
// ---------------------------------------------------------------------------
async function selftest() {
  const dir = join(tmpdir(), `derive-icsap-selftest-${process.pid}`);
  mkdirSync(dir, { recursive: true });
  const { q, run } = await duckdb();
  const cube = join(dir, "sih_icsap_2001.parquet");
  await run(`COPY (
    SELECT * FROM (VALUES
      -- year, uf, municipality_code, csap_group, sex, age, race, n, days, value, deaths, n_total, exclusion, cid_revision
      (2001, 'AC', '120010', 'g01', 'F', 30, 'branca', 5,  20, 100.50, 1, 40, NULL, 10),
      (2001, 'AC', '120010', 'g02', 'F', 30, 'branca', 3,  9,  50.25,  0, 40, NULL, 10),
      (2001, 'AC', '120020', NULL,  'M', 60, 'preta',  0,  0,  0.0,    0, 25, NULL, 10),
      (2001, 'AC', '120010', NULL,  'F', 25, 'parda',  0,  0,  0.0,    0, 10, 'parto', 10),
      (2001, 'RR', '140010', 'g01', 'M', 45, 'parda',  7,  30, 300.10, 2, 50, NULL, 10),
      (2000, 'AC', '120010', 'g03', 'F', 30, 'branca', 2,  4,  10.00,  0, 12, NULL, 9),
      (2000, 'AC', '120010', 'g03', 'M', 70, 'preta',  1,  8,  22.40,  1, 8,  NULL, NULL)
    ) AS t(year, uf, municipality_code, csap_group, sex, age, race, n, days, value, deaths, n_total, exclusion, cid_revision)
  ) TO '${posix(cube)}' (FORMAT PARQUET)`);

  const estr = join(dir, "estratos.parquet");
  const resumo = join(dir, "resumo.parquet");
  await run(sqlEstratos(cube, estr));
  await run(sqlResumo(cube, resumo));

  // estratos = DISTINCT do cubo
  const [{ a, b }] = await q(`SELECT (SELECT count(*) FROM read_parquet('${posix(estr)}')) AS a,
    (SELECT count(*) FROM (SELECT DISTINCT ${ESTRATO_COLS} FROM read_parquet('${posix(cube)}'))) AS b`);
  if (Number(a) !== Number(b)) fail(`selftest: estratos ${a} != DISTINCT ${b}`);

  // percentual por (universe, year, uf): resumo × direto do cubo
  const direto = await q(`
    WITH universos(universe) AS (VALUES ('csapaih'), ('all')),
    e AS (SELECT DISTINCT ${ESTRATO_COLS} FROM read_parquet('${posix(cube)}')),
    den AS (SELECT u.universe, e.year, e.uf, SUM(n_total) AS t FROM e CROSS JOIN universos u WHERE u.universe='all' OR e.exclusion IS NULL GROUP BY 1,2,3),
    num AS (SELECT u.universe, c.year, c.uf, SUM(n) AS n FROM read_parquet('${posix(cube)}') c CROSS JOIN universos u WHERE csap_group IS NOT NULL AND (u.universe='all' OR c.exclusion IS NULL) GROUP BY 1,2,3)
    SELECT d.universe, d.year, d.uf, COALESCE(n.n, 0) AS n, d.t FROM den d LEFT JOIN num n USING (universe, year, uf) ORDER BY 1,2,3`);
  const viaResumo = await q(`
    WITH den AS (SELECT universe, year, uf, SUM(n_total) AS t FROM (SELECT DISTINCT universe, year, uf, cid_revision, n_total FROM read_parquet('${posix(resumo)}')) GROUP BY 1,2,3),
    num AS (SELECT universe, year, uf, SUM(n_icsap) AS n FROM read_parquet('${posix(resumo)}') WHERE csap_group IS NOT NULL GROUP BY 1,2,3)
    SELECT d.universe, d.year, d.uf, COALESCE(n.n, 0) AS n, d.t FROM den d LEFT JOIN num n USING (universe, year, uf) ORDER BY 1,2,3`);
  const J = (v) => JSON.stringify(v, (_, x) => (typeof x === "bigint" ? Number(x) : x));
  if (J(direto) !== J(viaResumo)) fail(`selftest: resumo diverge do cubo\n direto: ${J(direto)}\n resumo: ${J(viaResumo)}`);

  // casos cravados: AC/2001 csapaih = 8/65 (estrato 'parto' fora dos dois lados); all = 8/75
  const ac = viaResumo.filter((r) => r.uf === "AC" && Number(r.year) === 2001);
  const want = { csapaih: [8, 65], all: [8, 75] };
  for (const r of ac) {
    const [n, t] = want[r.universe];
    if (Number(r.n) !== n || Number(r.t) !== t) fail(`selftest: AC/2001 ${r.universe} = ${r.n}/${r.t}, esperado ${n}/${t}`);
  }
  console.error("derive-icsap-summary: selftest OK (estratos = DISTINCT; resumo = cubo nos dois universos; AC/2001 cravado)");
}

// ---------------------------------------------------------------------------
// Derivação real: manifesto → baixa cada cubo ICSAP (verificando sha256) →
// estratos por ano + resumo único + sidecar de proveniência.
// ---------------------------------------------------------------------------
async function main() {
  const outDir = String(args.out ?? "data/sih-summary");
  const workDir = String(args.work ?? ".derive-cache");
  ensureDirs(outDir, workDir);

  const { manifest, base } = await loadManifest(args.manifest, fail);
  const wanted = wantedYears(manifest, args.years);

  const derivedFrom = {};
  const estratosMeta = {};
  const { q, run } = await duckdb();
  for (const year of wanted) {
    const { path: local, sha } = await ensureCube({ kind: "icsap", year, manifest, base, workDir, fail });
    derivedFrom[String(year)] = sha;
    const out = join(outDir, `sih_icsap_estratos_${year}.parquet`);
    await run(sqlEstratos(local, out));
    const [{ rows }] = await q(`SELECT count(*) AS rows FROM read_parquet('${posix(out)}')`);
    estratosMeta[String(year)] = { rows: Number(rows) };
    console.error(`derive-icsap-summary: ${year} estratos ok (${rows} estratos, ${statSync(out).size} bytes)`);
  }

  const resumoPath = join(outDir, "sih_icsap_resumo.parquet");
  await run(sqlResumo(join(workDir, "sih_icsap_*.parquet"), resumoPath));
  const [{ rows: resumoRows }] = await q(`SELECT count(*) AS rows FROM read_parquet('${posix(resumoPath)}')`);
  const totals = await q(`SELECT universe, SUM(n_icsap) AS n_icsap FROM read_parquet('${posix(resumoPath)}') WHERE csap_group IS NOT NULL GROUP BY universe ORDER BY universe`);

  writeProvenance(outDir, "icsap_summary_provenance.json", {
    builder: { name: "derive-icsap-summary.mjs", version: VERSION },
    source: "cubos sih_icsap_*.parquet publicados no canal sih/cubos/ (função pura; nada dos microdados)",
    manifest_generated_at: manifest.generated_at ?? null,
    derived_from: derivedFrom,
    files: {
      resumo: { rows: Number(resumoRows) },
      estratos: estratosMeta,
    },
    totals: Object.fromEntries(totals.map((t) => [t.universe, Number(t.n_icsap)])),
  });
  console.error(`derive-icsap-summary: resumo ok (${resumoRows} linhas, ${statSync(resumoPath).size} bytes; anos ${wanted[0]}–${wanted[wanted.length - 1]})`);
}

if (args.selftest === true) {
  await selftest();
} else {
  await main();
}
