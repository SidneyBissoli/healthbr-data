#!/usr/bin/env python3
"""
sync_check.py — Comparison engine for healthbr-data synchronization system.

Compares official data sources (OpenDATASUS S3, DATASUS FTP) with the
healthbr-data redistribution on Cloudflare R2, using manifest.json files
as the baseline. Produces sync-status.json for the dashboard.

Usage:
    python sync_check.py --output sync-status.json

Environment variables:
    R2_ACCESS_KEY_ID      R2 access key (read-only sufficient)
    R2_SECRET_ACCESS_KEY  R2 secret key
    R2_ENDPOINT           R2 S3-compatible endpoint URL

See: docs/strategy-synchronization.md, section 3 for comparison logic.
See: docs/implementation-synchronization.md, Etapa 2 for context.
"""

import argparse
import base64
import ftplib
import json
import os
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

import boto3

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

R2_BUCKET = "healthbr-data"
ENGINE_VERSION = "1.2.0"

# COVID baseline file — stores last successful API counts per UF.
# Used as fallback when the Elasticsearch API is unreachable (e.g.,
# from GitHub Actions runners outside Brazil that get 403 Forbidden).
# Updated automatically when the API succeeds; committed to the repo.
COVID_BASELINE_FILENAME = "covid-baseline.json"

# OpenDATASUS (microdata rotina)
OPENDATASUS_BASE = "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br"

# OpenDATASUS COVID — Elasticsearch API
# Public credentials published at:
#   https://opendatasus.saude.gov.br/dataset/covid-19-vacinacao
# Replaces the previous S3 HEAD approach, which broke whenever the
# government republished CSVs with new Spark hashes (403 errors).
ES_COVID_URL = "https://imunizacao-es.saude.gov.br/desc-imunizacao"
ES_COVID_USER = "imunizacao_public"
ES_COVID_PASS = "qlto5t&7r_@+#Tlstigi"

# DATASUS FTP (aggregated data)
DATASUS_FTP_HOST = "ftp.datasus.gov.br"
DATASUS_FTP_PATH = "/dissemin/publicos/PNI/DADOS/"

# DATASUS FTP (SINASC — live births)
SINASC_FTP_NOV = "/dissemin/publicos/SINASC/NOV/DNRES/"
SINASC_FTP_ANT = "/dissemin/publicos/SINASC/ANT/DNRES/"
SINASC_YEAR_START = 1994
SINASC_YEAR_END = 2022  # most recent year on FTP as of 2026-03-08

MONTHS_PT = ["jan", "fev", "mar", "abr", "mai", "jun",
             "jul", "ago", "set", "out", "nov", "dez"]

UFS = sorted([
    "AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO", "MA", "MG",
    "MS", "MT", "PA", "PB", "PE", "PI", "PR", "RJ", "RN", "RO", "RR",
    "RS", "SC", "SE", "SP", "TO",
])

# Network resilience
HTTP_TIMEOUT = 30
ES_TIMEOUT = 60  # Elasticsearch aggregations can take longer
FTP_TIMEOUT = 30
MAX_RETRIES = 3
RETRY_BACKOFF = 2  # seconds, multiplied by attempt number

# Empty .dbf files on DATASUS FTP are ~257 bytes (header only, 0 records).
# Files below this threshold are treated as "not published".
EMPTY_DBF_THRESHOLD = 500


# ---------------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------------


def http_head(url):
    """HTTP HEAD request with retry. Returns metadata dict."""
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            req = urllib.request.Request(url, method="HEAD")
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
                return {
                    "exists": True,
                    "size_bytes": int(resp.headers.get("Content-Length", 0)),
                    "etag": resp.headers.get("ETag", ""),
                    "last_modified": resp.headers.get("Last-Modified", ""),
                }
        except urllib.error.HTTPError as e:
            if e.code in (403, 404):
                # OpenDATASUS returns 403 for missing files (not 404)
                return {"exists": False}
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_BACKOFF * attempt)
                continue
            return {"exists": False, "error": f"HTTP {e.code}"}
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_BACKOFF * attempt)
                continue
            return {"exists": False, "error": "network error"}
    return {"exists": False, "error": "max retries"}


