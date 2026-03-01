# Implementation Plan: Data Synchronization Dashboard

> Operational guide for implementing the synchronization system described
> in `strategy-synchronization.md`. This document is the execution plan —
> the strategy document defines *what* and *why*; this one defines *how*,
> *where*, and *in what order*.
>
> Created: 2026-03-01
>
> **Related documents:**  
> - `strategy-synchronization.md` — Architecture, schemas, comparison
>   logic, dashboard layout, manifest structure.  
> - `strategy-expansion-pt.md` — Module lifecycle (this plan implements
>   Phase 5 sync requirements for all 4 SI-PNI datasets simultaneously).  
> - `reference-pipelines-pt.md` — Pipeline details (Etapa 5 modifies
>   these pipelines).  

---

## 0. Current State

**What exists:**  
- 4 datasets published on R2: `sipni/microdados/`, `sipni/covid/microdados/`,
  `sipni/agregados/doses/`, `sipni/agregados/cobertura/`  
- 4 version control CSVs: `data/controle_versao_*.csv`  
- 4 pipeline scripts in `scripts/pipeline/`  
- `strategy-synchronization.md` with full architecture and code sketches  

**What does NOT exist yet:**  
- No `manifest.json` files on R2 (pipelines were built before the schema existed)  
- No `sync-status.json`  
- No HF Space for the dashboard  
- No comparison engine script  
- No cron/scheduled job  
- No `scripts/sync/` directory  

**Scope:** This is the first time any module reaches this step. All 3
components of the sync system (manifest, engine, dashboard) must be
created from scratch. All 4 SI-PNI datasets will be registered
simultaneously.

---

## 1. Etapa 1 — Retroactive Manifest Generation

### Objective

Generate `manifest.json` for each of the 4 datasets already on R2,
using existing version control CSVs and R2 LIST operations.

### What to build

Script: `scripts/sync/generate-retroactive-manifests.py`

### Logic

For each dataset:

1. Read the local version control CSV to extract per-partition metadata
   (source URL, ETag, content_length, record count, processing date).
2. Run `LIST` against R2 to get actual file sizes and counts per partition.
3. Assemble a `manifest.json` following the schema in
   `strategy-synchronization.md`, section 5.3.
4. Upload to R2 at the dataset's prefix.

### Manifests to generate

| Dataset | R2 path | Version control CSV |
|---------|---------|---------------------|
| SI-PNI microdados | `sipni/manifest.json` | `data/controle_versao_microdata.csv` |
| SI-PNI COVID | `sipni/covid/manifest.json` | `data/controle_versao_covid.csv` |
| Agregados doses | `sipni/agregados/doses/manifest.json` | `data/controle_versao_sipni_agregados_doses.csv` |
| Agregados cobertura | `sipni/agregados/cobertura/manifest.json` | `data/controle_versao_sipni_agregados_cobertura.csv` |

### Constraints

- **SHA-256 of individual Parquet files: omit in this first generation.**
  Computing checksums would require downloading ~60GB of Parquet files
  from R2. Not worth it for retroactive generation. Future pipeline runs
  (Etapa 5) will compute SHA-256 at write time.
- The `source_etag` and `source_last_modified` fields come from the
  version control CSVs (recorded at processing time). They represent
  the state of the source *when it was processed*, which is exactly
  what the comparison engine needs.

### Dependencies

- Python 3, boto3
- R2 credentials (read-write — needs to upload manifests)
- Local access to the 4 version control CSVs (copy to Hetzner or run locally)

### Execution environment

Can run locally (Windows) or on Hetzner. Only makes LIST/PUT requests
to R2 — no heavy computation, no data download from government sources.

### Verification

After running:

```bash
# Verify manifests exist on R2
rclone cat r2:healthbr-data/sipni/manifest.json | python3 -m json.tool | head -20
rclone cat r2:healthbr-data/sipni/covid/manifest.json | python3 -m json.tool | head -20
rclone cat r2:healthbr-data/sipni/agregados/doses/manifest.json | python3 -m json.tool | head -20
rclone cat r2:healthbr-data/sipni/agregados/cobertura/manifest.json | python3 -m json.tool | head -20
```

Each manifest should have: `manifest_version`, `dataset`, `last_updated`,
`partitions` dict with entries matching the version control CSV.

