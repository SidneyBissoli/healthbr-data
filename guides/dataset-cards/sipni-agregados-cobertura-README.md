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
  - coverage
  - historical
pretty_name: "SI-PNI — Aggregated Vaccination Coverage (Brazil, 1994–2019)"
size_categories:
  - 1M<n<10M
task_categories:
  - tabular-classification
source_datasets:
  - original
---

# SI-PNI — Aggregated Vaccination Coverage (Brazil, 1994–2019)

Historical aggregated vaccination coverage data from Brazil's National
Immunization Program (SI-PNI), covering 26 years of municipality-level
coverage indicators pre-calculated by the Ministry of Health. Converted
from legacy .dbf files to Apache Parquet.

**Part of the [healthbr-data](https://huggingface.co/SidneyBissoli) project** — open redistribution of Brazilian public health data.

## Summary

| Item | Detail |
|------|--------|
| **Official source** | DATASUS FTP / Ministry of Health |
| **Temporal coverage** | 1994–2019 |
| **Geographic coverage** | All Brazilian municipalities (by state) |
| **Granularity** | Aggregated: one row per municipality × composite vaccine indicator |
| **Volume** | 2.8M+ records (686 .dbf files processed) |
| **Format** | Apache Parquet, partitioned by `ano/uf` |
| **Data types** | All fields stored as `string` (preserves original format) |
| **Update frequency** | Static (historical series, no longer updated at source) |
| **License** | CC-BY 4.0 |

## Resumo em português

**SI-PNI — Cobertura Vacinal Agregada (Brasil, 1994–2019)**

Dados históricos agregados de cobertura vacinal do Programa Nacional de
Imunizações (PNI), cobrindo 26 anos de indicadores de cobertura em nível
municipal, pré-calculados pelo Ministério da Saúde. Convertidos de
arquivos .dbf legados para Apache Parquet.

| Item | Detalhe |
|------|---------|
| **Fonte oficial** | FTP DATASUS / Ministério da Saúde |
| **Cobertura temporal** | 1994–2019 |
| **Cobertura geográfica** | Todos os municípios brasileiros (por UF) |
| **Granularidade** | Agregado: uma linha por município × indicador composto de vacina |
| **Volume** | 2,8M+ registros (686 arquivos .dbf processados) |
| **Formato** | Apache Parquet, particionado por `ano/uf` |
| **Atualização** | Estática (série histórica, não atualizada na fonte) |

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

ds <- open_dataset("s3://healthbr-data/sipni/agregados/cobertura/", format = "parquet")

# Example: coverage indicators in São Paulo, 2015
ds |>
  filter(ano == "2015", uf == "SP") |>
  head(20) |>
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
    "healthbr-data/sipni/agregados/cobertura/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

table = dataset.to_table(
    filter=(pds.field("ano") == "2015") & (pds.field("uf") == "SP")
)
print(table.to_pandas().head())
```

> **Note:** These credentials are **read-only** and safe to use in scripts.
> The bucket does not allow anonymous S3 access — credentials are required.

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
```

## Structural eras

The .dbf files underwent one major structural transition:

| Era | Period | Columns | Key difference |
|:---:|--------|:-------:|----------------|
| 1 | 1994–2012 | 9 | Includes DOSE, FX_ETARIA; COBERT as numeric (decimal point) |
| 2 | 2013–2019 | 7 | DOSE and FX_ETARIA removed; COB as character (decimal comma) |

The coverage field name and format changed: `COBERT` (numeric, periods) in
era 1 vs `COB` (character, commas) in era 2. Both are preserved as-is.

## Schema

Key variables (varies by era):

| Variable | Description | Available |
|----------|-------------|:---------:|
| `MUNICIP` | Municipality code | All eras |
| `IMESSION` | Composite vaccine indicator code (per IMUNOCOB.DBF, 26 indicators) | All eras |
| `COBERT` / `COB` | Coverage percentage (pre-calculated by Ministry) | Era 1 / Era 2 |
| `QT_DOSE` | Number of administered doses | All eras |
| `POP` | Target population (denominator) | All eras |
| `DOSE` | Dose type | Era 1 only |
| `FX_ETARIA` | Age group | Era 1 only |

**Important:** The vaccine codes in coverage files use the `IMUNOCOB.DBF`
dictionary (26 composite indicators), which is different from the
`IMUNO.CNV` dictionary used in the doses files (85 individual vaccines).
Coverage indicators often combine multiple individual vaccines into a single
metric (e.g., "Polio" coverage combines OPV and IPV doses).

## Source and processing

**Original source:** 702 .dbf files (dBase III) from the DATASUS FTP server.
Of these, 686 were successfully processed (remaining were unavailable or
empty). Bootstrap time: 44 minutes for 2,762,327 records.

**Processing:** .dbf → R (`foreign::read.dbf`) → Parquet (`arrow::write_dataset`)
→ upload to R2 (`rclone`). No transformations are applied. Consolidated
files (UF, BR, IG prefixes) were excluded.

## Known limitations

1. **Government data, not ours.** Values are preserved exactly as in the
   original .dbf files, including the pre-calculated coverage percentages.
2. **Two structural eras.** Dose and age group columns disappear in 2013.
   Coverage field name and decimal format change between eras.
3. **Composite indicators.** The IMUNOCOB dictionary combines multiple
   vaccines into single coverage metrics. The mapping rules are complex
   and changed over time.
4. **All fields are strings.** The coverage percentage field must be parsed
   by the user (note the decimal point vs comma difference between eras).
5. **Static dataset.** No longer updated at source after 2019.
6. **Coverage ≠ doses.** This dataset contains pre-calculated coverage
   rates. For raw dose counts, see `sipni-agregados-doses`.

## Citation

```bibtex
@misc{healthbrdata,
  author = {Sidney da Silva Bissoli},
  title  = {healthbr-data: Redistribution of Brazilian Public Health Data},
  year   = {2026},
  url    = {https://huggingface.co/datasets/SidneyBissoli/sipni-agregados-cobertura},
  note   = {Original source: Ministry of Health / DATASUS}
}
```

## Contact

- **GitHub:** [https://github.com/SidneyBissoli](https://github.com/SidneyBissoli)
- **Hugging Face:** [https://huggingface.co/SidneyBissoli](https://huggingface.co/SidneyBissoli)
- **E-mail:** sbissoli76@gmail.com

---

*Last updated: 2026-02-28*