def es_query(endpoint, body=None):
    """
    Elasticsearch query with Basic Auth and retry.
    Returns parsed JSON response or {"error": str}.

    Uses public credentials from OpenDATASUS for COVID vaccination data.
    """
    credentials = base64.b64encode(
        f"{ES_COVID_USER}:{ES_COVID_PASS}".encode()
    ).decode()

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            req = urllib.request.Request(
                endpoint,
                method="POST" if body else "GET",
                headers={
                    "Authorization": f"Basic {credentials}",
                    "Content-Type": "application/json",
                },
            )
            if body:
                data = json.dumps(body).encode("utf-8")
            else:
                data = None

            with urllib.request.urlopen(req, data=data, timeout=ES_TIMEOUT) as resp:
                return json.loads(resp.read())

        except urllib.error.HTTPError as e:
            error_body = ""
            try:
                error_body = e.read().decode("utf-8", errors="replace")[:200]
            except Exception:
                pass
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_BACKOFF * attempt)
                continue
            return {"error": f"HTTP {e.code}: {error_body}"}
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_BACKOFF * attempt)
                continue
            return {"error": f"network error: {e}"}

    return {"error": "max retries"}


def es_count_by_uf():
    """
    Query Elasticsearch API for COVID vaccination record count per UF.
    Uses a terms aggregation on paciente_endereco_uf.

    Returns:
        {
            "success": bool,
            "total": int,              # total records in the index
            "counts": {"AC": N, ...},  # record count per UF
            "error": str | None,
        }
    """
    body = {
        "size": 0,
        "track_total_hits": True,
        "aggs": {
            "by_uf": {
                "terms": {
                    "field": "paciente_endereco_uf",
                    "size": 30,  # 27 UFs + margin
                }
            }
        },
    }

    result = es_query(f"{ES_COVID_URL}/_search", body)

    if "error" in result:
        return {
            "success": False,
            "total": 0,
            "counts": {},
            "error": result["error"],
        }

    try:
        total = result["hits"]["total"]["value"]
        buckets = result["aggregations"]["by_uf"]["buckets"]
        counts = {b["key"]: b["doc_count"] for b in buckets}
        return {
            "success": True,
            "total": total,
            "counts": counts,
            "error": None,
        }
    except (KeyError, TypeError) as e:
        return {
            "success": False,
            "total": 0,
            "counts": {},
            "error": f"Unexpected ES response structure: {e}",
        }


def ftp_list_pni():
    """
    Connect to DATASUS FTP and LIST the PNI/DADOS directory.
    Returns {"success": bool, "files": {FILENAME: size_bytes}, "error": str|None}.
    Single connection, reused for both doses and cobertura checks.
    """
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            ftp = ftplib.FTP(timeout=FTP_TIMEOUT)
            ftp.connect(DATASUS_FTP_HOST)
            ftp.login()  # anonymous

            lines = []
            ftp.retrlines(f"LIST {DATASUS_FTP_PATH}", lines.append)

            files = {}
            for line in lines:
                parts = line.split()
                if not parts:
                    continue
                name = parts[-1].upper()
                size = None
                # Windows format: "05-23-19  05:19PM  14843 FILENAME"
                if len(parts) >= 4 and parts[-2].isdigit():
                    size = int(parts[-2])
                # Unix format: "-rw-r--r-- 1 user group SIZE ... FILENAME"
                elif len(parts) >= 9:
                    try:
                        size = int(parts[4])
                    except ValueError:
                        pass
                if size is not None:
                    files[name] = size

            ftp.quit()
            return {"success": True, "files": files, "error": None}

        except (ftplib.all_errors, OSError, TimeoutError) as e:
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_BACKOFF * attempt)
                continue
            return {"success": False, "files": {}, "error": str(e)}

    return {"success": False, "files": {}, "error": "max retries"}


