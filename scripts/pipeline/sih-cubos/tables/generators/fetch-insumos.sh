#!/usr/bin/env bash
# Baixa e extrai os INSUMOS dos geradores das tabelas de classificação — as
# tabelas CNV do DATASUS para o SIH 1992–1997 (CID9_*.CNV, CID9XINV.CNV,
# PROCOBST.CNV, IDENT.CNV …), que vêm em TAB_SIH_199201-199712.zip da pasta
# Auxiliar do FTP do SIH/SUS.
#
# O zip é público (DATASUS) e uma cópia fica no canal, em
# sih/cubos/insumos/TAB_SIH_199201-199712.zip, para a cadeia de reprodução não
# depender do FTP estar no ar (docs/policy-reproducibility-pt.md). Tudo o que
# este script grava é gitignored (insumos/); o que vale é o que os geradores
# escrevem em tables/*.json, versionado.
#
# Uso (a partir de qualquer pasta):
#   bash scripts/pipeline/sih-cubos/tables/generators/fetch-insumos.sh
# Depois, na ordem:
#   python .../generators/estudo-1992-1997-cnv.py     # insumos/cid9_codes.csv (+ relatório)
#   python .../generators/cid9-tables.py              # tables/cid9-codes.json, cid9-chapters.json
#   python .../generators/csap-universe-tables.py     # tables/csap-universe.json
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSUMOS="$HERE/insumos"
ZIP="TAB_SIH_199201-199712.zip"
CANAL="https://data.sidneybissoli.com/sih/cubos/insumos/$ZIP"
FTP="ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/199201_200712/Auxiliar/$ZIP"

mkdir -p "$INSUMOS/tab"
if [ ! -s "$INSUMOS/$ZIP" ]; then
  echo "fetch-insumos: baixando $ZIP do canal"
  if ! curl -fsSL --max-time 300 "$CANAL" -o "$INSUMOS/$ZIP"; then
    echo "fetch-insumos: canal indisponível; tentando o FTP do DATASUS"
    curl -fsSL --max-time 600 "$FTP" -o "$INSUMOS/$ZIP"
  fi
fi
sha256sum "$INSUMOS/$ZIP" | tee "$INSUMOS/$ZIP.sha256"
unzip -oq "$INSUMOS/$ZIP" -d "$INSUMOS/tab"
n=$(ls "$INSUMOS/tab" | wc -l)
echo "fetch-insumos: $n arquivo(s) em $INSUMOS/tab/"
for f in CID9_01.CNV CID9_CAP.CNV CID9XINV.CNV PROCOBST.CNV IDENT.CNV; do
  [ -f "$INSUMOS/tab/$f" ] || { echo "fetch-insumos: falta $f no zip" >&2; exit 1; }
done
