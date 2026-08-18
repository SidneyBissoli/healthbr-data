#!/usr/bin/env bash
# ==============================================================================
# mirror-sih-raw.sh — Espelha os .dbc do SIH (FTP DATASUS) para o R2 (_raw/)
# ==============================================================================
#
# Por quê: o FTP do DATASUS entrega ~2,7 MiB/s e conecta sempre a partir do
# Brasil, mas ~0,85 MiB/s com timeouts frequentes a partir da VPS na Europa.
# Para bootstraps grandes (SP: 9.412 arquivos, 54 GiB) é muito mais rápido
# baixar de uma máquina no Brasil, subir para o R2 e deixar a VPS processar
# do R2 (pipeline com SIH_FONTE=r2). Depois do bootstrap o espelho pode ser
# apagado (rclone purge r2:healthbr-data/_raw/sih/<tipo>).
#
# Uso (PC, rclone remote "r2"):
#   bash scripts/maintenance/mirror-sih-raw.sh SP            # tudo (1997–hoje)
#   bash scripts/maintenance/mirror-sih-raw.sh SP 2008       # só ano >= 2008
#   PARALLEL=6 LOTE=150 bash scripts/maintenance/mirror-sih-raw.sh RD
#
# Retomável: compara a listagem do FTP com o que já está no R2 (nome + tamanho)
# e só baixa o que falta. Trabalha em lotes (download → verificação de
# tamanho → rclone move → apaga local), então o disco local nunca passa de
# ~LOTE arquivos. Ctrl-C a qualquer momento; rode de novo para continuar.
# ==============================================================================

set -uo pipefail

TIPO="${1:?uso: mirror-sih-raw.sh RD|SP [ano_minimo]}"; TIPO="${TIPO^^}"
ANO_MIN="${2:-0}"
PARALLEL="${PARALLEL:-5}"
LOTE="${LOTE:-120}"
R2_DEST="r2:healthbr-data/_raw/sih/${TIPO,,}"
FTP_BASE="ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS"
FTP_DIRS=("$FTP_BASE/200801_/Dados/" "$FTP_BASE/199201_200712/Dados/")
WORK="${WORK:-${TMPDIR:-/tmp}/sih-mirror-${TIPO,,}}"
mkdir -p "$WORK/stage"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# --- 1. Listagem do FTP (nome→tamanho→url), filtrada por tipo e ano --------
log "Listando FTP ($TIPO)..."
: > "$WORK/ftp.tsv"
for d in "${FTP_DIRS[@]}"; do
  curl -s --connect-timeout 30 -m 300 "$d" > "$WORK/list.txt" || { echo "ERRO: LIST $d falhou"; exit 1; }
  # IIS: "MM-DD-YY  HH:MMAM  SIZE  NAME"
  awk -v tipo="$TIPO" -v url="$d" -v anomin="$ANO_MIN" '
    NF==4 && $3 ~ /^[0-9]+$/ {
      n=toupper($4)
      if (n !~ ("^" tipo "[A-Z][A-Z][0-9][0-9][0-9][0-9]\\.DBC$")) next
      yy=substr(n,5,2)+0; ano=(yy>=92)?1900+yy:2000+yy
      if (ano < anomin) next
      # nome canônico em maiúsculas + .dbc minúsculo (o IIS é case-insensitive)
      canon=substr(n,1,8) ".dbc"
      print canon "\t" $3 "\t" url canon
    }' "$WORK/list.txt" >> "$WORK/ftp.tsv"
done
sort -u -o "$WORK/ftp.tsv" "$WORK/ftp.tsv"
N_FTP=$(wc -l < "$WORK/ftp.tsv")
GIB=$(awk -F'\t' '{s+=$2} END{printf "%.1f", s/2^30}' "$WORK/ftp.tsv")
log "FTP: $N_FTP arquivos $TIPO ($GIB GiB)"

# --- 2. O que já está no R2 (nome→tamanho) --------------------------------
log "Listando R2 $R2_DEST ..."
rclone lsf "$R2_DEST/" --format "ps" --separator $'\t' 2>/dev/null \
  | awk -F'\t' '{print $1 "\t" $2}' | sort > "$WORK/r2.tsv"
N_R2=$(wc -l < "$WORK/r2.tsv")

# pendentes = no FTP e (ausente no R2 ou tamanho diferente)
awk -F'\t' -v r2f="$WORK/r2.tsv" \
  'FILENAME==r2f {r2[$1]=$2; next} !($1 in r2) || r2[$1] != $2 {print}' \
  "$WORK/r2.tsv" "$WORK/ftp.tsv" > "$WORK/pending.tsv"
N_PEND=$(wc -l < "$WORK/pending.tsv")
log "R2: $N_R2 já espelhados; pendentes: $N_PEND"
[ "$N_PEND" -eq 0 ] && { log "Nada a fazer."; exit 0; }

# --- 3. Lotes: download paralelo → verificação → move para R2 -------------
# O upload do lote k roda em segundo plano enquanto o lote k+1 baixa
# (stage separado por lote), sobrepondo as duas metades do trabalho.
baixar() {  # baixar STAGE NOME TAMANHO URL
  local stage="$1" nome="$2" tam="$3" url="$4" dest="$1/$2"
  for i in 1 2 3; do
    curl -s --connect-timeout 30 -m 900 -o "$dest" "$url" && \
      [ "$(stat -c %s "$dest" 2>/dev/null || echo 0)" = "$tam" ] && { echo "ok $nome"; return 0; }
    sleep $((5*i))
  done
  rm -f "$dest"; echo "FALHA $nome"; return 1
}
export -f baixar

subir() {  # subir STAGE  (em background; apaga o stage ao terminar)
  rclone move "$1" "$R2_DEST" --transfers 8 --checkers 16 \
    --s3-no-check-bucket --stats-one-line --stats 60s > "$1.upload.log" 2>&1
  rmdir "$1" 2>/dev/null || true
}

split -l "$LOTE" -d -a 4 "$WORK/pending.tsv" "$WORK/lote."
FEITOS=0; FALHAS=0; UPLOAD_PID=""
for lote in "$WORK"/lote.*; do
  n=$(wc -l < "$lote"); stage="$WORK/stage/$(basename "$lote")"; mkdir -p "$stage"
  log "Lote $(basename "$lote"): $n arquivos — download ($PARALLEL paralelos)..."
  # shellcheck disable=SC2016
  tr '\t' ' ' < "$lote" | xargs -P "$PARALLEL" -L 1 bash -c 'baixar "$0" "$1" "$2" "$3"' "$stage" \
    | grep -c "^ok" > "$WORK/okcount" || true
  ok=$(cat "$WORK/okcount"); FEITOS=$((FEITOS+ok)); FALHAS=$((FALHAS+n-ok))
  # espera o upload anterior (no máximo 2 lotes em disco) e dispara o deste
  [ -n "$UPLOAD_PID" ] && wait "$UPLOAD_PID"
  log "  baixados $ok/$n — upload em segundo plano para $R2_DEST ..."
  subir "$stage" & UPLOAD_PID=$!
  rm -f "$lote"
  log "  progresso: $FEITOS baixados nesta sessão, $FALHAS falhas (re-rode para tentar de novo)"
done
[ -n "$UPLOAD_PID" ] && wait "$UPLOAD_PID"
log "Concluído: $FEITOS arquivos; $FALHAS falhas. Verifique: rclone size $R2_DEST"
