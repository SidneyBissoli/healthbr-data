#!/usr/bin/env bash
# ==============================================================================
# inspect-last-run.sh — Resumo legível da última rodada de manutenção
# ==============================================================================
#
# Lê o que a rodada deixou no R2 (maintenance/last-run.json + last-run.log
# + checkpoints/) e imprime: estado da rodada, plano de trabalho, uma linha
# por pipeline com início/fim/duração/resultado, o que cada pipeline
# produziu (meses persistidos no SIH, meses no SI-PNI, etc.), sinais de
# problema (timeouts de FTP, erros, watchdog) e se há VPS de manutenção viva.
#
# Uso (do PC, com rclone remote "r2" configurado):
#   bash scripts/maintenance/inspect-last-run.sh            # rodada no R2
#   bash scripts/maintenance/inspect-last-run.sh --live     # log ao vivo da
#                                                           # VPS (via hcloud + ssh)
#   bash scripts/maintenance/inspect-last-run.sh --file /caminho/maintenance.log
#
# Dependências: rclone (modo R2); hcloud + ssh (modo --live; opcionais para
# o bloco "VPS ativa"); jq ou python3 para o JSON.
# ==============================================================================

set -uo pipefail

R2_REMOTE="${R2_REMOTE:-r2:healthbr-data}"
HCLOUD_CONTEXT="${HCLOUD_CONTEXT:-healthbr}"
MODE="r2"
LOG_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --live) MODE="live" ;;
    --file) MODE="file"; LOG_FILE="$2"; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "argumento desconhecido: $1" >&2; exit 2 ;;
  esac
  shift
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

hr() { printf '%s\n' "----------------------------------------------------------------------"; }
title() { echo; echo "== $* =="; }

# hcloud pode não estar no PATH (winget instala fora dele)
find_hcloud() {
  if command -v hcloud >/dev/null 2>&1; then echo hcloud; return; fi
  local w
  w=$(ls "$LOCALAPPDATA"/Microsoft/WinGet/Packages/HetznerCloud.CLI*/hcloud.exe 2>/dev/null | head -1)
  [ -n "$w" ] && echo "$w"
}
HCLOUD=$(find_hcloud || true)

cat > "$TMP/jg.py" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); v = d.get(sys.argv[2])
print(", ".join(map(str, v)) if isinstance(v, list) else ("" if v is None else v))
EOF
PY=$(command -v python3 || command -v python || true)
json_get() {  # json_get FILE KEY  (top-level scalar/array → texto)
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" '.[$k] | if type=="array" then join(", ") else tostring end' "$1" 2>/dev/null
  elif [ -n "$PY" ]; then
    "$PY" "$TMP/jg.py" "$1" "$2" 2>/dev/null
  else
    grep -o "\"$2\": *\"[^\"]*\"" "$1" | head -1 | sed 's/.*: *"//; s/"$//'
  fi
}

# --- 1. VPS ativa -------------------------------------------------------------
title "VPS de manutenção (Hetzner)"
VPS_IP=""
if [ -n "$HCLOUD" ]; then
  VPS_LIST=$("$HCLOUD" --context "$HCLOUD_CONTEXT" server list \
               --selector healthbr=maintenance-run 2>/dev/null | tail -n +2)
  if [ -n "$VPS_LIST" ]; then
    echo "$VPS_LIST" | awk '{printf "  %-30s %-8s %-16s idade=%s\n", $2, $3, $4, $NF}'
    VPS_IP=$(echo "$VPS_LIST" | awk 'NR==1{print $4}')
  else
    echo "  nenhuma VPS de manutenção ativa"
  fi
else
  echo "  (hcloud não encontrado — pulando)"
fi

