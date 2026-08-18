#!/usr/bin/env bash
# ==============================================================================
# run-maintenance.sh — Orquestrador da manutenção (roda na VPS efêmera)
# ==============================================================================
#
# Executado pelo cloud-init da VPS criada pelo workflow maintenance.yml.
# Fluxo:
#   1. Baixa o sync-status.json mais recente do R2
#   2. prepare_maintenance.py decide quais pipelines rodar (e poda o controle
#      de versão das partições outdated de sih/sinasc)
#   3. Roda cada pipeline incremental
#   4. Commita os controles de versão atualizados de volta ao GitHub
#   5. Publica um resumo da rodada em maintenance/last-run.json no R2
#
# O upload do log completo e a AUTO-DELEÇÃO da VPS (hcloud server delete)
# ficam a cargo do cloud-init, para acontecerem mesmo se este script morrer
# no meio. O maintenance-reaper.yml é o backstop se até isso falhar.
#
# Pré-requisitos (garantidos pelo snapshot + cloud-init):
#   - R + arrow + read.dbc + pacotes do setup (reference-pipelines-pt.md, §2)
#   - python3 + polars + boto3, jq, rclone com remote "r2" configurado
#   - Repo clonado em $REPO com credencial de push (PAT na URL do remote)
#   - Env vars: R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT
# ==============================================================================

set -uo pipefail

REPO="${REPO:-/root/healthbr-data}"
R2_REMOTE="r2:healthbr-data"
T_INICIO=$(date -u +%s)
FALHAS=()
RODADOS=()

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# Sobe o log parcial e os controles para o R2. Chamado após cada pipeline:
# o log fica observável DURANTE a rodada e sobrevive a qualquer morte da
# VPS (o upload do cloud-init ao final é só backup), e os checkpoints dos
# controles ficam garantidos mesmo se o upload interno do pipeline falhar.
publicar_progresso() {
  rclone copyto /root/maintenance.log "$R2_REMOTE/maintenance/last-run.log" \
    --s3-no-check-bucket 2>/dev/null \
    || log "AVISO: upload do log parcial falhou"
  for csv in data/controle_versao_*.csv; do
    rclone copyto "$csv" "$R2_REMOTE/maintenance/checkpoints/$(basename "$csv")" \
      --s3-no-check-bucket 2>/dev/null || true
  done
}

cd "$REPO" || { echo "FATAL: repo não encontrado em $REPO"; exit 1; }

log "=== Manutenção healthbr-data — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# --- 1. Estado de sincronização ----------------------------------------------

log "Baixando sync-status.json do R2..."
if ! rclone copyto "$R2_REMOTE/sync-status.json" /root/sync-status.json; then
  echo "FATAL: não foi possível baixar sync-status.json"
  exit 1
fi

# --- 1b. Restaurar checkpoints de rodada interrompida -------------------------
# Os pipelines sobem o controle de versão para maintenance/checkpoints/ a cada
# lote concluído. Se existem checkpoints, a rodada anterior morreu no meio —
# eles estão estritamente à frente do repo e evitam refazer horas de trabalho.
# (Após uma rodada 100% ok, o passo 4b limpa o diretório.)

for csv in controle_versao_sinasc.csv controle_versao_sih_rd.csv \
           controle_versao_sih_sp.csv controle_versao_microdata.csv \
           controle_versao_covid.csv; do
  if [ -n "$(rclone lsf "$R2_REMOTE/maintenance/checkpoints/$csv" 2>/dev/null)" ]; then
    rclone copyto "$R2_REMOTE/maintenance/checkpoints/$csv" "data/$csv" \
      && log "Checkpoint restaurado: $csv (rodada anterior interrompida)"
  fi
done

# --- 2. Plano de trabalho -----------------------------------------------------

log "Determinando datasets pendentes..."
DATASETS=$(python3 scripts/maintenance/prepare_maintenance.py \
  /root/sync-status.json "$REPO") || {
  echo "FATAL: prepare_maintenance.py falhou"
  exit 1
}

if [ -z "$DATASETS" ]; then
  log "Nada a fazer — todos os datasets automatizados em sincronia."
