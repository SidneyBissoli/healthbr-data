# Strategy: Data Synchronization & Integrity Dashboard

## healthbr-data — Synchronization between redistributed and official datasets

**Status:** Implemented
**Last updated:** 2026-03-02
**Scope:** SI-PNI (vaccination data), extensible to SIM, SINASC, SIH

**Related documents:**
- `strategy-expansion-pt.md` — Module lifecycle (Phases 4, 5, 6 reference
  this document for manifest generation, dashboard registration, and
  package integration).
- `strategy-dissemination-pt.md` — Launch checklist (post-launch section
  includes dashboard implementation).
- `strategy-languages-pt.md` — This document is classified as English-only
  (technical architecture with code schemas).
- `reference-pipelines-pt.md` — Pipeline operations (manifest generation
  is integrated into pipeline execution).

---

## 1. Problem Statement

The healthbr-data project redistributes Brazilian public health datasets in modern
Parquet format via Cloudflare R2. The original data is published by the Ministry of
Health through OpenDATASUS (S3 buckets for microdata, 2020+) and DATASUS FTP servers
(aggregated data, 1994–2019).

Two critical questions arise for any researcher using redistributed data:

1. **Is the redistributed dataset up to date?** — Has the Ministry published new files
   or updated existing ones since the last pipeline run?
2. **Is the redistributed dataset complete?** — Are all files from the official source
   present in the redistribution, with matching sizes and record counts?

Without a transparent, automated answer to these questions, the project's credibility
depends entirely on trust. A public synchronization dashboard replaces trust with
verification.

---

## 2. Architecture Overview

The system has three components that operate independently but feed into each other:

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  Component 1: Comparison Engine (Python script)                     │
│    └── Runs on Hetzner VPS via cron (weekly)                        │
│    └── Queries both buckets via S3 API (boto3)                      │
│    └── Produces sync-status.json                                    │
│                                                                     │
│  Component 2: Dashboard (Hugging Face Space — Streamlit)            │
│    └── Reads sync-status.json                                       │
│    └── Renders visual indicators (green/red)                        │
│    └── Public URL for researchers                                   │
│                                                                     │
│  Component 3: Manifest (static JSON on R2)                          │
│    └── Published alongside Parquet files                            │
│    └── Consumed by sipni R package for local validation             │
│    └── Machine-readable audit trail                                 │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. Component 1: Comparison Engine

### 3.1 Purpose

A Python script that programmatically compares the contents of two S3-compatible
buckets and produces a structured JSON report.

### 3.2 Data Sources

| Source | Protocol | Bucket / Host | Path Pattern |
|--------|----------|---------------|--------------|
| **Official (microdata)** | S3 | `s3://ckan.saude.gov.br` | `PNI/json/vacinacao_{month}_{year}.json.zip` |
| **Official (aggregated)** | FTP | `ftp.datasus.gov.br` | `/dissemin/publicos/PNI/DADOS/` |
| **Redistributed** | S3 (R2) | `s3://healthbr-data` | `sipni/microdados/ano=YYYY/mes=MM/uf=XX/` |

### 3.3 Comparison Logic

The engine operates in two modes, reflecting the two data eras:

**Microdata (2020+):**

```
For each expected month (2020-01 through current month - 1):
  1. Check if source ZIP exists on OpenDATASUS
     → GET https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{month}_{year}.json.zip
     → Record: exists (bool), size (bytes), last_modified (datetime)

  2. Check if corresponding Parquets exist on R2
     → LIST s3://healthbr-data/sipni/microdados/ano={year}/mes={month}/
     → Record: exists (bool), total_size (bytes), file_count (int), last_modified (datetime)

  3. Compare:
     → source_exists AND redistributed_exists → check size ratio, flag if suspicious
     → source_exists AND NOT redistributed_exists → MISSING in redistribution
     → NOT source_exists AND redistributed_exists → EXTRA in redistribution (unlikely)
     → NOT source_exists AND NOT redistributed_exists → NOT YET PUBLISHED
```

**Aggregated data (1994–2019):**

