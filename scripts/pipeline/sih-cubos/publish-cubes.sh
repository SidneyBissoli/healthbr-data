#!/usr/bin/env bash
# Publica cubos + sidecars + manifesto em sih/cubos/ do bucket healthbr-data
# (R2), servido em https://data.sidneybissoli.com/sih/cubos/.
#
# Uso: publish-cubes.sh <anos separados por vírgula | all | none> [pasta-de-dados] [pasta-das-tabelas] [pasta-da-população]
# Exige R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY e R2_ENDPOINT no ambiente (os
# mesmos secrets que o sync-check.yml usa; token "Object Read & Write" do
# bucket healthbr-data). Usa o AWS CLI v2 (pré-instalado no ubuntu-latest)
# contra o endpoint S3 do R2. Com a 3ª posição, publica também as tabelas de
# classificação (tables/*.json) em sih/cubos/tables/, com sha256 no manifesto.
# Com a 4ª (build-sih-population.yml), publica os denominadores populacionais
# (pop_uf, pop_uf_agregado, pop_municipios .parquet + pop_provenance.json) ao
# lado dos cubos, assinados no bloco `population` do manifesto; `none` na 1ª
# posição = nenhum ano (só tabelas e/ou população; os anos herdam do anterior).
#
# Ordem: (1) baixa o manifesto anterior; (2) gera o novo com --verify (DuckDB
# confere cada cubo contra o sidecar e cada arquivo de população contra o
# pop_provenance.json — nada sobe sem bater); (3) envia os arquivos do(s)
# ano(s), tabelas e população; (4) envia o manifesto por último (quem lê o
# manifesto só vê arquivos que já estão lá); (5) confere pelo domínio público
# que cada arquivo responde com o tamanho local.
set -euo pipefail

YEARS_ARG="${1:?uso: publish-cubes.sh <anos|all|none> [pasta] [tabelas] [população]}"
DATA_DIR="${2:-data/sih-cubos}"
TABLES_DIR="${3:-}"
POP_DIR="${4:-}"
POP_FILES=(pop_uf.parquet pop_uf_agregado.parquet pop_municipios.parquet pop_provenance.json)
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID ausente}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY ausente}"
: "${R2_ENDPOINT:?R2_ENDPOINT ausente}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENDPOINT="$R2_ENDPOINT"
BUCKET="healthbr-data"
PREFIX="sih/cubos"
PUBLIC_BASE="https://data.sidneybissoli.com/${PREFIX}"
FALLBACK_BASE="https://pub-99d9e1a3f5c542178d04efbddf1bba97.r2.dev/${PREFIX}"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="auto"
export AWS_EC2_METADATA_DISABLED="true"
# AWS CLI >= 2.23 manda checksum CRC32 por padrão e o R2 recusa; "when_required"
# volta ao comportamento compatível com S3 clássico.
export AWS_REQUEST_CHECKSUM_CALCULATION="when_required"
export AWS_RESPONSE_CHECKSUM_VALIDATION="when_required"

command -v aws >/dev/null || { echo "::error::aws cli não encontrado"; exit 1; }

if [ "$YEARS_ARG" = "all" ]; then
  YEARS=$(ls "$DATA_DIR"/sih_provenance_*.json | sed -E 's/.*sih_provenance_([0-9]{4})\.json/\1/' | sort)
elif [ "$YEARS_ARG" = "none" ]; then
  YEARS=""
else
  YEARS=$(echo "$YEARS_ARG" | tr ',' ' ')
fi
YEARS_CSV=$(echo $YEARS | tr ' ' ',')
[ -n "$YEARS_CSV" ] || YEARS_CSV="none"
if [ -n "$POP_DIR" ]; then
  for F in "${POP_FILES[@]}"; do [ -f "$POP_DIR/$F" ] || { echo "::error::população: falta $POP_DIR/$F"; exit 1; }; done
fi
echo "publish-cubes: anos $YEARS_CSV de $DATA_DIR${TABLES_DIR:+; tabelas de $TABLES_DIR}${POP_DIR:+; população de $POP_DIR}"

# (1) manifesto anterior — pode não existir na primeira publicação
if ! curl -fsSL --max-time 30 "$PUBLIC_BASE/manifest.json" -o previous-manifest.json 2>/dev/null; then
  if ! curl -fsSL --max-time 30 "$FALLBACK_BASE/manifest.json" -o previous-manifest.json 2>/dev/null; then
    echo "publish-cubes: sem manifesto anterior (primeira publicação)"
    echo '{"years":{}}' > previous-manifest.json
  fi
fi

