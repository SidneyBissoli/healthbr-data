#!/usr/bin/env node
// Deriva os artefatos PRÉ-AGREGADOS do cubo de CAUSAS a partir dos cubos
// PUBLICADOS no canal — PLAN-006 do sih-br-mcp (sih:causas-pre-agregada,
// decisão do usuário em 10/09/2026). Função pura dos cubos: não toca FTP nem
// microdados. Irmão de derive-icsap-summary.mjs (PLAN-005); a máquina de
// baixar cubo conferindo hash é a mesma (summary-lib.mjs) e o `.derive-cache`
// é compartilhado.
//
// Por quê: o cubo de causas é o último caminho caro do servidor remoto —
// 1.253 MB nos 34 anos, contra 389 MB da ICSAP (que já tem resumo) e 1,2 MB
// das séries. Ele responde "quantas internações", "quanto o SUS gastou",
// "quais as principais causas" e "qual a taxa por 100 mil": as perguntas mais
// naturais. Pré-agregar derruba a série de 34 anos de 12,62 s para 0,01 s com
// uma thread (medido em 09-10/09/2026), e o download de 1,25 GB para 0,4 MB.
//
// Artefatos (publicados em sih/cubos/, bloco `causas_summary` do manifesto):
// - sih_causas_resumo.parquet — GRÃO A, UM arquivo com todos os anos:
//   year × uf × cid_chapter × cid_revision × is_csap × exclusion, com as
//   quatro medidas (n, days, value, deaths). Responde sozinho a série longa de
//   internações, óbitos, dias e gasto por UF e capítulo.
// - sih_causas_estratos_YYYY.parquet — GRÃO B, por ano: o grão A MAIS sexo,
//   faixa etária quinquenal e raça. Serve os recortes demográficos sem baixar
//   o cubo pesado (1995: 0,8 MB contra 22,8 MB).
// - causas_summary_provenance.json — derived_from com o sha256 do cubo-fonte
//   POR ANO (contrato de frescor: quem assina o manifesto recusa resumo
//   derivado de cubo que não é o publicado) e os totais por ano.
//
// FORA do grão, de propósito (PLAN-006 §7): mês, categoria CID de 3 dígitos
// (`cid_group`) e grupo CSAP. O grão com a categoria de 3 dígitos custaria
// 333,1 MB e 694 s de derivação — medido e rejeitado. Quem pede isso segue no
// cubo de causas, com o número certo.
//
// A FAIXA ETÁRIA é a MESMA de pop_uf_agregado.parquet ("0-4" … "75-79",
// "80 e +"), e por isso o consumidor reusa aggregatedAgeGroupsFor(): um
// recorte por idade só é atendível se começar em múltiplo de 5 e terminar em 4
// ou 9, ou for 80 e mais. Idade ausente ou negativa vira faixa NULA — ela
// entra no total e fica fora de qualquer recorte etário, como a idade ignorada
// da população.
//
// Uso:
//   node derive-causas-summary.mjs --out data/sih-summary \
//     [--manifest https://data.sidneybissoli.com/sih/cubos/manifest.json] \
//     [--work .derive-cache] [--years 1992,1993 | all]
//   node derive-causas-summary.mjs --selftest
//
// Determinismo: todo COPY tem ORDER BY completo (GROUP BY sem ORDER BY sai na
// ordem em que as threads terminam) e `value` soma como DECIMAL(18,2) (a soma
// paralela de DOUBLE muda o último dígito).
//
// PROVA DENTRO DA DERIVAÇÃO: cada ano do grão B é conferido contra o CUBO nas
// quatro medidas antes de seguir, e o grão A — que é uma rolagem do B, não uma
// segunda leitura do cubo — é conferido ano a ano contra os mesmos totais.
// Nada sai daqui sem reproduzir o cubo de onde veio.
import { statSync } from "node:fs";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { duckdb, ensureCube, ensureDirs, failWith, loadManifest, parseArgs, posix, wantedYears, writeProvenance } from "./summary-lib.mjs";

const VERSION = "1.0.0";

const args = parseArgs();
const fail = failWith("derive-causas-summary");

// ---------------------------------------------------------------------------
// SQL — os dois grãos. As chaves e as medidas têm os MESMOS NOMES do cubo de
// causas, de propósito: o consumidor (src/db/duckdb.ts) troca só o
// read_parquet e o resto do SQL — filtros, agrupamento, ORDER BY — continua
// valendo palavra por palavra.
// ---------------------------------------------------------------------------
const GRAO_A_KEYS = ["year", "uf", "cid_chapter", "cid_revision", "is_csap", "exclusion"];
const GRAO_B_KEYS = [...GRAO_A_KEYS, "sex", "age_group", "race"];