```
For each expected .dbf file (CPNIXXXX.dbf / DPNIXXXX.dbf):
  1. Check if source .dbf exists on DATASUS FTP
     → Record: exists (bool), size (bytes)

  2. Check if corresponding Parquets exist on R2
     → LIST s3://healthbr-data/sipni/agregados/{type}/ano={year}/uf={state}/
     → Record: exists (bool), total_size (bytes)

  3. Compare using same logic as above
```

### 3.4 Output: sync-status.json

```json
{
  "generated_at": "2026-02-28T03:00:00Z",
  "engine_version": "1.0.0",
  "dataset": "sipni",
  "summary": {
    "status": "outdated",
    "total_source_files": 73,
    "total_redistributed_files": 71,
    "in_sync": 69,
    "outdated": 2,
    "missing_in_redistribution": 2,
    "extra_in_redistribution": 0
  },
  "microdata": {
    "status": "outdated",
    "months": [
      {
        "year": 2024,
        "month": 1,
        "source": {
          "exists": true,
          "size_bytes": 1483927552,
          "last_modified": "2025-11-15T10:30:00Z",
          "url": "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_jan_2024.json.zip"
        },
        "redistributed": {
          "exists": true,
          "total_size_bytes": 892451328,
          "file_count": 27,
          "last_modified": "2025-12-01T03:00:00Z"
        },
        "status": "in_sync",
        "notes": null
      },
      {
        "year": 2025,
        "month": 1,
        "source": {
          "exists": true,
          "size_bytes": 1102438400,
          "last_modified": "2026-02-20T08:00:00Z"
        },
        "redistributed": {
          "exists": false
        },
        "status": "missing",
        "notes": "Source published 2026-02-20, not yet processed"
      }
    ]
  },
  "aggregated": {
    "status": "in_sync",
    "files": []
  }
}
```

### 3.5 Detecting Source Updates

The Ministry of Health frequently updates recent months (adding late-arriving records).
The engine must detect these updates by comparing the source's `Last-Modified` header
or `ETag` with the value recorded during the last pipeline run.

The pipeline already maintains a processing manifest (`manifest.json` on R2) that
records, for each processed month:

- Source URL
- Source size at processing time
- Source ETag/Last-Modified at processing time
- Processing timestamp
- Output record count
- Output SHA-256 checksums

The comparison engine reads this manifest and compares stored values with current
source metadata. If `Last-Modified` or `ETag` changed, the month is flagged as
`outdated` (source was updated after our last processing).

### 3.6 Scheduling

- **Frequency:** Weekly (cron on Hetzner VPS)
- **Runtime:** ~2–5 minutes (only HEAD/LIST requests, no data download)
- **Trigger:** `0 3 * * 1` (every Monday at 3 AM UTC)
- **Output:** Upload `sync-status.json` to R2 public bucket and push to HF Space repo

### 3.7 Implementation Sketch

