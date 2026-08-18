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
  - sih
  - hospitalizations
  - hospital-procedures
  - health-costs
  - sus
pretty_name: "SIH SP — Professional Services per Hospital Admission (Brazil, 1997–2026)"
size_categories:
  - 1B<n<10B
task_categories:
  - tabular-classification
source_datasets:
  - original
---

# SIH SP — Professional Services per Hospital Admission (Brazil, 1997–2026)

Act-level records from Brazil's Hospital Information System (SIH/SUS):
every procedure, exam, surgery, ICU day, blood product or prosthesis
billed inside a public hospital admission, with quantity, amount, SIGTAP
procedure code, and (from 2008) the professional who performed it. Each
admission (AIH) generates on average ~11 SP rows. This is the **SP
(Serviços Profissionais)** sub-module of the `sih/` namespace; it joins
to the admission-level **RD** dataset
([sih-rd](https://huggingface.co/datasets/SidneyBissoli/sih-rd)) via
`SP_NAIH = N_AIH`. Converted from legacy .dbc files to Apache Parquet.

**Part of the [healthbr-data](https://huggingface.co/SidneyBissoli) project** — open redistribution of Brazilian public health data.

## Summary

| Item | Detail |
|------|--------|
| **Official source** | DATASUS FTP / Ministry of Health |
| **Temporal coverage** | Jul/1997–2026 (SP files do not exist before 1997) |
| **Geographic coverage** | All 27 Brazilian states (by state of processing) |
| **Granularity** | One row per act/procedure inside an admission (~11 rows per AIH) |
| **Volume** | 3,198,639,792 records (9,410 .dbc files, 32.0 GiB Parquet on R2; 52.5 GiB compressed at source) |
| **Format** | Apache Parquet, partitioned by `ano/mes/uf` |
| **Data types** | All fields stored as `string` (preserves original format) |
| **Update frequency** | Monthly (source publishes ~2–3 months after competency month) |
| **License** | CC-BY 4.0 |

## Resumo em português

**SIH SP — Serviços Profissionais por Internação (Brasil, 1997–2026)**

Microdados em nível de **ato/procedimento** do Sistema de Informações
Hospitalares do SUS: cada procedimento, exame, cirurgia, diária de UTI,
hemoderivado ou órtese/prótese cobrado dentro de uma internação pública,
com quantidade, valor, código SIGTAP e (a partir de 2008) o profissional
executante (CBO e documento). Cada AIH gera em média ~11 linhas SP. É o
submódulo **SP** do namespace `sih/`; liga-se ao dataset de internações
**RD** ([sih-rd](https://huggingface.co/datasets/SidneyBissoli/sih-rd))
pela chave `SP_NAIH` = `N_AIH`.

O RD responde *quem, onde, quando, por quê e quanto custou* a internação;
o SP responde *o que exatamente foi feito, por quem e a que valor unitário*.
Contagens de internações, mortalidade hospitalar e permanência devem ser
feitas no RD — no SP essas informações aparecem repetidas em cada ato.

| Item | Detalhe |
|------|---------|
| **Fonte oficial** | FTP DATASUS / Ministério da Saúde |
| **Cobertura temporal** | jul/1997–2026 (não há arquivos SP antes de 1997) |
| **Granularidade** | Uma linha por ato/procedimento dentro da internação (~11 por AIH) |
| **Volume** | 3.198.639.792 registros (9.410 arquivos .dbc, 32,0 GiB em Parquet no R2; 52,5 GiB comprimidos na fonte) |
| **Formato** | Apache Parquet, particionado por `ano/mes/uf` |
| **Atualização** | Mensal (fonte publica ~2–3 meses após o mês de competência) |

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

# Acts performed in admissions processed in Acre, Jan 2024
sp <- open_dataset("s3://healthbr-data/sih/sp/ano=2024/mes=01/uf=AC/",
                   format = "parquet")

# Top procedures by amount billed
sp |>
  collect() |>
  mutate(valor = as.numeric(SP_VALATO)) |>
  count(SP_ATOPROF, wt = valor, sort = TRUE, name = "valor_total") |>
  head(20)

# Join with the admission-level RD dataset (same partition)
rd <- open_dataset("s3://healthbr-data/sih/rd/ano=2024/mes=01/uf=AC/",
                   format = "parquet") |> collect()
sp |> collect() |>
  inner_join(rd, by = c("SP_NAIH" = "N_AIH")) |>
  count(SEXO, SP_ATOPROF, sort = TRUE)
```

> **Important:** Point to specific partitions (`ano=YYYY/mes=MM/uf=XX/`),
> not to the dataset root. The root contains `README.md` and `manifest.json`,
> which Arrow cannot read as Parquet files — and never open `sih/` itself,
> which also holds the `rd/` sub-module with a different schema. SP is ~10×
> larger than RD: prefer narrow partitions and lazy engines (Arrow, DuckDB,
> Polars) over `collect()` on wide ranges.

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

sp = pds.dataset("healthbr-data/sih/sp/ano=2024/mes=01/uf=AC/",
                 filesystem=s3, format="parquet")
df = sp.to_table().to_pandas()
print(f"Acts: {len(df)}, distinct admissions: {df['SP_NAIH'].nunique()}")
```

> **Note:** These credentials are **read-only** and safe to use in scripts.
> The bucket does not allow anonymous S3 access — credentials are required.

## File structure

```
s3://healthbr-data/sih/
  README.md            ← namespace index (rd/, sp/)
  rd/                  ← admissions (see sih-rd)
  sp/                  ← this dataset
    README.md
    manifest.json
    ano=1997/
      mes=07/
        uf=AC/
          part-0.parquet
        ...
    ...
    ano=2026/
      mes=01/
        ...
```

## Historical schemas

The SP file changed far less than the RD file. Three schemas:

| Period | Columns | Key characteristics |
|--------|:-------:|---------------------|
| Jul/1997–~2005 | 16 | Hospital identified by CGC (`SP_CGCHOSP`); `SP_PTSP_NF` combined; no professional identification, no ICD |
| ~2006–2007 | 18 | `SP_GESTOR` + `SP_CNES` replace the CGC; `SP_PTSP` / `SP_NF` split |
| 2008–2026 | 36 | **FTP era change.** +professional (`SP_PF_CBO`, `SP_PF_DOC`, `SP_PJ_DOC`), +ICD (`SP_CIDPRI`, `SP_CIDSEC`), +complexity/financing (`SP_COMPLEX`, `SP_FINANC`, `SP_CO_FAEC`), +`SEQUENCIA`/`REMESSA`, +`SP_M_HOSP`/`SP_M_PAC` (municipalities), +`SP_QT_PROC`, `SP_U_AIH`; SIGTAP 10-digit codes |

Columns not present in a given era are absent from that partition's Parquet
file. Use `open_dataset(unify_schemas = TRUE)` in Arrow to query across eras
(missing columns filled with `null`).

## Schema (modern era, 2008–2026, 36 columns)

| Variable | Description |
|----------|-------------|
| `SP_GESTOR` | Managing authority code |
| `SP_UF` | State code (processing) |
| `SP_AA` / `SP_MM` | Competency year / month |
| `SP_CNES` | Health facility code (CNES) |
| `SP_NAIH` | AIH number — **join key to RD `N_AIH`** |
| `SP_PROCREA` | Main procedure of the admission (SIGTAP), as in RD `PROC_REA` |
| `SP_DTINTER` / `SP_DTSAIDA` | Admission / discharge date (YYYYMMDD) |
| `SP_NUM_PR` | Sequence of the professional/act |
| `SP_TIPO` | AIH type |
| `SP_CPFCGC` | Document of the billing entity |
| `SP_ATOPROF` | **Act/procedure performed (SIGTAP code)** |
| `SP_TP_ATO` | Act type |
| `SP_QTD_ATO` | Quantity |
| `SP_PTSP` / `SP_NF` | Points (SP) / invoice flag |
| `SP_VALATO` | **Amount of the act (R$)** |
| `SP_M_HOSP` / `SP_M_PAC` | Municipality of hospital / of patient (IBGE) |
| `SP_DES_HOS` / `SP_DES_PAC` | Hospital / patient outside the state (flags) |
| `SP_COMPLEX` | Complexity level |
| `SP_FINANC` / `SP_CO_FAEC` | Financing type / FAEC sub-type |
| `SP_PF_CBO` | Occupation (CBO) of the professional |
| `SP_PF_DOC` / `SP_PJ_DOC` | Document of the professional (individual / legal entity) |
| `IN_TP_VAL` | Amount type indicator |
| `SEQUENCIA` / `REMESSA` | Batch sequence / remittance |
| `SERV_CLA` | Service/classification |
| `SP_CIDPRI` / `SP_CIDSEC` | Primary / secondary diagnosis (ICD-10) |
| `SP_QT_PROC` | Procedure quantity |
| `SP_U_AIH` | Last-AIH flag |

> Reference tables (SIGTAP procedures, CBO occupations, ICD-10) are in the
> Ministry's TAB_SIH package; see the project documentation.

## Source and processing

**Original source:** 9,412 .dbc files from the DATASUS FTP server:
`200801_/Dados/` (modern era, 5,992 files, 45.2 GiB) and
`199201_200712/Dados/` (legacy era, 3,420 files, 9.2 GiB; SP starts in
Jul/1997). Files are named `SP{UF}{YY}{MM}.dbc`.

**Processing:** .dbc → R (`read.dbc::read.dbc()`) → all fields cast to
`character` → Parquet (`arrow::write_parquet()`) → upload to R2 (`rclone`).
Same pipeline as RD, selected with `SIH_TIPO=SP`. No value transformations
— field values are published exactly as provided by the Ministry of Health.

**Bootstrap:** 2026-08-18, pipeline 1.2.0, single run over both eras
(`SIH_SPRINT=3`) reading a temporary raw mirror of the FTP on R2
(`SIH_FONTE=r2`, deleted afterwards). Modern era (2008–2026): 5,991
files, 2,551,706,767 records; legacy era (Jul/1997–2007): 3,419 files,
646,933,025 records. Total: 9,410 files, 3,198,639,792 records,
32.0 GiB on R2, ~9 h single-thread on a Hetzner cpx42. Last month at
bootstrap: 2026-06; later months are added by the weekly maintenance. Two
source files exist on the FTP but contain no records (`SPAP0710.dbc`,
`SPAC0909.dbc`) and are therefore absent from R2; the Roraima gap
documented for RD (no files Jul/1997–May/2000) applies to SP as well.

## Reproducibility & provenance

Every Parquet file written by pipeline version ≥ 1.1.0 carries a JSON
provenance record in its schema metadata (key `healthbr`): `source_url`,
`source_file`, `source_hash_md5`, `source_size_bytes`, `download_date`,
`pipeline_script`, `pipeline_version` and (≥ 1.2.0) `git_commit`. The same
facts are recorded per partition in `manifest.json` (plus SHA-256 and record
count of each output file) and per source file in the version-control CSV in
the GitHub repository. Together they let anyone re-derive a partition from
the Ministry's original file and the exact code commit, and verify that the
copy they hold is intact. Data are **not** versioned: the R2 copy is the
latest publication; revisions by the Ministry replace files. **Every** SP
file carries a native embedded record (no backfill was needed — the whole
dataset was bootstrapped with pipeline 1.2.0). Full policy and audit recipe:
[docs/policy-reproducibility-pt.md](https://github.com/SidneyBissoli/healthbr-data/blob/master/docs/policy-reproducibility-pt.md).

```r
arrow::read_parquet("part-0.parquet", as_data_frame = FALSE)$metadata$healthbr
```

## Known limitations

1. **Government data, not ours.** Values are preserved exactly as in the
   original .dbc files, including inconsistencies or missing data.
2. **Act-level, not admission-level.** Counting rows counts acts, not
   admissions; patient demographics are not in SP — join with RD.
3. **All fields are strings.** Amounts (`SP_VALATO`), quantities and dates
   must be parsed by the user.
4. **Three historical schemas.** Professional identification and ICD codes
   only exist from 2008; the hospital key is CGC before ~2006 and CNES after.
5. **Starts in 1997.** Unlike RD (1992), no SP files exist for 1992–1996.
6. **Volume.** ~10× the rows of RD; query by partition and prefer lazy
   engines.
7. **Monthly partitioning** by year/month/state of processing.

## Related datasets

| Dataset | Period | Records | Link |
|---------|--------|---------|------|
| SIH RD (hospital admissions) | 1992–present | 415M+ | [sih-rd](https://huggingface.co/datasets/SidneyBissoli/sih-rd) |
| SINASC (live births) | 1994–2022 | 85M+ | [sinasc](https://huggingface.co/datasets/SidneyBissoli/sinasc) |
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
  url    = {https://huggingface.co/datasets/SidneyBissoli/sih-sp},
  note   = {Original source: Ministry of Health / DATASUS}
}
```

## Contact

- **GitHub:** [https://github.com/SidneyBissoli](https://github.com/SidneyBissoli)
- **Hugging Face:** [https://huggingface.co/SidneyBissoli](https://huggingface.co/SidneyBissoli)
- **E-mail:** sbissoli76@gmail.com

---

*Last updated: 2026-08-18 (bootstrap complete)*
