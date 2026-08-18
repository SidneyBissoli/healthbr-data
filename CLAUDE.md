# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

**healthbr-data** redistributes Brazilian public health data (DATASUS/OpenDATASUS) as
hive-partitioned Parquet on Cloudflare R2 (bucket `healthbr-data`, free egress, public
read-only S3 keys in the README). This repo holds the *pipelines, automation and docs* —
the data itself lives only in R2. There is no application to build; "running" something
means running a pipeline, the sync engine, or the maintenance tooling.

Docs are Portuguese-first; code comments/log messages are mixed PT/EN. Keep that style.
The canonical operational reference is `docs/reference-pipelines-pt.md` (one section per
pipeline + §15 automated maintenance) — update it whenever pipeline behaviour changes,
and bump its "Última atualização" footer.

## Non-negotiable data principles (see docs/project-pt.md §9)

- **Publish exactly what the Ministry publishes.** No cleaning, no recoding, no date
  normalisation, no CID remapping, no schema unification across eras (except the
  documented SINASC 1994–95 rename). Convenience belongs in the future `healthbR`
  package, not in the data.
- **All Parquet columns are strings.** Every pipeline reads with `colClasses = "character"` /
  polars `Utf8`.
- **Partition layout is stable and public API**: `ano=YYYY/mes=MM/uf=XX/` (SI-PNI, SIH),
  `ano=YYYY/uf=XX/` (SINASC). Changing it breaks users' `open_dataset()` calls.
- **Namespaces**: a system with several sub-datasets gets a parent prefix with short
  sub-prefixes (`sipni/microdados/`, `sipni/covid/`, `sih/rd/`, `sih/sp/`); flat ids with
  hyphens (`sipni-covid`, `sih-rd`) are used outside R2 — sync-status keys, HF repos, CSV
  names. Never nest a sub-dataset directly under a prefix that already holds `ano=` dirs
  (Arrow would recurse into it).
- **Reproducibility is mandatory, versioning is not** (`docs/policy-reproducibility-pt.md`):
  every Parquet carries `healthbr` schema metadata (source_url, source MD5/size,
  download_date, pipeline_script, pipeline_version, git_commit); the manifest and the
  control CSV record the same facts. Bump `PIPELINE_VERSION` when output changes. Data
  are overwritten on source revision — no `_history/`, no raw-file retention (the
  `_raw/` mirror is a bootstrap aid, deleted afterwards). Run pipelines from a git clone
  (or set `HEALTHBR_GIT_COMMIT`); `git_commit = "unknown"` in production is a defect.
  Parquets from the 1.0.0 bootstraps of SIH RD / SINASC got their metadata via
  `scripts/maintenance/backfill-metadata.py` (metadata-only rewrite, `git_commit_inferred`).

## Datasets and pipelines

| Dataset (R2 prefix) | Pipeline | Lang | Source | Version-control CSV |
|---|---|---|---|---|
| `sipni/microdados/` | `scripts/pipeline/sipni-microdata-pipeline-python.py` | Python (jq+polars) | OpenDATASUS JSON zips, per month | `data/controle_versao_microdata.csv` |
| `sipni/covid/microdados/` | `scripts/pipeline/sipni-covid-pipeline.py` | Python (polars) | OpenDATASUS CSV, per UF | `data/controle_versao_covid.csv` |
| `sipni/agregados/{doses,cobertura}/` | `sipni-agregados-*-pipeline-r.R` | R (foreign) | DATASUS FTP .dbf, 1994–2019 (static) | `controle_versao_sipni_agregados_*.csv` |
| `sipni/dicionarios/` | `sipni-dicionarios-pipeline-r.R` | R | .cnv/.dbf (static) | none |
| `sinasc/` | `sinasc-pipeline-r.R` | R (read.dbc) | DATASUS FTP .dbc, 1994–2022 | `controle_versao_sinasc.csv` |
| `sih/rd/` (AIH reduzida) | `sih-pipeline-r.R` (`SIH_TIPO=RD`, default) | R (read.dbc) | DATASUS FTP .dbc, 1992–present | `controle_versao_sih_rd.csv` |
| `sih/sp/` (serviços profissionais) | `sih-pipeline-r.R` (`SIH_TIPO=SP`) | R (read.dbc) | DATASUS FTP .dbc, 1997–present | `controle_versao_sih_sp.csv` |

Shared mechanics every pipeline follows:
- **Version-control CSV = the source of truth for "already processed".** Pipelines skip
  any file/month present in their CSV. To force reprocessing, delete the row (this is what
  `prepare_maintenance.py` does for outdated SIH/SINASC partitions). Python pipelines
  additionally detect source changes by ETag/hash.
- **Staging → `rclone` upload → `manifest.json` update** per batch. Manifests
  (`<prefix>/manifest.json`) are what the sync engine compares against sources. Python
  uses `scripts/pipeline/manifest_utils.py` (boto3, needs `R2_*` env vars; silently skipped
  if absent); R pipelines each define `update_manifest_r2()` on top of the configured
  `rclone` remote `r2`.
- Pipelines are designed to run on an ephemeral **Hetzner VPS (Ubuntu, x86)**, not locally:
  R `parallel::mclapply` prefetch is unix-only, paths like `/root/...` are assumed. On
  Windows you can parse-check and unit-test, not run end-to-end.
