#!/usr/bin/env bash
# ==============================================================================
# launch-bootstrap-vps.sh — VPS efêmera para bootstrap de um módulo (do PC)
# ==============================================================================
#
# Cria uma VPS Hetzner a partir do snapshot de manutenção (label
# healthbr=maintenance), injeta credenciais e o repo via cloud-init, roda UM
# comando de pipeline e se autodeleta ao terminar. Como o maintenance.yml,
# mas para bootstraps longos disparados manualmente — e SEM o label
# healthbr=maintenance-run (o reaper não a mata; a duração é livre).
#
# Uso:
#   bash scripts/maintenance/launch-bootstrap-vps.sh <nome> '<comando>' [tipo]
#
#   bash scripts/maintenance/launch-bootstrap-vps.sh sih-sp \
#     'SIH_TIPO=SP SIH_SPRINT=3 SIH_FONTE=r2 Rscript scripts/pipeline/sih-pipeline-r.R'
#
# O comando roda com cwd na raiz do repo clonado (branch master), com o
# rclone remote "r2" configurado, e o log fica observável em
#   r2:healthbr-data/maintenance/bootstrap/<nome>.log     (a cada 5 min)
#   r2:healthbr-data/maintenance/bootstrap/<nome>.done    (resumo ao fim)
# Os controles de versão que o pipeline gravar em data/ são commitados e
# enviados ao GitHub ao final (como na manutenção), e os checkpoints do
# pipeline (maintenance/checkpoints/) continuam valendo se a VPS morrer.
#
# Requer no ambiente: HCLOUD_TOKEN ou contexto hcloud "healthbr" ativo, e
# R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ENDPOINT / MAINT_GH_PAT
# (os mesmos secrets do GitHub Actions) — ou lidos de ~/.healthbr.env.
# ==============================================================================

set -euo pipefail

NOME="${1:?uso: launch-bootstrap-vps.sh <nome> '<comando>' [tipo]}"
CMD="${2:?informe o comando do pipeline entre aspas}"
TIPO_VPS="${3:-cpx42}"
LOCATION="${LOCATION:-nbg1}"
REPO_URL="${REPO_URL:-github.com/SidneyBissoli/healthbr-data.git}"
SSH_KEY="${SSH_KEY:-hetzner-sipni}"
HC="${HC:-$(command -v hcloud || ls "$LOCALAPPDATA"/Microsoft/WinGet/Packages/HetznerCloud.CLI*/hcloud.exe 2>/dev/null | head -1)}"
[ -x "$HC" ] || { echo "hcloud não encontrado"; exit 1; }
HCX=("$HC" --context "${HCLOUD_CONTEXT:-healthbr}")

[ -f ~/.healthbr.env ] && source ~/.healthbr.env
# Conveniência: R2 a partir do rclone remote "r2" e PAT a partir do gh CLI
if [ -z "${R2_ACCESS_KEY_ID:-}" ] && command -v rclone >/dev/null; then
  eval "$(rclone config dump | python -c '
import json,sys; r=json.load(sys.stdin).get("r2",{})
for k,v in (("R2_ACCESS_KEY_ID","access_key_id"),("R2_SECRET_ACCESS_KEY","secret_access_key"),("R2_ENDPOINT","endpoint")):
    print(k + "=" + r.get(v,""))')"
fi
[ -z "${MAINT_GH_PAT:-}" ] && command -v gh >/dev/null && MAINT_GH_PAT="$(gh auth token 2>/dev/null || true)"
for v in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT MAINT_GH_PAT; do
  [ -n "${!v:-}" ] || { echo "falta a variável $v (exporte ou coloque em ~/.healthbr.env)"; exit 1; }
done

SERVER="healthbr-boot-${NOME}"
if [ -z "${DRY_RUN:-}" ] && "${HCX[@]}" server describe "$SERVER" >/dev/null 2>&1; then
  echo "Já existe VPS $SERVER — abortando."; exit 1
fi

if [ -n "${DRY_RUN:-}" ]; then
  IMAGE_ID=0
else
  IMAGE_ID=$("${HCX[@]}" image list --type snapshot --selector healthbr=maintenance -o json \
    | python -c "import json,sys; l=sorted(json.load(sys.stdin), key=lambda i:i['created']); print(l[-1]['id'] if l else '')")
  [ -n "$IMAGE_ID" ] || { echo "nenhum snapshot healthbr=maintenance"; exit 1; }
