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
  - data-dictionary
  - lookup-table
pretty_name: "SI-PNI Data Dictionaries"
size_categories:
  - n<1K
task_categories:
  - tabular-classification
source_datasets:
  - original
---

# SI-PNI Data Dictionaries

Lookup tables for decoding numeric fields in the SI-PNI aggregated datasets
(doses applied and vaccination coverage, 1994–2019). Includes 6 Parquet
dictionaries and all 18 original TabWin files (.cnv/.dbf) from DATASUS.

**Part of the [healthbr-data](https://huggingface.co/SidneyBissoli) project** — open redistribution of Brazilian public health data.

## Summary

| Item | Detail |
|------|--------|
| **Official source** | DATASUS FTP / Ministry of Health |
| **Content** | 6 lookup tables (vaccines, doses, age groups, years, months, coverage indicators) |
| **Volume** | 263 rows across 6 Parquet files + 18 original files |
| **Format** | Apache Parquet (converted, UTF-8) + original .cnv/.dbf (Latin-1) |
| **Data types** | All columns stored as string |
| **Update frequency** | Static (source timestamp: May 2019) |
| **License** | CC-BY 4.0 |

## Resumo em português

**Dicionários de Dados — SI-PNI**

Tabelas de conversão (lookup) para decodificação dos campos numéricos nos
datasets agregados do SI-PNI (doses aplicadas e cobertura vacinal, 1994–2019).
Inclui 6 dicionários em Parquet e os 18 arquivos originais (.cnv/.dbf) do DATASUS.

| Item | Detalhe |
|------|---------|
| **Fonte oficial** | FTP DATASUS / Ministério da Saúde |
| **Conteúdo** | 6 tabelas de lookup (vacinas, doses, faixas etárias, anos, meses, indicadores de cobertura) |
| **Volume** | 263 linhas em 6 Parquets + 18 arquivos originais |
| **Formato** | Apache Parquet (convertido, UTF-8) + original .cnv/.dbf (Latin-1) |
| **Atualização** | Estático (fonte datada de maio/2019) |

> Para documentação completa em português, consulte o
> [repositório do projeto](https://github.com/SidneyBissoli/healthbr-data).

## Data access

Data is hosted on Cloudflare R2 and accessed via S3-compatible API. The
credentials below are **read-only** and intended for public use.

### R (Arrow)

```r
library(arrow)

Sys.setenv(
  AWS_ENDPOINT_URL      = "https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com",
  AWS_ACCESS_KEY_ID     = "28c72d4b3e1140fa468e367ae472b522",
  AWS_SECRET_ACCESS_KEY = "2937b2106736e2ba64e24e92f2be4e6c312bba3355586e41ce634b14c1482951",
  AWS_DEFAULT_REGION    = "auto"
)

# Read vaccine dictionary
imuno <- read_parquet("s3://healthbr-data/sipni/dicionarios/imuno.parquet")
print(imuno)

# Read dose type dictionary
dose <- read_parquet("s3://healthbr-data/sipni/dicionarios/dose.parquet")
print(dose)

# Example: decode IMUNO field in aggregated doses
library(dplyr)
doses_data <- open_dataset("s3://healthbr-data/sipni/agregados/doses/")
doses_sp_2019 <- doses_data |>
  filter(ano == "2019", uf == "SP") |>
  collect()

# Expand source_codes for join
imuno_expanded <- imuno |>
  tidyr::separate_rows(source_codes, sep = ",") |>
  rename(IMUNO = source_codes)

doses_decoded <- doses_sp_2019 |>
  left_join(imuno_expanded, by = "IMUNO")
```

### Python (PyArrow)

```python
import pyarrow.parquet as pq
import pyarrow.fs as fs

s3 = fs.S3FileSystem(
    endpoint_override="https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com",
    access_key="28c72d4b3e1140fa468e367ae472b522",
    secret_key="2937b2106736e2ba64e24e92f2be4e6c312bba3355586e41ce634b14c1482951",
    region="auto"
)

# Read vaccine dictionary
imuno = pq.read_table("healthbr-data/sipni/dicionarios/imuno.parquet", filesystem=s3)
print(imuno.to_pandas())

# Read all dictionaries
for name in ["imuno", "imunocob", "dose", "fxet", "ano", "mes"]:
    tbl = pq.read_table(f"healthbr-data/sipni/dicionarios/{name}.parquet", filesystem=s3)
    print(f"\n{name}: {tbl.num_rows} rows")
    print(tbl.to_pandas().head())
```

> **Note:** These credentials are **read-only** and safe to use in scripts.
> The bucket does not allow anonymous S3 access — credentials are required.

## File structure

```
s3://healthbr-data/sipni/dicionarios/
├── imuno.parquet           85 rows  (vaccines)
├── imunocob.parquet        26 rows  (coverage indicators)
├── dose.parquet            12 rows  (dose types)
├── fxet.parquet           101 rows  (age groups)
├── ano.parquet             26 rows  (years 1994–2019)
├── mes.parquet             13 rows  (months)
├── README.md
└── originais/
    ├── IMUNO.CNV           Main vaccine dictionary
    ├── IMUNOCOB.DBF        Coverage indicator dictionary
    ├── DOSE.CNV            Dose types
    ├── FXET.CNV            Age groups
    ├── ANO.CNV             Years
    ├── MES.CNV             Months
    ├── IMUNOC.CNV          = IMUNO (variant)
    ├── ANOMES.CNV          Year-month (long labels)
    ├── ANOMESC.CNV         Year-month (short labels)
    ├── MESC.CNV            Months (abbreviated)
    ├── COBIMU.CNV          Coverage vaccine groups
    ├── COBIMUC.CNV         Coverage groups (expanded)
    ├── COBIMUNO.CNV        Coverage groups + Influenza
    ├── COBIMUNO1.CNV       = COBIMU (reordered)
    ├── COBIMUNOW.CNV       = COBIMUC (duplicate)
    ├── IMUNOCT.CNV         11-vaccine subset
    ├── IMUNOt.CNV          = IMUNOCT (duplicate)
    └── IMUNOTC.CNV         9-vaccine subset
```

## Schema

### Parquet files from .cnv (imuno, dose, fxet, ano, mes)

| Column | Type | Description |
|--------|------|-------------|
| `code` | string | Sequential code in the .cnv file |
| `label` | string | Human-readable label (UTF-8) |
| `source_codes` | string | Code(s) in the .dbf data files that map to this label (comma-separated if multiple) |

### imunocob.parquet (from IMUNOCOB.DBF)

| Column | Type | Description |
|--------|------|-------------|
| `imuno` | string | Coverage indicator code (3 characters) |
| `nome` | string | Indicator name (UTF-8) |

### Many-to-one mappings

The `source_codes` field supports many-to-one mapping: multiple codes in
the raw .dbf data can resolve to the same label. This reflects coding
changes over time — vaccines that had their code changed by the Ministry
of Health still map to the same name.

Examples from `imuno.parquet`:

| label | source_codes | Meaning |
|-------|:------------:|---------|
| Hepatite A (HA) | 88,45 | Both codes 88 and 45 decode to Hepatite A |
| Hepatite B (HB) | 08,82 | Both codes 08 and 82 decode to Hepatite B |

## Source and processing

**Original source:** `ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/`

**Processing:** The .cnv files (TabWin proprietary fixed-width format,
Latin-1 encoded) were parsed positionally and converted to Parquet with
UTF-8 encoding. IMUNOCOB.DBF was read with `foreign::read.dbf()` and
converted. No values were modified — all labels and codes are published
exactly as provided by the Ministry of Health. Original files are
preserved in the `originais/` subfolder.

## .cnv format reference

The .cnv format is a proprietary fixed-width text format used by DATASUS's
TabWin software:

- **Line 1 (header):** `N_ENTRIES FIELD_WIDTH [FLAGS]`
- **Data lines:** positional — code at fixed offset, label padded with spaces, source codes at end
- **Encoding:** Latin-1 (ISO 8859-1)

## Related datasets

| Dataset | Period | Records | Link |
|---------|--------|--------:|------|
| SI-PNI Aggregated Doses | 1994–2019 | 84M+ | [sipni-agregados-doses](https://huggingface.co/datasets/SidneyBissoli/sipni-agregados-doses) |
| SI-PNI Aggregated Coverage | 1994–2019 | 2.8M+ | [sipni-agregados-cobertura](https://huggingface.co/datasets/SidneyBissoli/sipni-agregados-cobertura) |
| SI-PNI Routine Vaccination | 2020–present | 736M+ | [sipni-microdados](https://huggingface.co/datasets/SidneyBissoli/sipni-microdados) |
| SI-PNI COVID-19 Vaccination | 2021–present | 608M+ | [sipni-covid-microdados](https://huggingface.co/datasets/SidneyBissoli/sipni-covid-microdados) |

## Citation

```bibtex
@misc{healthbrdata,
  author = {Sidney da Silva Bissoli},
  title  = {healthbr-data: Redistribution of Brazilian Public Health Data},
  year   = {2026},
  url    = {https://huggingface.co/datasets/SidneyBissoli/sipni-dicionarios},
  note   = {Original source: Ministry of Health / DATASUS}
}
```

## Contact

- **GitHub:** [https://github.com/SidneyBissoli](https://github.com/SidneyBissoli)
- **Hugging Face:** [https://huggingface.co/SidneyBissoli](https://huggingface.co/SidneyBissoli)
- **E-mail:** sbissoli76@gmail.com

---

*Last updated: 2026-03-07*