def ftp_list_sinasc():
    """
    Connect to DATASUS FTP and LIST both SINASC directories (NOV + ANT).
    Returns {"success": bool, "files": {FILENAME: size_bytes}, "error": str|None}.
    Filenames are uppercased for consistent comparison.
    """
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            ftp = ftplib.FTP(timeout=FTP_TIMEOUT)
            ftp.connect(DATASUS_FTP_HOST)
            ftp.login()  # anonymous

            files = {}
            for ftp_path in (SINASC_FTP_NOV, SINASC_FTP_ANT):
                lines = []
                ftp.retrlines(f"LIST {ftp_path}", lines.append)

                for line in lines:
                    parts = line.split()
                    if not parts:
                        continue
                    name = parts[-1].upper()
                    size = None
                    # Windows format: "05-23-19  05:19PM  14843 FILENAME"
                    if len(parts) >= 4 and parts[-2].isdigit():
                        size = int(parts[-2])
                    # Unix format: "-rw-r--r-- 1 user group SIZE ... FILENAME"
                    elif len(parts) >= 9:
                        try:
                            size = int(parts[4])
                        except ValueError:
                            pass
                    if size is not None:
                        files[name] = size

            ftp.quit()
            return {"success": True, "files": files, "error": None}

        except (ftplib.all_errors, OSError, TimeoutError) as e:
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_BACKOFF * attempt)
                continue
            return {"success": False, "files": {}, "error": str(e)}

    return {"success": False, "files": {}, "error": "max retries"}


# ---------------------------------------------------------------------------
# R2 helpers
# ---------------------------------------------------------------------------


