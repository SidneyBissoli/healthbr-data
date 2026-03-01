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
  - microdata
pretty_name: "SI-PNI — Routine Vaccination Microdata"
size_categories:
  - 100M<n<1B
task_categories:
  - tabular-classification
  - time-series-forecasting
source_datasets:
  - original
---

# SI-PNI — Routine Vaccination Microdata

[🇧🇷 Resumo em Português](#resumo-em-português)

Individual-level vaccination records from Brazil's National Immunization
Program (SI-PNI), redistributed as partitioned Apache Parquet files for
efficient analytical access. Each row represents one administered dose.

## Summary

| Item | Detail |
|------|--------|
| **Official source** | OpenDATASUS / Ministry of Health (Brazil) |
| **Temporal coverage** | January 2020 — present (monthly updates) |
| **Geographic coverage** | All 5,570 Brazilian municipalities |
| **Granularity** | Individual record (one row per administered dose) |
| **Records** | ~736 million+ |
| **Format** | Apache Parquet, partitioned by `ano/mes/uf` (year/month/state) |
| **Data types** | All fields stored as `string` (preserves leading zeros) |
| **Update frequency** | Monthly, automated pipeline |
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
  "s3://healthbr-data/sipni/microdados/",
  format = "parquet"
)

# Example: BCG doses in Acre, January 2024
ds |>
  filter(ano == "2024", mes == "01", sg_uf == "AC") |>
  count(ds_vacina) |>
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
    "healthbr-data/sipni/microdados/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

# Read with filter
table = dataset.to_table(
    filter=(pds.field("ano") == "2024") & (pds.field("sg_uf") == "AC")
)
print(table.to_pandas().head())
```

> **Note:** The bucket allows anonymous read access. No credentials required.

## File structure

```
s3://healthbr-data/sipni/microdados/
  README.md
  ano=2020/
    mes=01/
      uf=AC/
        part-0.parquet
      uf=AL/
        part-0.parquet
      ...
    mes=02/
      ...
  ano=2021/
    ...
```

Each Parquet file contains records for one specific month and state.
Hive-style partitioning (`key=value`) enables automatic partition pruning
in Arrow, DuckDB, and Spark — queries filtered by year, month, or state
read only the relevant files.

## Schema

The dataset contains 56 variables, all stored as `string` to preserve
leading zeros in codes (IBGE municipality codes, CNES, ZIP codes,
race/ethnicity codes).

Key variables:

| Variable | Description |
|----------|-------------|
| `dt_vacina` | Vaccination date (YYYY-MM-DD) |
| `co_vacina` | Immunobiological code |
| `ds_vacina` | Immunobiological name |
| `co_dose_vacina` | Dose code (1st, 2nd, 3rd, booster, etc.) |
| `sg_uf` | State of vaccination |
| `co_municipio_ibge` | IBGE municipality code (6 digits) |
| `co_cnes` | CNES health facility code |
| `dt_nascimento` | Patient date of birth |
| `co_sexo` | Sex (M/F) |
| `co_raca_cor` | Self-declared race/ethnicity |

> For the complete 56-variable dictionary, refer to the Ministry of Health's
> `Dicionario_tb_ria_rotina.pdf`.

## Source and processing

**Original source:** Compressed JSON files published by the Ministry of
Health via OpenDATASUS (S3).

**Why JSON instead of CSV?** CSV exports from 2020–2024 contain
serialization artifacts (numeric fields with `.0` suffix, lost leading
zeros). JSON preserves all values as strings with full integrity.
CSV exports from 2025 onward are clean, but JSON is used for consistency
across the entire series.

**Processing pipeline:** JSON → NDJSON (via `jq`) → Parquet (via `polars`)
→ upload to R2 (via `rclone`). No transformations are applied to the data —
values are published exactly as provided by the Ministry of Health.

**Verification:** Each processed file has an MD5 hash recorded in a version
control file. The pipeline compares server ETags against local records to
detect updates.

## Known limitations

1. **Government data, not ours.** Errors in the original data are
   intentionally preserved. No cleaning or correction is applied.

2. **Variable completeness.** Many fields have optional entry and contain
   high proportions of empty values or "SEM INFORMACAO" (no information).

3. **All fields are strings.** Type casting (Date, integer) should be done
   by the user at analysis time. The `sipni` R package (in development)
   will handle this automatically.

4. **Temporal coverage.** Individual-level microdata is only available from
   January 2020 onward. For the historical series (1994–2019), see the
   aggregated data at `s3://healthbr-data/sipni/agregados/`.

5. **Lag.** The Ministry may take weeks to publish a given month's data.
   Our pipeline runs monthly and reflects what is available at the source.

6. **Official typo.** Column 17 is named `no_fantasia_estalecimento`
   (missing the "b" in "estabelecimento"). This is the official name in the
   Ministry's database — not our error.

## Resumo em Português

Microdados individuais de vacinação de rotina do Sistema de Informação do
Programa Nacional de Imunizações (SI-PNI), redistribuídos em formato Apache
Parquet particionado para acesso analítico eficiente. Cada linha representa
uma dose aplicada.

**Fonte:** OpenDATASUS / Ministério da Saúde. **Período:** Janeiro/2020 em
diante. **Registros:** ~736 milhões. **Atualização:** Mensal. **Acesso:**
Leitura anônima via protocolo S3 (ver exemplos de código acima).

## Suggested citation

```bibtex
@misc{healthbrdata_sipni_microdados,
  author = {Sidney Silva},
  title = {{SI-PNI} Routine Vaccination Microdata — healthbr-data},
  year = {2026},
  url = {https://huggingface.co/datasets/sidneyjunior/sipni-microdados-vacinacao},
  note = {Original source: Ministry of Health / OpenDATASUS, Brazil}
}
```

## Contact

- **GitHub:** [healthbr-data](https://github.com/sidneyjunior/healthbr-data)
- **Project:** [healthbr-data](https://huggingface.co/healthbr-data)

---

*Last updated: 2026-02-27*
