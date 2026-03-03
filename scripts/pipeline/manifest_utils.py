#!/usr/bin/env python3
"""
manifest_utils.py — Shared utilities for manifest.json management on R2.

Used by pipeline scripts to update manifest.json after processing
each partition (Etapa 5 of the synchronization system).

See: docs/strategy-synchronization.md, section 5.3 for manifest schema.
See: docs/implementation-synchronization.md, Etapa 5 for context.
"""

import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import boto3


def get_r2_client():
    """Create boto3 S3 client for Cloudflare R2 using environment variables."""
    endpoint = os.environ.get("R2_ENDPOINT")
    access_key = os.environ.get("R2_ACCESS_KEY_ID")
    secret_key = os.environ.get("R2_SECRET_ACCESS_KEY")

    if not all([endpoint, access_key, secret_key]):
        # Fall back to None — caller should handle (e.g., use rclone instead)
        return None

    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )


def load_manifest(r2_client, bucket: str, key: str) -> dict:
    """Load manifest.json from R2. Returns empty manifest if not found."""
    try:
        resp = r2_client.get_object(Bucket=bucket, Key=key)
        return json.loads(resp["Body"].read())
    except Exception as e:
        print(f"  manifest: could not load {key}, starting fresh: {e}",
              file=sys.stderr)
        return {
            "manifest_version": "1.0.0",
            "dataset": key.split("/")[0],
            "last_updated": None,
            "pipeline_version": "1.0.0",
            "partitions": {},
        }


def upload_manifest(r2_client, bucket: str, key: str, manifest: dict):
    """Upload manifest.json to R2."""
    manifest["last_updated"] = datetime.now(timezone.utc).isoformat()
    body = json.dumps(manifest, indent=2, ensure_ascii=False)
    r2_client.put_object(
        Bucket=bucket,
        Key=key,
        Body=body.encode("utf-8"),
        ContentType="application/json",
    )
    print(f"  manifest: uploaded {key} ({len(body)} bytes)")


def sha256_file(path) -> str:
    """Compute SHA-256 hash of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def collect_output_files(staging_dir: Path, r2_prefix: str) -> list[dict]:
    """
    Walk a staging directory and collect metadata for each Parquet file.

    Returns a list of dicts with: path, size_bytes, sha256, record_count.
    record_count is set to None (would require reading each file with Arrow).
    """
    files = []
    for parquet_path in sorted(staging_dir.rglob("*.parquet")):
        rel_path = parquet_path.relative_to(staging_dir)
        r2_path = f"{r2_prefix}/{rel_path}".replace("\\", "/")
        files.append({
            "path": r2_path,
            "size_bytes": parquet_path.stat().st_size,
            "sha256": sha256_file(parquet_path),
            "record_count": None,  # Would need Arrow to read; skip for now
        })
    return files


def update_manifest_partition(
    r2_client,
    bucket: str,
    manifest_key: str,
    partition_key: str,
    source_url: str,
    source_size_bytes: int,
    source_etag: str,
    source_last_modified: str | None,
    staging_dir: Path,
    r2_prefix: str,
    total_records: int,
):
    """
    Load manifest, update a single partition, and upload back to R2.

    This is the main entry point for pipeline scripts.

    Parameters
    ----------
    r2_client : boto3 S3 client
    bucket : R2 bucket name
    manifest_key : Path to manifest.json on R2 (e.g., "sipni/manifest.json")
    partition_key : Partition identifier (e.g., "2024-01" or "2024-AC")
    source_url : URL of the source file
    source_size_bytes : Size of source file at processing time
    source_etag : ETag of source file at processing time
    source_last_modified : Last-Modified header of source (if available)
    staging_dir : Local directory containing output Parquet files
    r2_prefix : R2 prefix for output files (e.g., "sipni/microdados")
    total_records : Total number of records processed
    """
    manifest = load_manifest(r2_client, bucket, manifest_key)

    output_files = collect_output_files(staging_dir, r2_prefix)
    total_size = sum(f["size_bytes"] for f in output_files)

    manifest["partitions"][partition_key] = {
        "source_url": source_url,
        "source_size_bytes": source_size_bytes,
        "source_etag": source_etag,
        "source_last_modified": source_last_modified,
        "processing_timestamp": datetime.now(timezone.utc).isoformat(),
        "output_files": output_files,
        "total_records": total_records,
        "total_size_bytes": total_size,
    }

    upload_manifest(r2_client, bucket, manifest_key, manifest)