// `cid_revision` só existe nos cubos do builder >= 2.5.0; nula significa
// CID-10 (a coluna é constante 10 em 1998+). Mesma defesa do consumidor.
const CID_REVISION = "COALESCE(cid_revision, 10) AS cid_revision";

// Faixa quinquenal idêntica à de pop_uf_agregado.parquet (AGGREGATED_AGE_GROUPS
// do consumidor): "0-4" … "75-79", "80 e +", e NULA para idade ausente ou
// absurda. `floor` e não CAST: o CAST de DOUBLE para INTEGER no DuckDB
// ARREDONDA, o que jogaria 4 anos na faixa "5-9".
const AGE_GROUP = `CASE
      WHEN age IS NULL OR age < 0 THEN NULL
      WHEN age >= 80 THEN '80 e +'
      ELSE CAST(CAST(floor(age / 5.0) * 5 AS INTEGER) AS VARCHAR) || '-' || CAST(CAST(floor(age / 5.0) * 5 + 4 AS INTEGER) AS VARCHAR)
    END AS age_group`;

const MEASURES = "SUM(n) AS n, SUM(days) AS days, SUM(CAST(value AS DECIMAL(18,2))) AS value, SUM(deaths) AS deaths";

/** Grão B (fino) de UM ano, direto do cubo daquele ano. */
function sqlEstratos(cubePath, outPath) {
  const keys = GRAO_B_KEYS.map((k) => (k === "cid_revision" ? CID_REVISION : k === "age_group" ? AGE_GROUP : k));
  const groupKeys = GRAO_B_KEYS.map((k) => (k === "cid_revision" ? "COALESCE(cid_revision, 10)" : k === "age_group" ? "age_group" : k));
  return `COPY (
    SELECT ${keys.join(", ")}, ${MEASURES}
    FROM read_parquet('${posix(cubePath)}')
    GROUP BY ${groupKeys.join(", ")}
    ORDER BY ${GRAO_B_KEYS.join(", ")}
  ) TO '${posix(outPath)}' (FORMAT PARQUET, COMPRESSION ZSTD)`;
}

/**
 * Grão A (grosso), TODOS os anos, ROLADO do grão B — e não relido dos cubos.
 * As chaves de A são subconjunto das de B e as quatro medidas são aditivas,
 * então a rolagem é exata; e como cada ano do B já foi conferido contra o
 * cubo, A herda a prova. Custa a leitura de ~56 MB em vez de 1,25 GB.
 */
function sqlResumo(estratosGlob, outPath) {
  return `COPY (
    SELECT ${GRAO_A_KEYS.join(", ")}, SUM(n) AS n, SUM(days) AS days, SUM(value) AS value, SUM(deaths) AS deaths
    FROM read_parquet('${posix(estratosGlob)}', union_by_name = true)
    GROUP BY ${GRAO_A_KEYS.join(", ")}
    ORDER BY ${GRAO_A_KEYS.join(", ")}
  ) TO '${posix(outPath)}' (FORMAT PARQUET, COMPRESSION ZSTD)`;
}

/** As quatro medidas de uma fonte, por ano — a moeda da conferência. */
function sqlTotais(path) {
  return `SELECT year, SUM(n) AS n, SUM(days) AS days, SUM(CAST(value AS DECIMAL(18,2))) AS value, SUM(deaths) AS deaths
    FROM read_parquet('${posix(path)}', union_by_name = true) GROUP BY year ORDER BY year`;
}

const numeric = (rows) =>
  rows.map((r) => ({ year: Number(r.year), n: Number(r.n), days: Number(r.days), value: Number(r.value), deaths: Number(r.deaths) }));

function compararTotais(rotuloA, a, rotuloB, b) {
  const J = (v) => JSON.stringify(v);
  if (J(numeric(a)) !== J(numeric(b))) {
    fail(`${rotuloA} não reproduz ${rotuloB}\n  ${rotuloA}: ${J(numeric(a))}\n  ${rotuloB}: ${J(numeric(b))}`);
  }
}

