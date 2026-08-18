#!/usr/bin/env python3
"""
publish-cards.py — Publica os dataset cards (guides/dataset-cards/) no
Hugging Face (README.md do repo de dataset) e no R2 (<prefixo>/README.md).

  python scripts/maintenance/publish-cards.py sih-sp sinasc      # ids escolhidos
  python scripts/maintenance/publish-cards.py --all
  python scripts/maintenance/publish-cards.py --all --only r2    # ou --only hf
  python scripts/maintenance/publish-cards.py --all --dry-run

Requisitos: login HF (~/.cache/huggingface/token, user SidneyBissoli) e o
remote rclone `r2`. Idempotente — o HF ignora upload sem mudança de conteúdo.
"""
import argparse
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CARDS_DIR = REPO_ROOT / "guides" / "dataset-cards"
HF_USER = "SidneyBissoli"
R2 = "r2:healthbr-data"

# id → (arquivo do card, repo HF ou None, prefixo R2 ou None)
CARDS = {
    "sinasc":                   ("sinasc-README.md",                   "sinasc",                   "sinasc"),
    "sipni-microdados":         ("sipni-microdados-README.md",         "sipni-microdados",         "sipni/microdados"),
    "sipni-covid":              ("sipni-covid-README.md",              "sipni-covid",              "sipni/covid/microdados"),
    "sipni-agregados-doses":    ("sipni-agregados-doses-README.md",    "sipni-agregados-doses",    "sipni/agregados/doses"),
    "sipni-agregados-cobertura":("sipni-agregados-cobertura-README.md","sipni-agregados-cobertura","sipni/agregados/cobertura"),
    "sipni-dicionarios":        ("../dataset-card-sipni-dicionarios.md","sipni-dicionarios",       "sipni/dicionarios"),
    "sih-rd":                   ("sih-rd-README.md",                   "sih-rd",                   "sih/rd"),
    "sih-sp":                   ("sih-sp-README.md",                   "sih-sp",                   "sih/sp"),
    "sih-index":                ("sih-index-README.md",                None,                       "sih"),
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ids", nargs="*", help="ids dos cards (ver CARDS)")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--only", choices=["hf", "r2"], help="publicar só num destino")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("-m", "--message", default="Update dataset card", help="mensagem de commit no HF")
    a = ap.parse_args()

    ids = list(CARDS) if a.all else a.ids
    if not ids:
        ap.error("informe ids ou --all")
    unknown = [i for i in ids if i not in CARDS]
    if unknown:
        ap.error(f"ids desconhecidos: {unknown}; válidos: {list(CARDS)}")

    api = None
    if a.only != "r2":
        from huggingface_hub import HfApi
        api = HfApi()
        me = api.whoami()["name"]
        assert me == HF_USER, f"logado no HF como {me}, esperado {HF_USER}"

    for i in ids:
        card, hf_repo, r2_prefix = CARDS[i]
        path = (CARDS_DIR / card).resolve()
        if not path.exists():
            print(f"[{i}] ERRO: {path} não existe", file=sys.stderr)
            sys.exit(1)
        if hf_repo and a.only != "r2":
            repo_id = f"{HF_USER}/{hf_repo}"
            if a.dry_run:
                print(f"[{i}] (dry) HF {repo_id}/README.md ← {path.name}")
            else:
                api.upload_file(path_or_fileobj=str(path), path_in_repo="README.md",
                                repo_id=repo_id, repo_type="dataset",
                                commit_message=f"{a.message} ({path.name})")
                print(f"[{i}] HF ok: https://huggingface.co/datasets/{repo_id}")
        if r2_prefix and a.only != "hf":
            dest = f"{R2}/{r2_prefix}/README.md"
            if a.dry_run:
                print(f"[{i}] (dry) rclone copyto {path} {dest}")
            else:
                subprocess.run(["rclone", "copyto", str(path), dest, "--s3-no-check-bucket"], check=True)
                print(f"[{i}] R2 ok: {dest}")


if __name__ == "__main__":
    main()
