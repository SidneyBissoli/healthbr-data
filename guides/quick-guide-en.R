
# =============================================================================
# QUICK GUIDE: SI-PNI Pipeline → Parquet → R2 → sipni
# =============================================================================
#
# v02 — 2026-02-24
# Updated to reflect: JSON as primary source, Python pipeline
# (jq + polars), expanded scope 1994-2025+, sync via HEAD requests.
#
# ARCHITECTURE
# ============
#
#   ┌──────────────────────────────────────────────────────────────────┐
#   │                                                                  │
#   │  VPS (Hetzner)                                                   │
#   │    ├── Bootstrap: CPX42 (8 vCPU, 16 GB RAM, x86) — $21.99/mo   │
#   │    ├── Maintenance: CX22 ($3.99/mo) or on-demand                │
#   │    ├── Downloads JSONs from OpenDATASUS (sync via HEAD)         │
#   │    ├── jq (C) + polars (Rust) + Python orchestrator             │
#   │    ├── Converts to partitioned Parquet (year/month/state)       │
#   │    └── Uploads to R2 via rclone                                 │
#   │                                                                  │
#   │  Cloudflare R2 (primary storage)                                │
#   │    ├── Bucket: healthbr-data                                    │
#   │    ├── Prefix: sipni/microdados/ano=YYYY/mes=MM/uf=XX/         │
#   │    ├── Free egress                                              │
#   │    └── Serves Parquets via S3 protocol                          │
#   │                                                                  │
#   │  Hugging Face (mirror for discoverability)                      │
#   │    └── README points to R2 as primary source                    │
#   │                                                                  │
#   │  sipni (R package)                                              │
#   │    └── arrow::open_dataset() directly from R2                   │
#   │    └── Harmonizes vaccines, computes coverage, time series      │
#   │                                                                  │
#   │  GitHub (source code)                                           │
#   │    └── Version-controls pipeline + package (separate repos)     │
#   │                                                                  │
#   └──────────────────────────────────────────────────────────────────┘
#
# PRODUCTION PIPELINE
# ===================
#
#   pipeline_rapido.py — Single script, orchestrates everything:
#     1. HEAD requests for all months (2020 to present)
#     2. Compares ETag + Content-Length against local control file
#     3. Classifies each month: new / updated / unchanged / unavailable
#     4. Downloads and processes only new/updated months
#     5. jq: JSON array → JSONL (~2s per 800MB part)
#     6. polars: JSONL → partitioned Parquet (multi-threaded)
#     7. rclone: upload to R2
#     8. Updates control CSV
#
# =============================================================================
# PREREQUISITES
# =============================================================================
#
# On the VPS (production pipeline):
#   apt install -y jq python3-pip
#   pip3 install polars --break-system-packages
#   curl https://rclone.org/install.sh | bash
#   rclone config create r2 s3 provider Cloudflare \
#     access_key_id XXX secret_access_key YYY \
#     endpoint https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com
#
# In R (data consumption):
#   install.packages(c("arrow", "dplyr"))
#
# =============================================================================
# ABOUT THE DATA
# =============================================================================
#
# FULL PROJECT SCOPE
# ------------------
# The project integrates three sources into a continuous 1994-2025+ time series:
#   1. Historical aggregated data (1994-2019) — .dbf from DATASUS FTP
#   2. Individual-level microdata (2020-2025+) — JSON from OpenDATASUS
#   3. Population denominators — SINASC (live births) + IBGE
#
# MICRODATA (2020-2025+)
# ----------------------
# Primary source: JSON (not CSV)
# URLs:
#   2020-2024: https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{month}_{year}.json.zip
#   2025+:     https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{month}_{year}_json.zip
#   NOTE: URL pattern changed in 2025. The pipeline tests both.
#
# Why JSON instead of CSV?
#   The CSVs from 2020-2024 contain export artifacts:
#     - Numeric fields serialized as float (e.g., 420750.0 instead of 420750)
#     - Leading zeros lost in codes (race/color: "3" instead of "03")
#   JSON preserves all values as strings with leading zeros intact.
#   The 2025 CSV was fixed, but JSON is preferred for consistency.
#
# JSON characteristics:
#   - Encoding: UTF-8
#   - Structure: single-line JSON array (can exceed 2GB uncompressed)
#   - 56 actual columns (named fields)
#   - All fields as strings (leading zeros preserved)
#   - Implicit header (field names in JSON objects)
#   - ~1.8 GB/month compressed (zip)
#
# CSV characteristics (alternative source/fallback):
#   - Encoding: Latin-1
#   - WITH header (col_names = TRUE)
#   - Delimiter: ;
#   - 56 actual columns (+ 1 empty artifact from trailing ; when parsed)
#   - Float artifacts in 2020-2024 (fixed in 2025)
#   - ~1.3 GB/month compressed (zip)
#
# Decision on types:
#   ALL character in Parquet. Codes such as IBGE, CNES, and ZIP codes
#   have significant leading zeros. Strong typing (Date, integer) will
#   be handled in the sipni R package, not in the published data.
#
# Official dictionary: Dicionario_tb_ria_rotina.pdf (60 fields, 56 in data)
# Official typo: column 17 = "no_fantasia_estalecimento" (missing "b")
# Missing fields: st_vida_paciente, dt_entrada_datalake,
#   co_identificador_sistema, ds_identificador_sistema
#
# AGGREGATED DATA (1994-2019)
# ---------------------------
# Source: ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/
# Format: .dbf (dBase III), 1,504 files (752 coverage + 752 doses)
# NOTE: coverage and doses use different IMUNO code systems
#   - Doses (DPNI) → IMUNO.CNV (85 individual vaccines)
#   - Coverage (CPNI) → IMUNOCOB.DBF (26 composite indicators)
#
# =============================================================================
# STEP BY STEP
# =============================================================================
#
# 1. Run the pipeline on the VPS:
#    nohup python3 -u /root/pipeline_rapido.py > /root/pipeline.log 2>&1 &
#    tail -f /root/pipeline.log
#
# 2. Monitor:
#    tail -30 /root/pipeline.log
#    grep "✓" /root/pipeline.log
#    cat /root/data/controle_versao_microdata.csv
#
# 3. Test remote access (R):
#    library(arrow)
#    ds <- open_dataset("s3://healthbr-data/sipni/microdados/")
#    ds |>
#      filter(ano == "2024", mes == "01", uf == "AC") |>
#      count(ds_vacina) |>
#      collect()
#
# =============================================================================
# SMART SYNCHRONIZATION
# =============================================================================
#
# The pipeline does NOT use arbitrary windows (e.g., "redownload last 6 months").
#
# Instead:
#   1. Sends HEAD requests to the Ministry's S3 for ALL months (2020–present)
#   2. Compares ETag + Content-Length against local control CSV
#   3. Classifies: new, updated, unchanged, unavailable
#   4. Only downloads/reprocesses what's needed
#
# HEAD requests are virtually free (~73 requests in a few seconds).
# Control file persists across runs → resumes where it left off.
#
# =============================================================================
# R2 STRUCTURE
# =============================================================================
#
#   s3://healthbr-data/sipni/
#     microdados/                        ← New SI-PNI (2020-2025+)
#       ano=2024/mes=01/uf=AC/
#         part-00001.parquet
#     agregados/                         ← Old SI-PNI (1994-2019)
#       doses/
#         ano=1998/uf=AC/part-0.parquet
#       cobertura/
#         ano=2005/uf=SP/part-0.parquet
#     populacao/                         ← Denominators
#       sinasc/                          ← Live births by municipality
#       ibge/                            ← Population estimates
#     dicionarios/                       ← Reference (originals from MoH)
#
# =============================================================================
# VPS AUTOMATION
# =============================================================================
#
# Monthly cron (e.g., 15th of each month at 3 AM):
#   0 3 15 * * python3 -u /root/pipeline_rapido.py >> /root/pipeline.log 2>&1
#
# The pipeline automatically detects new/updated months via HEAD.
# Only new data is processed.
#
# For maintenance: CX22 server ($3.99/mo) or create/destroy on demand.
#
# =============================================================================
# REFERENCE NUMBERS
# =============================================================================
#
# Series: Jan/2020 – Feb/2026 (~73 months)
# Peak COVID months (2021-2022): 17-34 parts per zip, 6-12M records/month
# Normal months (2020, 2023-2024): 15-27 parts, 5-11M records/month
# 2025+ months: single large file (up to 29GB uncompressed)
# Estimated total: ~500M+ records
# Pipeline speed: ~12 min/month (4.4x faster than R version)
#
# =============================================================================
# COMMON ISSUES
# =============================================================================
#
# "jq not found"
#   → apt install -y jq
#
# "polars: got non-null value for NULL-typed column"
#   → Force Utf8 schema in polars (read_ndjson with explicit schema)
#
# "Disk full"
#   → The pipeline keeps peak usage at ~4GB (zip + 1 extracted JSON)
#   → Check that staging was cleaned after upload
#   → No files should remain after complete processing
#
# "rclone: access denied"
#   → Check R2 token: rclone lsd r2:healthbr-data
#   → Token needs scope specific to the bucket
#
# "HEAD request returns 403"
#   → Normal: the government's S3 returns 403 (not 404) for missing URLs
#   → The pipeline already handles this as "unavailable"
#
# "SSH: host key verification failed"
#   → If you recreated the server with the same IP: ssh-keygen -R IP
#
# "Out of memory with multiple workers"
#   → For large files (>1.5GB): pipeline uses jq --stream automatically
#   → jq --stream uses constant memory (~600MB) regardless of file size
#
# =============================================================================
# STRATEGIC DECISIONS
# =============================================================================
#
# 1. JSON over CSV: CSV 2020-2024 has artifacts. JSON preserves everything.
# 2. Single bucket healthbr-data: prefixes per system (sipni/, sim/, etc.)
# 3. Data exactly as the government provides: no decoding. Dictionaries separate.
# 4. Temporary server: heavy bootstrap, then destroy. Maintenance on demand.
# 5. Python for pipeline, R for package: speed in production, target audience in consumption.
# 6. All character in Parquet: source fidelity, typing in the package.
# 7. Municipality normalized to 6 digits: IBGE standard (no check digit).
#
# =============================================================================
