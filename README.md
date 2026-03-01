🇬🇧 English | [🇧🇷 Português](README.pt.md)

# healthbr-data

Free redistribution of Brazilian public health data (SUS) in modern
analytical format.

**healthbr-data** redistributes public health data from Brazil's Unified
Health System (SUS) in Apache Parquet format, with free access via S3
protocol, automated monthly updates, and complete documentation. Start
analyzing 500 million+ vaccination records in 3 lines of R or Python code.

## Available datasets

| Dataset | R2 prefix | Records | Period | Status |
|---------|-----------|---------|--------|--------|
| SI-PNI Routine vaccination (microdata) | `sipni/microdados/` | ~736M | 2020–present | ✅ Available |
| SI-PNI COVID vaccination (microdata) | `sipni/covid/microdados/` | ~608M | 2021–present | ✅ Available |
| SI-PNI Historical aggregates (doses) | `sipni/agregados/doses/` | ~84M | 1994–2019 | ✅ Available |
| SI-PNI Historical aggregates (coverage) | `sipni/agregados/cobertura/` | ~2.8M | 1994–2019 | ✅ Available |

## Quick start

### R (Arrow)

```r
library(arrow)

# Configure Cloudflare R2 endpoint (free egress, read-only public token)
Sys.setenv(
  AWS_ENDPOINT_URL      = "https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com",
  AWS_ACCESS_KEY_ID     = "28c72d4b3e1140fa468e367ae472b522",
  AWS_SECRET_ACCESS_KEY = "2937b2106736e2ba64e24e92f2be4e6c312bba3355586e41ce634b14c1482951",
  AWS_DEFAULT_REGION    = "auto"
)

# Connect to the dataset
ds <- open_dataset("s3://healthbr-data/sipni/microdados/", format = "parquet")

# Example: count vaccines administered in Acre, January 2024
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

# Read a filtered subset
table = dataset.to_table(
    filter=(pds.field("ano") == "2024") & (pds.field("uf") == "AC")
)
print(table.to_pandas().head())
```

## Why this project?

Brazil's public health data (DATASUS/OpenDATASUS) is available to the
public but distributed in formats that make large-scale analysis difficult:
massive JSON arrays, legacy .dbf files, and CSVs with encoding and type
inconsistencies. Researchers routinely spend days just downloading and
preparing data before any analysis can begin.

**healthbr-data** solves this by providing the same data in Apache Parquet
format, partitioned by year/month/state, served via S3 with zero egress
cost. A query that would require downloading 130 GB of raw files from the
Ministry's server takes seconds via Arrow's partition pruning.

The data is published exactly as provided by the Ministry of Health — no
cleaning, no transformation, no loss of information. Dictionaries and
documentation are published separately as reference.

## Architecture

```
Ministry of Health (JSON/CSV/DBF)
        ↓ automated pipeline
VPS Hetzner (processing)
        ↓ jq + polars + rclone
Cloudflare R2 (S3-compatible storage, free egress)
        ↓ Arrow / DuckDB
Researchers (R, Python, or any Parquet-compatible tool)
```

## Roadmap

- ✅ Routine vaccination microdata (SI-PNI), 2020–present — 736M+ records
- ✅ COVID vaccination microdata (SI-PNI COVID), 2021–present — 608M+ records
- ✅ Historical aggregated doses (SI-PNI), 1994–2019 — 84M+ records
- ✅ Historical aggregated coverage (SI-PNI), 1994–2019 — 2.8M+ records
- 🔧 Official dictionaries from the Ministry of Health
- 📋 R package `healthbR` for integrated access
- 📋 Harmonized vaccination coverage time series (1994–present)
- 🔮 New information systems (SIM, SINASC, SIH)

## Documentation

- [Project architecture and decisions (PT)](docs/project-pt.md) |
  [EN](docs/project-en.md)
- [Quick start guide (PT)](guides/quick-guide-pt.R) |
  [EN](guides/quick-guide-en.R)
- [Harmonization: aggregates ↔ microdata (PT)](docs/harmonization-pt.md)

## Supporting the project

This project is maintained independently. Infrastructure costs are modest
(~$7–27/month) but ongoing. If you find these data useful, consider
supporting the project:

- **GitHub Sponsors** — [link to be added]
- **Pix** (Brazil) — `sbissoli76@gmail.com`

See the [transparency page](docs/strategy-dissemination-pt.md) for a full
breakdown of costs and contributions.

## License

CC-BY 4.0. Data source: Ministry of Health / OpenDATASUS.

## Citation

If you use these data in publications, please cite:

```bibtex
@misc{healthbrdata,
  author = {Sidney da Silva Bissoli},
  title  = {healthbr-data: Redistribution of Brazilian Public Health Data},
  year   = {2026},
  url    = {https://huggingface.co/SidneyBissoli},
  note   = {Original source: Ministry of Health / OpenDATASUS}
}
```

## Contact

- **GitHub:** [https://github.com/SidneyBissoli](https://github.com/SidneyBissoli)
- **Hugging Face:** [https://huggingface.co/SidneyBissoli](https://huggingface.co/SidneyBissoli)
- **E-mail:** sbissoli76@gmail.com