- SIH: one script for both file types — `SIH_TIPO=RD|SP` picks prefix/CSV/first year
  (RD 1992, SP 1997; both eras share the FTP naming `{TIPO}{UF}{AAMM}.dbc`; SP has 3
  schemas 16/18/36 cols, RD 14 schemas). `SIH_SPRINT` env (1 = 2008+, 2 = old era, 3 =
  both; maintenance uses 3); `SIH_WORKERS=N` processes the UFs of a month in N forked
  workers (unix only, default 1 — use for bootstraps/backfills from the R2 mirror);
  persists **per month** (upload + manifest + CSV checkpoint); has an FTP circuit breaker
  (`SIH_FTP_FALHAS_LIMIAR`/`SIH_FTP_PROBE_TENTATIVAS`/`SIH_FTP_PROBE_ESPERA`) that exits
  **75** when the DATASUS FTP is down — the orchestrator treats 75 as "resume next run",
  not as a pipeline failure.

## Sync + automated maintenance (the part that spans many files)

```
.github/workflows/sync-check.yml   (Mon 03:00 UTC, or push to data/controle_versao_*.csv)
  └─ scripts/sync/sync_check.py → sync-status.json → R2 + HF Space dashboard
     └─ if missing/outdated in an automated dataset (never on push events):
        gh workflow run maintenance.yml
.github/workflows/maintenance.yml  (launch-and-exit, ~2 min; aborts if a maint VPS exists)
  └─ creates Hetzner cpx42 from snapshot labelled healthbr=maintenance, cloud-init runs:
     scripts/maintenance/run-maintenance.sh
       1. restore data/controle_versao_*.csv checkpoints from r2:maintenance/checkpoints/
       2. scripts/maintenance/prepare_maintenance.py → which datasets to run (+ prunes CSVs)
       3. run pipelines in order sinasc → sipni-microdados → sipni-covid → sih-rd → sih-sp,
          each under `timeout 14h` (sinasc 4h); log + checkpoints pushed to R2 after each
       4. commit + push controle CSVs as healthbr-maintenance-bot (this push re-triggers
          sync-check to refresh the dashboard)
       5. write r2:maintenance/last-run.json ("started" left there = run died)
     then upload last-run.log and `hcloud server delete $(hostname)`
.github/workflows/maintenance-reaper.yml (every 3h): deletes maint VPS that are off or >48h old
```

Automated datasets: sinasc, sih-rd, sih-sp, sipni-microdados, sipni-covid. Aggregates and dictionaries
are static — drift there is anomalous and handled manually. `sipni-covid` only runs if
`data/controle_versao_covid.csv` exists in the repo.

Commits authored by `healthbr-maintenance-bot` touching only `data/controle_versao_*.csv`
are normal machine output — `git pull` before pushing; never rewrite them.

## Commands

```bash
# Syntax / unit checks that run on Windows (no network, no R2)
"/c/Program Files/R/R-4.6.1/bin/Rscript.exe" -e "invisible(parse('scripts/pipeline/sih-pipeline-r.R'))"
"/c/Program Files/R/R-4.6.1/bin/Rscript.exe" scripts/pipeline/sih-ftp-breaker-test.R   # 22 checks
bash -n scripts/maintenance/run-maintenance.sh scripts/maintenance/inspect-last-run.sh

# Sync engine locally (needs R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ENDPOINT)
python scripts/sync/sync_check.py --output sync-status.json

# Inspect the last maintenance run (R2), the live VPS log, or a local log
bash scripts/maintenance/inspect-last-run.sh
bash scripts/maintenance/inspect-last-run.sh --live
bash scripts/maintenance/inspect-last-run.sh --file /path/maintenance.log

# Trigger / watch automation
gh workflow run maintenance.yml -f reason="manual: <why>"
gh run list --limit 10
rclone cat r2:healthbr-data/maintenance/last-run.json

# Hetzner (hcloud is installed via winget, outside PATH)
HC=/c/Users/SIDNEY/AppData/Local/Microsoft/WinGet/Packages/HetznerCloud.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe/hcloud.exe
"$HC" --context healthbr server list --selector healthbr=maintenance-run
ssh -o StrictHostKeyChecking=no root@<ip>   # maint VPS reuse IPs → known_hosts warnings are expected

# Publish dataset cards (guides/dataset-cards/) to HF + R2 after editing them
python scripts/maintenance/publish-cards.py sih-sp sinasc      # or --all, --only hf|r2, --dry-run

# Rebuild the maintenance snapshot after changing the R/Python stack
# (follow the header of scripts/maintenance/setup-snapshot.sh)
```

Local `rclone` remote is named `r2`; the pipelines and scripts hard-code that name.
Real pipeline runs happen on the VPS (see "Rodar e monitorar" in each section of
`docs/reference-pipelines-pt.md`).

## Layout pointers

- `docs/` — strategy/decision docs (`project-pt.md` is the "why", `reference-pipelines-pt.md`
  the "how", `contract-consumers-pt.md` what consumers such as `healthbR` may assume — update
  it when a guarantee changes), per-dataset `*/exploration-pt.md` (schema archaeology, eras, quirks).
- `guides/dataset-cards/` — bilingual READMEs published to HF/R2 for each dataset; keep
  record counts there in sync with the README tables when a dataset changes.
- `scripts/exploration/` — one-off R exploration; `archive/` — superseded pipeline versions.
- `scripts/sync/hf-space/` — clone of the HF Space (dashboard); it has its own git.
- `data/exploration/` is gitignored scratch; `data/controle_versao_*.csv` is tracked state.