else
  # --- 3. Rodar pipelines -----------------------------------------------------
  for ds in $DATASETS; do
    # Guarda: um bootstrap desse módulo em VPS dedicada (launch-bootstrap-vps.sh,
    # label modulo=<ds>) escreve no mesmo prefixo — nunca rodar em paralelo
    if [ -n "${HCLOUD_TOKEN:-}" ] && command -v hcloud >/dev/null 2>&1; then
      N_BOOT=$(hcloud server list --selector "healthbr=bootstrap,modulo=$ds" -o json 2>/dev/null \
                 | jq length 2>/dev/null || echo 0)
      if [ "${N_BOOT:-0}" != "0" ]; then
        log "--- $ds: bootstrap em andamento em VPS dedicada — pulando nesta rodada ---"
        FALHAS+=("$ds(bootstrap-em-andamento)")
        continue
      fi
    fi
    log "--- Pipeline: $ds ---"
    # timeout: um pipeline travado (FTP preso, worker morto) vira falha
    # registrada em vez de rodada eterna; com os checkpoints, o custo de
    # um kill é só o lote em andamento
    case "$ds" in
      sinasc)
        timeout --kill-after=5m 4h Rscript scripts/pipeline/sinasc-pipeline-r.R
        ;;
      sih-rd|sih-sp)
        # sih-rd → SIH_TIPO=RD (sih/rd/), sih-sp → SIH_TIPO=SP (sih/sp/)
        SIH_TIPO="${ds#sih-}"; SIH_TIPO="${SIH_TIPO^^}"
        SIH_TIPO="$SIH_TIPO" SIH_SPRINT=3 timeout --kill-after=5m 14h \
          Rscript scripts/pipeline/sih-pipeline-r.R
        rc=$?
        # 75 (EX_TEMPFAIL): o pipeline detectou o FTP do DATASUS fora do ar
        # e encerrou limpo — tudo até ali está persistido. Não é erro do
        # pipeline; a rodada seguinte retoma do ponto exato.
        if [ "$rc" -eq 75 ]; then
          log "--- $ds: FTP DATASUS indisponível — encerrou limpo (progresso persistido; retoma na próxima rodada) ---"
          FALHAS+=("$ds(ftp-indisponivel)")
          publicar_progresso
          continue
        fi
        (exit "$rc")
        ;;
      sipni-microdados)
        CONTROLE_CSV_MICRODADOS="$REPO/data/controle_versao_microdata.csv" \
          timeout --kill-after=5m 14h \
          python3 scripts/pipeline/sipni-microdata-pipeline-python.py
        ;;
      sipni-covid)
        # Sem o controle no repo, o pipeline reprocessaria os ~272 GB do zero
        if [ ! -f "$REPO/data/controle_versao_covid.csv" ]; then
          log "AVISO: data/controle_versao_covid.csv ausente do repo;"
          log "       pulando sipni-covid para evitar reprocessamento total."
          FALHAS+=("$ds(sem-controle)")
          continue
        fi
        CONTROLE_CSV_COVID="$REPO/data/controle_versao_covid.csv" \
          timeout --kill-after=5m 14h \
          python3 scripts/pipeline/sipni-covid-pipeline.py
        ;;
      *)
        log "AVISO: dataset desconhecido '$ds'; ignorando"
        continue
        ;;
    esac

    if [ $? -eq 0 ]; then
      RODADOS+=("$ds")
      log "--- $ds: OK ---"
    else
      FALHAS+=("$ds")
      log "--- $ds: FALHOU (seguindo para o próximo) ---"
    fi
    publicar_progresso
  done

  # --- 4. Commitar controles de versão ---------------------------------------
  git config user.name "healthbr-maintenance-bot"
  git config user.email "noreply@healthbr-data.org"
  git add data/controle_versao_*.csv
  if ! git diff --cached --quiet; then
    git commit -m "maintenance: update version control ($(date -u +%Y-%m-%d))"
    git pull --rebase origin master && git push origin master \
      && log "Controles de versão commitados e enviados." \
      || { FALHAS+=("git-push"); log "ERRO: push dos controles falhou"; }
  else
    log "Controles de versão sem mudanças."
  fi

  # --- 4b. Limpar checkpoints (só quando a rodada fechou 100%) ---------------
  if [ ${#FALHAS[@]} -eq 0 ]; then
    rclone purge "$R2_REMOTE/maintenance/checkpoints" 2>/dev/null || true
    log "Checkpoints limpos (rodada completa e commitada)."
  else
    log "Rodada com falhas — checkpoints preservados para a próxima retomar."
  fi
fi

# --- 5. Resumo da rodada ------------------------------------------------------

T_TOTAL=$(( $(date -u +%s) - T_INICIO ))
STATUS=$([ ${#FALHAS[@]} -eq 0 ] && echo "success" || echo "partial_failure")

jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg status "$STATUS" \
  --arg rodados "${RODADOS[*]:-}" \
  --arg falhas "${FALHAS[*]:-}" \
  --argjson dur "$T_TOTAL" \
  '{timestamp: $ts, status: $status, duration_seconds: $dur,
    datasets_run: ($rodados | split(" ") | map(select(. != ""))),
    failures: ($falhas | split(" ") | map(select(. != "")))}' \
  > /root/last-run.json

rclone copyto /root/last-run.json "$R2_REMOTE/maintenance/last-run.json" \
  --s3-no-check-bucket
publicar_progresso

log "=== Concluído: status=$STATUS, duração=${T_TOTAL}s ==="
[ "$STATUS" = "success" ]
