#!/usr/bin/env python3
"""
backfill-metadata.py — Backfill do metadado de proveniência `healthbr` nos
Parquets publicados antes da pipeline_version 1.1.0 (bootstraps 1.0.0), sem
reprocessar a fonte. Também completa `git_commit` nos arquivos 1.1.0 (que já
têm o registro embutido, mas sem o commit).

Política: docs/policy-reproducibility-pt.md — o metadado embutido, o
manifesto e o CSV de controle devem concordar entre si. Este script grava os
três a partir do que já está registrado (CSV de controle + manifesto):

  metadado `healthbr` (JSON no schema metadata do Parquet):
    dataset, source_url (manifesto), source_file, source_hash_md5 (CSV),
    source_size_bytes (CSV), download_date (= data_processamento do CSV),
    pipeline_script, pipeline_version (a ORIGINAL: 1.0.0 / 1.1.0),
    git_commit (inferido — ver abaixo), git_commit_inferred = true,
    metadata_backfill = {backfilled_at, script, git_commit (deste script),
                         git_commit_basis, download_date_basis}
  manifesto (<prefixo>/manifest.json), por partição:
    source_hash_md5, pipeline_script, pipeline_version, git_commit,
    git_commit_inferred, metadata_backfilled_at, output_files[].sha256/size
    (o arquivo físico muda ao regravar o rodapé; o conteúdo lógico não)
  CSV de controle: colunas pipeline_version e git_commit preenchidas.

Inferência do git_commit: o script 1.0.0 de cada pipeline foi commitado
DEPOIS do bootstrap (SIH RD 020ee5c, SINASC ac2ff96) e não mudou até a
1.1.0 (5a7fb0d). Regra: último commit que tocou o pipeline_script com data
<= data_processamento; se não houver (bootstrap anterior ao 1º commit), o
primeiro commit do script. Requer rodar dentro de um clone do repositório.

Só o schema metadata é regravado: a tabela é lida com pyarrow, recebe o
metadado, é gravada e RELIDA — se `equals()` falhar ou o schema (tipos)
mudar, o arquivo é descartado e o erro reportado; nada sobe.

Uso (do PC ou de uma VPS via launch-bootstrap-vps.sh):
  python scripts/maintenance/backfill-metadata.py --dataset sinasc --anos 1994 --dry-run
  python scripts/maintenance/backfill-metadata.py --dataset sinasc
  python scripts/maintenance/backfill-metadata.py --dataset sih-rd --workers 4

Trabalha ano a ano: baixa a pasta ano=YYYY do R2 (rclone), regrava o que
precisar, sobe só os arquivos alterados, atualiza manifesto (baixado fresco
na hora) e CSV, e limpa. Idempotente: arquivos que já têm `git_commit` no
metadado são pulados. Não rodar em paralelo com a manutenção do mesmo
dataset (o manifesto seria disputado).
"""
import argparse
import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

REPO_ROOT = Path(__file__).resolve().parents[2]
RCLONE_REMOTE = "r2"
BUCKET = "healthbr-data"
SCRIPT_REL = "scripts/maintenance/backfill-metadata.py"

DATASETS = {
    "sih-rd": dict(
        prefix="sih/rd",
        csv="data/controle_versao_sih_rd.csv",
        script="scripts/pipeline/sih-pipeline-r.R",
        part_key=lambda r: f"{r['ano']}-{r['mes']}-{r['uf']}",
        part_dir=lambda r: f"ano={r['ano']}/mes={r['mes']}/uf={r['uf']}",
    ),
    "sinasc": dict(
        prefix="sinasc",
        csv="data/controle_versao_sinasc.csv",
        script="scripts/pipeline/sinasc-pipeline-r.R",
        part_key=lambda r: f"{r['ano']}-{r['uf']}",
        part_dir=lambda r: f"ano={r['ano']}/uf={r['uf']}",
    ),
}


