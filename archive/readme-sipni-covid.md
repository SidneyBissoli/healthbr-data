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
  - covid-19
  - immunization
  - microdata
pretty_name: "SI-PNI — COVID-19 Vaccination Microdata"
size_categories:
  - 100M<n<1B
task_categories:
  - tabular-classification
  - time-series-forecasting
source_datasets:
  - original
---

# SI-PNI — COVID-19 Vaccination Microdata

[🇧🇷 Resumo em Português](#resumo-em-português)

Individual-level COVID-19 vaccination records from Brazil's National
Immunization Program (SI-PNI), redistributed as partitioned Apache Parquet
files for efficient analytical access. Each row represents one administered
dose.

## Summary

| Item | Detail |
|------|--------|
| **Official source** | OpenDATASUS / Ministry of Health (Brazil) |
| **Temporal coverage** | January 2021 — present |
| **Geographic coverage** | All 27 Brazilian states |
| **Granularity** | Individual record (one row per administered dose, anonymized) |
| **Records** | ~608 million |
| **Format** | Apache Parquet, partitioned by `ano/mes/uf` (year/month/state) |
| **Data types** | All fields stored as `string` (preserves leading zeros) |
| **Update frequency** | As published by the Ministry of Health |
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
  "s3://healthbr-data/sipni/covid/microdados/",
  format = "parquet"
)

# Example: Pfizer doses in São Paulo, March 2022
ds |>
  filter(ano == "2022", mes == "03", uf == "SP") |>
  count(vacina_nome) |>
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
    "healthbr-data/sipni/covid/microdados/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

# Read with filter
table = dataset.to_table(
    filter=(pds.field("ano") == "2022") & (pds.field("uf") == "SP")
)
print(table.to_pandas().head())
```

> **Note:** The bucket allows anonymous read access. No credentials required.

## File structure

```
s3://healthbr-data/sipni/covid/microdados/
  README.md
  ano=2021/
    mes=01/
      uf=AC/
        part-0.parquet
      uf=AL/
        part-0.parquet
      ...
    mes=02/
      ...
  ano=2022/
    ...
  ano=_invalid/
    mes=.../
      uf=.../
        part-0.parquet
```

Each Parquet file contains records for one specific month and state.
Hive-style partitioning (`key=value`) enables automatic partition pruning.

**The `ano=_invalid/` partition** contains records whose vaccination dates
fall outside the expected range (2021–present). These are records with
dates like 1899, 1900, or birth years — data entry errors in the original
source. They are preserved (not discarded) but separated from valid
partitions to avoid polluting the year-based structure.

## Schema

The dataset contains 32 variables, all stored as `string`. The naming
convention from the Ministry of Health uses mixed camelCase.

Key variables:

| Variable | Description |
|----------|-------------|
| `paciente_id` | Anonymized patient ID (SHA-256 hash) |
| `paciente_idade` | Patient age at vaccination |
| `paciente_dataNascimento` | Patient date of birth |
| `paciente_enumSexoBiologico` | Biological sex (M/F) |
| `paciente_racaCor_codigo` | Race/ethnicity code |
| `paciente_endereco_uf` | Patient state |
| `paciente_endereco_coIbgeMunicipio` | IBGE municipality code (6 digits) |
| `vacina_codigo` | Vaccine code |
| `vacina_nome` | Vaccine name |
| `vacina_dataAplicacao` | Vaccination date (ISO datetime) |
| `vacina_descricao_dose` | Dose description (1st, 2nd, booster, etc.) |
| `vacina_numDose` | Dose number |
| `estabelecimento_valor` | CNES health facility code |
| `estabelecimento_uf` | Facility state |
| `sistema_origem` | Source system (Novo PNI, IDS Saúde, VACIVIDA, etc.) |
| `status` | Record status (`final` = valid) |

> **Note:** The field `estalecimento_noFantasia` contains an official typo
> (missing "b" in "estabelecimento") — this is the original name in the
> Ministry's database.

## Source and processing

**Original source:** CSV files partitioned by state (UF), published by the
Ministry of Health on S3 via OpenDATASUS. Total raw volume: ~292 GB across
135 CSV files (27 states × 5 parts each).

**Why CSV?** Unlike routine vaccination data, no JSON format is available
for COVID-19 data. CSV is the only bulk download option.

**Processing pipeline:** CSV → Parquet (via `polars`) → upload to R2 (via
`rclone`). All fields are cast to string for consistency. Records with
vaccination dates outside the expected range (2021–present) are routed to
the `ano=_invalid/` partition rather than being discarded.

**Verification:** Each processed file has metadata recorded in a version
control CSV.

## Known limitations

1. **Government data, not ours.** Errors in the original data are
   intentionally preserved. No cleaning or correction is applied.

2. **Invalid dates.** Some records have vaccination dates from 1899, 1900,
   or other implausible years (data entry errors). These are stored in the
   `ano=_invalid/` partition (~39 MB, ~2,756 objects).

3. **All fields are strings.** Type casting should be done by the user at
   analysis time.

4. **Multiple source systems.** Records come from several vaccination
   registration systems (Novo PNI, IDS Saúde, VACIVIDA, e-SUS APS, etc.),
   which may introduce duplicates or inconsistencies.

5. **Truncated ZIP codes.** The `paciente_endereco_cep` field contains only
   5-digit ZIP code prefixes (anonymization by the Ministry).

6. **No official data dictionary.** The PDF dictionary for this dataset is
   inaccessible on the OpenDATASUS portal. Field mapping was done
   empirically from the data and the Elasticsearch API.

## Resumo em Português

Microdados individuais de vacinação COVID-19 do Sistema de Informação do
Programa Nacional de Imunizações (SI-PNI), redistribuídos em formato Apache
Parquet particionado para acesso analítico eficiente. Cada linha representa
uma dose aplicada (dados anonimizados).

**Fonte:** OpenDATASUS / Ministério da Saúde. **Período:** Janeiro/2021 em
diante. **Registros:** ~608 milhões. **Acesso:** Leitura anônima via
protocolo S3 (ver exemplos de código acima).

**Partição `ano=_invalid/`:** Contém registros com datas de vacinação fora
do intervalo esperado (2021–presente), como anos 1899, 1900 ou anos de
nascimento. Esses registros são preservados (não descartados) mas separados
das partições válidas.

## Suggested citation

```bibtex
@misc{healthbrdata_sipni_covid,
  author = {Sidney Silva},
  title = {{SI-PNI} {COVID-19} Vaccination Microdata — healthbr-data},
  year = {2026},
  url = {https://huggingface.co/datasets/sidneyjunior/sipni-covid-vacinacao},
  note = {Original source: Ministry of Health / OpenDATASUS, Brazil}
}
```

## Contact

- **GitHub:** [healthbr-data](https://github.com/sidneyjunior/healthbr-data)
- **Project:** [healthbr-data](https://huggingface.co/healthbr-data)

---

*Last updated: 2026-02-27*
