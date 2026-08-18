#!/usr/bin/env python3
"""
backfill-metadata.py — Backfill do metadado de proveniência `healthbr` nos
Parquets publicados sem ele (bootstraps 1.0.0; meses 1.1.0 gravados sem o
registro por fallback do polars), sem reprocessar a fonte. Também completa
`git_commit` nos registros 1.1.0 que existem mas não o têm.

Política: docs/policy-reproducibility-pt.md — o metadado embutido, o
manifesto e o CSV de controle devem concordar entre si. Este script grava os
três a partir do que já está registrado (CSV de controle + manifesto):

  metadado `healthbr` (key-value metadata do rodapé do Parquet + schema Arrow):
    dataset, source_url, source_file, hash da fonte (`source_hash_md5` nos
    .dbc; `source_etag` + `source_hash_md5_zip` na rotina SI-PNI),
    source_size_bytes, download_date (= data_processamento do CSV),
    pipeline_script, pipeline_version (a ORIGINAL — lida do script no commit
    inferido), git_commit (inferido), git_commit_inferred = true,
    metadata_backfill = {backfilled_at, script, git_commit (deste script),
                         basis, git_commit_basis, download_date_basis}
  manifesto (<prefixo>/manifest.json), por partição:
    source_hash_md5, pipeline_script, pipeline_version, git_commit,
    git_commit_inferred, metadata_backfilled_at, output_files[].sha256/size/
    record_count (o arquivo físico muda ao regravar o rodapé; o conteúdo não)
  CSV de controle: colunas pipeline_version e git_commit preenchidas.

Inferência do git_commit: último commit que tocou o pipeline_script com data
<= data_processamento; se não houver (bootstrap anterior ao 1º commit do
script — SIH RD 020ee5c, SINASC ac2ff96), o primeiro commit. A
pipeline_version é lida de `PIPELINE_VERSION` no script nesse commit (1.0.0
se o script ainda não a declarava). Requer rodar num clone do repositório.

Só o schema metadata é regravado: a tabela é lida com pyarrow, recebe o
metadado, é gravada e RELIDA — se `equals()` falhar ou o schema (tipos)
mudar, o arquivo é descartado e o erro reportado; nada sobe. Leitura do
registro existente pelo key-value do rodapé (`read_metadata`), que é onde o
polars o grava (não aparece em `read_schema()`).

Uso (do PC ou de uma VPS via launch-bootstrap-vps.sh):
  python scripts/maintenance/backfill-metadata.py --dataset sinasc --grupos ano=1994 --dry-run
  python scripts/maintenance/backfill-metadata.py --dataset sih-rd --workers 6
  python scripts/maintenance/backfill-metadata.py --dataset sipni-microdados --workers 8

Trabalha por grupo (pasta do R2: `ano=YYYY` no SIH/SINASC, `ano=YYYY/mes=MM`
na rotina SI-PNI): baixa o grupo, regrava o que precisar, sobe só os arquivos
alterados, atualiza manifesto (baixado fresco na hora) e CSV, e limpa.
Idempotente: arquivos que já têm `git_commit` no registro são pulados (mas
manifesto/CSV são sincronizados). Não rodar em paralelo com a manutenção do
mesmo dataset (o manifesto seria disputado).
"""
import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import pyarrow.parquet as pq

REPO_ROOT = Path(__file__).resolve().parents[2]
RCLONE_REMOTE = "r2"
BUCKET = "healthbr-data"
SCRIPT_REL = "scripts/maintenance/backfill-metadata.py"


def _iso(ts):
    return ts.replace(" ", "T")[:19] + "Z"


def _meta_dbc(cfg, row, part):
    return {
        "dataset": cfg["prefix"],
        "source_url": part["source_url"],
        "source_file": row["arquivo"],
        "source_hash_md5": row["hash_md5"],
        "source_size_bytes": int(float(row["tamanho_bytes"])),
        "download_date": _iso(row["data_processamento"]),
    }


def _meta_sipni_microdados(cfg, row, part):
    return {
        "dataset": cfg["prefix"],
        "source_url": row.get("url_origem") or part["source_url"],
        "source_file": row["arquivo"],
        "source_etag": row["etag_servidor"],
        "source_hash_md5_zip": row["hash_md5_zip"],
        "source_size_bytes": int(float(row["content_length"])),
        "download_date": _iso(row["data_processamento"]),
    }


