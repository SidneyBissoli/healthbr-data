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
  - sinasc
  - births
  - live-births
  - maternal-health
  - vital-statistics
pretty_name: "SINASC — Live Birth Records (Brazil, 1994–2022)"
size_categories:
  - 10M<n<100M
task_categories:
  - tabular-classification
source_datasets:
  - original
---

# SINASC — Live Birth Records (Brazil, 1994–2022)

Individual-level live birth records from Brazil's Live Birth Information
System (SINASC), covering 29 years of vital statistics data. Each record
corresponds to one Declaration of Live Birth (DNV) and includes maternal,
newborn, and delivery characteristics. Converted from legacy .dbc files
to Apache Parquet.

**Part of the [healthbr-data](https://huggingface.co/SidneyBissoli) project** — open redistribution of Brazilian public health data.

## Summary

| Item | Detail |
|------|--------|
| **Official source** | DATASUS FTP / Ministry of Health |
| **Temporal coverage** | 1994–2022 |
| **Geographic coverage** | All 27 Brazilian states (by municipality of occurrence) |
| **Granularity** | Individual: one row per live birth |
| **Volume** | 85M+ records (783 .dbc files processed) |
| **Format** | Apache Parquet, partitioned by `ano/uf` |
| **Data types** | All fields stored as `string` (preserves original format) |
| **Update frequency** | Annual (source publishes ~12–15 months after reference year) |
| **License** | CC-BY 4.0 |

## Resumo em português

**SINASC — Registros de Nascidos Vivos (Brasil, 1994–2022)**

Microdados individuais de nascidos vivos do Sistema de Informações sobre
Nascidos Vivos (SINASC), cobrindo 29 anos de estatísticas vitais. Cada
registro corresponde a uma Declaração de Nascido Vivo (DNV) e inclui
características maternas, do recém-nascido e do parto. Convertidos de
arquivos .dbc legados para Apache Parquet.

| Item | Detalhe |
|------|---------|
| **Fonte oficial** | FTP DATASUS / Ministério da Saúde |
| **Cobertura temporal** | 1994–2022 |
| **Cobertura geográfica** | Todos os 27 estados brasileiros (por município de ocorrência) |
| **Granularidade** | Individual: uma linha por nascido vivo |
| **Volume** | 85M+ registros (783 arquivos .dbc processados) |
| **Formato** | Apache Parquet, particionado por `ano/uf` |
| **Atualização** | Anual (fonte publica ~12–15 meses após o ano de referência) |

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

ds <- open_dataset("s3://healthbr-data/sinasc/", format = "parquet")

# Example: live births in São Paulo, 2022
ds |>
  filter(ano == "2022", uf == "SP") |>
  count(SEXO) |>
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
    "healthbr-data/sinasc/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

table = dataset.to_table(
    filter=(pds.field("ano") == "2022") & (pds.field("uf") == "SP")
)
print(table.to_pandas().head())
```

> **Note:** These credentials are **read-only** and safe to use in scripts.
> The bucket does not allow anonymous S3 access — credentials are required.

## File structure

```
s3://healthbr-data/sinasc/
  README.md
  manifest.json
  ano=1994/
    uf=AC/
      part-0.parquet
    uf=AL/
      part-0.parquet
    ...
  ano=1995/
    ...
  ...
  ano=2022/
    uf=AC/
      part-0.parquet
    ...
    uf=TO/
      part-0.parquet
```

## Historical schemas

The Declaration of Live Birth (DNV) form underwent multiple revisions since
1994. The dataset preserves 12 distinct schemas:

| Schema | Period | Columns | Key characteristics |
|:------:|--------|:-------:|---------------------|
| 1 | 1994–1995 | 27 | Distinct naming convention; mapped to modern names |
| 2 | 1996–1998 | 21 | First modern naming convention |
| 3 | 1999–2000 | 20 | |
| 4 | 2001 | 23 | |
| 5 | 2002–2005 | 26 | |
| 6 | 2006–2009 | 29 | |
| 7 | 2010 | 55 | Major form expansion |
| 8 | 2011 | 56 | |
| 9 | 2012 | 56 | |
| 10 | 2013 | 59 | |
| 11 | 2014–2017 | 61 | |
| 12 | 2018–2022 | 61 | Same as schema 11 (case normalization only) |

The number of columns varies by year and state. Columns not present in a
given era will be absent from that partition's Parquet file.

## Schema (modern era, 2018–2022)

Key variables in the most recent schema (61 columns):

| Variable | Description |
|----------|-------------|
| `NUMERODN` | Declaration of Live Birth ID |
| `CODESTAB` | Health facility code |
| `CODMUNNASC` | Municipality of occurrence (IBGE 6-digit) |
| `LOCNASC` | Place of birth (1=hospital, 2=other health facility, 3=home, 4=other, 5=indigenous village) |
| `IDADEMAE` | Mother's age (years) |
| `ESCMAE` | Mother's education level |
| `CODMUNRES` | Mother's municipality of residence (IBGE 6-digit) |
| `GESTACAO` | Gestational age (weeks, coded) |
| `GRAVIDEZ` | Type of pregnancy (1=single, 2=twin, 3=triplet+) |
| `PARTO` | Type of delivery (1=vaginal, 2=cesarean) |
| `CONSULTAS` | Number of prenatal visits (coded) |
| `DTNASC` | Date of birth (DDMMYYYY) |
| `SEXO` | Sex (1=male, 2=female, 0=undetermined) |
| `PESO` | Birth weight (grams) |
| `APGAR1` | Apgar score at 1 minute |
| `APGAR5` | Apgar score at 5 minutes |
| `RACACOR` | Race/color (1=white, 2=black, 3=asian, 4=brown, 5=indigenous) |
| `IDANOMAL` | Congenital anomaly detected (1=yes, 2=no, 9=unknown) |
| `CODANOMAL` | ICD-10 code of congenital anomaly |
| `DTCADASTRO` | Registration date |
| `DTNASCMAE` | Mother's date of birth |
| `QTDFILVIVO` | Mother's number of living children |
| `QTDFILMORT` | Mother's number of deceased children |

> For the complete variable list across all eras, see the
> [exploration document](https://github.com/SidneyBissoli/healthbr-data/blob/main/docs/sinasc/exploration-pt.md).

## Schema unification (1994–1995)

Records from 1994–1995 use a different naming convention. The pipeline maps
20 fields to their modern equivalents (e.g., `CODIGO` → `NUMERODN`,
`MUNI_OCOR` → `CODMUNNASC`). Date fields are converted from `YYYYMMDD` to
`DDMMYYYY` for consistency. Six local fields without national equivalents
are preserved as extra columns (`CARTORIO`, `DATA_CART`, `AREA`,
`BAIRRO_MAE`, `CRS_MAE`, `CRS_OCOR`). Four internal control fields are
discarded (`ETNIA`, `FIL_ABORT`, `NUMEXPORT`, `CRITICA` — all nearly 100%
null).

## Source and processing

**Original source:** 843 .dbc files from the DATASUS FTP server, covering
two directories: `NOV/DNRES/` (1996–2022, 734 files) and `ANT/DNRES/`
(1994–1995, 109 files). Of these, 783 were successfully processed
(remaining were unavailable on the FTP server at processing time).

**Processing:** .dbc → R (`read.dbc::read.dbc()`) → schema unification
(1994–1995 name mapping + date format conversion) → all fields cast to
`character` → Parquet (`arrow::write_dataset()`) → upload to R2 (`rclone`).
No value transformations are applied — field values are published exactly
as provided by the Ministry of Health.

**Bootstrap:** 783 files, 85,033,402 records, 0 errors, 117 minutes on
Hetzner CX21.

## Known limitations

1. **Government data, not ours.** Values are preserved exactly as in the
   original .dbc files, including any inconsistencies or missing data.
2. **Twelve historical schemas.** The number of columns varies by year
   (21–61). Queries spanning multiple eras must handle missing columns.
3. **All fields are strings.** Numeric fields (weight, Apgar scores, age)
   and dates (DDMMYYYY format) must be parsed by the user.
4. **OpenDATASUS inaccessible.** The S3 endpoint returned HTTP 403 at
   processing time (March 2026). FTP is the only viable source.
5. **Coverage ends at 2022.** The most recent year available on the FTP
   server at processing time. Newer years will be added as they become
   available.
6. **By municipality of occurrence.** Records are classified by where the
   birth occurred, not where the mother resides. Use `CODMUNRES` for
   residence-based analysis.
7. **60 files unavailable.** 60 of the 843 expected files (grid of 27
   UFs × all years) were not found on the FTP server. These are mostly
   from 1994–1995 for states with smaller populations.

## Related datasets

| Dataset | Period | Records | Link |
|---------|--------|---------|------|
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
  url    = {https://huggingface.co/datasets/SidneyBissoli/sinasc},
  note   = {Original source: Ministry of Health / DATASUS}
}
```

## Contact

- **GitHub:** [https://github.com/SidneyBissoli](https://github.com/SidneyBissoli)
- **Hugging Face:** [https://huggingface.co/SidneyBissoli](https://huggingface.co/SidneyBissoli)
- **E-mail:** sbissoli76@gmail.com

---

*Last updated: 2026-03-08*
