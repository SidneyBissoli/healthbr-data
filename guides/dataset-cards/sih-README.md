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
  - hospital-admissions
  - morbidity
  - sus
pretty_name: "SIH — Hospital Admission Records (Brazil, 1992–2026)"
size_categories:
  - 100M<n<1B
task_categories:
  - tabular-classification
source_datasets:
  - original
---

# SIH — Hospital Admission Records (Brazil, 1992–2026)

Individual-level hospital admission records from Brazil's Hospital
Information System (SIH/SUS), covering 35 years of public hospital data.
Each record corresponds to one Reduced Hospital Admission Authorization
(AIH Reduzida — RD) and includes patient demographics, diagnoses (ICD-9
for 1992–1997, ICD-10 from 1998 onward), procedures, length of stay,
costs, and outcome. Converted from legacy .dbc files to Apache Parquet.

**Part of the [healthbr-data](https://huggingface.co/SidneyBissoli) project** — open redistribution of Brazilian public health data.

## Summary

| Item | Detail |
|------|--------|
| **Official source** | DATASUS FTP / Ministry of Health |
| **Temporal coverage** | 1992–2026 |
| **Geographic coverage** | All 27 Brazilian states (by municipality of hospitalization) |
| **Granularity** | Individual: one row per hospital admission (AIH) |
| **Volume** | 415M+ records (11,011 .dbc files processed) |
| **Format** | Apache Parquet, partitioned by `ano/mes/uf` |
| **Data types** | All fields stored as `string` (preserves original format) |
| **Update frequency** | Monthly (source publishes ~2–3 months after competency month) |
| **License** | CC-BY 4.0 |

## Resumo em português

**SIH — Registros de Internações Hospitalares (Brasil, 1992–2026)**

Microdados individuais de internações hospitalares do Sistema de Informações
Hospitalares do SUS (SIH/SUS), cobrindo 35 anos de dados hospitalares
públicos. Cada registro corresponde a uma Autorização de Internação
Hospitalar Reduzida (AIH-RD) e inclui dados demográficos do paciente,
diagnósticos (CID-9 para 1992–1997, CID-10 a partir de 1998), procedimentos,
tempo de permanência, custos e desfecho. Convertidos de arquivos .dbc legados
para Apache Parquet.

| Item | Detalhe |
|------|---------|
| **Fonte oficial** | FTP DATASUS / Ministério da Saúde |
| **Cobertura temporal** | 1992–2026 |
| **Cobertura geográfica** | Todos os 27 estados brasileiros (por município de internação) |
| **Granularidade** | Individual: uma linha por internação hospitalar (AIH) |
| **Volume** | 415M+ registros (11.011 arquivos .dbc processados) |
| **Formato** | Apache Parquet, particionado por `ano/mes/uf` |
| **Atualização** | Mensal (fonte publica ~2–3 meses após o mês de competência) |

> Para documentação completa em português, consulte o
> [repositório do projeto](https://github.com/SidneyBissoli/healthbr-data).

## Data access

Data is hosted on Cloudflare R2 and accessed via S3-compatible API. The
credentials below are **read-only** and intended for public use.

### R (Arrow)

```r
library(arrow)
library(dplyr)

Sys.setenv(
  AWS_ENDPOINT_URL      = "https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com",
  AWS_ACCESS_KEY_ID     = "28c72d4b3e1140fa468e367ae472b522",
  AWS_SECRET_ACCESS_KEY = "2937b2106736e2ba64e24e92f2be4e6c312bba3355586e41ce634b14c1482951",
  AWS_DEFAULT_REGION    = "auto"
)

# Open a single partition (year/month/state)
ds <- open_dataset(
  "s3://healthbr-data/sih/ano=2024/mes=01/uf=SP/",
  format = "parquet"
)

# Example: hospital admissions in São Paulo, Jan 2024, by diagnosis
ds |>
  collect() |>
  count(DIAG_PRINC, sort = TRUE) |>
  head(20)
```

> **Important:** Point to specific partitions (`ano=YYYY/mes=MM/uf=XX/`),
> not to the dataset root. The root contains `README.md` and `manifest.json`,
> which Arrow cannot read as Parquet files. You can also open broader paths
> like `ano=YYYY/` or `ano=YYYY/mes=MM/` to load multiple partitions at once.

### Python (PyArrow)

```python
import pyarrow.dataset as pds
import pyarrow.fs as fs

s3 = fs.S3FileSystem(
    endpoint_override="https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com",
    access_key="28c72d4b3e1140fa468e367ae472b522",
    secret_key="2937b2106736e2ba64e24e92f2be4e6c312bba3355586e41ce634b14c1482951",
    region="auto"
)

# Single partition (year/month/state)
dataset = pds.dataset(
    "healthbr-data/sih/ano=2024/mes=01/uf=SP/",
    filesystem=s3,
    format="parquet"
)

# Example: admissions in São Paulo, Jan 2024
df = dataset.to_table().to_pandas()
print(df.head())
print(f"Records: {len(df)}, Columns: {len(df.columns)}")
```

> **Note:** These credentials are **read-only** and safe to use in scripts.
> The bucket does not allow anonymous S3 access — credentials are required.
> Point to specific partitions, not the dataset root (see note above).

## File structure

```
s3://healthbr-data/sih/
  README.md
  manifest.json
  ano=1992/
    mes=01/
      uf=AC/
        part-0.parquet
      uf=AL/
        part-0.parquet
      ...
    mes=02/
      ...
  ...
  ano=2026/
    mes=01/
      ...
```

## Historical schemas

The AIH form underwent major revisions from 1992 to 2015. The dataset
preserves 14 distinct schemas:

| Period | Columns | Key characteristics |
|--------|:-------:|---------------------|
| 1992–1993 | 35 | Start of computerization; ICD-9; 2-digit year |
| 1994 | 39 | |
| 1995–1997 | 41–42 | ICD-9; dates as YYMMDD |
| 1998 | 41 | **Transition:** ICD-10, 8-digit dates, 4-digit year |
| 1999–2001 | 52–60 | +ICU fields, +management fields |
| 2002–2005 | 68–69 | +CNES (2004) |
| 2006–2007 | 75 | |
| 2008–2010 | 86 | **FTP era change;** SIGTAP 10-digit procedures; +RACA_COR |
| 2011–2012 | 93 | |
| 2013 | 95 | |
| 2014–2026 | 113 | **Stabilized** — +DIAGSEC1–DIAGSEC9 |

The number of columns varies by year. Columns not present in a given era
will be absent from that partition's Parquet file. Use
`open_dataset(unify_schemas = TRUE)` in Arrow to query across eras
(missing columns filled with `null`).

## Schema (modern era, 2014–2026, 113 columns)

Key variables in the most recent schema:

| Variable | Description |
|----------|-------------|
| `UF_ZI` | State code (processing) |
| `ANO_CMPT` | Competency year |
| `MES_CMPT` | Competency month |
| `N_AIH` | AIH number (admission ID) |
| `CNES` | Health facility code (CNES) |
| `MUNIC_MOV` | Municipality of hospitalization (IBGE code) |
| `MUNIC_RES` | Patient's municipality of residence (IBGE code) |
| `NASC` | Patient's date of birth |
| `SEXO` | Sex (1=male, 3=female) |
| `IDADE` | Age |
| `RACA_COR` | Race/color |
| `DT_INTER` | Admission date |
| `DT_SAIDA` | Discharge date |
| `DIAS_PERM` | Length of stay (days) |
| `DIAG_PRINC` | Primary diagnosis (ICD-10) |
| `DIAGSEC1`–`DIAGSEC9` | Secondary diagnoses (ICD-10) |
| `PROC_REA` | Procedure performed (SIGTAP code) |
| `VAL_TOT` | Total amount (R$) |
| `MORTE` | Death during admission (0=no, 1=yes) |
| `CEP` | Patient's ZIP code |
| `CAR_INT` | Admission type |
| `COMPLEX` | Complexity level |

> For the complete variable list across all 14 schemas, see the
> [exploration document](https://github.com/SidneyBissoli/healthbr-data/blob/main/docs/sih/exploration-pt.md).

## Source and processing

**Original source:** 11,011 .dbc files from the DATASUS FTP server,
covering two directories: `200801_/Dados/` (modern era, 5,856 files) and
`199201_200712/Dados/` (legacy era, 5,155 files). Scope: RD (AIH Reduzida)
only — SP, RJ, ER file types are future expansions.

**Processing:** .dbc → R (`read.dbc::read.dbc()`) → all fields cast to
`character` → Parquet (`arrow::write_parquet()`) → upload to R2 (`rclone`).
No value transformations are applied — field values are published exactly as
provided by the Ministry of Health. Dates in the legacy era (YYMMDD) are
preserved as-is; ICD-9 codes (1992–1997) are not converted to ICD-10.

**Bootstrap:** Processed in 2 sprints: Sprint 1 (2008–2026, 5,856 files,
217.8M records, ~18h) + Sprint 2 (1992–2007, 5,155 files, 197.6M records,
~12–15h). Total: 11,011 files, 415,372,502 records, 16.1 GiB on R2.

## Known limitations

1. **Government data, not ours.** Values are preserved exactly as in the
   original .dbc files, including any inconsistencies or missing data.
2. **Fourteen historical schemas.** The number of columns varies from 35
   (1992) to 113 (2014+). Queries spanning multiple eras must handle
   missing columns.
3. **All fields are strings.** Numeric fields (costs, age, length of stay)
   and dates must be parsed by the user.
4. **RD only.** This dataset contains only AIH Reduzida (processed
   admissions). SP (professional services), RJ (rejected), and ER (errors)
   are not included.
5. **ICD-9 in legacy era (1992–1997).** Diagnosis codes use ICD-9 (6
   characters) before 1998 and ICD-10 (3–4 characters) from 1998 onward.
   No conversion is applied.
6. **Legacy date format (1992–1997).** Dates use YYMMDD (6 digits) in the
   legacy era and YYYYMMDD (8 digits) from 1998 onward. No conversion is
   applied.
7. **19 historical gaps.** 19 files from the legacy era were not found on
   the FTP server (mostly Roraima 1995–2000, plus AC 1994 and AP 2007).
   These are Ministry-side gaps, not pipeline failures.
8. **Monthly partitioning.** Unlike SINASC (annual), SIH is partitioned
   by year/month/state, reflecting the monthly publication frequency.

## Related datasets

| Dataset | Period | Records | Link |
|---------|--------|---------|------|
| SINASC (live births) | 1994–2022 | 85M+ | [sinasc](https://huggingface.co/datasets/SidneyBissoli/sinasc) |
| SI-PNI Microdados (vaccination) | 2020–present | 736M+ | [sipni-microdados](https://huggingface.co/datasets/SidneyBissoli/sipni-microdados) |
| SI-PNI COVID (vaccination) | 2021–present | 608M+ | [sipni-covid](https://huggingface.co/datasets/SidneyBissoli/sipni-covid) |
| SI-PNI Agregados — Doses | 1994–2019 | 84M+ | [sipni-agregados-doses](https://huggingface.co/datasets/SidneyBissoli/sipni-agregados-doses) |
| SI-PNI Agregados — Cobertura | 1994–2019 | 2.8M+ | [sipni-agregados-cobertura](https://huggingface.co/datasets/SidneyBissoli/sipni-agregados-cobertura) |
| SI-PNI Dicionários | Static | 263 rows | [sipni-dicionarios](https://huggingface.co/datasets/SidneyBissoli/sipni-dicionarios) |

## Citation

```bibtex
@misc{healthbrdata,
  author = {Sidney da Silva Bissoli},
  title  = {healthbr-data: Redistribution of Brazilian Public Health Data},
  year   = {2026},
  url    = {https://huggingface.co/datasets/SidneyBissoli/sih},
  note   = {Original source: Ministry of Health / DATASUS}
}
```

## Contact

- **GitHub:** [https://github.com/SidneyBissoli](https://github.com/SidneyBissoli)
- **Hugging Face:** [https://huggingface.co/SidneyBissoli](https://huggingface.co/SidneyBissoli)
- **E-mail:** sbissoli76@gmail.com

---

*Last updated: 2026-03-09*
