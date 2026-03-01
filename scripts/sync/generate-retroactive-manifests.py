#!/usr/bin/env python3
"""
generate-retroactive-manifests.py

Generates manifest.json for each of the 4 SI-PNI datasets already on R2,
using existing version control CSVs and R2 LIST operations.

This is a one-time retroactive generation. Future pipeline runs (Etapa 5)
will update manifests at write time with SHA-256 checksums.

Usage:
    python generate-retroactive-manifests.py              # generate and upload
    python generate-retroactive-manifests.py --dry-run    # generate locally only

Environment variables required:
    R2_ACCESS_KEY_ID      R2 access key (read-write)
    R2_SECRET_ACCESS_KEY  R2 secret key
    R2_ENDPOINT           R2 S3-compatible endpoint URL

See: docs/strategy-synchronization.md, section 5.3 for manifest schema.
See: docs/implementation-synchronization.md, Etapa 1 for context.
"""

import argparse
import csv
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import boto3

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

R2_BUCKET = "healthbr-data"
MANIFEST_VERSION = "1.0.0"
PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent

DATASETS = [
    {
        "name": "sipni-microdados",
        "label": "SI-PNI microdados (2020+)",
        "manifest_key": "sipni/manifest.json",
        "r2_prefix": "sipni/microdados/",
        "csv_file": "controle_versao_microdata.csv",
        "type": "microdata",
    },
    {
        "name": "sipni-covid",
        "label": "SI-PNI COVID microdados",
        "manifest_key": "sipni/covid/manifest.json",
        "r2_prefix": "sipni/covid/microdados/",
        "csv_file": "controle_versao_covid.csv",
        "type": "covid",
    },
    {
        "name": "sipni-agregados-doses",
        "label": "SI-PNI agregados doses (1994-2019)",
        "manifest_key": "sipni/agregados/doses/manifest.json",
        "r2_prefix": "sipni/agregados/doses/",
        "csv_file": "controle_versao_sipni_agregados_doses.csv",
        "type": "agregados",
    },
    {
        "name": "sipni-agregados-cobertura",
        "label": "SI-PNI agregados cobertura (1994-2019)",
        "manifest_key": "sipni/agregados/cobertura/manifest.json",
        "r2_prefix": "sipni/agregados/cobertura/",
        "csv_file": "controle_versao_sipni_agregados_cobertura.csv",
        "type": "agregados",
    },
]

# ---------------------------------------------------------------------------
# R2 helpers
# ---------------------------------------------------------------------------


def get_r2_client():
    """Create boto3 S3 client for Cloudflare R2."""
    missing = [v for v in ("R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_ENDPOINT")
               if v not in os.environ]
    if missing:
        print(f"ERROR: missing environment variables: {', '.join(missing)}",
              file=sys.stderr)
        sys.exit(1)
    return boto3.client(
        "s3",
        endpoint_url=os.environ["R2_ENDPOINT"],
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
    )


def list_r2_objects(client, prefix):
    """List all objects under a prefix, handling pagination."""
    objects = []
    paginator = client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=R2_BUCKET, Prefix=prefix):
        objects.extend(page.get("Contents", []))
    return objects


def upload_manifest(client, key, manifest_dict):
    """Upload manifest JSON to R2."""
    body = json.dumps(manifest_dict, indent=2, ensure_ascii=False)
    client.put_object(
        Bucket=R2_BUCKET,
        Key=key,
        Body=body.encode("utf-8"),
        ContentType="application/json",
    )


# ---------------------------------------------------------------------------
# R2 grouping: objects -> partition groups
# ---------------------------------------------------------------------------

RE_YM_UF = re.compile(r"ano=(\d{4})/mes=(\d{2})/uf=([A-Z]{2})/")
RE_Y_UF = re.compile(r"ano=(\d{4})/uf=([A-Z]{2})/")


def group_by_year_month(objects):
    """Group Parquet files by YYYY-MM partition key."""
    groups = defaultdict(list)
    for obj in objects:
        key = obj["Key"]
        if not key.endswith(".parquet"):
            continue
        m = RE_YM_UF.search(key)
        if m:
            partition = f"{m.group(1)}-{m.group(2)}"
            groups[partition].append({
                "path": key,
                "size_bytes": obj["Size"],
                "sha256": None,
                "record_count": None,
            })
    return groups