# id → config. part_key = chave da partição no manifesto; group = pasta do R2
# baixada de uma vez (unidade de trabalho); meta = registro-base a partir da
# linha do CSV + partição do manifesto; md5 = coluna do CSV com o hash da fonte
# (vai para `source_hash_md5` no manifesto).
DATASETS = {
    "sih-rd": dict(
        prefix="sih/rd", csv="data/controle_versao_sih_rd.csv",
        script="scripts/pipeline/sih-pipeline-r.R", manifest="sih/rd/manifest.json",
        part_key=lambda r: f"{r['ano']}-{r['mes']}-{r['uf']}",
        group=lambda r: f"ano={r['ano']}",
        meta=_meta_dbc, md5="hash_md5",
    ),
    "sinasc": dict(
        prefix="sinasc", csv="data/controle_versao_sinasc.csv",
        script="scripts/pipeline/sinasc-pipeline-r.R", manifest="sinasc/manifest.json",
        part_key=lambda r: f"{r['ano']}-{r['uf']}",
        group=lambda r: f"ano={r['ano']}",
        meta=_meta_dbc, md5="hash_md5",
    ),
    "sipni-microdados": dict(
        prefix="sipni/microdados", csv="data/controle_versao_microdata.csv",
        script="scripts/pipeline/sipni-microdata-pipeline-python.py",
        manifest="sipni/manifest.json",            # manifesto vive em sipni/, não em sipni/microdados/
        part_key=lambda r: f"{r['ano']}-{int(r['mes']):02d}",
        group=lambda r: f"ano={r['ano']}/mes={int(r['mes']):02d}",
        meta=_meta_sipni_microdados, md5="hash_md5_zip",
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
    return os.environ.get("HEALTHBR_GIT_COMMIT") or git("rev-parse", "HEAD")


_commit_cache, _version_cache = {}, {}


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


def versao_no_commit(script_rel, commit):
    """PIPELINE_VERSION declarada no script naquele commit; 1.0.0 se ausente."""
    if (script_rel, commit) in _version_cache:
        return _version_cache[(script_rel, commit)]
    try:
        src = git("show", f"{commit}:{script_rel}")
    except subprocess.CalledProcessError:
        src = ""
    m = re.search(r'PIPELINE_VERSION\s*(?:<-|=)\s*"(\d+\.\d+\.\d+)"', src)
    v = m.group(1) if m else "1.0.0"
    _version_cache[(script_rel, commit)] = v
    return v


# --- parquet ------------------------------------------------------------------

def sha256_file(p, chunk=1 << 20):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while b := f.read(chunk):
            h.update(b)
    return h.hexdigest()


def ler_healthbr(path):
    """Registro existente, do key-value metadata do rodapé (cobre R e polars)."""
    md = pq.read_metadata(path).metadata or {}
    raw = md.get(b"healthbr")
    return json.loads(raw) if raw else None


def regravar(path_in, path_out, meta):
    """Regrava path_in em path_out com metadado `healthbr` = meta. Verifica."""
    t = pq.read_table(path_in)
    md = dict(t.schema.metadata or {})
    md[b"healthbr"] = json.dumps(meta, ensure_ascii=False).encode("utf-8")
    t2 = t.replace_schema_metadata(md)
    pq.write_table(t2, path_out, compression="snappy")
    t3 = pq.read_table(path_out)
    if not t3.schema.remove_metadata().equals(t.schema.remove_metadata()):
        raise RuntimeError("schema mudou na regravação")
    if not t3.equals(t):
        raise RuntimeError("conteúdo mudou na regravação")
    if json.loads(pq.read_metadata(path_out).metadata[b"healthbr"]) != meta:
        raise RuntimeError("metadado não gravado como esperado")
    return t3.num_rows


# --- CSV ----------------------------------------------------------------------

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
    return pv in ("", "NA") or gc in ("", "NA", "unknown")


# --- núcleo -------------------------------------------------------------------

def processar_arquivo(cfg, row, path_r2, dir_in, dir_out, agora, commit_backfill, part):
    """Um Parquet. Retorna dict de resultado (status ok|ja_tem|nao_baixado)."""
    rel = path_r2.split(cfg["prefix"] + "/", 1)[1]
    src = dir_in / rel
    if not src.exists():
        return dict(status="nao_baixado", path=str(src))

    existente = ler_healthbr(src)
    if existente and existente.get("git_commit") and existente.get("git_commit") != "unknown":
        return dict(status="ja_tem", upload=False, rel=rel, path_r2=path_r2,
                    sha256=sha256_file(src), size=src.stat().st_size,
                    n=pq.read_metadata(src).num_rows,
                    pipeline_version=existente.get("pipeline_version"),
                    git_commit=existente["git_commit"],
                    inferred=bool(existente.get("git_commit_inferred")))

    ts = row["data_processamento"]
    commit_inferido = inferir_git_commit(cfg["script"], ts)
    pv = versao_no_commit(cfg["script"], commit_inferido)
    if existente:  # registro presente sem commit: preserva, completa
        meta = dict(existente)
        pv = existente.get("pipeline_version", pv)
        basis = f"{pv} record kept; git_commit added"
    else:
        meta = cfg["meta"](cfg, row, part)
        meta["pipeline_script"] = cfg["script"]
        meta["pipeline_version"] = pv
        basis = f"record built from control CSV + manifest (file written by pipeline {pv} without it)"
    meta["git_commit"] = commit_inferido
    meta["git_commit_inferred"] = True
    meta["metadata_backfill"] = {
        "backfilled_at": agora,
        "script": SCRIPT_REL,
        "git_commit": commit_backfill,
        "basis": basis,
        "git_commit_basis": "last commit of pipeline_script dated <= download_date, else its first commit; "
                            "pipeline_version read from the script at that commit",
        "download_date_basis": "processing timestamp recorded in the control CSV",
    }

    dst = dir_out / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    n = regravar(src, dst, meta)
    return dict(status="ok", upload=True, rel=rel, path_r2=path_r2, sha256=sha256_file(dst),
                size=dst.stat().st_size, n=n, pipeline_version=pv,
                git_commit=commit_inferido, inferred=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", required=True, choices=list(DATASETS))
    ap.add_argument("--grupos", nargs="*", help="restringir a estes grupos (ex.: ano=1994 ou ano=2020/mes=01)")
    ap.add_argument("--anos", nargs="*", type=int, help="restringir a estes anos")
    ap.add_argument("--limit", type=int, help="máximo de partições por grupo (teste)")
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
    r2_manifest = f"{RCLONE_REMOTE}:{BUCKET}/{cfg['manifest']}"

    pend = [r for r in rows if precisa(r)]
    if a.anos:
        pend = [r for r in pend if int(r["ano"]) in a.anos]
    grupos = sorted({cfg["group"](r) for r in pend})
    if a.grupos:
        grupos = [g for g in grupos if g in a.grupos]
    log(f"dataset={a.dataset} linhas={len(rows)} pendentes={len(pend)} grupos={len(grupos)} "
        f"({grupos[0] if grupos else '-'}..{grupos[-1] if grupos else '-'}) dry_run={a.dry_run} "
        f"commit_backfill={commit_backfill[:7]}")

    work = Path(a.workdir) if a.workdir else Path(tempfile.mkdtemp(prefix="healthbr-backfill-"))
    work.mkdir(parents=True, exist_ok=True)
    dir_in, dir_out = work / "in", work / "out"   # espelham a raiz do prefixo
    tot = dict(ok=0, ja_tem=0, erro=0, outros=0)

    for grupo in grupos:
        rows_g = [r for r in pend if cfg["group"](r) == grupo]
        if a.limit:
            rows_g = rows_g[: a.limit]
        for d in (dir_in / grupo, dir_out / grupo):
            if d.exists():
                shutil.rmtree(d)
            d.mkdir(parents=True)

        manifest = json.loads(rclone("cat", r2_manifest).stdout)   # fresco
        parts = manifest["partitions"]

        # arquivos a tratar = output_files das partições pendentes do grupo
        tarefas = []   # (row, key, path_r2, part)
        for r in rows_g:
            key = cfg["part_key"](r)
            part = parts.get(key)
            if part is None:
                log(f"  aviso {key}: sem partição no manifesto"); tot["outros"] += 1; continue
            files = [f["path"] for f in part.get("output_files", [])]
            if not files:
                log(f"  aviso {key}: partição sem output_files"); tot["outros"] += 1; continue
            for pth in files:
                tarefas.append((r, key, pth, part))

        log(f"{grupo}: baixando {len(tarefas)} arquivo(s) de {len(rows_g)} partição(ões) ...")
        rclone("copy", f"{r2_prefix}/{grupo}/", str(dir_in / grupo), "--transfers", "32", "--checkers", "64")

        resultados = []   # (row, key, res)
        with ThreadPoolExecutor(max_workers=a.workers) as ex:
            futs = [(ex.submit(processar_arquivo, cfg, r, pth, dir_in, dir_out, agora, commit_backfill, part), r, key)
                    for r, key, pth, part in tarefas]
            for fut, r, key in futs:
                try:
                    res = fut.result()
                except Exception as e:  # noqa
                    res = dict(status="erro", msg=str(e))
                    log(f"  ERRO {key}: {e}")
                resultados.append((r, key, res))

        oks = [(r, k, res) for r, k, res in resultados if res["status"] in ("ok", "ja_tem")]
        n_up = sum(1 for _, _, res in oks if res["upload"])
        n_ja = len(oks) - n_up
        n_err = sum(1 for _, _, res in resultados if res["status"] == "erro")
        n_out = len(resultados) - len(oks) - n_err
        for _, k, res in resultados:
            if res["status"] not in ("ok", "ja_tem", "erro"):
                log(f"  aviso {k}: {res}")
        log(f"{grupo}: regravados={n_up} ja_tinham={n_ja} erros={n_err} outros={n_out}")
        tot["ok"] += n_up; tot["ja_tem"] += n_ja; tot["erro"] += n_err; tot["outros"] += n_out

        # partições em que TODOS os arquivos deram certo (senão manifesto/CSV ficariam mentindo)
        por_part = {}
        for r, k, res in resultados:
            por_part.setdefault(k, {"row": r, "res": [], "falha": False})
            if res["status"] in ("ok", "ja_tem"):
                por_part[k]["res"].append(res)
            else:
                por_part[k]["falha"] = True
        completas = {k: v for k, v in por_part.items() if not v["falha"] and v["res"]}

        if completas and not a.dry_run:
            if n_up:
                log(f"{grupo}: subindo {n_up} arquivo(s) ...")
                rclone("copy", str(dir_out / grupo), f"{r2_prefix}/{grupo}/", "--transfers", "32", "--checkers", "64")
            manifest = json.loads(rclone("cat", r2_manifest).stdout)   # fresco de novo
            parts = manifest["partitions"]
            for k, v in completas.items():
                r, ress = v["row"], v["res"]
                p = parts[k]
                p["source_hash_md5"] = r[cfg["md5"]]
                p["pipeline_script"] = cfg["script"]
                p["pipeline_version"] = ress[0]["pipeline_version"]
                p["git_commit"] = ress[0]["git_commit"]
                if any(x["inferred"] for x in ress):
                    p["git_commit_inferred"] = True
                    p["metadata_backfilled_at"] = agora
                by_path = {x["path_r2"]: x for x in ress}
                for f in p["output_files"]:
                    x = by_path.get(f["path"])
                    if x:
                        f["sha256"] = x["sha256"]; f["size_bytes"] = x["size"]
                        if f.get("record_count") is None:
                            f["record_count"] = x["n"]
                p["total_size_bytes"] = sum(f["size_bytes"] for f in p["output_files"])
                r["pipeline_version"] = ress[0]["pipeline_version"]
                r["git_commit"] = ress[0]["git_commit"]
            manifest["last_updated"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
            manifest["metadata_backfill"] = {"script": SCRIPT_REL, "git_commit": commit_backfill, "last_run": agora}
            tmp = work / "manifest.json"
            tmp.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
            rclone("copyto", str(tmp), r2_manifest)
            salvar_csv(csv_path, rows, fields)
            log(f"{grupo}: manifesto + CSV atualizados ({len(completas)} partição(ões)).")

        shutil.rmtree(dir_in / grupo, ignore_errors=True)
        if not (a.dry_run and a.workdir):
            shutil.rmtree(dir_out / grupo, ignore_errors=True)

    log(f"FIM: regravados={tot['ok']} ja_tinham={tot['ja_tem']} erros={tot['erro']} outros={tot['outros']}")
    if not a.workdir:
        shutil.rmtree(work, ignore_errors=True)
    elif a.dry_run:
        log(f"dry-run: saída mantida em {dir_out}")
    sys.exit(1 if tot["erro"] else 0)


if __name__ == "__main__":
    main()