```python
#!/usr/bin/env python3
"""
healthbr-sync-check: Compare official sources with R2 redistribution.
"""

import boto3
import json
import ftplib
from datetime import datetime, timezone

# --- Configuration ---

OPENDATASUS_BUCKET = "ckan.saude.gov.br"
OPENDATASUS_REGION = "sa-east-1"
OPENDATASUS_PREFIX = "PNI/json/"

R2_ENDPOINT = "https://<account_id>.r2.cloudflarestorage.com"
R2_BUCKET = "healthbr-data"
R2_PREFIX_MICRO = "sipni/microdados/"
R2_PREFIX_AGGR = "sipni/agregados/"

DATASUS_FTP = "ftp.datasus.gov.br"
DATASUS_PATH = "/dissemin/publicos/PNI/DADOS/"

MONTHS_PT = ["jan", "fev", "mar", "abr", "mai", "jun",
             "jul", "ago", "set", "out", "nov", "dez"]


def check_opendatasus(s3_client, year: int, month: int) -> dict:
    """Check if a source ZIP exists on OpenDATASUS."""
    month_pt = MONTHS_PT[month - 1]

    # Try both URL patterns (pre-2025 and 2025+)
    keys = [
        f"{OPENDATASUS_PREFIX}vacinacao_{month_pt}_{year}.json.zip",
        f"{OPENDATASUS_PREFIX}vacinacao_{month_pt}_{year}_json.zip",
    ]

    for key in keys:
        try:
            response = s3_client.head_object(Bucket=OPENDATASUS_BUCKET, Key=key)
            return {
                "exists": True,
                "size_bytes": response["ContentLength"],
                "last_modified": response["LastModified"].isoformat(),
                "etag": response.get("ETag", ""),
                "key": key,
            }
        except s3_client.exceptions.ClientError:
            continue

    return {"exists": False}


def check_r2(s3_client, year: int, month: int) -> dict:
    """Check if redistributed Parquets exist on R2."""
    prefix = f"{R2_PREFIX_MICRO}ano={year}/mes={month:02d}/"

    response = s3_client.list_objects_v2(Bucket=R2_BUCKET, Prefix=prefix)
    contents = response.get("Contents", [])

    if not contents:
        return {"exists": False}

    return {
        "exists": True,
        "total_size_bytes": sum(obj["Size"] for obj in contents),
        "file_count": len(contents),
        "last_modified": max(
            obj["LastModified"] for obj in contents
        ).isoformat(),
    }


def load_manifest(s3_client) -> dict:
    """Load the processing manifest from R2."""
    try:
        response = s3_client.get_object(
            Bucket=R2_BUCKET, Key="sipni/manifest.json"
        )
        return json.loads(response["Body"].read())
    except Exception:
        return {}


def determine_status(source: dict, redistributed: dict, manifest: dict,
                     year: int, month: int) -> tuple[str, str | None]:
    """Determine sync status for a given month."""
    if not source["exists"] and not redistributed["exists"]:
        return "not_published", None

    if source["exists"] and not redistributed["exists"]:
        return "missing", f"Source available, not yet processed"

    if not source["exists"] and redistributed["exists"]:
        return "extra", "Present in redistribution but not in source"

    # Both exist — check if source was updated after processing
    manifest_key = f"{year}-{month:02d}"
    if manifest_key in manifest:
        stored_etag = manifest[manifest_key].get("source_etag", "")
        if stored_etag and stored_etag != source.get("etag", ""):
            return "outdated", "Source updated after last processing"
        stored_modified = manifest[manifest_key].get("source_last_modified", "")
        if stored_modified and stored_modified != source.get("last_modified", ""):
            return "outdated", "Source modified date changed"

    return "in_sync", None


def run_comparison() -> dict:
    """Main comparison logic."""

    # Initialize S3 clients
    opendatasus_client = boto3.client(
        "s3", region_name=OPENDATASUS_REGION,
        config=boto3.session.Config(signature_version="UNSIGNED"),
    )

    r2_client = boto3.client(
        "s3", endpoint_url=R2_ENDPOINT,
        aws_access_key_id="...",
        aws_secret_access_key="...",
    )

    manifest = load_manifest(r2_client)
    now = datetime.now(timezone.utc)

    results = []
    counters = {"in_sync": 0, "outdated": 0, "missing": 0, "extra": 0}

    # Check all months from 2020-01 to current month
    for year in range(2020, now.year + 1):
        max_month = now.month if year == now.year else 12
        for month in range(1, max_month + 1):
            source = check_opendatasus(opendatasus_client, year, month)
            redistributed = check_r2(r2_client, year, month)
            status, notes = determine_status(
                source, redistributed, manifest, year, month
            )

            counters[status] = counters.get(status, 0) + 1

            results.append({
                "year": year,
                "month": month,
                "source": source,
                "redistributed": redistributed,
                "status": status,
                "notes": notes,
            })

    # Determine overall status
    if counters.get("missing", 0) > 0 or counters.get("outdated", 0) > 0:
        overall = "outdated"
    else:
        overall = "in_sync"

    return {
        "generated_at": now.isoformat(),
        "engine_version": "1.0.0",
        "dataset": "sipni",
        "summary": {
            "status": overall,
            "total_source_files": sum(
                1 for r in results if r["source"].get("exists", False)
            ),
            "total_redistributed_files": sum(
                1 for r in results if r["redistributed"].get("exists", False)
            ),
            **counters,
        },
        "microdata": {
            "status": overall,
            "months": results,
        },
    }
```

---