def log(msg):
    print(f"[{datetime.now(timezone.utc).strftime('%H:%M:%S')}] {msg}", flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def rclone(*args):
    return run(["rclone", *args, "--s3-no-check-bucket"])


# --- git ----------------------------------------------------------------------

def git(*args):
    return run(["git", *args], cwd=REPO_ROOT).stdout.strip()


def commit_atual():
    env = os.environ.get("HEALTHBR_GIT_COMMIT")
    return env or git("rev-parse", "HEAD")


_commit_cache = {}


def inferir_git_commit(script_rel, ts):
    """Último commit do script <= ts (naive = UTC); senão o primeiro commit."""
    dia = ts[:19]
    if (script_rel, dia) in _commit_cache:
        return _commit_cache[(script_rel, dia)]
    c = git("log", "-1", "--format=%H", f"--before={dia} +0000", "--", script_rel)
    if not c:
        primeiro = git("log", "--reverse", "--format=%H", "--", script_rel).splitlines()
        c = primeiro[0] if primeiro else ""
    if not c:
        raise RuntimeError(f"sem histórico git para {script_rel}")
    _commit_cache[(script_rel, dia)] = c
    return c


# --- parquet ------------------------------------------------------------------

def sha256_file(p, chunk=1 << 20):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while b := f.read(chunk):
            h.update(b)
    return h.hexdigest()


def ler_healthbr(path):
    md = pq.read_schema(path).metadata or {}
    raw = md.get(b"healthbr")
    return json.loads(raw) if raw else None


def regravar(path_in, path_out, meta):
    """Regrava path_in em path_out com metadado `healthbr` = meta. Verifica."""
    t = pq.read_table(path_in)
    md = dict(t.schema.metadata or {})
    md[b"healthbr"] = json.dumps(meta, ensure_ascii=False).encode("utf-8")
    t2 = t.replace_schema_metadata(md)
    pq.write_table(t2, path_out, compression="snappy")
    # verificação: mesmo conteúdo, mesmos tipos, metadado gravado
    t3 = pq.read_table(path_out)
    if not t3.schema.remove_metadata().equals(t.schema.remove_metadata()):
        raise RuntimeError("schema mudou na regravação")
    if not t3.equals(t):
        raise RuntimeError("conteúdo mudou na regravação")
    if json.loads(t3.schema.metadata[b"healthbr"]) != meta:
        raise RuntimeError("metadado não gravado como esperado")
    return t3.num_rows


# --- núcleo -------------------------------------------------------------------

def carregar_csv(path):
    with open(path, encoding="utf-8", newline="") as f:
        r = csv.DictReader(f)
        return list(r), list(r.fieldnames)


def salvar_csv(path, rows, fields):
    for c in ("pipeline_version", "git_commit"):
        if c not in fields:
            fields.append(c)
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fields})


def precisa(row):
    pv = (row.get("pipeline_version") or "").strip()
    gc = (row.get("git_commit") or "").strip()
    return pv in ("", "NA") or gc in ("", "NA")