def get_r2_client():
    """Create boto3 S3 client for Cloudflare R2."""
    missing = [v for v in ("R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_ENDPOINT")
               if v not in os.environ]
    if missing:
        print(f"ERROR: missing env vars: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)
    return boto3.client(
        "s3",
        endpoint_url=os.environ["R2_ENDPOINT"],
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
    )


def load_manifest(r2_client, key):
    """Load manifest.json from R2. Returns dict or None."""
    try:
        resp = r2_client.get_object(Bucket=R2_BUCKET, Key=key)
        return json.loads(resp["Body"].read())
    except Exception as e:
        print(f"  WARNING: cannot load {key}: {e}", file=sys.stderr)
        return None


# ---------------------------------------------------------------------------
# COVID baseline helpers
# ---------------------------------------------------------------------------


def load_covid_baseline(baseline_dir):
    """
    Load COVID baseline counts from covid-baseline.json.
    Returns {"total": N, "counts": {"AC": N, ...}, "timestamp": str} or None.
    """
    path = Path(baseline_dir) / COVID_BASELINE_FILENAME
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if "counts" in data and isinstance(data["counts"], dict):
            return data
        return None
    except (json.JSONDecodeError, OSError) as e:
        print(f"  WARNING: cannot load baseline: {e}", file=sys.stderr)
        return None


def save_covid_baseline(baseline_dir, total, counts):
    """
    Save COVID baseline counts to covid-baseline.json.
    Called when the Elasticsearch API succeeds.
    """
    path = Path(baseline_dir) / COVID_BASELINE_FILENAME
    data = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": "elasticsearch_api",
        "endpoint": ES_COVID_URL,
        "total": total,
        "counts": counts,
    }
    try:
        path.write_text(
            json.dumps(data, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        print(f"  sipni-covid: baseline saved to {path}")
    except OSError as e:
        print(f"  WARNING: cannot save baseline: {e}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Status classification
# ---------------------------------------------------------------------------


def classify(source_exists, has_manifest, manifest_part, source_meta):
    """
    Classify sync status for a partition.
    Returns (status, notes).

    Statuses: in_sync, outdated, missing, not_published, extra, check_failed
    """
    # Network error → can't determine
    if source_meta.get("error"):
        return "check_failed", f"Source check error: {source_meta['error']}"

    if not source_exists and not has_manifest:
        return "not_published", None

    if source_exists and not has_manifest:
        return "missing", "Source available, not yet processed"

    if not source_exists and has_manifest:
        return "extra", "In redistribution but not found at source"

    # Both exist — check if source was updated after last processing
    stored_etag = (manifest_part or {}).get("source_etag")
    stored_size = (manifest_part or {}).get("source_size_bytes")
    current_etag = source_meta.get("etag", "")
    current_size = source_meta.get("size_bytes")

    # ETag comparison (primary signal)
    if stored_etag and current_etag and stored_etag != current_etag:
        return "outdated", "Source ETag changed since last processing"

    # Size comparison (secondary signal — FTP has no ETag)
    if stored_size and current_size and stored_size != current_size:
        return "outdated", f"Source size changed ({stored_size} -> {current_size})"

    return "in_sync", None


def classify_covid(source_count, manifest_part):
    """
    Classify sync status for a COVID partition using record count comparison.
    Returns (status, notes).

    Unlike the generic classify(), this uses the Elasticsearch API record
    count as the source signal instead of S3 ETags/sizes.
    """
    has_manifest = manifest_part is not None

    if source_count is None and not has_manifest:
        return "not_published", None

    if source_count is not None and source_count > 0 and not has_manifest:
        return "missing", f"Source has {source_count:,} records, not yet processed"

    if (source_count is None or source_count == 0) and has_manifest:
        return "extra", "In redistribution but not found at source"

    # Both exist — compare record counts
    manifest_records = manifest_part.get("total_records") or 0

    if source_count > manifest_records:
        diff = source_count - manifest_records
        return "outdated", (
            f"Source has {diff:,} new records "
            f"({manifest_records:,} -> {source_count:,})"
        )

    if source_count < manifest_records:
        # Source has fewer records — possible reprocessing or data correction
        diff = manifest_records - source_count
        return "outdated", (
            f"Source has {diff:,} fewer records "
            f"({manifest_records:,} -> {source_count:,})"
        )

    return "in_sync", None


# ---------------------------------------------------------------------------
# Dataset checkers
# ---------------------------------------------------------------------------


def check_sipni_microdados(r2_client):
    """
    Check SI-PNI microdata (rotina): S3 HEAD per month (2020–present).
    URL patterns:
      PNI/json/vacinacao_{month_pt}_{year}.json.zip      (pre-2025)
      PNI/json/vacinacao_{month_pt}_{year}_json.zip       (2025+)
    """
    print("  sipni-microdados: loading manifest...")
    manifest = load_manifest(r2_client, "sipni/manifest.json")
    if not manifest:
        return {
            "status": "check_failed", "summary": {}, "details": [],
            "error": "Could not load manifest",
        }

    partitions = manifest.get("partitions", {})
    now = datetime.now(timezone.utc)

    details = []
    counters = {}

    # Check all months from 2020-01 through current month
    print("  sipni-microdados: checking source ", end="", flush=True)
    for year in range(2020, now.year + 1):
        max_month = now.month if year == now.year else 12
        for month in range(1, max_month + 1):
            key = f"{year}-{month:02d}"
            month_pt = MONTHS_PT[month - 1]

            # Try both URL patterns
            urls = [
                f"{OPENDATASUS_BASE}/PNI/json/vacinacao_{month_pt}_{year}.json.zip",
                f"{OPENDATASUS_BASE}/PNI/json/vacinacao_{month_pt}_{year}_json.zip",
            ]

            source = {"exists": False}
            used_url = urls[0]
            for url in urls:
                result = http_head(url)
                if result.get("exists"):
                    source = result
                    used_url = url
                    break
                # If error (not just 403/404), propagate it
                if result.get("error"):
                    source = result
                    break

            mpart = partitions.get(key)
            status, notes = classify(
                source.get("exists", False), mpart is not None, mpart, source,
            )
            counters[status] = counters.get(status, 0) + 1

            sym = {"in_sync": ".", "outdated": "!", "missing": "X",
                   "not_published": "-", "extra": "?", "check_failed": "E"}
            print(sym.get(status, "?"), end="", flush=True)

            details.append({
                "partition": key,
                "status": status,
                "source": {
                    "exists": source.get("exists", False),
                    "url": used_url,
                    "size_bytes": source.get("size_bytes"),
                    "etag": source.get("etag"),
                    "last_modified": source.get("last_modified"),
                },
                "redistribution": {
                    "exists": mpart is not None,
                    "total_records": mpart["total_records"] if mpart else None,
                    "total_size_bytes": mpart["total_size_bytes"] if mpart else None,
                    "output_file_count": len(mpart["output_files"]) if mpart else 0,
                    "processing_timestamp": (
                        mpart.get("processing_timestamp") if mpart else None
                    ),
                },
                "notes": notes,
            })

    print()

    overall = "in_sync"
    if counters.get("missing", 0) > 0 or counters.get("outdated", 0) > 0:
        overall = "outdated"
    if counters.get("check_failed", 0) > 0 and not counters.get("in_sync", 0):
        overall = "check_failed"

    return {
        "status": overall,
        "summary": {"total_checked": len(details), **counters},
        "details": details,
    }


def check_sipni_covid(r2_client, baseline_dir):
    """
    Check SI-PNI COVID microdata via Elasticsearch API with baseline fallback.

    Primary: queries the public Elasticsearch API at imunizacao-es.saude.gov.br
    for record counts per UF and compares against the manifest.

    Fallback: if the API is unreachable (e.g., 403 from non-Brazilian IPs),
    loads the last successful counts from covid-baseline.json.

    When the API succeeds, the baseline file is updated automatically.

    Source: https://opendatasus.saude.gov.br/dataset/covid-19-vacinacao
    Index: desc-imunizacao
    Auth: Basic (public credentials)
    """
    print("  sipni-covid: loading manifest...")
    manifest = load_manifest(r2_client, "sipni/covid/manifest.json")
    if not manifest:
        return {
            "status": "check_failed", "summary": {}, "details": [],
            "error": "Could not load manifest",
        }

    partitions = manifest.get("partitions", {})

    # Try Elasticsearch API first
    print("  sipni-covid: querying Elasticsearch API...", end=" ", flush=True)
    es_result = es_count_by_uf()
    source_type = "elasticsearch_api"
    source_note = None

    if es_result["success"]:
        print(f"OK ({es_result['total']:,} total records)")
        # Save successful result as baseline for future fallback
        save_covid_baseline(baseline_dir, es_result["total"], es_result["counts"])
        source_counts = es_result["counts"]
        source_total = es_result["total"]
    else:
        print(f"FAILED: {es_result['error']}")
        # Fallback to baseline
        print("  sipni-covid: loading baseline fallback...", end=" ", flush=True)
        baseline = load_covid_baseline(baseline_dir)
        if baseline is None:
            print("NOT FOUND")
            return {
                "status": "check_failed",
                "summary": {},
                "details": [],
                "error": (
                    f"Elasticsearch API failed: {es_result['error']}. "
                    f"No baseline file found at {baseline_dir}/{COVID_BASELINE_FILENAME}"
                ),
            }
        print(f"OK (baseline from {baseline.get('generated_at', 'unknown')})")
        source_counts = baseline["counts"]
        source_total = baseline.get("total", sum(baseline["counts"].values()))
        source_type = "baseline_fallback"
        source_note = f"API unavailable; using baseline from {baseline.get('generated_at', 'unknown')}"

    details = []
    counters = {}

    for uf in UFS:
        source_count = source_counts.get(uf)
        mpart = partitions.get(uf)

        status, notes = classify_covid(source_count, mpart)
        # Append baseline note if applicable
        if source_note and notes:
            notes = f"{notes} ({source_note})"
        elif source_note:
            notes = source_note
        counters[status] = counters.get(status, 0) + 1

        sym = {"in_sync": ".", "outdated": "!", "missing": "X",
               "not_published": "-", "extra": "?", "check_failed": "E"}
        print(sym.get(status, "?"), end="", flush=True)

        details.append({
            "partition": uf,
            "status": status,
            "source": {
                "type": source_type,
                "endpoint": ES_COVID_URL,
                "record_count": source_count,
            },
            "redistribution": {
                "exists": mpart is not None,
                "total_records": mpart.get("total_records") if mpart else None,
                "total_size_bytes": (
                    mpart.get("total_size_bytes") if mpart else None
                ),
                "output_file_count": (
                    len(mpart["output_files"]) if mpart else 0
                ),
                "processing_timestamp": (
                    mpart.get("processing_timestamp") if mpart else None
                ),
            },
            "notes": notes,
        })

    print()

    overall = "in_sync"
    if counters.get("missing", 0) > 0 or counters.get("outdated", 0) > 0:
        overall = "outdated"
    if counters.get("check_failed", 0) > 0 and not counters.get("in_sync", 0):
        overall = "check_failed"

    return {
        "status": overall,
        "summary": {
            "total_checked": len(details),
            "source_total_records": source_total,
            **counters,
        },
        "details": details,
    }


def check_sipni_agregados(r2_client, tipo, ftp_listing):
    """
    Check SI-PNI agregados (doses or cobertura) against FTP listing.

    tipo: "doses" or "cobertura"
    ftp_listing: pre-fetched result from ftp_list_pni()
    File patterns: DPNIUFYY.DBF (doses), CPNIUFYY.DBF (cobertura)
    """
    prefix_char = "D" if tipo == "doses" else "C"
    manifest_key = f"sipni/agregados/{tipo}/manifest.json"

    print(f"  sipni-agregados-{tipo}: loading manifest...")
    manifest = load_manifest(r2_client, manifest_key)
    if not manifest:
        return {
            "status": "check_failed", "summary": {}, "details": [],
            "error": "Could not load manifest",
        }

    if not ftp_listing["success"]:
        return {
            "status": "check_failed", "summary": {}, "details": [],
            "error": f"FTP failed: {ftp_listing['error']}",
        }

    partitions = manifest.get("partitions", {})
    ftp_files = ftp_listing["files"]

    details = []
    counters = {}

    for year in range(1994, 2020):
        yy = f"{year % 100:02d}"
        for uf in UFS:
            key = f"{year}-{uf}"
            filename = f"{prefix_char}PNI{uf}{yy}.DBF"

            ftp_size = ftp_files.get(filename)
            source_exists = (
                ftp_size is not None and ftp_size > EMPTY_DBF_THRESHOLD
            )

            source = {
                "exists": source_exists,
                "filename": filename,
                "size_bytes": ftp_size,
            }

            mpart = partitions.get(key)
            status, notes = classify(
                source_exists, mpart is not None, mpart, source,
            )
            counters[status] = counters.get(status, 0) + 1

            details.append({
                "partition": key,
                "status": status,
                "source": source,
                "redistribution": {
                    "exists": mpart is not None,
                    "total_records": (
                        mpart["total_records"] if mpart else None
                    ),
                    "total_size_bytes": (
                        mpart["total_size_bytes"] if mpart else None
                    ),
                    "processing_timestamp": (
                        mpart.get("processing_timestamp") if mpart else None
                    ),
                },
                "notes": notes,
            })

    n = len(details)
    sync = counters.get("in_sync", 0)
    print(f"  sipni-agregados-{tipo}: {n} checked, {sync} in_sync")

    overall = "in_sync"
    if counters.get("missing", 0) > 0 or counters.get("outdated", 0) > 0:
        overall = "outdated"

    return {
        "status": overall,
        "summary": {"total_checked": n, **counters},
        "details": details,
    }


def check_sinasc(r2_client, ftp_listing):
    """
    Check SINASC (live births) against FTP listing.

    FTP file patterns:
      Modern (1996–2022): DN{UF}{YYYY}.DBC  in NOV/DNRES/
      Old    (1994–1995): DNR{UF}{YYYY}.DBC in ANT/DNRES/

    Manifest partition keys: "{year}-{uf}" (e.g., "2022-SP")
    """
    print("  sinasc: loading manifest...")
    manifest = load_manifest(r2_client, "sinasc/manifest.json")
    if not manifest:
        return {
            "status": "check_failed", "summary": {}, "details": [],
            "error": "Could not load manifest",
        }

    if not ftp_listing["success"]:
        return {
            "status": "check_failed", "summary": {}, "details": [],
            "error": f"FTP failed: {ftp_listing['error']}",
        }

    partitions = manifest.get("partitions", {})
    ftp_files = ftp_listing["files"]

    details = []
    counters = {}

    for year in range(SINASC_YEAR_START, SINASC_YEAR_END + 1):
        for uf in UFS:
            key = f"{year}-{uf}"

            # Build expected filename (matches pipeline info_arquivo logic)
            if year <= 1995:
                filename = f"DNR{uf}{year}.DBC"
            else:
                filename = f"DN{uf}{year}.DBC"

            ftp_size = ftp_files.get(filename)
            # .dbc files can be small but valid; use a lower threshold
            # than .dbf (header-only .dbc is ~100 bytes)
            source_exists = ftp_size is not None and ftp_size > EMPTY_DBF_THRESHOLD

            source = {
                "exists": source_exists,
                "filename": filename,
                "size_bytes": ftp_size,
            }

            mpart = partitions.get(key)
            status, notes = classify(
                source_exists, mpart is not None, mpart, source,
            )
            counters[status] = counters.get(status, 0) + 1

            details.append({
                "partition": key,
                "status": status,
                "source": source,
                "redistribution": {
                    "exists": mpart is not None,
                    "total_records": (
                        mpart["total_records"] if mpart else None
                    ),
                    "total_size_bytes": (
                        mpart["total_size_bytes"] if mpart else None
                    ),
                    "processing_timestamp": (
                        mpart.get("processing_timestamp") if mpart else None
                    ),
                },
                "notes": notes,
            })

    n = len(details)
    sync = counters.get("in_sync", 0)
    print(f"  sinasc: {n} checked, {sync} in_sync")

    overall = "in_sync"
    if counters.get("missing", 0) > 0 or counters.get("outdated", 0) > 0:
        overall = "outdated"

    return {
        "status": overall,
        "summary": {"total_checked": n, **counters},
        "details": details,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Compare official sources with healthbr-data redistribution on R2."
        ),
    )
    parser.add_argument(
        "--output", "-o", required=True,
        help="Path for sync-status.json output.",
    )
    parser.add_argument(
        "--baseline-dir", "-b",
        default=str(Path(__file__).parent),
        help=(
            "Directory for covid-baseline.json (default: same as this script). "
            "The baseline is loaded as fallback when the ES API is unreachable, "
            "and updated automatically when the API succeeds."
        ),
    )
    args = parser.parse_args()
    baseline_dir = Path(args.baseline_dir)

    r2_client = get_r2_client()
    now = datetime.now(timezone.utc)

    print(f"healthbr-data sync check — {now.strftime('%Y-%m-%d %H:%M UTC')}")
    print("=" * 60)

    results = {}

    # --- S3-based datasets (HTTP HEAD requests) ---
    results["sipni-microdados"] = check_sipni_microdados(r2_client)

    # --- Elasticsearch-based datasets (with baseline fallback) ---
    results["sipni-covid"] = check_sipni_covid(r2_client, baseline_dir)

    # --- FTP-based datasets (single connection, reused) ---
    print("  Connecting to DATASUS FTP...")
    ftp_listing = ftp_list_pni()
    if ftp_listing["success"]:
        print(f"  FTP: {len(ftp_listing['files'])} files listed")
    else:
        print(f"  FTP FAILED: {ftp_listing['error']}", file=sys.stderr)

    results["sipni-agregados-doses"] = check_sipni_agregados(
        r2_client, "doses", ftp_listing,
    )
    results["sipni-agregados-cobertura"] = check_sipni_agregados(
        r2_client, "cobertura", ftp_listing,
    )

    # --- FTP-based datasets: SINASC (separate connection) ---
    print("  Connecting to DATASUS FTP (SINASC)...")
    sinasc_listing = ftp_list_sinasc()
    if sinasc_listing["success"]:
        print(f"  FTP SINASC: {len(sinasc_listing['files'])} files listed")
    else:
        print(f"  FTP SINASC FAILED: {sinasc_listing['error']}", file=sys.stderr)

    results["sinasc"] = check_sinasc(r2_client, sinasc_listing)

    # --- Assemble output ---
    output = {
        "generated_at": now.isoformat(),
        "engine_version": ENGINE_VERSION,
        "datasets": results,
    }

    # --- Summary ---
    print("\n" + "=" * 60)
    print("Summary:")
    for name, ds in results.items():
        s = ds.get("summary", {})
        parts = []
        for k in ("in_sync", "outdated", "missing", "not_published",
                   "extra", "check_failed"):
            v = s.get(k, 0)
            if v > 0:
                parts.append(f"{k}={v}")
        detail_str = ", ".join(parts) if parts else "no data"
        print(f"  {name}: {ds['status']} ({detail_str})")

    # --- Write output ---
    out_path = Path(args.output)
    out_path.write_text(
        json.dumps(output, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    print(f"\nOutput written to: {out_path}")
    print(f"File size: {out_path.stat().st_size / 1024:.0f} KB")


if __name__ == "__main__":
    main()