## 4. Component 2: Hugging Face Space Dashboard

### 4.1 Purpose

A public, interactive web dashboard that visualizes the synchronization status
between official sources and the healthbr-data redistribution. Hosted for free
on Hugging Face Spaces.

### 4.2 Platform Choice

| Option | Pros | Cons |
|--------|------|------|
| **HF Space (Streamlit)** | Free hosting, Python-native, git-based deploy, public URL | Limited customization |
| **HF Space (Gradio)** | Free, ML-focused community | Less suited for dashboards |
| **HF Space (Static HTML)** | Lightest weight, fastest load | No server-side logic |
| **Cloudflare Pages** | Fast CDN, custom domain | Separate infrastructure |
| **GitHub Pages** | Free, git-native | Static only, no server-side |

**Decision:** Hugging Face Space with Streamlit. Rationale:

- The dashboard lives next to the dataset (same platform, same user profile)
- Free tier is sufficient (basic CPU, always-on for public Spaces)
- Python environment allows direct S3 queries if needed (fallback if JSON is stale)
- Researchers discovering the dataset on HF naturally find the dashboard

### 4.3 Space Structure

```
huggingface.co/spaces/sidneycavalcanti/healthbr-sync-status/
├── app.py                  # Streamlit application
├── requirements.txt        # streamlit, boto3, pandas
├── sync-status.json        # Updated weekly by Component 1
└── README.md               # Space metadata card
```

### 4.4 Dashboard Layout

```
┌──────────────────────────────────────────────────────────────────┐
│  healthbr-data — Data Synchronization Status                     │
│  Last checked: 2026-02-28 03:00 UTC                              │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────────────────────────┐  ┌────────────────────────────┐  │
│  │  🟢 Aggregated (1994-2019) │  │  🔴 Microdata (2020-2025)  │  │
│  │  1,504 / 1,504 files      │  │  69 / 73 months            │  │
│  │  Status: In sync           │  │  Status: 4 months behind   │  │
│  └────────────────────────────┘  └────────────────────────────┘  │
│                                                                  │
│  📊 Microdata Detail                                             │
│  ┌──────┬───────┬────────────┬──────────────┬────────┐           │
│  │ Year │ Month │ Source     │ Redistributed│ Status │           │
│  ├──────┼───────┼────────────┼──────────────┼────────┤           │
│  │ 2024 │ 01    │ 1.38 GB   │ 832 MB       │ 🟢     │           │
│  │ 2024 │ 02    │ 1.41 GB   │ 845 MB       │ 🟢     │           │
│  │ ...  │       │           │              │        │           │
│  │ 2025 │ 01    │ 1.10 GB   │ —            │ 🔴     │           │
│  │ 2025 │ 02    │ —         │ —            │ ⚪     │           │
│  └──────┴───────┴────────────┴──────────────┴────────┘           │
│                                                                  │
│  Legend: 🟢 In sync  🔴 Missing/Outdated  ⚪ Not yet published   │
│                                                                  │
│  Size comparison:                                                │
│  Source (ZIP/JSON): 98.4 GB total                                │
│  Redistributed (Parquet): 59.1 GB total                          │
│  Compression ratio: 1.66x                                        │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 4.5 Status Indicators

| Indicator | Meaning | Condition |
|-----------|---------|-----------|
| 🟢 Green | In sync | Source and redistribution both exist; source unchanged since processing |
| 🔴 Red | Action needed | Source exists but redistribution is missing or outdated |
| 🟡 Yellow | Source updated | Source was modified after last processing (data may have changed) |
| ⚪ Gray | Not yet published | Source file does not exist (month not yet released by MoH) |

### 4.6 Implementation Sketch (app.py)

```python
import streamlit as st
import json
import pandas as pd
from pathlib import Path

st.set_page_config(page_title="healthbr-data Sync Status", layout="wide")

# Load sync status
status_file = Path("sync-status.json")
if not status_file.exists():
    st.error("sync-status.json not found. Dashboard not yet initialized.")
    st.stop()

data = json.loads(status_file.read_text())

# Header
st.title("healthbr-data — Synchronization Status")
st.caption(f"Last checked: {data['generated_at']}")