def group_by_uf(objects):
    """Group Parquet files by UF partition key (for COVID)."""
    groups = defaultdict(list)
    skipped_invalid = 0
    for obj in objects:
        key = obj["Key"]
        if not key.endswith(".parquet"):
            continue
        # Skip _invalid partitions (records with dates outside expected range)
        if "/ano=_invalid/" in key:
            skipped_invalid += 1
            continue
        m = RE_YM_UF.search(key)
        if m:
            uf = m.group(3)
            groups[uf].append({
                "path": key,
                "size_bytes": obj["Size"],
                "sha256": None,
                "record_count": None,
            })
    if skipped_invalid:
        print(f"  (skipped {skipped_invalid} files in ano=_invalid/)")
    return groups


def group_by_year_uf(objects):
    """Group Parquet files by YYYY-UF partition key (for agregados)."""
    groups = defaultdict(list)
    for obj in objects:
        key = obj["Key"]
        if not key.endswith(".parquet"):
            continue
        m = RE_Y_UF.search(key)
        if m:
            partition = f"{m.group(1)}-{m.group(2)}"
            groups[partition].append({
                "path": key,
                "size_bytes": obj["Size"],
                "sha256": None,
                "record_count": None,
            })
    return groups


# ---------------------------------------------------------------------------
# Partition builders: CSV + R2 groups -> partitions dict
# ---------------------------------------------------------------------------


