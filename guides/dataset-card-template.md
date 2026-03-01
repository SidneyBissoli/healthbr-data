# Dataset Card Template — healthbr-data

> This file is a reusable template for Hugging Face dataset cards.
> Copy it, replace all `[PLACEHOLDERS]`, and remove this header block.
>
> The template is bilingual: English as the primary language (for HF
> discoverability), with a Portuguese summary section for Brazilian
> researchers. See `docs/strategy-languages-pt.md` for the full i18n
> method.
>
> **Updated 2026-02-28:** Credentials are read-only and published in
> the dataset card. R2 does not support anonymous S3 API access — all
> examples must include the read-only token. File naming convention
> is `part-NNNNN.parquet`. Citation key is `healthbrdata` (no year).
> Author name is `Sidney da Silva Bissoli`. Added "Related datasets"
> section and "Part of healthbr-data" tagline.

---

```markdown
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
  - [SYSTEM_TAG]          # e.g., sipni, sim, sinasc, sih
  - [TOPIC_TAG]           # e.g., vaccination, mortality, births
pretty_name: "[DATASET_PRETTY_NAME]"
size_categories:
  - [SIZE_CATEGORY]       # e.g., 1M<n<10M, 100M<n<1B
task_categories:
  - tabular-classification
source_datasets:
  - original
---

# [DATASET_TITLE]

[ONE_PARAGRAPH_DESCRIPTION]

**Part of the [healthbr-data](https://huggingface.co/SidneyBissoli) project** — open redistribution of Brazilian public health data.

## Summary

| Item | Detail |
|------|--------|
| **Official source** | [SOURCE_NAME] / Ministry of Health |
| **Temporal coverage** | [START]–[END] |
| **Geographic coverage** | All 5,570 Brazilian municipalities |
| **Granularity** | [GRANULARITY] |
| **Volume** | [VOLUME] |
| **Format** | Apache Parquet, partitioned by `[PARTITIONING]` |
| **Data types** | [TYPES_NOTE] |
| **Update frequency** | [FREQUENCY] |
| **License** | CC-BY 4.0 |

## Resumo em português

**[DATASET_TITLE_PT]**

[UM_PARAGRAFO_DESCRICAO_PT]

| Item | Detalhe |
|------|---------|
| **Fonte oficial** | [FONTE] / Ministério da Saúde |
| **Cobertura temporal** | [INICIO]–[FIM] |
| **Cobertura geográfica** | Todos os 5.570 municípios brasileiros |
| **Granularidade** | [GRANULARIDADE] |
| **Volume** | [VOLUME] |
| **Formato** | Apache Parquet, particionado por `[PARTICIONAMENTO]` |
| **Atualização** | [FREQUENCIA] |

> Para documentação completa em português, consulte o
> [repositório do projeto](https://github.com/SidneyBissoli/healthbr-data).

## Data access

Data is hosted on Cloudflare R2 and accessed via S3-compatible API. The
credentials below are **read-only** and intended for public use.

### R (Arrow)

\```r
library(arrow)
library(dplyr)

Sys.setenv(
  AWS_ENDPOINT_URL      = "https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com",
  AWS_ACCESS_KEY_ID     = "28c72d4b3e1140fa468e367ae472b522",
  AWS_SECRET_ACCESS_KEY = "2937b2106736e2ba64e24e92f2be4e6c312bba3355586e41ce634b14c1482951",
  AWS_DEFAULT_REGION    = "auto"
)

ds <- open_dataset("s3://healthbr-data/[R2_PREFIX]/", format = "parquet")

# Example: [EXAMPLE_DESCRIPTION]
ds |>
  filter([EXAMPLE_FILTER]) |>
  count([EXAMPLE_COUNT]) |>
  collect()
\```

### Python (PyArrow)

\```python
import pyarrow.dataset as pds
import pyarrow.fs as fs

s3 = fs.S3FileSystem(
    endpoint_override="https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com",
    access_key="28c72d4b3e1140fa468e367ae472b522",
    secret_key="2937b2106736e2ba64e24e92f2be4e6c312bba3355586e41ce634b14c1482951",
    region="auto"
)

dataset = pds.dataset(
    "healthbr-data/[R2_PREFIX]/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

table = dataset.to_table(filter=[EXAMPLE_FILTER_PY])
print(table.to_pandas().head())
\```

> **Note:** These credentials are **read-only** and safe to use in scripts.
> The bucket does not allow anonymous S3 access — credentials are required.

## File structure

\```
s3://healthbr-data/[R2_PREFIX]/
  README.md
  [PARTITION_EXAMPLE]/
    part-00001.parquet
    part-00002.parquet
    ...
\```

## Schema

[SCHEMA_DESCRIPTION]

| Variable | Description |
|----------|-------------|
| [VAR_1]  | [DESC_1]    |
| [VAR_2]  | [DESC_2]    |
| ...      | ...         |

> For the complete data dictionary, see [DICTIONARY_REFERENCE].

## Source and processing

**Original source:** [SOURCE_DESCRIPTION]

**Processing:** [PROCESSING_DESCRIPTION]. No transformations are applied
— values are published exactly as provided by the Ministry of Health.

## Known limitations

1. [LIMITATION_1]
2. [LIMITATION_2]
3. [LIMITATION_3]

## Related datasets

| Dataset | Period | Records | Link |
|---------|--------|---------|------|
| [RELATED_1] | [PERIOD] | [VOLUME] | [LINK] |
| [RELATED_2] | [PERIOD] | [VOLUME] | [LINK] |

## Citation

\```bibtex
@misc{healthbrdata,
  author = {Sidney da Silva Bissoli},
  title  = {healthbr-data: Redistribution of Brazilian Public Health Data},
  year   = {2026},
  url    = {https://huggingface.co/datasets/SidneyBissoli/[HF_REPO_NAME]},
  note   = {Original source: Ministry of Health / [SOURCE]}
}
\```

## Contact

- **GitHub:** [https://github.com/SidneyBissoli](https://github.com/SidneyBissoli)
- **Hugging Face:** [https://huggingface.co/SidneyBissoli](https://huggingface.co/SidneyBissoli)
- **E-mail:** sbissoli76@gmail.com

---

*Last updated: [DATE]*
```