# Summary cards
col1, col2, col3 = st.columns(3)

summary = data["summary"]
overall_emoji = "🟢" if summary["status"] == "in_sync" else "🔴"

with col1:
    st.metric("Overall Status", f"{overall_emoji} {summary['status'].replace('_', ' ').title()}")
with col2:
    st.metric("Source Files", summary["total_source_files"])
with col3:
    st.metric("Redistributed Files", summary["total_redistributed_files"])

# Detail table
st.subheader("Microdata (2020+)")

if "microdata" in data and "months" in data["microdata"]:
    rows = []
    for m in data["microdata"]["months"]:
        status_emoji = {
            "in_sync": "🟢",
            "outdated": "🟡",
            "missing": "🔴",
            "extra": "⚠️",
            "not_published": "⚪",
        }.get(m["status"], "❓")

        source_size = m["source"].get("size_bytes")
        redist_size = m["redistributed"].get("total_size_bytes")

        rows.append({
            "Year": m["year"],
            "Month": f"{m['month']:02d}",
            "Source Size": f"{source_size / 1e9:.2f} GB" if source_size else "—",
            "Redistributed Size": f"{redist_size / 1e9:.2f} GB" if redist_size else "—",
            "Files": m["redistributed"].get("file_count", "—"),
            "Status": status_emoji,
            "Notes": m.get("notes") or "",
        })

    df = pd.DataFrame(rows)

    # Color-coded status filter
    status_filter = st.multiselect(
        "Filter by status:",
        ["🟢 In sync", "🔴 Missing", "🟡 Outdated", "⚪ Not published"],
        default=["🔴 Missing", "🟡 Outdated"],
    )

    if status_filter:
        emoji_filter = [s.split(" ")[0] for s in status_filter]
        df = df[df["Status"].isin(emoji_filter)]

    st.dataframe(df, use_container_width=True, hide_index=True)

# Size comparison
st.subheader("Size Comparison")
total_source = sum(
    m["source"].get("size_bytes", 0)
    for m in data["microdata"]["months"]
    if m["source"].get("exists")
)
total_redist = sum(
    m["redistributed"].get("total_size_bytes", 0)
    for m in data["microdata"]["months"]
    if m["redistributed"].get("exists")
)

col1, col2, col3 = st.columns(3)
with col1:
    st.metric("Source (ZIP/JSON)", f"{total_source / 1e9:.1f} GB")
with col2:
    st.metric("Redistributed (Parquet)", f"{total_redist / 1e9:.1f} GB")
with col3:
    ratio = total_source / total_redist if total_redist > 0 else 0
    st.metric("Compression Ratio", f"{ratio:.2f}x")