// ---------------------------------------------------------------------------
// Selftest: mini-cubo embutido com o que costuma quebrar — as duas revisões
// CID, is_csap dos dois lados, exclusão nula e não nula, raça e sexo nulos,
// e as idades de FRONTEIRA da faixa quinquenal (0, 4, 5, 79, 80, 95 e nula).
// Confere que B reproduz o cubo nas quatro medidas, que A reproduz B, e crava
// o mapa de faixa etária.
// ---------------------------------------------------------------------------
async function selftest() {
  const dir = join(tmpdir(), `derive-causas-selftest-${process.pid}`);
  mkdirSync(dir, { recursive: true });
  const { q, run } = await duckdb();
  const cube = join(dir, "sih_causas_2001.parquet");
  await run(`COPY (
    SELECT * FROM (VALUES
      -- year, uf, cid_chapter, cid_revision, cid_group, sex, age, race, exclusion, is_csap, csap_group, month, n, days, value, deaths
      (2001, 'AC',  1, 10, 'A09', 'F',    0, 'branca', NULL,    true,  'g01', 1,  5, 20.0, 100.50, 1),
      (2001, 'AC',  1, 10, 'A09', 'F',    4, 'branca', NULL,    true,  'g01', 2,  3,  9.0,  50.25, 0),
      (2001, 'AC',  1, 10, 'A09', 'M',    5, 'preta',  NULL,    true,  'g01', 3,  2,  4.0,  10.00, 0),
      (2001, 'AC', 15, 10, 'O80', 'F',   25, 'parda',  'parto', false, NULL,  4,  9, 18.0, 222.22, 0),
      (2001, 'RR',  9, 10, 'I10', 'M',   79, NULL,     NULL,    true,  'g05', 5,  7, 30.0, 300.10, 2),
      (2001, 'RR',  9, 10, 'I10', 'M',   80, NULL,     NULL,    true,  'g05', 6,  1,  2.0,   7.77, 1),
      (2001, 'RR',  9, 10, 'I10', 'M',   95, 'ignorado', NULL,  true,  'g05', 7,  4,  8.0,  11.11, 0),
      (2001, 'RR', 19, 10, 'S00', NULL, NULL, NULL,    NULL,    false, NULL,  8,  6, 12.0,  33.33, 0),
      (2000, 'AC',  1,  9, '001', 'F',   30, 'branca', NULL,    true,  'g03', 9,  2,  4.0,  10.00, 0),
      (2000, 'AC',  1, NULL, '001', 'M',  70, 'preta',  NULL,    true,  'g03', 10, 1,  8.0,  22.40, 1)
    ) AS t(year, uf, cid_chapter, cid_revision, cid_group, sex, age, race, exclusion, is_csap, csap_group, month, n, days, value, deaths)
  ) TO '${posix(cube)}' (FORMAT PARQUET)`);

  const estr = join(dir, "sih_causas_estratos_2001.parquet");
  const resumo = join(dir, "resumo.parquet");
  await run(sqlEstratos(cube, estr));
  await run(sqlResumo(estr, resumo));

  // B reproduz o CUBO nas quatro medidas; A reproduz B.
  compararTotais("grão B", await q(sqlTotais(estr)), "o cubo", await q(sqlTotais(cube)));
  compararTotais("grão A", await q(sqlTotais(resumo)), "o grão B", await q(sqlTotais(estr)));

  // Faixa etária cravada nas fronteiras (0 e 4 na mesma; 79 e 80 em faixas diferentes; nula fica nula).
  const faixas = await q(`SELECT age_group, SUM(n) AS n FROM read_parquet('${posix(estr)}') GROUP BY age_group ORDER BY age_group NULLS FIRST`);
  // Comparado como conjunto: o rótulo da faixa é VARCHAR e ordena
  // lexicograficamente ("25-29" antes de "5-9"), como no arquivo de população —
  // quem exibe ordena pela lista canônica, não pelo texto.
  const ordenado = (o) => JSON.stringify(Object.fromEntries(Object.entries(o).sort(([a], [b]) => a.localeCompare(b))));
  const mapa = Object.fromEntries(faixas.map((f) => [f.age_group ?? "NULO", Number(f.n)]));
  const esperado = { NULO: 6, "0-4": 8, "5-9": 2, "25-29": 9, "30-34": 2, "70-74": 1, "75-79": 7, "80 e +": 5 };
  if (ordenado(mapa) !== ordenado(esperado)) {
    fail(`selftest: faixas etárias ${JSON.stringify(mapa)}, esperado ${JSON.stringify(esperado)}`);
  }

  // cid_revision nula vira 10 (o cubo tem uma linha assim, em 2000).
  const [{ revs }] = await q(`SELECT count(DISTINCT cid_revision) AS revs FROM read_parquet('${posix(resumo)}') WHERE year = 2000`);
  if (Number(revs) !== 2) fail(`selftest: 2000 devia ter as revisões 9 e 10 (nula vira 10), tem ${revs}`);

  // A exclusão é CHAVE do grão, não um universo: a linha de parto sobrevive nos dois artefatos.
  const [{ partos }] = await q(`SELECT SUM(n) AS partos FROM read_parquet('${posix(resumo)}') WHERE exclusion = 'parto'`);
  if (Number(partos) !== 9) fail(`selftest: exclusion='parto' devia somar 9, somou ${partos}`);

  console.error("derive-causas-summary: selftest OK (grão B = cubo nas 4 medidas; grão A = grão B; faixas etárias e cid_revision cravadas)");
}