---

## 2. Etapa 2 — Comparison Engine

### Objective

Implement `sync_check.py`: a script that compares official sources with
R2 redistribution and produces `sync-status.json`.

### What to build

Script: `scripts/sync/sync_check.py`

### Architecture

The engine uses a registry of datasets (per `strategy-synchronization.md`,
section 10), each with its own checker class:

```python
DATASETS = {
    "sipni-microdados": {
        "source_type": "s3",
        "manifest_path": "sipni/manifest.json",
        "r2_prefix": "sipni/microdados/",
        "checker": SIPNIMicrodataChecker,
    },
    "sipni-covid": {
        "source_type": "s3",
        "manifest_path": "sipni/covid/manifest.json",
        "r2_prefix": "sipni/covid/microdados/",
        "checker": SIPNICovidChecker,
    },
    "sipni-agregados-doses": {
        "source_type": "ftp",
        "manifest_path": "sipni/agregados/doses/manifest.json",
        "r2_prefix": "sipni/agregados/doses/",
        "checker": SIPNIAgregadosDosesChecker,
    },
    "sipni-agregados-cobertura": {
        "source_type": "ftp",
        "manifest_path": "sipni/agregados/cobertura/manifest.json",
        "r2_prefix": "sipni/agregados/cobertura/",
        "checker": SIPNIAgregadosCoberturaChecker,
    },
}
```

### Checker logic per dataset type

**Microdata checkers (sipni-microdados, sipni-covid):**
- S3 HEAD requests to OpenDATASUS to get current ETag + Content-Length + Last-Modified.
- Compare with values stored in the manifest.
- Classify each partition as: `in_sync`, `outdated`, `missing`, `not_published`.
- See `strategy-synchronization.md`, section 3.3 for detailed logic.

**Microdata rotina URL patterns:**
```
PNI/json/vacinacao_{month_pt}_{year}.json.zip      (pre-2025)
PNI/json/vacinacao_{month_pt}_{year}_json.zip       (2025+)
```

**COVID URL pattern:**
```
PNI/vacinacao/completo/uf/uf={UF}/part-00001.csv   (and parts 2-5)
```
Note: COVID source is organized by UF, not by month. The checker needs
to compare at the UF level (27 UFs × 5 parts = 135 files).

**Aggregated checkers (sipni-agregados-doses, sipni-agregados-cobertura):**
- FTP LIST on `ftp.datasus.gov.br:/dissemin/publicos/PNI/DADOS/` to get
  file sizes.
- Compare with manifest.
- File patterns: `DPNIUFYY.dbf` (doses), `CPNIUFYY.dbf` (cobertura).
- Note: FTP has no ETag or Last-Modified per file in standard LIST.
  Comparison is by file existence + size.

### Output

Single file: `sync-status.json` with top-level structure:

```json
{
  "generated_at": "ISO datetime",
  "engine_version": "1.0.0",
  "datasets": {
    "sipni-microdados": { "status": "...", "summary": {...}, "details": [...] },
    "sipni-covid": { "status": "...", "summary": {...}, "details": [...] },
    "sipni-agregados-doses": { "status": "...", "summary": {...}, "details": [...] },
    "sipni-agregados-cobertura": { "status": "...", "summary": {...}, "details": [...] }
  }
}
```

This extends the single-dataset schema from `strategy-synchronization.md`
section 3.4 to multi-dataset. Each dataset entry follows the same
structure (summary + detail array).

### Dependencies

- Python 3, boto3, ftplib (stdlib)
- R2 credentials (read-only — only reads manifests)
- Network access to OpenDATASUS S3 and DATASUS FTP

### Execution environment

Must run where FTP and S3 are accessible. Hetzner is fine, but
GitHub Actions is the final target (Etapa 4). The script should be
designed to run in any environment with Python 3 + boto3.

### CLI interface

```bash
python3 sync_check.py --output sync-status.json
```

### Verification

```bash
python3 sync_check.py --output /tmp/sync-status.json
cat /tmp/sync-status.json | python3 -m json.tool | head -40
```

Check that all 4 datasets appear with plausible status values.

---

## 3. Etapa 3 — Hugging Face Space (Streamlit Dashboard)

### Objective