# --- 2. last-run.json ---------------------------------------------------------
title "last-run.json (R2)"
if rclone cat "$R2_REMOTE/maintenance/last-run.json" > "$TMP/last-run.json" 2>/dev/null \
   && [ -s "$TMP/last-run.json" ]; then
  STATUS=$(json_get "$TMP/last-run.json" status)
  echo "  status:     $STATUS"
  for k in run_id timestamp reason duration_seconds datasets_run failures; do
    v=$(json_get "$TMP/last-run.json" "$k")
    [ -n "$v" ] && printf '  %-11s %s\n' "$k:" "$v"
  done
  if [ "$STATUS" = "started" ]; then
    if [ -n "$VPS_IP" ]; then
      echo "  → rodada EM ANDAMENTO (VPS viva)."
    else
      echo "  → 'started' sem VPS viva = RODADA MORTA (watchdog/reaper); checkpoints devem estar preservados."
    fi
  fi
else
  echo "  não foi possível ler $R2_REMOTE/maintenance/last-run.json"
fi

# --- 3. Obter o log -----------------------------------------------------------
title "Fonte do log"
LOG="$TMP/maintenance.log"
case "$MODE" in
  r2)
    if rclone copyto "$R2_REMOTE/maintenance/last-run.log" "$LOG" 2>/dev/null; then
      echo "  $R2_REMOTE/maintenance/last-run.log ($(wc -l < "$LOG") linhas; atualizado após cada pipeline)"
    else
      echo "  não foi possível baixar last-run.log"; LOG=""
    fi ;;
  live)
    if [ -z "$VPS_IP" ]; then echo "  --live: nenhuma VPS ativa"; LOG=""
    elif ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 "root@$VPS_IP" \
           'cat /root/maintenance.log' > "$LOG" 2>/dev/null; then
      echo "  ssh root@$VPS_IP:/root/maintenance.log ($(wc -l < "$LOG") linhas, ao vivo)"
    else
      echo "  falha no ssh para $VPS_IP"; LOG=""
    fi ;;
  file)
    if [ -r "$LOG_FILE" ]; then cp "$LOG_FILE" "$LOG"; echo "  $LOG_FILE"
    else echo "  arquivo não legível: $LOG_FILE"; LOG=""; fi ;;
esac

if [ -n "$LOG" ] && [ -s "$LOG" ]; then

# --- 4. Cabeçalho, checkpoints, plano ----------------------------------------
title "Rodada"
grep -m1 '=== Manutenção' "$LOG" | sed 's/^/  /'
NCK=$(grep -c 'Checkpoint restaurado' "$LOG")
[ "$NCK" -gt 0 ] && echo "  checkpoints restaurados: $NCK (rodada anterior interrompida)" \
                 || echo "  checkpoints restaurados: nenhum (rodada anterior fechou 100%)"
grep -m1 'Nada a fazer' "$LOG" | sed 's/^/  /'

title "Plano (prepare_maintenance.py)"
grep -E '^  [a-z-]+: (missing=|em sincronia|[0-9]+ linha)' "$LOG" | sed 's/^/  /'

# --- 5. Fases -----------------------------------------------------------------
title "Pipelines"
awk '
function tosec(t,  a) { split(t, a, ":"); return a[1]*3600 + a[2]*60 + a[3] }
function dur(s, e,  d) { d = e - s; if (d < 0) d += 86400;
  return sprintf("%dh%02dm%02ds", int(d/3600), int((d%3600)/60), d%60) }
