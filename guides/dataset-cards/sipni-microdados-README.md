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
  - sipni
  - vaccination
  - immunization
pretty_name: "SI-PNI — Routine Vaccination Microdata (Brazil)"
size_categories:
  - 100M<n<1B
task_categories:
  - tabular-classification
source_datasets:
  - original
---

# SI-PNI — Routine Vaccination Microdata (Brazil, 2020–present)

Individual-level vaccination records from Brazil's National Immunization
Program (SI-PNI), redistributed as partitioned Apache Parquet for efficient
analytical access. Each row represents one administered dose.

**Part of the [healthbr-data](https://huggingface.co/SidneyBissoli) project** — open redistribution of Brazilian public health data.

## Summary

| Item | Detail |
|------|--------|
| **Official source** | OpenDATASUS / Ministry of Health |
| **Temporal coverage** | January 2020 – present (monthly updates) |
| **Geographic coverage** | All 5,570 Brazilian municipalities |
| **Granularity** | Individual record (one row per administered dose) |
| **Volume** | 736M+ records |
| **Format** | Apache Parquet, partitioned by `ano/mes/uf` |
| **Data types** | All fields stored as `string` (preserves leading zeros) |
| **Update frequency** | Monthly |
| **License** | CC-BY 4.0 |

## Resumo em português

**SI-PNI — Microdados de Vacinação de Rotina (Brasil, 2020–presente)**

Microdados individuais de vacinação de rotina do Sistema de Informação do
Programa Nacional de Imunizações (SI-PNI), redistribuídos em formato Apache
Parquet particionado para acesso analítico eficiente. Cada linha representa
uma dose aplicada.

| Item | Detalhe |
|------|---------|
| **Fonte oficial** | OpenDATASUS / Ministério da Saúde |
| **Cobertura temporal** | Janeiro/2020 – presente (atualização mensal) |
| **Cobertura geográfica** | Todos os 5.570 municípios brasileiros |
| **Granularidade** | Registro individual (uma linha por dose aplicada) |
| **Volume** | 736M+ registros |
| **Formato** | Apache Parquet, particionado por `ano/mes/uf` |
| **Atualização** | Mensal |

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

ds <- open_dataset("s3://healthbr-data/sipni/microdados/", format = "parquet")

# Example: vaccines administered in Acre, January 2024
ds |>
  filter(ano == "2024", mes == "01", uf == "AC") |>
  count(ds_vacina) |>
  collect()
```

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

dataset = pds.dataset(
    "healthbr-data/sipni/microdados/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

table = dataset.to_table(
    filter=(pds.field("ano") == "2024") & (pds.field("uf") == "AC")
)
print(table.to_pandas().head())
```

> **Note:** These credentials are **read-only** and safe to use in scripts.
> The bucket does not allow anonymous S3 access — credentials are required.

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

Each Parquet file contains records for a specific month and state.
Hive-style partitioning (`key=value`) enables automatic partition pruning
in Arrow and DuckDB — filtered queries read only the relevant files.

## Schema

The dataset contains 56 variables, all stored as `string` to preserve
leading zeros in IBGE municipality codes, CNES facility codes, ZIP codes,
and race/ethnicity codes. Key variables include:

| Variable | Description |
|----------|-------------|
| `dt_vacina` | Vaccination date (YYYY-MM-DD) |
| `co_vacina` | Immunobiological code |
| `ds_vacina` | Immunobiological description |
| `co_dose` | Dose code (1st, 2nd, 3rd, booster, etc.) |
| `sg_uf` | State abbreviation |
| `co_municipio_ibge` | IBGE municipality code (6 digits) |
| `co_cnes` | CNES health facility code |
| `dt_nascimento` | Patient date of birth |
| `co_sexo` | Sex (M/F) |
| `co_raca_cor` | Self-reported race/ethnicity |

> For the complete 56-variable data dictionary, see the Ministry of Health's
> `Dicionario_tb_ria_rotina.pdf`.

## Source and processing

**Original source:** Compressed JSON files from OpenDATASUS (Ministry of
Health S3 bucket).

**Why JSON instead of CSV?** The CSV exports from 2020–2024 contain
serialization artifacts (numeric fields with `.0` suffix, loss of leading
zeros). JSON preserves all values as strings with full integrity.

**Processing:** JSON → NDJSON (via `jq`) → Parquet (via `polars`) → upload
to R2 (via `rclone`). No transformations are applied — values are published
exactly as provided by the Ministry of Health.

## Known limitations

1. **Government data, not ours.** Errors in the original data are
   intentionally preserved. No cleaning or correction is applied.
2. **Variable completeness.** Many fields have optional reporting and may
   contain high proportions of empty values or "SEM INFORMACAO".
3. **All fields are strings.** Type casting (Date, integer) must be done by
   the user at analysis time.
4. **Temporal coverage.** Individual-level microdata is available only from
   January 2020. For the 1994–2019 historical series, see the aggregated
   datasets: `sipni-agregados-doses` and `sipni-agregados-cobertura`.
5. **Lag.** The Ministry may take weeks to publish a given month's data.
   The pipeline runs monthly and reflects what is available at the source.
6. **Does not include COVID-19.** COVID vaccination data is in a separate
   dataset: `sipni-covid`.

## Citation

```bibtex
@misc{healthbrdata,
  author = {Sidney da Silva Bissoli},
  title  = {healthbr-data: Redistribution of Brazilian Public Health Data},
  year   = {2026},
  url    = {https://huggingface.co/datasets/SidneyBissoli/sipni-microdados},
  note   = {Original source: Ministry of Health / OpenDATASUS}
}
```

## Contact

- **GitHub:** [https://github.com/SidneyBissoli](https://github.com/SidneyBissoli)
- **Hugging Face:** [https://huggingface.co/SidneyBissoli](https://huggingface.co/SidneyBissoli)
- **E-mail:** sbissoli76@gmail.com

---

*Last updated: 2026-02-28*
