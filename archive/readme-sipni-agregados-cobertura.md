---
language:
  - pt
license: cc-by-4.0
tags:
  - health
  - vaccination
  - brazil
  - public-health
  - parquet
  - sipni
  - datasus
  - immunization
  - aggregated
  - coverage
  - historical
pretty_name: "SI-PNI — Aggregated Vaccination Coverage (1994–2019)"
size_categories:
  - 1M<n<10M
task_categories:
  - tabular-classification
  - time-series-forecasting
source_datasets:
  - original
---

# SI-PNI — Aggregated Vaccination Coverage (1994–2019)

[🇧🇷 Resumo em Português](#resumo-em-português)

Pre-calculated vaccination coverage rates from Brazil's National
Immunization Program (SI-PNI), covering the historical period 1994–2019.
Each row contains dose counts, target population, and coverage percentage
for a municipality and vaccine combination. Redistributed as partitioned
Apache Parquet files from original .dbf files on the DATASUS FTP server.

## Summary

| Item | Detail |
|------|--------|
| **Official source** | DATASUS FTP / Ministry of Health (Brazil) |
| **Temporal coverage** | 1994–2019 (26 years) |
| **Geographic coverage** | All Brazilian municipalities |
| **Granularity** | Municipality × vaccine (× dose × age group until 2012) |
| **Records** | **2,762,327** |
| **Format** | Apache Parquet, partitioned by `ano/uf` (year/state) |
| **Data types** | All fields stored as `string` (preserves original formatting) |
| **Update frequency** | Static (historical data, no updates expected) |
| **License** | CC-BY 4.0 |

## Data access

### R (Arrow)

```r
library(arrow)

# S3 endpoint configuration (anonymous read access)
Sys.setenv(
  AWS_ENDPOINT_URL = "https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com",
  AWS_ACCESS_KEY_ID = "",
  AWS_SECRET_ACCESS_KEY = "",
  AWS_DEFAULT_REGION = "auto"
)

# Connect to the dataset
ds <- open_dataset(
  "s3://healthbr-data/sipni/agregados/cobertura/",
  format = "parquet",
  unify_schemas = TRUE
)

# Example: coverage by vaccine in Minas Gerais, 2015
ds |>
  filter(ano == "2015", uf == "MG") |>
  group_by(IMUNO) |>
  summarise(
    media_cobertura = mean(as.numeric(COBERT), na.rm = TRUE)
  ) |>
  collect()
```

### Python (PyArrow)

```python
import pyarrow.dataset as pds
import pyarrow.fs as fs

s3 = fs.S3FileSystem(
    endpoint_override="https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com",
    region="auto",
    anonymous=True
)

dataset = pds.dataset(
    "healthbr-data/sipni/agregados/cobertura/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

table = dataset.to_table(
    filter=(pds.field("ano") == "2015") & (pds.field("uf") == "MG")
)
print(table.to_pandas().head())
```

> **Note:** The bucket allows anonymous read access. No credentials required.
>
> **Important:** Use `unify_schemas = TRUE` in R (or equivalent) because
> the schema changes across eras (see below).

## File structure

```
s3://healthbr-data/sipni/agregados/cobertura/
  README.md
  ano=1994/
    uf=AC/
      part-0.parquet
    uf=AL/
      part-0.parquet
    ...
  ano=1995/
    ...
  ano=2019/
    ...
```

Each Parquet file contains all coverage records for one state in one year.
Partitioned by `ano/uf`.

## Schema

The dataset has two structural eras with different column sets:

### Era 1–2: 1994–2012 (9 columns)

| Variable | Description |
|----------|-------------|
| `ANO` | Year |
| `UF` | State code |
| `MUNIC` | Municipality code (**7 digits** until 2012, includes IBGE check digit) |
| `FX_ETARIA` | Age group code |
| `IMUNO` | Coverage indicator code (see IMUNOCOB.DBF dictionary) |
| `DOSE` | Dose type |
| `QT_DOSE` | Number of doses applied |
| `POP` | Target population (denominator) |
| `COBERT` | Coverage rate (%) — **decimal point separator** |

### Era 3: 2013–2019 (7 columns)

| Variable | Description |
|----------|-------------|
| `ANO` | Year |
| `UF` | State code |
| `MUNIC` | Municipality code (**6 digits**, IBGE check digit removed) |
| `IMUNO` | Coverage indicator code (composite, embeds dose and age group) |
| `QT_DOSE` | Number of doses applied |
| `POP` | Target population (denominator) |
| `COBERT` | Coverage rate (%) — **decimal comma separator** |

**Key change in 2013:** The `FX_ETARIA` and `DOSE` columns disappear.
Starting in 2013, each IMUNO code is a composite indicator that already
embeds the correct dose and age group for coverage calculation.

**Using `open_dataset(unify_schemas = TRUE)`** in Arrow automatically fills
missing columns with `null` when reading across eras.

## Key differences from the doses dataset

This dataset is a companion to the aggregated doses dataset
(`s3://healthbr-data/sipni/agregados/doses/`). Key differences:

| Aspect | Doses (DPNI) | Coverage (CPNI) |
|--------|:------------:|:---------------:|
| Vaccine dictionary | IMUNO.CNV (85 individual vaccines) | **IMUNOCOB.DBF** (26 composite coverage indicators) |
| Exclusive fields | ANOMES, MES, DOSE1, DOSEN, DIFER | **POP, COBERT** |
| Purpose | Count of doses applied | Pre-calculated coverage rates |
| Schema eras | 3 (7→12→12 columns) | **2** (9→7 columns) |
| Records | 84 million | **2.8 million** |

**The IMUNO codes are different between doses and coverage.** In the doses
dataset, each code identifies an individual vaccine (e.g., `02` = BCG). In
the coverage dataset, each code represents a composite coverage indicator
that may sum multiple vaccines (e.g., `073` = Hepatitis B total = HB +
Pentavalent + Hexavalent combined).

## COBERT field: decimal separator inconsistency

The `COBERT` field (pre-calculated coverage) changes decimal separator
format at the 2013 transition:

| Period | Source type | Value in Parquet | Example |
|:------:|:----------:|:----------------:|:-------:|
| 1994–2012 | numeric (dot separator) | `"39.87"` | `as.character(39.87)` |
| 2013–2019 | character (comma separator) | `"64,86"` | preserved as-is |

Both are stored as strings in Parquet. Users must handle the inconsistent
decimal separator when converting to numeric. This is an artifact of the
original .dbf files.

## Source and processing

**Original source:** 702 .dbf files on the DATASUS FTP server
(`ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/`), following the
naming pattern `CPNI{UF}{YY}.DBF` (27 states × 26 years).

**Files processed:** 686 out of 702. 16 are empty (.dbf headers with 0
rows, returned by the FTP for states without data in early years).

**Processing pipeline:** .dbf → R (`foreign::read.dbf`) → Parquet
(`arrow::write_parquet`) → upload to R2 (via `rclone`). All fields are
stored as `string` to preserve original formatting.

**Consolidated files excluded:** Same rationale as the doses dataset —
national (CPNIBR) and state-level (CPNIUF) consolidations are redundant
with the state files and are excluded.

**Coverage dictionary:** `IMUNOCOB.DBF` (26 composite coverage indicators),
available in the DATASUS FTP auxiliary files directory. This is a different
dictionary from the `IMUNO.CNV` used for doses.

## Known limitations

1. **Government data, not ours.** Values are published exactly as found in
   the original .dbf files — including the pre-calculated coverage rates.

2. **Coverage is pre-calculated by the Ministry.** The `COBERT` field
   equals `QT_DOSE / POP * 100`. These values may differ from coverage
   calculated directly from the doses dataset due to differences in
   denominators and dose aggregation rules used by the Ministry.

3. **IMUNO codes are composite indicators.** They require the `IMUNOCOB.DBF`
   dictionary (not `IMUNO.CNV`) for interpretation. This dictionary will be
   published in `s3://healthbr-data/sipni/dicionarios/`.

4. **Inconsistent decimal separator.** The `COBERT` field uses dot (`.`)
   in 1994–2012 and comma (`,`) in 2013–2019.

5. **All fields are strings.** Numeric fields (`QT_DOSE`, `POP`, `COBERT`)
   must be cast by the user.

6. **Inconsistent municipality codes.** 7 digits (1994–2012) vs 6 digits
   (2013–2019).

7. **FX_ETARIA and DOSE disappear in 2013.** These columns are absent from
   2013 onward — they are embedded in the composite IMUNO codes.

8. **Missing states in early years.** Some state-year combinations in
   1994–1996 have empty files (valid .dbf headers with 0 rows).

## Resumo em Português

Dados agregados de cobertura vacinal do Programa Nacional de Imunizações
(SI-PNI), período 1994–2019. Cada linha contém o total de doses, a
população-alvo e a cobertura percentual pré-calculada para uma combinação
de município × indicador de cobertura. Redistribuído em formato Apache
Parquet a partir dos arquivos .dbf originais do FTP do DATASUS.

**Fonte:** FTP do DATASUS / Ministério da Saúde. **Período:** 1994–2019
(26 anos). **Registros:** 2.762.327. **Acesso:** Leitura anônima via
protocolo S3 (ver exemplos de código acima).

**Duas eras estruturais:** 9 colunas (1994–2012, com FX_ETARIA e DOSE),
7 colunas (2013–2019, indicadores compostos). Use
`unify_schemas = TRUE` no Arrow para leitura unificada.

**O campo COBERT muda de separador decimal:** ponto (1994–2012) para
vírgula (2013–2019). Essa inconsistência é da fonte original.

**Os códigos IMUNO são diferentes dos dados de doses.** Este dataset usa
o dicionário `IMUNOCOB.DBF` (26 indicadores compostos de cobertura), não
o `IMUNO.CNV` (85 vacinas individuais) usado nos dados de doses.

## Suggested citation

```bibtex
@misc{healthbrdata_sipni_agregados_cobertura,
  author = {Sidney Silva},
  title = {{SI-PNI} Aggregated Vaccination Coverage (1994--2019) — healthbr-data},
  year = {2026},
  url = {https://huggingface.co/datasets/sidneyjunior/sipni-agregados-cobertura},
  note = {Original source: DATASUS / Ministry of Health, Brazil}
}
```

## Contact

- **GitHub:** [healthbr-data](https://github.com/sidneyjunior/healthbr-data)
- **Project:** [healthbr-data](https://huggingface.co/healthbr-data)

---

*Last updated: 2026-02-27*