function flush() {
  if (cur == "") return
  n++; name[n]=cur; st[n]=start; en[n]=endt; res[n]=result
  s_files[n]=files; s_rows[n]=rows; s_att[n]=att; s_err[n]=err; s_months[n]=months
  s_ftp[n]=ftp; s_stopped[n]=stopped; s_kill[n]=kill; s_sihpers[n]=sihpers
  cur=""
}
/^\[[0-9:]+\] --- Pipeline: / {
  flush(); cur=$4; sub(/ ---$/,"",cur); start=substr($1,2,8); endt=""; result="(sem fim registrado)"
  files=0; rows=0; att=0; err=0; months=""; ftp=0; stopped=""; kill=0; sihpers=0; next
}
cur != "" && /^\[[0-9:]+\] --- .*: (OK|FALHOU|FTP DATASUS indisponível)/ {
  endt=substr($1,2,8)
  if ($0 ~ /: OK ---/) result="OK"
  else if ($0 ~ /FTP DATASUS/) result="ENCERROU LIMPO (FTP indisponível)"
  else result="FALHOU"
  flush(); next
}
cur != "" {
  if ($0 ~ /Attempt [0-9]+\/[0-9]+ failed/) att++
  if ($0 ~ /(ERROR|ERRO|Error|FATAL|Traceback)/) err++
  if ($0 ~ /rows \([0-9]+ src cols/) { files++ }                    # SIH por arquivo
  if ($0 ~ /^  ✓ .*registros/) { files++ }                          # SI-PNI por mês
  if ($0 ~ /^  DN[A-Z]{2,3}[0-9]{4}\.dbc: .*registros/) { files++ }  # SINASC por arquivo
  if ($0 ~ /^Subindo ano [0-9]{4}:/) { m=$3; sub(/:$/,"",m); months = months (months==""?"":", ") m; sihpers++ }
  if ($0 ~ /^Persisting [0-9]{4}-[0-9]{2}:/) {
    m=$2; sub(/:$/,"",m); months = months (months==""?"":", ") m; sihpers++
  }
  if ($0 ~ /FTP: .*probing/) ftp++
  if ($0 ~ /FTP unavailable — stopped cleanly at/) { stopped=$0; sub(/.*stopped cleanly at /,"",stopped); sub(/ \(.*/,"",stopped) }
  if ($0 ~ /Killed|Terminated|timeout: sending signal/) kill++
}
END {
  flush()
  if (n == 0) { print "  (nenhum pipeline iniciado)"; exit }
  printf "  %-18s %-9s %-9s %-10s %s\n", "pipeline", "início", "fim", "duração", "resultado"
  for (i=1;i<=n;i++) {
    e = en[i]; d = (e=="") ? "..." : dur(tosec(st[i]), tosec(e))
    printf "  %-18s %-9s %-9s %-10s %s\n", name[i], st[i], (e==""?"—":e), d, res[i]
  }
  print ""
  for (i=1;i<=n;i++) {
    printf "  %s:", name[i]
    if (s_files[i]>0) printf "  itens processados=%d", s_files[i]
    if (s_sihpers[i]>0) printf "  lotes persistidos=%d [%s]", s_sihpers[i], s_months[i]
    if (s_att[i]>0) printf "  tentativas FTP falhas=%d", s_att[i]
    if (s_ftp[i]>0) printf "  sondas FTP=%d", s_ftp[i]
    if (s_stopped[i]!="") printf "  parou-em=%s", s_stopped[i]
    if (s_err[i]>0) printf "  linhas de erro=%d", s_err[i]
    if (s_kill[i]>0) printf "  SINAL DE KILL/WATCHDOG=%d", s_kill[i]
    if (s_files[i]==0 && s_att[i]==0 && s_err[i]==0 && s_sihpers[i]==0) printf "  (nada novo)"
    print ""
  }
}' "$LOG"

# --- 6. Fechamento -------------------------------------------------------------
title "Fechamento"
grep -E 'Controles de versão|ERRO: push|Checkpoints limpos|checkpoints preservados|=== Concluído' "$LOG" \
  | sed 's/^/  /' || true
if ! grep -q '=== Concluído' "$LOG"; then
  LAST=$(grep -E '^\[[0-9:]+\]' "$LOG" | tail -1)
  echo "  (sem linha de conclusão — rodada em andamento ou morta; último marcador: ${LAST:-nenhum})"
fi

fi  # LOG

# --- 7. Checkpoints no R2 -----------------------------------------------------
title "Checkpoints no R2 (maintenance/checkpoints/)"
CK=$(rclone lsl "$R2_REMOTE/maintenance/checkpoints/" 2>/dev/null)
if [ -n "$CK" ]; then
  echo "$CK" | awk '{printf "  %-32s %s %s  %s bytes\n", $4, $2, substr($3,1,8), $1}'
  echo "  → presentes = a última rodada não fechou 100% (ou está em andamento); a próxima retoma deles."
else
  echo "  vazio (última rodada fechou 100% e limpou)"
fi
echo
