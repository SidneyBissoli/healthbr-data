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
  - doses
  - historical
pretty_name: "SI-PNI — Aggregated Doses Applied (1994–2019)"
size_categories:
  - 10M<n<100M
task_categories:
  - tabular-classification
  - time-series-forecasting
source_datasets:
  - original
---

# SI-PNI — Aggregated Doses Applied (1994–2019)

[🇧🇷 Resumo em Português](#resumo-em-português)

Aggregated vaccination dose counts from Brazil's National Immunization
Program (SI-PNI), covering the historical period 1994–2019. Each row
represents the total number of doses for a given municipality, vaccine,
dose type, and age group combination. Redistributed as partitioned Apache
Parquet files from original .dbf files on the DATASUS FTP server.

## Summary

| Item | Detail |
|------|--------|
| **Official source** | DATASUS FTP / Ministry of Health (Brazil) |
| **Temporal coverage** | 1994–2019 (26 years) |
| **Geographic coverage** | All Brazilian municipalities |
| **Granularity** | Municipality × vaccine × dose × age group (one row per combination) |
| **Records** | **84,022,233** |
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
  "s3://healthbr-data/sipni/agregados/doses/",
  format = "parquet",
  unify_schemas = TRUE
)

# Example: total doses by vaccine in São Paulo, 2018
ds |>
  filter(ano == "2018", uf == "SP") |>
  count(IMUNO, wt = as.numeric(QT_DOSE)) |>
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
    "healthbr-data/sipni/agregados/doses/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

table = dataset.to_table(
    filter=(pds.field("ano") == "2018") & (pds.field("uf") == "SP")
)
print(table.to_pandas().head())
```

> **Note:** The bucket allows anonymous read access. No credentials required.
>
> **Important:** Use `unify_schemas = TRUE` in R (or equivalent) because
> the schema changes across eras (see below).

## File structure

```
s3://healthbr-data/sipni/agregados/doses/
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

Each Parquet file contains all dose records for one state in one year.
Partitioned by `ano/uf` (not `ano/mes/uf`, since monthly granularity is
unavailable before 2004).

## Schema

The dataset has three structural eras with different column sets:

### Era 1: 1994–2003 (7 columns)

| Variable | Description |
|----------|-------------|
| `ANO` | Year (integer stored as string) |
| `UF` | State code |
| `MUNIC` | Municipality code (**7 digits**, includes IBGE check digit) |
| `FX_ETARIA` | Age group code |
| `IMUNO` | Vaccine code (see IMUNO.CNV dictionary) |
| `DOSE` | Dose type |
| `QT_DOSE` | Number of doses applied |

### Era 2: 2004–2012 (12 columns)

All 7 columns from Era 1, plus:

| Variable | Description |
|----------|-------------|
| `ANOMES` | Year-month (YYYYMM) |
| `MES` | Month |
| `DOSE1` | 1st doses applied |
| `DOSEN` | Last (Nth) doses applied |
| `DIFER` | Difference (DOSE1 − DOSEN, for dropout rate calculation) |

### Era 3: 2013–2019 (12 columns)

Same 12 columns as Era 2, but:
- `MUNIC` changes from **7 digits to 6 digits** (IBGE check digit removed)

**Using `open_dataset(unify_schemas = TRUE)`** in Arrow automatically fills
missing columns with `null` when reading across eras.

## Key transitions

1. **Municipality code (2013):** Changes from 7 digits (with IBGE check
   digit) to 6 digits. The code is preserved exactly as in the source.
   Normalization to a consistent format is left to the user or the `sipni`
   R package (in development).

2. **Monthly granularity (2004):** The `ANOMES`, `MES`, `DOSE1`, `DOSEN`,
   and `DIFER` columns appear starting in 2004. Before that, only annual
   totals exist.

3. **APIDOS → APIWEB transition (July 2013):** The vaccination registration
   system changed mid-2013. Data from 2013 may contain records from both
   the old (APIDOS) and new (APIWEB/SIPNI) systems.

4. **Vaccine code evolution:** 65 unique IMUNO codes appear across 26 years,
   reflecting three generations of vaccines in the national calendar
   (e.g., DTP → Tetravalent → Pentavalent).

## Source and processing

**Original source:** 702 .dbf files on the DATASUS FTP server
(`ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/`), following the
naming pattern `DPNI{UF}{YY}.DBF` (27 states × 26 years).

**Files processed:** 674 out of 702. 12 files are unavailable (states
absent from the FTP in 1994–1996), and 16 are empty (valid .dbf headers
with 0 rows, returned by the FTP for states without data in early years).

**Processing pipeline:** .dbf → R (`foreign::read.dbf`) → Parquet
(`arrow::write_parquet`) → upload to R2 (via `rclone`). All fields are
stored as `string` to preserve original formatting.

**Consolidated files excluded:** National (DPNIBR) and state-level (DPNIUF)
consolidated files are excluded. DPNIBR was validated as having zero
difference against the sum of all 27 state files. DPNIUF has a different
schema (no municipality column) and is trivially reproducible. DPNIIG
(unknown state) does not exist on the FTP.

**Vaccine dictionary:** `IMUNO.CNV` (85 individual vaccine entries),
available in the DATASUS FTP auxiliary files directory.

## Known limitations

1. **Government data, not ours.** Values are published exactly as found in
   the original .dbf files.

2. **IMUNO codes are opaque.** Vaccine codes require the `IMUNO.CNV`
   dictionary for interpretation. This dictionary will be published
   separately in `s3://healthbr-data/sipni/dicionarios/`.

3. **All fields are strings.** Numeric fields like `QT_DOSE` must be cast
   by the user.

4. **Inconsistent municipality codes.** 7 digits (1994–2012) vs 6 digits
   (2013–2019). Users must handle this when merging across eras.

5. **No coverage calculation.** This dataset contains only dose counts, not
   coverage rates. For pre-calculated coverage, see
   `s3://healthbr-data/sipni/agregados/cobertura/`.

6. **Missing states in early years.** 12 state-year combinations (1994–1996)
   are not available on the FTP. These are not empty — they simply do not
   exist.

## Resumo em Português

Dados agregados de doses aplicadas do Programa Nacional de Imunizações
(SI-PNI), período 1994–2019. Cada linha representa o total de doses para
uma combinação de município × vacina × tipo de dose × faixa etária.
Redistribuído em formato Apache Parquet a partir dos arquivos .dbf
originais do FTP do DATASUS.

**Fonte:** FTP do DATASUS / Ministério da Saúde. **Período:** 1994–2019
(26 anos). **Registros:** 84.022.233. **Acesso:** Leitura anônima via
protocolo S3 (ver exemplos de código acima).

**Três eras estruturais:** 7 colunas (1994–2003), 12 colunas (2004–2012),
12 colunas com município de 6 dígitos (2013–2019). Use
`unify_schemas = TRUE` no Arrow para leitura unificada.

## Suggested citation

```bibtex
@misc{healthbrdata_sipni_agregados_doses,
  author = {Sidney Silva},
  title = {{SI-PNI} Aggregated Doses Applied (1994--2019) — healthbr-data},
  year = {2026},
  url = {https://huggingface.co/datasets/sidneyjunior/sipni-agregados-doses},
  note = {Original source: DATASUS / Ministry of Health, Brazil}
}
```

## Contact

- **GitHub:** [healthbr-data](https://github.com/sidneyjunior/healthbr-data)
- **Project:** [healthbr-data](https://huggingface.co/healthbr-data)

---

*Last updated: 2026-02-27*