# Footer
st.divider()
st.caption(
    "This dashboard compares the official SI-PNI data published by Brazil's "
    "Ministry of Health with the healthbr-data redistribution on Cloudflare R2. "
    "Updated weekly. Source code: github.com/sidneycavalcanti/healthbr-data"
)
```

---

## 5. Component 3: Manifest on R2

### 5.1 Purpose

A machine-readable JSON file stored alongside the Parquet data on R2. It serves
two audiences:

1. **The dashboard** (Component 2) — reads it to determine sync status
2. **The R package** (`sipni`) — reads it to validate local data integrity

### 5.2 Location

```
s3://healthbr-data/sipni/manifest.json
```

### 5.3 Structure

```json
{
  "manifest_version": "1.0.0",
  "dataset": "sipni",
  "last_updated": "2026-02-28T03:00:00Z",
  "pipeline_version": "1.2.0",
  "partitions": {
    "2024-01": {
      "source_url": "https://s3.sa-east-1.amazonaws.com/.../vacinacao_jan_2024.json.zip",
      "source_size_bytes": 1483927552,
      "source_etag": "\"abc123def456\"",
      "source_last_modified": "2025-11-15T10:30:00Z",
      "processing_timestamp": "2025-12-01T03:00:00Z",
      "output_files": [
        {
          "path": "sipni/microdados/ano=2024/mes=01/uf=AC/part-0.parquet",
          "size_bytes": 12451328,
          "sha256": "a1b2c3d4e5f6...",
          "record_count": 48923
        },
        {
          "path": "sipni/microdados/ano=2024/mes=01/uf=AL/part-0.parquet",
          "size_bytes": 28934112,
          "sha256": "f6e5d4c3b2a1...",
          "record_count": 112456
        }
      ],
      "total_records": 12483921,
      "total_size_bytes": 892451328
    }
  }
}
```

### 5.4 Integration with sipni R Package

The manifest enables two key functions in the R package:

**`sipni::check_sync()`** — Compares manifest with current source metadata:

```r
sipni::check_sync()
#> ✔ 69/73 months in sync
#> ✖ 2025-01: source updated 2026-02-20, last processed 2025-12-01
#> ✖ 2025-02: missing (source available since 2026-02-25)
#> ℹ 2025-03: not yet published
#> ℹ 2025-04: not yet published
```

**`sipni::validate_local(path)`** — Compares local Parquet files with manifest checksums:

```r
sipni::validate_local("~/data/sipni/")
#> Checking 69 partitions against manifest...
#> ✔ 68/69 partitions match (SHA-256 verified)
#> ✖ ano=2024/mes=06/uf=MG/part-0.parquet: checksum mismatch
#>   Expected: a1b2c3...  Got: x9y8z7...
#>   Run sipni::update_data() to fix
```

---

## 6. Data Flow

```
                      ┌──────────────────┐
                      │ Ministry of Health│
                      │ (OpenDATASUS S3) │
                      │ (DATASUS FTP)    │
                      └────────┬─────────┘
                               │
                               │ HEAD / LIST requests (no download)
                               │
                      ┌────────▼─────────┐
                      │ Comparison Engine │ ← Cron: weekly on Hetzner VPS
                      │ (Python script)   │
                      └──┬─────────┬──────┘
                         │         │
           reads ────────┘         └──────── produces
                         │                        │
                ┌────────▼───────┐    ┌───────────▼──────────┐
                │ manifest.json  │    │ sync-status.json     │
                │ (on R2)        │    │ (pushed to HF Space) │
                └────────┬───────┘    └───────────┬──────────┘
                         │                        │
               ┌─────────▼─────────┐    ┌─────────▼──────────┐
               │ sipni R package   │    │ HF Space Dashboard │
               │ check_sync()     │    │ (Streamlit app)    │
               │ validate_local() │    │ Public URL          │
               └───────────────────┘    └────────────────────┘
```

---

## 7. Operational Procedures

### 7.1 Weekly Cron (Comparison Engine)

```bash
# /etc/cron.d/healthbr-sync
# Every Monday at 3:00 AM UTC
0 3 * * 1 healthbr /opt/healthbr/sync-check.sh >> /var/log/healthbr-sync.log 2>&1
```

**sync-check.sh:**

```bash
#!/bin/bash
set -euo pipefail

cd /opt/healthbr/sync-engine/

# Run comparison
python3 sync_check.py --output sync-status.json

# Upload to R2 (public access)
rclone copyto sync-status.json r2:healthbr-data/sipni/sync-status.json \
  --transfers 16 --checkers 32

