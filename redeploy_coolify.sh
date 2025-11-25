#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# redeploy_coolify.sh
# Synchronise les variables CI commençant par SF_ (sans préfixe SF_ dans Coolify) et redéploie l'application
# Usage: redeploy_coolify.sh (SF_APP_VERSION optionnel pour le log)
# Variables CI requises :
#   COOLIFY_API_URL, COOLIFY_TOKEN, COOLIFY_APP_UUID
# ----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

RETRIES=3
DELAY=2
TIMEOUT=15

for cmd in bash curl jq mktemp grep env; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ Dépendance manquante: $cmd" >&2
    exit 1
  fi
done

# --- Variables CI obligatoires ---
: "${COOLIFY_API_URL:?COOLIFY_API_URL non défini}"
: "${COOLIFY_TOKEN:?COOLIFY_TOKEN non défini}"
: "${COOLIFY_APP_UUID:?COOLIFY_APP_UUID non défini}"

API_URL="$COOLIFY_API_URL"
TOKEN="$COOLIFY_TOKEN"
APP_UUID="$COOLIFY_APP_UUID"
APP_VERSION="${SF_APP_VERSION:-"(non spécifiée)"}"

AUTH_HEADER=( -H "Authorization: Bearer $TOKEN" )
JSON_HEADER=( -H "Content-Type: application/json" )

log() { echo "[$(date '+%F %T')] $*" >&2; }

curl_retry() {
  local args=("$@") code
  for i in $(seq 1 $RETRIES); do
    code=$(curl -s --max-time $TIMEOUT -w "%{http_code}" -o "$TMP_OUT" "${args[@]}") || true
    if [[ "$code" =~ ^2 ]]; then
      cat "$TMP_OUT"
      return 0
    fi
    log "Tentative $i/$RETRIES échouée (HTTP $code)"
    sleep $DELAY
  done
  return 1
}

build_payload() {
  local lines="$1"
  jq -Rn '
    [inputs
      | capture("(?<raw>SF_(?<key>[^=]+))=(?<value>.*)")
      | { key: .key, value: .value, is_build_time:true, is_literal:true }
    ] | { data: . }' <<<"$lines"
}

apply_sf_envs() {
  local lines="$1"
  if [[ -z "$lines" ]]; then
    log "ℹ️ Aucune variable SF_ à appliquer"
    return 0
  fi

  log "Construction du payload SF_"
  payload=$(build_payload "$lines") || { log "❌ Échec construction JSON"; exit 1; }
  mapfile -t KEYS < <(jq -r '.data[].key' <<<"$payload")
  log "📋 Variables SF_ détectées (préfixe retiré): ${KEYS[*]}"

  log "Application des variables SF_ (add/override uniquement)"
  bulk_code=$(curl -s --max-time $TIMEOUT -w "%{http_code}" -o "$TMP_OUT" \
    "${AUTH_HEADER[@]}" "${JSON_HEADER[@]}" \
    -X PATCH "$API_URL/applications/$APP_UUID/envs/bulk" \
    -d "$payload"
  )
  if [[ "$bulk_code" =~ ^2 ]]; then
    log "✅ Variables SF_ synchronisées (bulk)"
    return 0
  fi

  log "⚠️ Bulk KO ($bulk_code), fallback individuel"
  while IFS= read -r raw_line; do
    [[ -z "$raw_line" ]] && continue
    IFS='=' read -r raw val <<<"$raw_line"
    key="${raw#SF_}"
    single=$(jq -n --arg k "$key" --arg v "$val" '{key:$k,value:$v,is_build_time:true,is_literal:true}')
    curl_retry "${AUTH_HEADER[@]}" "${JSON_HEADER[@]}" -X PATCH "$API_URL/applications/$APP_UUID/envs" -d "$single" \
      || curl_retry "${AUTH_HEADER[@]}" "${JSON_HEADER[@]}" -X POST "$API_URL/applications/$APP_UUID/envs" -d "$single"
  done <<<"$lines"
  log "✅ Fallback terminé"
}

deploy_app() {
  log "Déploiement version $APP_VERSION"
  response_code=$(curl -s --max-time $TIMEOUT -w "%{http_code}" -o "$TMP_OUT" \
    "${AUTH_HEADER[@]}" -X GET "$API_URL/deploy?uuid=$APP_UUID&force=true")
  if [[ "$response_code" =~ ^2 ]]; then
    cat "$TMP_OUT" | jq .
    log "🎉 Déploiement terminé"
  else
    log "❌ Déploiement échoué (HTTP $response_code)"
    log "📝 Réponse de l'API :"
    sed 's/^/   /' "$TMP_OUT" >&2
    exit 1
  fi
}

cleanup() { rm -f "$TMP_OUT"; }
trap cleanup EXIT

TMP_OUT=$(mktemp)

SF_LINES=$(env | grep -E '^SF_' || true)

apply_sf_envs "$SF_LINES"
deploy_app
