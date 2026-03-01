
# =============================================================================
# QUICK GUIDE: SI-PNI Pipeline → Parquet → R2 → healthbR
# =============================================================================
#
# ARCHITECTURE
# ============
#
#   ┌──────────────────────────────────────────────────────────────────┐
#   │                                                                  │
#   │  VPS (Hetzner, €4/month)                                        │
#   │    ├── Downloads CSVs from OpenDATASUS (monthly via cron)        │
#   │    ├── Converts to partitioned Parquet (year/month/state)        │
#   │    └── Uploads to R2 via rclone                                  │
#   │                                                                  │
#   │  Cloudflare R2 (primary storage)                                 │
#   │    └── Serves Parquets via S3 protocol (free egress)             │
#   │                                                                  │
#   │  Hugging Face (mirror / showcase)                                │
#   │    └── Discoverability for researchers                           │
#   │                                                                  │
#   │  healthbR (R package)                                            │
#   │    └── arrow::open_dataset("s3://...") directly from R2          │
#   │                                                                  │
#   │  GitHub (source code)                                            │
#   │    └── Version-controls scripts. VPS does git pull and runs.     │
#   │                                                                  │
#   └──────────────────────────────────────────────────────────────────┘
#
# SCRIPTS
# =======
#
#   00_explorar_dados.R     ← Downloads sample, confirms structure
#         ↓
#   01_converter_parquet.R  ← CSV → Partitioned Parquet (main script)
#         ↓
#   02_upload_r2.R          ← Parquet → R2 + HF mirror
#
# =============================================================================
# PREREQUISITES
# =============================================================================
#
# In R:
#   install.packages(c("arrow", "dplyr", "readr", "fs", "glue",
#                       "curl", "digest"))
#
# On the VPS (for upload):
#   - rclone installed and configured with R2 endpoint
#   - git installed (for pulling code)
#   - Cloudflare account with R2 + API token
#
# For the HF mirror:
#   - Hugging Face account: https://huggingface.co/join
#   - Write token: https://huggingface.co/settings/tokens
#   - git-lfs installed
#
# =============================================================================
# ABOUT THE DATA
# =============================================================================
#
# Source: OpenDATASUS / SI-PNI (New PNI integrated with RNDS)
# URL:   https://arquivosdadosabertos.saude.gov.br/dados/dbbni/
# Original format: Compressed CSV (zip), ~1.3 GB/month
#
# CSV characteristics:
#   - NO header (col_names = FALSE)
#   - Encoding: Latin-1
#   - Delimiter: ;
#   - 56 columns (55 actual + 1 artifact from trailing ;)
#   - All fields are VARCHAR in the original database
#
# Mapping of the 55 columns:
#   Validated against the official dictionary (Dicionario_tb_ria_rotina.pdf)
#   and independently confirmed via the named-field JSON file.
#   See NOMES_COLUNAS vector in script 01.
#
# Decision on types:
#   ALL character in Parquet. Codes such as IBGE, CNES, and ZIP codes
#   have significant leading zeros. Converting to integer would lose
#   information. Typing will be refined later with local inspection.
#
# =============================================================================
# STEP BY STEP
# =============================================================================
#
# 1. Run 00_explorar_dados.R
#    → Downloads 10,000 rows from one month
#    → Confirms the column mapping is correct
#    → If any column doesn't match, STOP and investigate
#
# 2. Run 01_converter_parquet.R
#    → Start with ANOS <- 2024, MESES <- 1:2 (few months)
#    → Downloads ~1.3 GB per month, may take a while
#    → Parquets are saved in parquet_pni/ano=YYYY/mes=MM/uf=XX/
#    → Version control in controle_versao.csv
#    → Then expand: ANOS <- 2020:2025, MESES <- 1:12
#
# 3. Run 02_upload_r2.R
#    → Uploads Parquets to R2 via rclone
#    → Generates README for Hugging Face mirror
#    → Follow on-screen instructions for the HF mirror
#
# 4. Test remote access:
#    library(arrow)
#    ds <- open_dataset("s3://healthbr-data/sipni/")
#    ds |> filter(uf == "AC", ano == "2024") |> count(ds_vacina) |> collect()
#
# =============================================================================
# VPS AUTOMATION (future)
# =============================================================================
#
# Monthly cron (e.g., 15th of each month at 3 AM):
#   0 3 15 * * cd /path/to/repo && git pull && Rscript 01_converter_parquet.R && Rscript 02_upload_r2.R
#
# Script 01 detects identical hashes and skips already-processed months.
# Only new data is processed.
#
# =============================================================================
# COMMON ISSUES
# =============================================================================
#
# "Download timeout"
#   → DATASUS servers are slow. Try again.
#   → Or download manually and place in temp_csv/
#
# "56 columns expected, N found"
#   → The CSV structure may have changed. Compare with the JSON:
#     https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/
#
# "Wrong encoding (garbled characters)"
#   → Make sure you're using locale(encoding = "Latin1")
#
# "Insufficient memory"
#   → Arrow reads as Table (not data.frame) by default
#   → If the issue persists, process one month at a time
#
# =============================================================================