# Push to HF Space
cd /opt/healthbr/hf-space-repo/
cp /opt/healthbr/sync-engine/sync-status.json .
git add sync-status.json
git commit -m "Update sync status $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
git push
```

### 7.2 After Pipeline Runs (Manifest Update)

Whenever the main data pipeline processes new months, it must also update
`manifest.json` on R2. This is part of the pipeline itself, not a separate job.

```python
# At the end of the pipeline, after uploading Parquets:
manifest = load_existing_manifest()
manifest["partitions"][f"{year}-{month:02d}"] = {
    "source_url": source_url,
    "source_size_bytes": source_size,
    "source_etag": source_etag,
    "source_last_modified": source_last_modified,
    "processing_timestamp": datetime.now(timezone.utc).isoformat(),
    "output_files": output_file_details,
    "total_records": total_records,
    "total_size_bytes": total_parquet_size,
}
manifest["last_updated"] = datetime.now(timezone.utc).isoformat()
upload_to_r2(manifest, "sipni/manifest.json")
```

### 7.3 Alerting (Optional, Future)

If the comparison engine detects new source data that hasn't been processed
within 7 days, it can trigger a notification:

- **GitHub Issue** (auto-created via API): "New SI-PNI data available: 2025-02"
- **Email notification** (via VPS sendmail or external service)
- **Slack/Telegram webhook** (lightweight, immediate)

This is not critical for launch but improves operational responsiveness.

---

## 8. Cost Analysis

| Component | Cost | Notes |
|-----------|------|-------|
| Comparison Engine (VPS) | €0/month | Runs on existing Hetzner VPS |
| HF Space (Streamlit) | $0/month | Free tier for public Spaces |
| R2 storage (sync-status.json) | ~$0.00 | Negligible (single JSON file) |
| S3 API requests to OpenDATASUS | $0 | Unsigned/public, HEAD only |
| FTP queries to DATASUS | $0 | Public FTP |
| **Total** | **~$0/month** | No incremental cost |

---

## 9. Implementation Roadmap

| Phase | Task | Priority | Depends On |
|-------|------|----------|------------|
| **1. Foundation** | Define manifest.json schema | High | — |
| **1. Foundation** | Add manifest generation to existing pipeline | High | Schema |
| **2. Engine** | Implement sync_check.py | High | Manifest |
| **2. Engine** | Add FTP comparison for aggregated data | Medium | Engine |
| **2. Engine** | Set up cron on VPS | Medium | Engine |
| **3. Dashboard** | Create HF Space with Streamlit app | Medium | Engine output |
| **3. Dashboard** | Design responsive layout | Low | Space |
| **4. Integration** | Implement `sipni::check_sync()` in R package | Medium | Manifest |
| **4. Integration** | Implement `sipni::validate_local()` in R package | Medium | Manifest |
| **5. Alerting** | Auto-create GitHub Issues for stale data | Low | Engine |

---

## 10. Extension to Other Datasets

The architecture is dataset-agnostic. When SIM, SINASC, or SIH pipelines are
added, each gets:

1. Its own manifest at `s3://healthbr-data/{dataset}/manifest.json`
2. Its own section in `sync-status.json`
3. Its own tab or section in the Streamlit dashboard
4. Its own comparison logic (FTP for .dbf, S3 for newer formats)

The comparison engine loads a registry of datasets and iterates:

```python
DATASETS = {
    "sipni": {
        "source_type": "s3+ftp",
        "r2_prefix": "sipni/",
        "checker": SIPNIChecker,
    },
    "sim": {
        "source_type": "ftp",
        "r2_prefix": "sim/",
        "checker": SIMChecker,
    },
    # ...
}
```

---

## 11. Security Considerations

- The comparison engine uses **read-only** R2 credentials (separate from the
  pipeline's read-write token)
- OpenDATASUS queries use **unsigned** S3 requests (public bucket)
- The HF Space has **no credentials** — it only reads a static JSON file
- The manifest on R2 is **public** (researchers need it for validation)
- No sensitive data is stored or transmitted by any component

---

## 12. Implementation Notes

**Implemented:** 2026-03-02

**Deviations from original design:**

1. **HF Space uses Docker SDK** instead of Streamlit SDK. The Streamlit
   built-in SDK was deprecated by Hugging Face. The Space now uses a
   Dockerfile with `python:3.12-slim` and runs Streamlit on port 8501.
   App source lives in `src/app.py` (not root `app.py`).

2. **GitHub Actions instead of Hetzner cron.** The weekly sync check runs
   as a GitHub Actions workflow (`.github/workflows/sync-check.yml`)
   instead of a cron job on the VPS. This eliminates infrastructure cost
   and keeps the automation version-controlled.

3. **Single R2 token** used for both read and write operations in the
   workflow, rather than separate read-only and read-write tokens.

4. **Comparison engine uses `urllib`** (stdlib) for HTTP HEAD requests
   instead of boto3 unsigned S3 client. This avoids the need for
   `botocore.UNSIGNED` configuration for OpenDATASUS queries.

**Live URLs:**

- Dashboard: https://huggingface.co/spaces/SidneyBissoli/healthbr-sync-status
- Workflow: https://github.com/SidneyBissoli/healthbr-data/actions/workflows/sync-check.yml
