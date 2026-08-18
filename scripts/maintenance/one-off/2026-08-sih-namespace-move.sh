#!/usr/bin/env bash
# ==============================================================================
# 2026-08-sih-namespace-move.sh — Move sih/ano=… → sih/rd/ano=… no R2 (one-off)
# ==============================================================================
#
# Contexto: ao adicionar o submódulo SP, o SIH virou namespace (sih/rd/,
# sih/sp/), como o sipni/. Este script move os dados RD existentes para
# sih/rd/ com operações server-side (sem egress), reescreve os caminhos no
# manifest.json e publica os READMEs de índice e do RD.
#
# PRÉ-CONDIÇÕES (verificadas no início):
#   - nenhuma VPS de manutenção ativa (a rodada em curso grava em sih/)
#   - o código com R2_PREFIX = "sih/rd" já está em master (senão a próxima
#     rodada gravaria no lugar antigo)
#
# Roda do PC (rclone remote "r2"). Idempotente: pode ser reexecutado.
# ==============================================================================

set -euo pipefail

R2="r2:healthbr-data"
REPO="${REPO:-/c/dev/parquet-files}"
HC="${HC:-/c/Users/SIDNEY/AppData/Local/Microsoft/WinGet/Packages/HetznerCloud.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe/hcloud.exe}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# --- 0. Pré-condições ---------------------------------------------------------
if [ -x "$HC" ]; then
  N=$("$HC" --context healthbr server list --selector healthbr=maintenance-run -o json | python -c "import json,sys;print(len(json.load(sys.stdin)))")
  [ "$N" = "0" ] || { echo "ABORT: há VPS de manutenção ativa ($N). Espere a rodada fechar."; exit 1; }
fi
git -C "$REPO" fetch -q origin
if ! git -C "$REPO" show origin/master:scripts/pipeline/sih-pipeline-r.R | grep -q 'r2_prefix = "sih/rd"'; then
  echo "ABORT: origin/master ainda não tem R2_PREFIX sih/rd — faça o push do código antes."; exit 1
fi

# --- 1. Mover dados (2 passos: rclone recusa move para dentro da própria árvore)
if [ -n "$(rclone lsf "$R2/sih/" --dirs-only | grep -E '^ano=' | head -1)" ]; then
  log "Passo 1a: sih/ano=* → sih__rd_tmp/ (server-side)"
  rclone move "$R2/sih" "$R2/sih__rd_tmp" --include "ano=*/**" \
    --transfers 32 --checkers 64 --stats 30s --stats-one-line
  log "Passo 1b: sih__rd_tmp/ → sih/rd/ (server-side)"
  rclone move "$R2/sih__rd_tmp" "$R2/sih/rd" \
    --transfers 32 --checkers 64 --stats 30s --stats-one-line
  rclone rmdirs "$R2/sih__rd_tmp" 2>/dev/null || true
else
  log "Passo 1: nenhum sih/ano=* restante (já movido)"
fi

# --- 2. Manifest: reescrever paths e dataset ----------------------------------
if rclone lsf "$R2/sih/manifest.json" | grep -q manifest.json; then
  log "Passo 2: manifest sih/manifest.json → sih/rd/manifest.json (paths reescritos)"
  rclone copyto "$R2/sih/manifest.json" "$TMP/manifest.json"
  python - "$TMP/manifest.json" <<'EOF'
import json, sys
p = sys.argv[1]
m = json.load(open(p, encoding="utf-8"))
m["dataset"] = "sih/rd"
n = 0
for part in m.get("partitions", {}).values():
    for f in part.get("output_files", []):
        if f.get("path", "").startswith("sih/ano="):
            f["path"] = "sih/rd/" + f["path"][len("sih/"):]
            n += 1
json.dump(m, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(f"  {n} caminhos reescritos, {len(m['partitions'])} partições")
EOF
  rclone copyto "$TMP/manifest.json" "$R2/sih/rd/manifest.json"
  rclone deletefile "$R2/sih/manifest.json"
else
  log "Passo 2: manifest já em sih/rd/ (ou ausente)"
fi

# --- 3. READMEs ----------------------------------------------------------------
log "Passo 3: READMEs (índice em sih/, card RD em sih/rd/, card SP em sih/sp/)"
rclone copyto "$REPO/guides/dataset-cards/sih-index-README.md" "$R2/sih/README.md"
rclone copyto "$REPO/guides/dataset-cards/sih-rd-README.md"    "$R2/sih/rd/README.md"
rclone copyto "$REPO/guides/dataset-cards/sih-sp-README.md"    "$R2/sih/sp/README.md"

# --- 4. Checkpoint antigo no R2 (nome mudou) ---------------------------------
if rclone lsf "$R2/maintenance/checkpoints/controle_versao_sih.csv" | grep -q csv; then
  log "Passo 4: renomeando checkpoint controle_versao_sih.csv → controle_versao_sih_rd.csv"
  rclone moveto "$R2/maintenance/checkpoints/controle_versao_sih.csv" \
                "$R2/maintenance/checkpoints/controle_versao_sih_rd.csv"
fi

# --- 5. Verificação -----------------------------------------------------------
log "Verificação:"
echo "  sih/ raiz:      $(rclone lsf "$R2/sih/" | tr '\n' ' ')"
echo "  sih/rd/ anos:   $(rclone lsf "$R2/sih/rd/" --dirs-only | wc -l) diretórios ano=*"
echo "  sih/rd/ objetos: $(rclone size "$R2/sih/rd/" --json | python -c 'import json,sys;d=json.load(sys.stdin);print(d["count"],"objetos,",round(d["bytes"]/2**30,2),"GiB")')"
log "Concluído."