def processar_arquivo(cfg, row, dir_in, dir_out, agora, commit_backfill, manifest_parts):
    """Retorna (row_key, resultado dict) ou levanta exceção."""
    key = cfg["part_key"](row)
    pdir = cfg["part_dir"](row)
    part = manifest_parts.get(key)
    if part is None:
        return key, dict(status="sem_manifesto")
    files = [f["path"] for f in part.get("output_files", [])]
    if len(files) != 1:
        return key, dict(status="n_arquivos_inesperado", n=len(files))
    rel = files[0].split(cfg["prefix"] + "/", 1)[1]
    src = dir_in / rel
    if not src.exists():
        return key, dict(status="nao_baixado", path=str(src))

    existente = ler_healthbr(src)
    if existente and existente.get("git_commit") and existente.get("git_commit") != "unknown":
        # Parquet já completo (rodada anterior interrompida antes de manifesto/CSV,
        # ou arquivo 1.2.0): nada a regravar, mas manifesto/CSV são sincronizados.
        return key, dict(status="ja_tem", upload=False, rel=rel, path_r2=files[0],
                         sha256=sha256_file(src), size=src.stat().st_size,
                         n=pq.read_metadata(src).num_rows,
                         pipeline_version=existente.get("pipeline_version"),
                         git_commit=existente["git_commit"],
                         inferred=bool(existente.get("git_commit_inferred")))

    ts = row["data_processamento"]
    commit_inferido = inferir_git_commit(cfg["script"], ts)
    if existente:  # 1.1.0: completa o registro, preserva o resto
        meta = dict(existente)
        pv = existente.get("pipeline_version", "1.1.0")
        basis = "1.1.0 record kept; git_commit added"
    else:
        pv = "1.0.0"
        meta = {
            "dataset": cfg["prefix"],
            "source_url": part["source_url"],
            "source_file": row["arquivo"],
            "source_hash_md5": row["hash_md5"],
            "source_size_bytes": int(float(row["tamanho_bytes"])),
            "download_date": ts.replace(" ", "T")[:19] + "Z",
            "pipeline_script": cfg["script"],
            "pipeline_version": pv,
        }
        basis = "1.0.0 record built from control CSV + manifest"
    meta["git_commit"] = commit_inferido
    meta["git_commit_inferred"] = True
    meta["metadata_backfill"] = {
        "backfilled_at": agora,
        "script": SCRIPT_REL,
        "git_commit": commit_backfill,
        "basis": basis,
        "git_commit_basis": "last commit of pipeline_script dated <= download_date, else its first commit",
        "download_date_basis": "processing timestamp recorded in the control CSV",
    }

    dst = dir_out / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    n = regravar(src, dst, meta)
    return key, dict(status="ok", upload=True, rel=rel, path_r2=files[0], sha256=sha256_file(dst),
                     size=dst.stat().st_size, n=n, pipeline_version=pv,
                     git_commit=commit_inferido, inferred=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", required=True, choices=list(DATASETS))
    ap.add_argument("--anos", nargs="*", type=int, help="restringir a estes anos")
    ap.add_argument("--limit", type=int, help="máximo de arquivos por ano (teste)")
    ap.add_argument("--workers", type=int, default=2, help="threads de regravação")
    ap.add_argument("--dry-run", action="store_true", help="não sobe nada, não altera manifesto/CSV")
    ap.add_argument("--workdir", help="diretório de trabalho (default: temp)")
    a = ap.parse_args()

    cfg = DATASETS[a.dataset]
    csv_path = REPO_ROOT / cfg["csv"]
    rows, fields = carregar_csv(csv_path)
    agora = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    commit_backfill = commit_atual()
    r2_prefix = f"{RCLONE_REMOTE}:{BUCKET}/{cfg['prefix']}"

    pend = [r for r in rows if precisa(r)]
    anos = sorted({int(r["ano"]) for r in pend})
    if a.anos:
        anos = [y for y in anos if y in a.anos]
    log(f"dataset={a.dataset} linhas={len(rows)} pendentes={len(pend)} anos={anos[0] if anos else '-'}..{anos[-1] if anos else '-'} "
        f"({len(anos)} anos) dry_run={a.dry_run} commit_backfill={commit_backfill[:7]}")

    work = Path(a.workdir) if a.workdir else Path(tempfile.mkdtemp(prefix="healthbr-backfill-"))
    work.mkdir(parents=True, exist_ok=True)
    tot = dict(ok=0, ja_tem=0, erro=0, outros=0)

    for ano in anos:
        rows_ano = [r for r in pend if int(r["ano"]) == ano]
        if a.limit:
            rows_ano = rows_ano[: a.limit]
        # dir_in/dir_out espelham a raiz do prefixo (rel = ano=YYYY/.../part.parquet)
        dir_in, dir_out = work / "in", work / "out"
        for d in (dir_in / f"ano={ano}", dir_out / f"ano={ano}"):
            if d.exists():
                shutil.rmtree(d)
            d.mkdir(parents=True)

        # manifesto fresco (a manutenção pode ter mexido)
        manifest = json.loads(rclone("cat", f"{r2_prefix}/manifest.json").stdout)
        parts = manifest["partitions"]

        log(f"{ano}: baixando {len(rows_ano)} arquivo(s) de {r2_prefix}/ano={ano}/ ...")
        if a.limit:
            for r in rows_ano:
                pdir = cfg["part_dir"](r)                      # ano=YYYY/.../uf=XX
                rclone("copy", f"{r2_prefix}/{pdir}/", str(dir_in / pdir), "--transfers", "8")
        else:
            rclone("copy", f"{r2_prefix}/ano={ano}/", str(dir_in / f"ano={ano}"), "--transfers", "16", "--checkers", "32")

        resultados = {}
        with ThreadPoolExecutor(max_workers=a.workers) as ex:
            futs = {ex.submit(processar_arquivo, cfg, r, dir_in, dir_out, agora, commit_backfill, parts): r for r in rows_ano}
            for fut, r in futs.items():
                try:
                    key, res = fut.result()
                except Exception as e:  # noqa
                    key, res = cfg["part_key"](r), dict(status="erro", msg=str(e))
                    log(f"  ERRO {key}: {e}")
                resultados[key] = (r, res)

        # "ok" = regravado (sobe); "ja_tem" = só sincroniza manifesto/CSV
        oks = {k: v for k, v in resultados.items() if v[1]["status"] in ("ok", "ja_tem")}
        n_up = sum(1 for v in oks.values() if v[1]["upload"])
        n_ja = len(oks) - n_up
        n_err = sum(1 for v in resultados.values() if v[1]["status"] == "erro")
        n_out = len(resultados) - len(oks) - n_err
        for k, (r, res) in resultados.items():
            if res["status"] not in ("ok", "ja_tem", "erro"):
                log(f"  aviso {k}: {res}")
        log(f"{ano}: regravados={n_up} ja_tinham={n_ja} erros={n_err} outros={n_out}")
        tot["ok"] += n_up; tot["ja_tem"] += n_ja; tot["erro"] += n_err; tot["outros"] += n_out

        if oks and not a.dry_run:
            # 1. upload só dos regravados
            if n_up:
                log(f"{ano}: subindo {n_up} arquivo(s) ...")
                rclone("copy", str(dir_out / f"ano={ano}"), f"{r2_prefix}/ano={ano}/", "--transfers", "16", "--checkers", "32")
            # 2. manifesto (fresco de novo, patch só das partições tocadas)
            manifest = json.loads(rclone("cat", f"{r2_prefix}/manifest.json").stdout)
            parts = manifest["partitions"]
            for k, (r, res) in oks.items():
                p = parts[k]
                p["source_hash_md5"] = r["hash_md5"]
                p["pipeline_script"] = cfg["script"]
                p["pipeline_version"] = res["pipeline_version"]
                p["git_commit"] = res["git_commit"]
                if res["inferred"]:
                    p["git_commit_inferred"] = True
                    p["metadata_backfilled_at"] = agora
                for f in p["output_files"]:
                    if f["path"] == res["path_r2"]:
                        f["sha256"] = res["sha256"]
                        f["size_bytes"] = res["size"]
                        if f.get("record_count") is None:
                            f["record_count"] = res["n"]
                p["total_size_bytes"] = sum(f["size_bytes"] for f in p["output_files"])
            manifest["last_updated"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
            manifest["metadata_backfill"] = {"script": SCRIPT_REL, "git_commit": commit_backfill, "last_run": agora}
            tmp = work / "manifest.json"
            tmp.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
            rclone("copyto", str(tmp), f"{r2_prefix}/manifest.json")
            # 3. CSV
            for k, (r, res) in oks.items():
                r["pipeline_version"] = res["pipeline_version"]
                r["git_commit"] = res["git_commit"]
            salvar_csv(csv_path, rows, fields)
            log(f"{ano}: manifesto + CSV atualizados.")

        shutil.rmtree(dir_in / f"ano={ano}", ignore_errors=True)
        if not (a.dry_run and a.workdir):   # dry-run com --workdir deixa a saída para inspeção
            shutil.rmtree(dir_out / f"ano={ano}", ignore_errors=True)

    log(f"FIM: regravados={tot['ok']} ja_tinham={tot['ja_tem']} erros={tot['erro']} outros={tot['outros']}")
    if not a.workdir:
        shutil.rmtree(work, ignore_errors=True)
    elif a.dry_run:
        log(f"dry-run: saída mantida em {work / 'out'}")
    sys.exit(1 if tot["erro"] else 0)


if __name__ == "__main__":
    main()
