#!/usr/bin/env python3
"""
manifest_summary.py — resumo enxuto de um manifest.json, para quem só precisa
saber SE uma partição mudou, não tudo sobre ela.

O manifesto do sih/rd tem 11 mil partições e 10,4 MB (o r2.dev não comprime).
Um consumidor que gerou um produto derivado a partir do espelho — o
sih-br-mcp, com seus cubos por ano — precisa, a cada inicialização ou a cada
rodada de rebuild, comparar o que usou com o que está publicado: MD5 e tamanho
do .dbc de origem (reedição no Ministério), SHA-256 do Parquet (o pipeline
regenerou), a data de processamento e a existência da partição. Isso cabe em
~2,5 MB. Este script lê o manifesto inteiro do R2, escreve
`<prefix>/manifest-summary.json` ao lado dele com o MESMO cabeçalho
(`manifest_version`, `dataset`, `last_updated`, `pipeline_version`) e, por
partição, só esses campos. O `last_updated` idêntico é o contrato: o
consumidor confere que o resumo é da mesma edição que o manifesto e, se não
for (o resumo nasce alguns minutos depois da republicação, na rodada do
sync-check), cai no manifesto inteiro.

Uso:
    python manifest_summary.py --prefix sih/rd --upload
    python manifest_summary.py --prefix sih/rd --output manifest-summary.json
    python manifest_summary.py --input manifest.json --output out.json   # offline

Variáveis de ambiente (leitura e escrita no R2): R2_ACCESS_KEY_ID,
R2_SECRET_ACCESS_KEY, R2_ENDPOINT — as mesmas do sync_check.py.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone

SUMMARY_VERSION = "1.0.0"
PARTITION_FIELDS = ("source_hash_md5", "source_size_bytes", "processing_timestamp")
OUTPUT_FIELDS = ("sha256",)
HEADER_FIELDS = ("manifest_version", "dataset", "last_updated", "pipeline_version")


def summarize(manifest, source_key):
    """Reduz um manifesto ao que a comparação de frescor precisa. Puro."""
    partitions = {}
    for key, part in (manifest.get("partitions") or {}).items():
        entry = {f: part.get(f) for f in PARTITION_FIELDS if f in part}
        outputs = part.get("output_files") or []
        if outputs:
            entry["output_files"] = [{f: o.get(f) for f in OUTPUT_FIELDS if f in o} for o in outputs]
        partitions[key] = entry
    summary = {f: manifest.get(f) for f in HEADER_FIELDS if f in manifest}
    summary["summary"] = {
        "version": SUMMARY_VERSION,
        "source": source_key,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "partitions": len(partitions),
        "fields": list(PARTITION_FIELDS) + ["output_files[].sha256"],
        "note": "Resumo do manifesto para checagem de frescor: mesmo last_updated que o manifesto de origem; por partição, só o que diz se ela mudou.",
    }
    summary["partitions"] = partitions
    return summary


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--prefix", default="sih/rd", help="prefixo do dataset no bucket (manifesto em <prefix>/manifest.json)")
    ap.add_argument("--input", help="manifesto local (offline; não lê o R2)")
    ap.add_argument("--output", help="grava o resumo neste arquivo local")
    ap.add_argument("--upload", action="store_true", help="sobe o resumo para <prefix>/manifest-summary.json no R2")
    args = ap.parse_args()

    source_key = f"{args.prefix}/manifest.json"
    summary_key = f"{args.prefix}/manifest-summary.json"

    client = None
    if args.input:
        with open(args.input, encoding="utf-8") as fh:
            manifest = json.load(fh)
    else:
        from sync_check import get_r2_client, load_manifest  # mesmas credenciais e bucket

        client = get_r2_client()
        manifest = load_manifest(client, source_key)
        if manifest is None:
            print(f"ERROR: nao foi possivel ler {source_key}", file=sys.stderr)
            sys.exit(1)

    summary = summarize(manifest, source_key)
    body = json.dumps(summary, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    print(
        f"{source_key}: {len(summary['partitions'])} particoes, last_updated {summary.get('last_updated')}; "
        f"resumo {len(body) / 1e6:.2f} MB"
    )

    # No Actions, expõe o last_updated para o passo que avisa o sih-br-mcp.
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as fh:
            fh.write(f"last_updated={summary.get('last_updated') or ''}\n")

    if args.output:
        with open(args.output, "wb") as fh:
            fh.write(body)
        print(f"gravado em {args.output}")

    if args.upload:
        if client is None:
            from sync_check import get_r2_client

            client = get_r2_client()
        from sync_check import R2_BUCKET

        client.put_object(
            Bucket=R2_BUCKET,
            Key=summary_key,
            Body=body,
            ContentType="application/json; charset=utf-8",
            CacheControl="public, max-age=300",
        )
        print(f"enviado para s3://{R2_BUCKET}/{summary_key}")


if __name__ == "__main__":
    main()