# (2) manifesto novo, verificado
EXTRA_FLAGS=()
if [ -n "$TABLES_DIR" ]; then EXTRA_FLAGS+=(--tables "$TABLES_DIR"); fi
if [ -n "$POP_DIR" ]; then EXTRA_FLAGS+=(--population "$POP_DIR"); fi
node "$HERE/cubes-manifest.mjs" --data "$DATA_DIR" --years "$YEARS_CSV" \
  --previous previous-manifest.json --verify "${EXTRA_FLAGS[@]}" \
  --base-url "$PUBLIC_BASE/" --out cubes-manifest.json

# (3) arquivos do(s) ano(s)
# max-age=300 (era 86400 até 2026-09-08): todo objeto daqui é REESCRITO NO LUGAR
# (mesmo nome, conteúdo novo a cada rebuild) e a borda do domínio honra o
# Cache-Control do objeto — com 24 h, o consumidor recebia o cubo do build
# anterior (HIT, Age 15 h) enquanto o manifesto já assinava o novo, e a
# verificação de tamanho/SHA-256 falhava (sih_series_2023: 36.047 bytes servidos
# vs 36.352 na origem, prova do sih-br-mcp 0.12.0). O egresso do R2 é grátis;
# a borda só ganha latência. Quem verifica pelo manifesto deve ainda anexar
# ?v=<sha256> à URL (chave de cache por versão) — docs/contract-consumers-pt.md.
put() { # put <arquivo local> <nome remoto> <content-type>
  aws s3 cp "$1" "s3://$BUCKET/$PREFIX/$2" --endpoint-url "$ENDPOINT" \
    --content-type "$3" --cache-control "public, max-age=300" --only-show-errors
  echo "  enviado $2"
}
for Y in $YEARS; do
  for C in causas series icsap; do
    put "$DATA_DIR/sih_${C}_${Y}.parquet" "sih_${C}_${Y}.parquet" "application/vnd.apache.parquet"
  done
  put "$DATA_DIR/sih_provenance_${Y}.json" "sih_provenance_${Y}.json" "application/json"
done
# (3b) tabelas de classificação — o contrato que o consumidor confere por sha256
if [ -n "$TABLES_DIR" ]; then
  for T in "$TABLES_DIR"/*.json; do
    put "$T" "tables/$(basename "$T")" "application/json"
  done
fi
# (3c) denominadores populacionais — ao lado dos cubos, assinados em `population`
if [ -n "$POP_DIR" ]; then
  for F in "${POP_FILES[@]}"; do
    case "$F" in *.parquet) CT="application/vnd.apache.parquet" ;; *) CT="application/json" ;; esac
    put "$POP_DIR/$F" "$F" "$CT"
  done
fi

# (4) manifesto por último, com cache curto
aws s3 cp cubes-manifest.json "s3://$BUCKET/$PREFIX/manifest.json" --endpoint-url "$ENDPOINT" \
  --content-type "application/json" --cache-control "public, max-age=300" --only-show-errors
echo "  enviado manifest.json"

# (5) conferência pelo domínio público: tamanho remoto = tamanho local
falhas=0
check() { # check <arquivo local> <nome remoto>
  local esperado remoto
  esperado=$(stat -c %s "$1" 2>/dev/null || stat -f %z "$1")
  remoto=$(curl -sI --max-time 30 "$PUBLIC_BASE/$2" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')
  if [ "$remoto" != "$esperado" ]; then
    echo "::error::$2: content-length remoto '$remoto' != local $esperado"
    falhas=$((falhas+1))
  fi
}
for Y in $YEARS; do
  for C in causas series icsap; do check "$DATA_DIR/sih_${C}_${Y}.parquet" "sih_${C}_${Y}.parquet"; done
  check "$DATA_DIR/sih_provenance_${Y}.json" "sih_provenance_${Y}.json"
done
if [ -n "$TABLES_DIR" ]; then
  for T in "$TABLES_DIR"/*.json; do check "$T" "tables/$(basename "$T")"; done
fi
if [ -n "$POP_DIR" ]; then
  for F in "${POP_FILES[@]}"; do check "$POP_DIR/$F" "$F"; done
fi
check cubes-manifest.json manifest.json
[ "$falhas" -eq 0 ] || exit 1
echo "publish-cubes: OK — $PUBLIC_BASE/manifest.json"
{
  echo "### Publicado em \`$PUBLIC_BASE/\`"
  echo
  echo "Anos: $YEARS_CSV${TABLES_DIR:+; tabelas de classificação}${POP_DIR:+; população (pop_uf, pop_uf_agregado, pop_municipios + pop_provenance.json)}. Manifesto: $PUBLIC_BASE/manifest.json"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
