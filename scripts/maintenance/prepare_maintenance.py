#!/usr/bin/env python3
# ==============================================================================
# prepare_maintenance.py — Decide o que a rodada de manutenção precisa fazer
# ==============================================================================
#
# Lê o sync-status.json (produzido pelo comparison engine sync_check.py) e:
#
#   1. Identifica quais datasets automatizados têm partições missing/outdated.
#   2. Para os datasets baseados em FTP (sih-rd, sih-sp, sinasc), remove do controle de
#      versão as linhas correspondentes às partições "outdated" — os pipelines
#      pulam qualquer arquivo já presente no controle, então sem essa poda as
#      revisões retroativas do Ministério nunca seriam reprocessadas.
#      (sipni-microdados e sipni-covid detectam atualização sozinhos, por ETag.)
#   3. Imprime no stdout a lista de datasets a rodar (um por linha), na ordem
#      de execução. Tudo mais vai para stderr.
#
# Datasets estáticos (agregados 1994-2019, dicionários) nunca entram na
# automação: qualquer divergência neles é anômala e pede inspeção manual.
#
# Uso: python3 scripts/maintenance/prepare_maintenance.py <sync-status.json> <repo-root>
# ==============================================================================

import csv
import json
import sys
from pathlib import Path

# Ordem de execução: mais rápidos primeiro, SIH (maior volume) por último;
# dentro do SIH, RD (dataset principal) antes de SP (3x maior)
AUTOMATED = ["sinasc", "sipni-microdados", "sipni-covid", "sih-rd", "sih-sp"]

# Datasets cujo pipeline pula arquivos presentes no controle CSV; partições
# outdated precisam ser removidas do controle para forçar reprocessamento
CONTROLE_PRUNE = {
    "sinasc": "data/controle_versao_sinasc.csv",
    "sih-rd": "data/controle_versao_sih_rd.csv",
    "sih-sp": "data/controle_versao_sih_sp.csv",
}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def prune_controle(repo_root, controle_rel, outdated_filenames):
    """Remove do controle as linhas cujos arquivos foram revisados na fonte."""
    path = Path(repo_root) / controle_rel
    if not path.exists():
        log(f"  AVISO: {controle_rel} não encontrado; nada a podar")
        return 0

    targets = {f.upper() for f in outdated_filenames}
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        fields = reader.fieldnames
        rows = list(reader)

    kept = [r for r in rows if r.get("arquivo", "").upper() not in targets]
    removed = len(rows) - len(kept)

    if removed:
        with open(path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fields)
            w.writeheader()
            w.writerows(kept)

    return removed


def main():
    if len(sys.argv) != 3:
        log("Uso: prepare_maintenance.py <sync-status.json> <repo-root>")
        sys.exit(2)

    status_path, repo_root = sys.argv[1], sys.argv[2]

    with open(status_path) as f:
        status = json.load(f)

    datasets = status.get("datasets", {})
    to_run = []

    for key in AUTOMATED:
        ds = datasets.get(key)
        if ds is None:
            log(f"  {key}: ausente do sync-status; ignorando")
            continue

        summary = ds.get("summary", {})
        n_missing = summary.get("missing", 0)
        n_outdated = summary.get("outdated", 0)

        if ds.get("status") == "check_failed":
            log(f"  {key}: check_failed na última verificação; "
                f"pulando (inspecionar manualmente)")
            continue

        if n_missing == 0 and n_outdated == 0:
            log(f"  {key}: em sincronia; nada a fazer")
            continue

        log(f"  {key}: missing={n_missing} outdated={n_outdated} -> rodar")

        if key in CONTROLE_PRUNE and n_outdated > 0:
            outdated_files = [
                d["source"]["filename"]
                for d in ds.get("details", [])
                if d.get("status") == "outdated"
                and d.get("source", {}).get("filename")
            ]
            removed = prune_controle(repo_root, CONTROLE_PRUNE[key],
                                     outdated_files)
            log(f"  {key}: {removed} linha(s) removida(s) do controle "
                f"para forçar reprocessamento")

        to_run.append(key)

    for key in to_run:
        print(key)


if __name__ == "__main__":
    main()
