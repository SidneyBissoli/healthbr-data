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
  - historical
pretty_name: "SI-PNI — Aggregated Vaccine Doses (Brazil, 1994–2019)"
size_categories:
  - 10M<n<100M
task_categories:
  - tabular-classification
source_datasets:
  - original
---

# SI-PNI — Aggregated Vaccine Doses (Brazil, 1994–2019)

Historical aggregated data on administered vaccine doses from Brazil's
National Immunization Program (SI-PNI), covering 26 years of municipality-
level records. Converted from legacy .dbf files to Apache Parquet for
modern analytical access.

**Part of the [healthbr-data](https://huggingface.co/SidneyBissoli) project** — open redistribution of Brazilian public health data.

## Summary

| Item | Detail |
|------|--------|
| **Official source** | DATASUS FTP / Ministry of Health |
| **Temporal coverage** | 1994–2019 |
| **Geographic coverage** | All Brazilian municipalities (by state) |
| **Granularity** | Aggregated: one row per municipality × vaccine × dose × age group |
| **Volume** | 84M+ records (674 .dbf files processed) |
| **Format** | Apache Parquet, partitioned by `ano/uf` |
| **Data types** | All fields stored as `string` (preserves original format) |
| **Update frequency** | Static (historical series, no longer updated at source) |
| **License** | CC-BY 4.0 |

## Resumo em português

**SI-PNI — Doses Aplicadas Agregadas (Brasil, 1994–2019)**

Dados históricos agregados de doses aplicadas do Programa Nacional de
Imunizações (PNI), cobrindo 26 anos de registros em nível municipal.
Convertidos de arquivos .dbf legados para Apache Parquet.

| Item | Detalhe |
|------|---------|
| **Fonte oficial** | FTP DATASUS / Ministério da Saúde |
| **Cobertura temporal** | 1994–2019 |
| **Cobertura geográfica** | Todos os municípios brasileiros (por UF) |
| **Granularidade** | Agregado: uma linha por município × vacina × dose × faixa etária |
| **Volume** | 84M+ registros (674 arquivos .dbf processados) |
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

ds <- open_dataset("s3://healthbr-data/sipni/agregados/doses/", format = "parquet")

# Example: vaccine doses in Acre, 2010
ds |>
  filter(ano == "2010", uf == "AC") |>
  count(IMUNO) |>
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
    "healthbr-data/sipni/agregados/doses/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

table = dataset.to_table(
    filter=(pds.field("ano") == "2010") & (pds.field("uf") == "AC")
)
print(table.to_pandas().head())
```

> **Note:** These credentials are **read-only** and safe to use in scripts.
> The bucket does not allow anonymous S3 access — credentials are required.

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
```

## Structural eras

The .dbf files underwent two structural transitions over 26 years:

| Era | Period | Columns | Key difference |
|:---:|--------|:-------:|----------------|
| 1 | 1994–2003 | 7 | Basic structure, 7-digit municipality code |
| 2 | 2004–2012 | 12 | Added dose, age group, and population fields; 7-digit municipality code |
| 3 | 2013–2019 | 12 | Same columns as era 2, but 6-digit municipality code |

All eras are preserved as-is in the Parquet files. The municipality code
format (7 vs 6 digits) is kept as originally recorded.

## Schema

Key variables (varies by era):

| Variable | Description | Available |
|----------|-------------|:---------:|
| `MUNICIP` | Municipality code (7 digits until 2012, 6 digits from 2013) | All eras |
| `IMESSION` | Vaccine code (per IMUNO.CNV dictionary, 85 entries) | All eras |
| `QT_DOSE` | Number of administered doses | All eras |
| `DOSE` | Dose type (1st, 2nd, booster, etc.) | Eras 2–3 |
| `FX_ETARIA` | Age group | Eras 2–3 |
| `POP` | Target population | Eras 2–3 |

> For the complete vaccine code dictionary (65 unique codes across 26 years),
> see `IMUNO.CNV` from the DATASUS FTP `/PNI/AUXILIARES/` directory.

## Source and processing

**Original source:** 702 .dbf files (dBase III) from the DATASUS FTP server
(`ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/`). Of these, 674
were successfully processed, 12 were unavailable on the server, and 16 were
empty.

**Processing:** .dbf → R (`foreign::read.dbf`) → Parquet (`arrow::write_dataset`)
→ upload to R2 (`rclone`). No transformations are applied. Consolidated
files (UF, BR, IG prefixes) were excluded — only state-level files with
municipal granularity are included.

**Validation:** The sum of all 27 state files matches the national
consolidated file (DPNIBR) with zero difference.

## Known limitations

1. **Government data, not ours.** Values are preserved exactly as in the
   original .dbf files.
2. **Three structural eras.** Column availability and municipality code
   format change across time periods. Users must handle this in analysis.
3. **All fields are strings.** Preserves original format including
   municipality code leading digits.
4. **No microdata.** These are aggregated counts, not individual records.
   For individual-level data from 2020 onward, see `sipni-microdados`.
5. **Static dataset.** The Ministry stopped publishing aggregated .dbf
   files after 2019. The new SI-PNI system (2020+) produces individual
   records instead.

## Citation

```bibtex
@misc{healthbrdata,
  author = {Sidney da Silva Bissoli},
  title  = {healthbr-data: Redistribution of Brazilian Public Health Data},
  year   = {2026},
  url    = {https://huggingface.co/datasets/SidneyBissoli/sipni-agregados-doses},
  note   = {Original source: Ministry of Health / DATASUS}
}
```

## Contact

- **GitHub:** [https://github.com/SidneyBissoli](https://github.com/SidneyBissoli)
- **Hugging Face:** [https://huggingface.co/SidneyBissoli](https://huggingface.co/SidneyBissoli)
- **E-mail:** sbissoli76@gmail.com

---

*Last updated: 2026-02-28*
