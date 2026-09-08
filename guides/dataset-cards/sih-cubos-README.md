---
language:
  - pt
license: cc-by-4.0
tags:
  - health
  - brazil
  - public-health
  - parquet
  - datasus
  - sih
  - hospitalizations
  - icsap
  - derived
pretty_name: "SIH cubes — yearly aggregates of hospital admissions (Brazil, 1992–2025)"
size_categories:
  - 100M<n<1B
task_categories:
  - tabular-classification
source_datasets:
  - SidneyBissoli/sih-rd
---

# SIH cubes — yearly aggregates of hospital admissions (Brazil, 1992–2025)

Three Parquet cubes per year, aggregated from the individual admission
records in [`sih/rd/`](sih-rd-README.md) (SIH/SUS, AIH Reduzida) by the
`sih-cubos` pipeline of [healthbr-data](https://github.com/SidneyBissoli/healthbr-data)
(`scripts/pipeline/sih-cubos/build-aggregations.R`; until 2026-09-08 the builder
lived in [sih-br-mcp](https://github.com/SidneyBissoli/sih-br-mcp), which now
consumes this channel). They are **derived data**: the Ministry of
Health / DATASUS is the source, `sih/rd/` is the redistribution the cubes
were read from, and each year ships with a provenance sidecar naming the
exact partitions (URL, MD5, size and mirror download date of every `.dbc`).

**Part of the [healthbr-data](https://huggingface.co/SidneyBissoli) project** — open redistribution of Brazilian public health data.

## Summary

| Item | Detail |
|------|--------|
| **Upstream source** | Ministry of Health / DATASUS, SIH/SUS (RD files) via `sih/rd/` |
| **Temporal coverage** | 1992–2025, one cube set per year of admission (`DT_INTER`) |
| **Geographic coverage** | All 27 states; municipality of residence from 1998 |
| **Granularity** | Aggregated counts (no individual records) |
| **Files per year** | `sih_causas_<year>.parquet`, `sih_series_<year>.parquet`, `sih_icsap_<year>.parquet`, `sih_provenance_<year>.json` |
| **Manifest** | `sih/cubos/manifest.json` — size and SHA-256 of every file and of the classification tables |
| **Classification tables** | `sih/cubos/tables/*.json` (ICD-9 decoding, ICSAP lists, csapAIH universe) — the contract consumers copy and verify by SHA-256 |
| **Builder** | healthbr-data `scripts/pipeline/sih-cubos/build-aggregations.R` ≥ 2.7.0 (2.5.0–2.6.1 in sih-br-mcp; version and git commit recorded in the sidecar) |
| **Rebuild** | `rebuild-sih-cubes.yml`: Tuesday 06:00 UTC and after every mirror maintenance; only the years whose `sih/rd/` partitions changed |
| **License** | CC-BY 4.0 (upstream data is public; the aggregation is this project's) |

## Resumo em português

**Cubos do SIH — agregados anuais de internações hospitalares (Brasil, 1992–2025)**

Três cubos Parquet por ano, agregados a partir dos microdados de `sih/rd/`
pela pipeline `sih-cubos` do [healthbr-data](https://github.com/SidneyBissoli/healthbr-data)
(até 08/09/2026, pelo sih-br-mcp, hoje consumidor do canal).
São dados **derivados**: a fonte é o Ministério da Saúde / DATASUS, `sih/rd/`
é a redistribuição de onde os cubos foram lidos, e cada ano traz um sidecar
de proveniência (`sih_provenance_<ano>.json`) com as partições exatas (URL,
MD5, tamanho e data de download de cada `.dbc`). O cubo do ano Y contém as
internações com data de internação em Y, lidas das competências Y-01..Y-12 e
(Y+1)-01..04 (99,7–99,9 % das internações do ano).

## Cubes

All three cubes carry `cid_revision` (9 = ICD-9 coded admission, 1992–1997;
10 = ICD-10, 1998 onward; 1997 has both, see *Eras*).

| Cube | Keys | Measures |
|------|------|----------|
| `sih_causas_<year>` | `year, month, uf, cid_chapter, cid_revision, cid_group, sex, age, race, is_csap, csap_group` | `n, days, value, deaths` |
| `sih_series_<year>` | `year_month, uf, cid_chapter, cid_revision` | `n, deaths` |
| `sih_icsap_<year>` | `year, uf, municipality_code, cid_revision, csap_group, sex, age, race` | `n, days, value, deaths, n_total` |

- `age` is completed years (`COD_IDADE` 2 = days and 3 = months both map to 0;
  builders before 2.5.0 swapped the two and gave newborns aged 12–30 days
  `age` 1–2 — every year was rebuilt in September 2026).
- `sex`: `M`, `F` (`SEXO` 1 / 3, and 2 in the 1992–1997 layout) or `I`.
- `race`: `branca, preta, parda, amarela, indigena, ignorado`; **null in every
  row before 2008** (`RACA_COR` only exists in the AIH layout from 2008).
- `is_csap` / `csap_group`: Brazilian list of Ambulatory Care Sensitive
  Conditions (ICSAP), Portaria MS/SAS 221/2008, groups g01–g19.
- `exclusion` (causes and ICSAP cubes): the ICSAP **universe** of the R package
  [csapAIH](https://github.com/fulvionedel/csapAIH) (Nedel), the method used in
  the Brazilian literature — `procedimento_obstetrico` (obstetric procedure:
  the package's 10 SIGTAP codes from 2008; the delivery/cesarean/abortion
  groups of DATASUS `PROCOBST.CNV` for the old 8-digit table until 2007),
  `parto` (delivery diagnosis O80–O84; ICD-9 650, 669.5–669.7),
  `longa_permanencia` (long-stay AIH, `IDENT = 5`), or **null = inside the
  universe**. The CSAP classification is kept for every row; the literature's
  ICSAP share excludes the marked rows from numerator and denominator.
- **ICSAP cube denominators:** the cube has one row per (stratum × CSAP group)
  plus one row per stratum **without** any ICSAP admission (`csap_group` null,
  `n = 0`). `n_total` is the total number of admissions of the stratum
  (`year, uf, municipality_code, cid_revision, sex, age, race, exclusion`),
  repeated in every row of that stratum: the ICSAP share is `sum(n) /
  sum(n_total over DISTINCT strata)` — never `sum(n_total)` over rows — and,
  for the csapAIH convention, over rows where `exclusion` is null only.

## Eras (what changes along the series)

| Years | Diagnosis | `uf` / municipality | `race` | `value` |
|-------|-----------|---------------------|--------|---------|
| 1992–1997 | **ICD-9** (`cid_revision = 9`): `cid_group` is the 3-digit ICD-9 category (`"466"`, `"E883"`, `"V01"`), `cid_chapter` the equivalent ICD-10 chapter; ICSAP from a **derived, non-official ICD-9 list** (`sih/cubos/tables/csap-groups-cid9.json`; g03 and g05 not comparable with 1998+) | `uf` = state of the **hospital file** (`MUNIC_RES` missing in 1992–93 and empty until Nov/1994); `municipality_code` null | null | nominal, in the currency of the billing month (Cr$ until 1993-06, CR$ 1993-07..1994-06, R$ from 1994-07) — see `currency` in the sidecar |
| 1998–2007 | ICD-10 | `uf` = state of **residence**; municipality of residence | null | R$ nominal |
| 2008–2025 | ICD-10 | residence | present | R$ nominal |

Other 1992–1997 facts recorded in the sidecars: admissions without
`DT_INTER` in the source (competencies 1992-01..04 and 1993-01) enter the cube
with the billing month as month (`records_date_imputed`); 1997 also contains
the admissions billed in 1998-01..04, already coded in ICD-10
(`cid_revision = 10`), whose ICSAP share is underestimated in Jan–Feb 1998
(adaptation to ICD-10). Full documentation: sih-br-mcp
`docs/analise-002-sih-1992-1997.md` (source study) and
`docs/analise-003-icsap-cid9.md` (derived ICSAP list and its validation on
the 1997/98 boundary).

## Provenance sidecar

`sih_provenance_<year>.json` (`manifest_version` 1.1.0) records, per year:
the competency window and whether it is complete, the file states read, every
`sih/rd/` partition (path, SHA-256, record count, source `.dbc` URL, MD5,
size, mirror processing timestamp), builder version and git commit, totals
(`records_read`, `records_in_cube`, rows per cube, `records_date_imputed`),
`cid_revision` counts, `icsap_list_revision` per revision, `not_official_icsap`,
`icsap_comparability` (ICD-9 years), `uf_basis` (`arquivo` / `residencia`),
`municipality_available`, `currency`, `columns_missing` and human-readable
notes.

## Reproducibility & provenance

- **Pipeline:** `scripts/pipeline/sih-cubos/` in the healthbr-data repository —
  `build-aggregations.R` (builder), `rebuild-cubes.R` (CLI), `cube-delta.mjs`,
  `cubes-manifest.mjs`, `publish-cubes.sh`; recipe in its `README.md`, operational
  reference in `docs/reference-pipelines-pt.md` §16.
- **Chain:** DATASUS `.dbc` → `sih/rd/` (1:1 Parquet, manifest with MD5 and download
  date) → builder (reads `sih/rd/` through the R package healthbR) → `sih/cubos/`.
  The sidecar of each year lists every partition read, so a cube can be traced to the
  exact source files.
- **Gates before publishing:** partition counts must equal the `sih/rd/` manifest;
  the new sidecar is compared with the published one (lost partitions, drops > 1 %,
  regressed windows and unrequested scope changes fail the run); the reference
  consumer (sih-br-mcp) is started on the new cubes; every cube is verified with DuckDB
  against its sidecar before the manifest is signed.
- **Classification tables** (`sih/cubos/tables/`): `cid9-codes.json` and
  `cid9-chapters.json` are generated from DATASUS's `TAB_SIH_199201-199712.zip`
  (`CID9_*.CNV`; a copy is kept in `sih/cubos/insumos/`, SHA-256
  `b433310785e08b5d2d0c5a438f495ac6b2af9a10d86d8741a3252bc268b1ff88`),
  `csap-universe.json` from `PROCOBST.CNV` plus the csapAIH code lists;
  `csap-groups.json` transcribes Portaria MS/SAS 221/2008 and `csap-groups-cid9.json`
  is the derived ICD-9 list (sih-br-mcp `docs/analise-003-icsap-cid9.md`).
  Generators: `scripts/pipeline/sih-cubos/tables/generators/`.
- **Build log:** `data/controle_versao_sih_cubos.csv` in the repository — one row per
  (year, build) with builder version, git commit, healthbR version, partitions, totals
  and the mirror manifest date; the channel (`manifest.json` + sidecars) is the state.
- **State is the channel:** no sidecar is versioned in git; rebuilds start from the
  published sidecar (window, file states) and overwrite the year in place.

## Data access

```r
library(arrow); library(dplyr)
base <- "https://data.sidneybissoli.com/sih/cubos"
causas <- read_parquet(url(sprintf("%s/sih_causas_%d.parquet", base, 2023)))
causas |> group_by(cid_chapter) |> summarise(n = sum(n)) |> arrange(desc(n))
```

```python
import pandas as pd
base = "https://data.sidneybissoli.com/sih/cubos"
icsap = pd.read_parquet(f"{base}/sih_icsap_2023.parquet")
universe = icsap[icsap["exclusion"].isna()]          # csapAIH convention
strata = ["year", "uf", "municipality_code", "cid_revision", "sex", "age", "race", "exclusion"]
share = universe["n"].sum() / universe.drop_duplicates(strata)["n_total"].sum()
```

The same files are served from the `r2.dev` URL of the bucket; the
[sih-br-mcp](https://github.com/SidneyBissoli/sih-br-mcp) server downloads
them on demand (SHA-256 checked against the manifest) and exposes them as MCP
tools with the era notes above attached to every answer.

## Citation

Ministério da Saúde. Sistema de Informações Hospitalares do SUS (SIH/SUS),
AIH reduzida. Brasília: DATASUS. Aggregated by the
healthbr-data `sih-cubos` pipeline (`build-aggregations.R`) from the `sih/rd/`
Parquet mirror; served to MCP clients by sih-br-mcp. Derived
ICSAP list for 1992–1997 is not an official act.
