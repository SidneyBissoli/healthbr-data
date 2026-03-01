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
  - covid-19
  - immunization
pretty_name: "SI-PNI — COVID-19 Vaccination Microdata (Brazil)"
size_categories:
  - 100M<n<1B
task_categories:
  - tabular-classification
source_datasets:
  - original
---

# SI-PNI — COVID-19 Vaccination Microdata (Brazil, 2021–present)

Individual-level COVID-19 vaccination records from Brazil's National
Immunization Program (SI-PNI), redistributed as partitioned Apache Parquet
for efficient analytical access. Each row represents one administered dose.

**Part of the [healthbr-data](https://huggingface.co/SidneyBissoli) project** — open redistribution of Brazilian public health data.

## Summary

| Item | Detail |
|------|--------|
| **Official source** | OpenDATASUS / Ministry of Health |
| **Temporal coverage** | January 2021 – present |
| **Geographic coverage** | All 5,570 Brazilian municipalities |
| **Granularity** | Individual record (one row per administered dose) |
| **Volume** | 608M+ records |
| **Format** | Apache Parquet, partitioned by `ano/mes/uf` |
| **Data types** | All fields stored as `string` (preserves leading zeros) |
| **Update frequency** | Monthly |
| **License** | CC-BY 4.0 |

## Resumo em português

**SI-PNI — Microdados de Vacinação COVID-19 (Brasil, 2021–presente)**

Microdados individuais de vacinação contra COVID-19 do Sistema de Informação
do Programa Nacional de Imunizações (SI-PNI), redistribuídos em formato
Apache Parquet particionado para acesso analítico eficiente. Cada linha
representa uma dose aplicada.

| Item | Detalhe |
|------|---------|
| **Fonte oficial** | OpenDATASUS / Ministério da Saúde |
| **Cobertura temporal** | Janeiro/2021 – presente |
| **Cobertura geográfica** | Todos os 5.570 municípios brasileiros |
| **Granularidade** | Registro individual (uma linha por dose aplicada) |
| **Volume** | 608M+ registros |
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

ds <- open_dataset("s3://healthbr-data/sipni/covid/microdados/", format = "parquet")

# Example: COVID vaccines in São Paulo, March 2021
ds |>
  filter(ano == "2021", mes == "03", uf == "SP") |>
  count(vacina_nome) |>
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
    "healthbr-data/sipni/covid/microdados/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

table = dataset.to_table(
    filter=(pds.field("ano") == "2021") & (pds.field("uf") == "SP")
)
print(table.to_pandas().head())
```

> **Note:** These credentials are **read-only** and safe to use in scripts.
> The bucket does not allow anonymous S3 access — credentials are required.

## File structure

```
s3://healthbr-data/sipni/covid/microdados/
  README.md
  ano=2021/
    mes=01/
      uf=AC/
        part-0.parquet
      ...
  ano=2022/
    ...
  ano=_invalid/
    mes=.../
      uf=.../
```

Records with dates outside the expected range (2021–present) are placed
in `ano=_invalid/` rather than discarded, preserving all original data
without polluting the partition structure.

## Schema

The dataset contains 32 variables, all stored as `string`. Key variables
include:

| Variable | Description |
|----------|-------------|
| `vacina_dataaplicacao` | Vaccination date |
| `vacina_codigo` | Vaccine code |
| `vacina_nome` | Vaccine name |
| `vacina_descricao_dose` | Dose description (1st, 2nd, booster, etc.) |
| `estabelecimento_uf` | State of the health facility |
| `estabelecimento_municipio_codigo` | IBGE municipality code |
| `paciente_datanascimento` | Patient date of birth |
| `paciente_enumsexobiologico` | Biological sex |
| `paciente_racacor_codigo` | Race/ethnicity code |
| `vacina_fabricante_nome` | Vaccine manufacturer |
| `vacina_lote` | Vaccine lot number |
| `sistema_origem` | Source system (PNI, e-SUS APS, VACIVIDA, etc.) |

## Source and processing

**Original source:** CSV files by state from OpenDATASUS (Ministry of Health
S3 bucket, 27 states × 5 parts = 135 files, ~292 GB uncompressed).

**Processing:** CSV → Parquet (via `polars`) → upload to R2 (via `rclone`).
No transformations are applied — values are published exactly as provided
by the Ministry of Health.

**Note on CSV artifacts:** Unlike the routine vaccination data (which has
JSON available), COVID data exists only as CSV. Fields with external
standards (IBGE codes, CNES codes, ZIP codes, race/ethnicity) have been
corrected using deterministic rules. Fields depending on internal SI-PNI
dictionaries remain as-is pending dictionary availability.

## Known limitations

1. **Government data, not ours.** Errors in the original data are
   intentionally preserved. No cleaning or correction is applied beyond
   deterministic fixes for known CSV serialization artifacts.
2. **Variable completeness.** Many fields have optional reporting.
3. **All fields are strings.** Type casting must be done by the user.
4. **Invalid dates.** Records with vaccination dates outside 2021–present
   exist in the source data and are preserved in `ano=_invalid/`.
5. **Does not include routine vaccination.** Routine (non-COVID) vaccination
   data is in a separate dataset: `sipni-microdados`.

## Citation

```bibtex
@misc{healthbrdata,
  author = {Sidney da Silva Bissoli},
  title  = {healthbr-data: Redistribution of Brazilian Public Health Data},
  year   = {2026},
  url    = {https://huggingface.co/datasets/SidneyBissoli/sipni-covid},
  note   = {Original source: Ministry of Health / OpenDATASUS}
}
```

## Contact

- **GitHub:** [https://github.com/SidneyBissoli](https://github.com/SidneyBissoli)
- **Hugging Face:** [https://huggingface.co/SidneyBissoli](https://huggingface.co/SidneyBissoli)
- **E-mail:** sbissoli76@gmail.com

---

*Last updated: 2026-02-28*