Create a public Streamlit dashboard on Hugging Face Spaces that
visualizes the sync status of all 4 datasets.

### What to build

HF Space: `SidneyBissoli/healthbr-sync-status`

### File structure

```
huggingface.co/spaces/SidneyBissoli/healthbr-sync-status/
├── app.py                  # Streamlit application
├── requirements.txt        # streamlit, pandas
├── sync-status.json        # Updated weekly by GitHub Actions (Etapa 4)
└── README.md               # HF Space metadata card
```

### Dashboard layout

Expand the layout from `strategy-synchronization.md` section 4.4 to
handle 4 datasets:

- **Header:** Project name, last checked timestamp.
- **Summary row:** 4 cards, one per dataset, each showing status emoji
  + file/month count + overall status.
- **Tabs (one per dataset):** Each tab shows the detail table for that
  dataset (year/month grid for microdata, year/UF grid for aggregated).
- **Footer:** Explanation text, link to GitHub repo, link to HF datasets.

### Status indicators

Per `strategy-synchronization.md` section 4.5:

| Indicator | Meaning |
|-----------|---------|
| 🟢 | In sync |
| 🔴 | Missing or action needed |
| 🟡 | Source updated after last processing |
| ⚪ | Not yet published by Ministry |

### Implementation notes

- `app.py` based on sketch in `strategy-synchronization.md` section 4.6,
  but expanded with `st.tabs()` for multi-dataset support.
- No server-side logic beyond reading the static JSON. The Space only
  renders data; it never queries S3/FTP directly.
- `requirements.txt` should be minimal: `streamlit` and `pandas` only.

### README.md (Space card)

```yaml
---
title: healthbr-data Sync Status
emoji: 📊
colorFrom: green
colorTo: blue
sdk: streamlit
sdk_version: "1.45.0"
app_file: app.py
pinned: false
license: cc-by-4.0
---
```

### Deployment

1. Create the Space via HF web UI or `huggingface-cli`.
2. Clone the Space repo locally.
3. Add files (`app.py`, `requirements.txt`, `README.md`, initial
   `sync-status.json` from Etapa 2).
4. `git push` to deploy.

### Verification

- Visit `https://huggingface.co/spaces/SidneyBissoli/healthbr-sync-status`
- Confirm all 4 datasets are visible with correct status indicators.
- Confirm filtering works (status filter multiselect).

---

## 4. Etapa 4 — GitHub Actions (Scheduled Workflow)

### Objective

Automate weekly execution of the comparison engine and deployment of
results to the HF Space, using GitHub Actions instead of a dedicated
server.

### Decision rationale

| Option | Pros | Cons |
|--------|------|------|
| Hetzner CX22 permanent | Simple, same ecosystem | $3.99/month for 5 min/week |
| **GitHub Actions** | **Free, no server, version-controlled, integrated** | Needs repo secrets, FTP access may need testing |
| Hetzner on-demand | Minimal cost | Complex automation |

GitHub Actions is the best fit: the job runs ~2-5 minutes weekly, uses
only HEAD/LIST requests (no heavy computation), and the workflow file
lives in the same repo as the code.

### What to build

Workflow file: `.github/workflows/sync-check.yml`

### Workflow structure

```yaml
name: Weekly Sync Check

on:
  schedule:
    - cron: '0 3 * * 1'  # Every Monday at 3:00 AM UTC
  workflow_dispatch:        # Manual trigger for testing

jobs:
  sync-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - name: Install dependencies
        run: pip install boto3

      - name: Run comparison engine
        env:
          R2_ACCESS_KEY_ID: ${{ secrets.R2_READ_ACCESS_KEY_ID }}
          R2_SECRET_ACCESS_KEY: ${{ secrets.R2_READ_SECRET_ACCESS_KEY }}
          R2_ENDPOINT: ${{ secrets.R2_ENDPOINT }}
        run: python scripts/sync/sync_check.py --output sync-status.json

      - name: Upload sync-status.json to R2
        env:
          R2_ACCESS_KEY_ID: ${{ secrets.R2_WRITE_ACCESS_KEY_ID }}
          R2_SECRET_ACCESS_KEY: ${{ secrets.R2_WRITE_SECRET_ACCESS_KEY }}
          R2_ENDPOINT: ${{ secrets.R2_ENDPOINT }}
        run: |
          pip install awscli
          aws s3 cp sync-status.json s3://healthbr-data/sync-status.json \
            --endpoint-url $R2_ENDPOINT

      - name: Push sync-status.json to HF Space
        env:
          HF_TOKEN: ${{ secrets.HF_TOKEN }}
        run: |
          git clone https://SidneyBissoli:$HF_TOKEN@huggingface.co/spaces/SidneyBissoli/healthbr-sync-status hf-space
          cp sync-status.json hf-space/
          cd hf-space
          git config user.name "healthbr-sync-bot"
          git config user.email "noreply@healthbr-data.org"
          git add sync-status.json
          git commit -m "Update sync status $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
          git push
```