// ---------------------------------------------------------------------------
// Derivação real: manifesto → baixa cada cubo de causas (verificando sha256) →
// grão B por ano (conferido contra o cubo) → grão A rolado do B (conferido
// contra os mesmos totais) → sidecar de proveniência.
// ---------------------------------------------------------------------------
async function main() {
  const outDir = String(args.out ?? "data/sih-summary");
  const workDir = String(args.work ?? ".derive-cache");
  ensureDirs(outDir, workDir);

  const { manifest, base } = await loadManifest(args.manifest, fail);
  const wanted = wantedYears(manifest, args.years);

  const derivedFrom = {};
  const estratosMeta = {};
  const totaisDoCubo = [];
  const { q, run } = await duckdb();
  for (const year of wanted) {
    const { path: local, sha } = await ensureCube({ kind: "causas", year, manifest, base, workDir, fail });
    derivedFrom[String(year)] = sha;
    const out = join(outDir, `sih_causas_estratos_${year}.parquet`);
    await run(sqlEstratos(local, out));
    const doCubo = await q(sqlTotais(local));
    const doGrao = await q(sqlTotais(out));
    compararTotais(`grão B de ${year}`, doGrao, `o cubo de ${year}`, doCubo);
    totaisDoCubo.push(...doCubo);
    const [{ rows }] = await q(`SELECT count(*) AS rows FROM read_parquet('${posix(out)}')`);
    const t = numeric(doCubo)[0];
    estratosMeta[String(year)] = { rows: Number(rows), n: t.n, days: t.days, value: t.value, deaths: t.deaths };
    console.error(`derive-causas-summary: ${year} grão B ok (${rows} linhas, ${statSync(out).size} bytes; ${t.n} internações conferidas contra o cubo)`);
  }

  const resumoPath = join(outDir, "sih_causas_resumo.parquet");
  await run(sqlResumo(join(outDir, "sih_causas_estratos_*.parquet"), resumoPath));
  compararTotais("grão A", await q(sqlTotais(resumoPath)), "os cubos", totaisDoCubo);
  const [{ rows: resumoRows }] = await q(`SELECT count(*) AS rows FROM read_parquet('${posix(resumoPath)}')`);

  const soma = numeric(totaisDoCubo).reduce(
    (a, r) => ({ n: a.n + r.n, days: a.days + r.days, value: a.value + r.value, deaths: a.deaths + r.deaths }),
    { n: 0, days: 0, value: 0, deaths: 0 },
  );
  writeProvenance(outDir, "causas_summary_provenance.json", {
    builder: { name: "derive-causas-summary.mjs", version: VERSION },
    source: "cubos sih_causas_*.parquet publicados no canal sih/cubos/ (função pura; nada dos microdados)",
    grain: {
      resumo: GRAO_A_KEYS,
      estratos: GRAO_B_KEYS,
      age_groups: "faixas quinquenais de pop_uf_agregado.parquet (0-4 … 75-79, 80 e +); idade ausente ou negativa = faixa nula",
      out_of_grain: ["month", "cid_group", "csap_group"],
    },
    manifest_generated_at: manifest.generated_at ?? null,
    derived_from: derivedFrom,
    files: {
      resumo: { rows: Number(resumoRows) },
      estratos: estratosMeta,
    },
    totals: { n: soma.n, days: soma.days, value: Math.round(soma.value * 100) / 100, deaths: soma.deaths },
  });
  console.error(
    `derive-causas-summary: grão A ok (${resumoRows} linhas, ${statSync(resumoPath).size} bytes; anos ${wanted[0]}–${wanted[wanted.length - 1]}; ${soma.n} internações conferidas contra os cubos)`,
  );
}

if (args.selftest === true) {
  await selftest();
} else {
  await main();
}