fi
echo "Snapshot: $IMAGE_ID  |  VPS: $SERVER ($TIPO_VPS, $LOCATION)"

UD="$(mktemp)"
cat > "$UD" <<EOF
#cloud-config
write_files:
  - path: /root/maint.env
    permissions: "0600"
    content: |
      export R2_ACCESS_KEY_ID=${R2_ACCESS_KEY_ID}
      export R2_SECRET_ACCESS_KEY=${R2_SECRET_ACCESS_KEY}
      export R2_ENDPOINT=${R2_ENDPOINT}
      export GH_PAT=${MAINT_GH_PAT}
      export HCLOUD_TOKEN=${HCLOUD_TOKEN:-}
  - path: /root/bootstrap.sh
    permissions: "0700"
    content: |
      #!/usr/bin/env bash
      set -uo pipefail
      source /root/maint.env
      LOG=/root/bootstrap.log
      R2LOG="r2:healthbr-data/maintenance/bootstrap/${NOME}.log"
      log(){ echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] \$*" | tee -a \$LOG; }
      curl -sL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar xz -C /usr/local/bin hcloud
      rclone config create r2 s3 provider Cloudflare access_key_id "\$R2_ACCESS_KEY_ID" \\
        secret_access_key "\$R2_SECRET_ACCESS_KEY" endpoint "\$R2_ENDPOINT" >/dev/null
      git clone -q "https://x-access-token:\${GH_PAT}@${REPO_URL}" /root/healthbr-data
      cd /root/healthbr-data
      log "=== bootstrap ${NOME} — \$(git rev-parse --short HEAD) ==="
      log "cmd: ${CMD}"
      # log observável a cada 5 min
      ( while true; do sleep 300; rclone copyto \$LOG "\$R2LOG" --s3-no-check-bucket 2>/dev/null; done ) &
      TICK=\$!
      T0=\$(date +%s)
      bash -c '${CMD}' >> \$LOG 2>&1
      RC=\$?
      kill \$TICK 2>/dev/null
      log "=== fim: rc=\$RC, duração \$(( (\$(date +%s)-T0)/60 )) min ==="
      # controles de versão → GitHub
      git config user.name "healthbr-maintenance-bot"; git config user.email "noreply@healthbr-data.org"
      git add data/controle_versao_*.csv
      if ! git diff --cached --quiet; then
        git commit -qm "bootstrap ${NOME}: update version control (\$(date -u +%Y-%m-%d))"
        git pull -q --rebase origin master && git push -q origin master && log "controles enviados ao GitHub" || log "ERRO: push dos controles"
      fi
      rclone copyto \$LOG "\$R2LOG" --s3-no-check-bucket
      echo "{\"nome\":\"${NOME}\",\"rc\":\$RC,\"finished\":\"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \\
        | rclone rcat "r2:healthbr-data/maintenance/bootstrap/${NOME}.done" --s3-no-check-bucket
      hcloud server delete "\$(hostname)" || shutdown -h now
runcmd:
  - [ bash, -c, "nohup /root/bootstrap.sh > /root/cloudinit.out 2>&1 &" ]
EOF

if [ -n "${DRY_RUN:-}" ]; then
  echo "--- DRY_RUN: user-data renderizado (segredos mascarados) ---"
  sed -E 's/(KEY_ID=|ACCESS_KEY=|GH_PAT=|TOKEN=|x-access-token:)[^ @"]*/\1***/g' "$UD"
  rm -f "$UD"; exit 0
fi

"${HCX[@]}" server create --name "$SERVER" --type "$TIPO_VPS" --location "$LOCATION" \
  --image "$IMAGE_ID" --user-data-from-file "$UD" --ssh-key "$SSH_KEY" \
  --label healthbr=bootstrap --label modulo="$NOME"
rm -f "$UD"
echo
echo "VPS $SERVER criada. Acompanhe:"
echo "  rclone cat r2:healthbr-data/maintenance/bootstrap/${NOME}.log | tail"
echo "  $HC --context healthbr server list --selector healthbr=bootstrap"
echo "Ela se autodeleta ao terminar (sem reaper: se travar, delete manualmente)."