### Secrets required

These must be configured in the GitHub repo settings (Settings → Secrets
and variables → Actions):

| Secret | Purpose | How to obtain |
|--------|---------|---------------|
| `R2_READ_ACCESS_KEY_ID` | Read manifests from R2 | Cloudflare R2 → API Tokens → create read-only token |
| `R2_READ_SECRET_ACCESS_KEY` | (pair with above) | Same token |
| `R2_WRITE_ACCESS_KEY_ID` | Upload sync-status.json to R2 | Existing pipeline token or new write token |
| `R2_WRITE_SECRET_ACCESS_KEY` | (pair with above) | Same token |
| `R2_ENDPOINT` | R2 S3 endpoint URL | `https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com` |
| `HF_TOKEN` | Push to HF Space repo | huggingface.co → Settings → Access Tokens → create write token |

Note: If a single R2 token has both read and write permissions, use the
same key for both `R2_READ_*` and `R2_WRITE_*`. Separate tokens are
recommended for security (comparison engine only needs read; upload needs
write).

### FTP access from GitHub Actions

GitHub Actions runners have outbound FTP access. However, DATASUS FTP
(`ftp.datasus.gov.br`) can be slow or unreliable. The comparison engine
should implement:
- Connection timeout: 30 seconds
- Retry: 3 attempts with exponential backoff
- Graceful degradation: if FTP is unreachable, report aggregated datasets
  as `"status": "check_failed"` instead of crashing

### Verification

1. Push the workflow file to the repo.
2. Trigger manually via GitHub Actions UI (workflow_dispatch).
3. Check that `sync-status.json` appears on R2 and in the HF Space.
4. Wait for the next Monday 3 AM UTC and confirm automatic execution.

---

## 5. Etapa 5 — Pipeline Integration (Manifest at Write Time)

### Objective

Modify the 4 existing pipeline scripts so that they automatically
update the corresponding `manifest.json` on R2 after processing each
partition.

### What to modify

| Pipeline script | Manifest path on R2 |
|-----------------|---------------------|
| `scripts/pipeline/sipni-pipeline-python.py` | `sipni/manifest.json` |
| `scripts/pipeline/sipni-covid-pipeline.py` | `sipni/covid/manifest.json` |
| `scripts/pipeline/sipni-agregados-doses-pipeline-r.R` | `sipni/agregados/doses/manifest.json` |
| `scripts/pipeline/sipni-agregados-cobertura-pipeline-r.R` | `sipni/agregados/cobertura/manifest.json` |

### Logic to add (at the end of each partition's processing)

**Python pipelines (microdados, COVID):**

```python
# After uploading Parquets for a partition:
import hashlib, json

manifest = load_manifest_from_r2()  # GET sipni/manifest.json, parse JSON
partition_key = f"{year}-{month:02d}"

manifest["partitions"][partition_key] = {
    "source_url": source_url,
    "source_size_bytes": source_size,
    "source_etag": source_etag,
    "source_last_modified": source_last_modified,
    "processing_timestamp": datetime.now(timezone.utc).isoformat(),
    "output_files": [
        {
            "path": f"sipni/microdados/ano={year}/mes={month:02d}/uf={uf}/part-0.parquet",
            "size_bytes": file_size,
            "sha256": hashlib.sha256(file_bytes).hexdigest(),
            "record_count": record_count,
        }
        for uf, file_size, file_bytes, record_count in output_files
    ],
    "total_records": total_records,
    "total_size_bytes": total_parquet_size,
}
manifest["last_updated"] = datetime.now(timezone.utc).isoformat()
upload_manifest_to_r2(manifest)
```

