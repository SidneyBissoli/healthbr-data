#!/usr/bin/env python3
"""
2026-08-sih-namespace-hf.py — Lado Hugging Face da migração do SIH para namespace.

  1. Renomeia o dataset repo SidneyBissoli/sih → SidneyBissoli/sih-rd
     (o HF mantém redirect do nome antigo).
  2. Cria SidneyBissoli/sih-sp (público).
  3. Sobe os cards de guides/dataset-cards/ como README.md dos dois repos.

Rodar DEPOIS de 2026-08-sih-namespace-move.sh (os cards apontam para
sih/rd/ no R2). Requer login (~/.cache/huggingface/token). Idempotente.

  python scripts/maintenance/one-off/2026-08-sih-namespace-hf.py
"""
from pathlib import Path
from huggingface_hub import HfApi
from huggingface_hub.utils import RepositoryNotFoundError

REPO_ROOT = Path(__file__).resolve().parents[3]
CARDS = REPO_ROOT / "guides" / "dataset-cards"
USER = "SidneyBissoli"

api = HfApi()
me = api.whoami()["name"]
assert me == USER, f"logado como {me}, esperado {USER}"


def exists(repo_id):
    try:
        api.dataset_info(repo_id)
        return True
    except RepositoryNotFoundError:
        return False


# 1. sih → sih-rd
if exists(f"{USER}/sih-rd"):
    print("sih-rd já existe")
elif exists(f"{USER}/sih"):
    api.move_repo(from_id=f"{USER}/sih", to_id=f"{USER}/sih-rd", repo_type="dataset")
    print("renomeado: sih → sih-rd (redirect mantido pelo HF)")
else:
    api.create_repo(f"{USER}/sih-rd", repo_type="dataset", exist_ok=True)
    print("criado: sih-rd")

# 2. sih-sp
api.create_repo(f"{USER}/sih-sp", repo_type="dataset", exist_ok=True, private=False)
print("ok: sih-sp existe")

# 3. cards
for repo, card in (("sih-rd", "sih-rd-README.md"), ("sih-sp", "sih-sp-README.md")):
    api.upload_file(
        path_or_fileobj=str(CARDS / card),
        path_in_repo="README.md",
        repo_id=f"{USER}/{repo}",
        repo_type="dataset",
        commit_message=f"Dataset card ({card}) — SIH namespace (rd/sp), 2026-08",
    )
    print(f"card enviado: {repo} ← {card}")

print("Concluído: https://huggingface.co/datasets/SidneyBissoli/sih-rd | .../sih-sp")