def build_microdata_partitions(csv_path, r2_groups):
    """Build partitions for SI-PNI microdata (rotina)."""
    partitions = {}
    with open(csv_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            year, month = int(row["ano"]), int(row["mes"])
            key = f"{year}-{month:02d}"
            files = sorted(r2_groups.get(key, []), key=lambda x: x["path"])
            total_size = sum(fi["size_bytes"] for fi in files)
            partitions[key] = {
                "source_url": row["url_origem"],
                "source_size_bytes": int(row["content_length"]),
                "source_etag": row["etag_servidor"],
                "source_last_modified": None,
                "processing_timestamp": row["data_processamento"],
                "output_files": files,
                "total_records": int(row["n_registros"]),
                "total_size_bytes": total_size,
            }
    return partitions


def build_covid_partitions_from_csv(csv_path, r2_groups):
    """Build partitions for COVID from version control CSV."""
    partitions = {}
    with open(csv_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            uf = row["uf"]
            files = sorted(r2_groups.get(uf, []), key=lambda x: x["path"])
            total_size = sum(fi["size_bytes"] for fi in files)
            partitions[uf] = {
                "source_url": (
                    "https://s3.sa-east-1.amazonaws.com/"
                    f"ckan.saude.gov.br/SIPNI/COVID/uf/uf%3D{uf}/"
                ),
                "source_size_bytes": int(row["content_length_total"]),
                "source_etag": row["etags_concat"],
                "source_last_modified": None,
                "processing_timestamp": row["data_processamento"],
                "output_files": files,
                "total_records": int(row["n_registros"]),
                "total_size_bytes": total_size,
            }
    return partitions


def build_covid_partitions_from_r2(r2_groups):
    """Build partitions for COVID from R2 LIST only (no CSV available)."""
    partitions = {}
    for uf in sorted(r2_groups):
        files = sorted(r2_groups[uf], key=lambda x: x["path"])
        total_size = sum(fi["size_bytes"] for fi in files)
        partitions[uf] = {
            "source_url": (
                "https://s3.sa-east-1.amazonaws.com/"
                f"ckan.saude.gov.br/SIPNI/COVID/uf/uf%3D{uf}/"
            ),
            "source_size_bytes": None,
            "source_etag": None,
            "source_last_modified": None,
            "processing_timestamp": None,
            "output_files": files,
            "total_records": None,
            "total_size_bytes": total_size,
        }
    return partitions


def build_agregados_partitions(csv_path, r2_groups):
    """Build partitions for agregados (doses or cobertura)."""
    partitions = {}
    with open(csv_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            n_registros = int(row["n_registros"])
            if n_registros == 0:
                continue  # Skip empty DBFs (not uploaded to R2)
            year, uf = row["ano"], row["uf"]
            key = f"{year}-{uf}"
            files = sorted(r2_groups.get(key, []), key=lambda x: x["path"])
            total_size = sum(fi["size_bytes"] for fi in files)
            partitions[key] = {
                "source_url": (
                    "ftp://ftp.datasus.gov.br/dissemin/publicos/"
                    f"PNI/DADOS/{row['arquivo']}"
                ),
                "source_size_bytes": int(row["tamanho_bytes"]),
                "source_etag": None,
                "source_last_modified": None,
                "source_md5": row["hash_md5"],
                "processing_timestamp": row["data_processamento"],
                "output_files": files,
                "total_records": n_registros,
                "total_size_bytes": total_size,
            }
    return partitions


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Generate retroactive manifest.json for SI-PNI datasets on R2.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Save manifests locally without uploading to R2.",
    )
    args = parser.parse_args()

    client = get_r2_client()
    now = datetime.now(timezone.utc).isoformat()
    data_dir = PROJECT_ROOT / "data"

    for ds in DATASETS:
        print(f"\n{'=' * 60}")
        print(f"  {ds['label']}")
        print(f"{'=' * 60}")

        # --- Locate version control CSV ---
        csv_path = data_dir / ds["csv_file"]
        csv_available = csv_path.exists()
        if not csv_available:
            if ds["type"] == "covid":
                print(f"  WARNING: {ds['csv_file']} not found locally.")
                print(f"  Generating manifest from R2 LIST only (no source metadata).")
            else:
                print(f"  ERROR: {ds['csv_file']} not found. Skipping.",
                      file=sys.stderr)
                continue

        # --- LIST R2 objects ---
        print(f"  Listing R2: {ds['r2_prefix']}...")
        objects = list_r2_objects(client, ds["r2_prefix"])
        parquet_count = sum(1 for o in objects if o["Key"].endswith(".parquet"))
        print(f"  Found {parquet_count} Parquet files ({len(objects)} total objects)")

        # --- Group by partition ---
        if ds["type"] == "microdata":
            r2_groups = group_by_year_month(objects)
        elif ds["type"] == "covid":
            r2_groups = group_by_uf(objects)
        elif ds["type"] == "agregados":
            r2_groups = group_by_year_uf(objects)
        else:
            raise ValueError(f"Unknown dataset type: {ds['type']}")
        print(f"  Grouped into {len(r2_groups)} partitions")

        # --- Build partitions from CSV + R2 ---
        if ds["type"] == "microdata":
            partitions = build_microdata_partitions(csv_path, r2_groups)
        elif ds["type"] == "covid":
            if csv_available:
                partitions = build_covid_partitions_from_csv(csv_path, r2_groups)
            else:
                partitions = build_covid_partitions_from_r2(r2_groups)
        elif ds["type"] == "agregados":
            partitions = build_agregados_partitions(csv_path, r2_groups)

        # --- Cross-check: R2 partitions not in CSV ---
        csv_keys = set(partitions.keys())
        r2_keys = set(r2_groups.keys())
        r2_only = r2_keys - csv_keys
        csv_only = csv_keys - r2_keys
        if r2_only:
            print(f"  NOTE: {len(r2_only)} R2 partitions not in CSV: "
                  f"{sorted(r2_only)[:5]}{'...' if len(r2_only) > 5 else ''}")
        if csv_only:
            # Partitions in CSV but no R2 files (unexpected)
            empty = [k for k in csv_only if not partitions[k]["output_files"]]
            if empty:
                print(f"  WARNING: {len(empty)} CSV partitions with no R2 files: "
                      f"{sorted(empty)[:5]}{'...' if len(empty) > 5 else ''}")

        # --- Assemble manifest ---
        manifest = {
            "manifest_version": MANIFEST_VERSION,
            "dataset": ds["name"],
            "last_updated": now,
            "pipeline_version": "1.0.0",
            "generated_retroactively": True,
            "partitions": dict(sorted(partitions.items())),
        }
        if ds["type"] == "covid" and not csv_available:
            manifest["note"] = (
                "Source metadata unavailable: version control CSV was not "
                "present locally during retroactive generation. Source fields "
                "will be populated when the comparison engine runs (Etapa 2) "
                "or when the pipeline is re-run (Etapa 5)."
            )

        # --- Summary stats ---
        total_records = sum(
            p["total_records"] for p in partitions.values()
            if p["total_records"] is not None
        )
        total_r2_bytes = sum(p["total_size_bytes"] for p in partitions.values())
        total_files = sum(len(p["output_files"]) for p in partitions.values())

        print(f"  Manifest summary:")
        print(f"    Partitions:    {len(partitions)}")
        print(f"    Output files:  {total_files}")
        print(f"    Total records: {total_records:,}")
        print(f"    R2 size:       {total_r2_bytes / 1e9:.2f} GB")

        # --- Upload or save locally ---
        if args.dry_run:
            out_dir = PROJECT_ROOT / "data"
            out_path = out_dir / f"manifest-{ds['name']}.json"
            out_path.write_text(
                json.dumps(manifest, indent=2, ensure_ascii=False),
                encoding="utf-8",
            )
            print(f"  DRY RUN: saved to {out_path.name}")
        else:
            upload_manifest(client, ds["manifest_key"], manifest)
            print(f"  UPLOADED: r2://{R2_BUCKET}/{ds['manifest_key']}")

    print(f"\n{'=' * 60}")
    print("  Done!")
    print(f"{'=' * 60}\n")


if __name__ == "__main__":
    main()