**R pipelines (agregados):**

```r
# After uploading Parquets for a year:
# Use jsonlite to read/write manifest, rclone to upload
manifest <- jsonlite::fromJSON(
  system("rclone cat r2:healthbr-data/sipni/agregados/doses/manifest.json",
         intern = TRUE) |> paste(collapse = "\n")
)
# ... update manifest$partitions[[key]] ...
jsonlite::write_json(manifest, "/tmp/manifest.json", auto_unbox = TRUE)
system("rclone copyto /tmp/manifest.json r2:healthbr-data/sipni/agregados/doses/manifest.json --transfers 16 --checkers 32")
```

### SHA-256 at write time

From this point forward, SHA-256 of each output Parquet file will be
computed immediately after writing and before uploading. This is trivial
since the file is still in local storage. The retroactive manifests
(Etapa 1) will have `sha256: null` for existing files — this is
acceptable and documented.

### Verification

After modifying a pipeline and running it for one partition:

```bash
rclone cat r2:healthbr-data/sipni/manifest.json | python3 -c "
import json, sys
m = json.load(sys.stdin)
latest = max(m['partitions'].keys())
p = m['partitions'][latest]
print(f'Latest: {latest}')
print(f'Records: {p[\"total_records\"]}')
print(f'SHA-256 present: {p[\"output_files\"][0].get(\"sha256\") is not None}')
"
```

---

## 6. Etapa 6 — Validation and Documentation

### Objective

Confirm everything works end-to-end and update project documentation.

### Checklist

- [ ] All 4 manifests exist on R2 and are valid JSON
- [ ] `sync_check.py` runs successfully and produces valid `sync-status.json`
- [ ] HF Space is live at `https://huggingface.co/spaces/SidneyBissoli/healthbr-sync-status`
- [ ] All 4 datasets appear in the dashboard with correct status
- [ ] GitHub Actions workflow runs successfully (manual trigger)
- [ ] `sync-status.json` is updated on both R2 and HF Space after workflow run

### Documentation updates

| Document | Update |
|----------|--------|
| `strategy-synchronization.md` | Change status from "Draft" to "Implemented". Add actual HF Space URL. Note any deviations from the original design. |
| `strategy-expansion-pt.md` section 8 | Update Phase 5 criteria for all 4 datasets: "Dashboard de sincronização ✅" |
| `reference-pipelines-pt.md` | Add note to each pipeline section about manifest generation |

---

## 7. Execution Summary

| Etapa | What | Artifacts produced | Runs where |
|:-----:|------|--------------------|------------|
| 1 | Retroactive manifests | `scripts/sync/generate-retroactive-manifests.py` + 4 `manifest.json` on R2 | Local or Hetzner |
| 2 | Comparison engine | `scripts/sync/sync_check.py` + `sync-status.json` | Local/Hetzner (dev), GitHub Actions (prod) |
| 3 | HF Space | `app.py`, `requirements.txt`, `README.md` in HF Space repo | Hugging Face |
| 4 | Scheduled workflow | `.github/workflows/sync-check.yml` + repo secrets | GitHub Actions |
| 5 | Pipeline integration | Modified pipeline scripts (4 files) | Hetzner (at pipeline runtime) |
| 6 | Validation | Documentation updates (3 files) | Local |

### Recommended execution order

```
Etapa 1 → Etapa 2 → Etapa 3 → Etapa 4 → Etapa 5 → Etapa 6
```

Etapas 1–3 are the core (manifest + engine + dashboard).
Etapa 4 is automation.
Etapa 5 is future-proofing (pipeline integration).
Etapa 6 is closure.

### Tool recommendation

**Execute everything via Claude Code.** Rationale:
- Etapas 1–2: Python scripts that need iterative development and testing
  against real S3/FTP endpoints.
- Etapa 3: File creation + git push to HF Space.
- Etapa 4: YAML file creation + guidance on configuring GitHub secrets.
- Etapa 5: Surgical edits to existing pipeline scripts.
- Etapa 6: Markdown edits to existing docs.

Claude Code's terminal access enables testing against live endpoints,
SSH to Hetzner if needed, and rapid iteration.
