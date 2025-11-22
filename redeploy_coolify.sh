#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# redeploy_coolify.sh
# Synchronise les variables CI commençant par SF_ (sans préfixe SF_ dans Coolify) et redéploie l'application
# Conçu pour GitLab CI avec runner Docker (dind)
# Usage: redeploy_coolify.sh <VERSION_TAG>
# Variables CI requises (Settings > CI/CD > Variables):
#   COOLIFY_API_URL, COOLIFY_TOKEN, COOLIFY_APP_UUID, CI_REGISTRY_IMAGE
# ----------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# --- Configuration générale ---
RETRIES=3
DELAY=2
TIMEOUT=15

# --- Vérification des dépendances ---
for cmd in bash curl jq mktemp grep env; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ Dépendance manquante: $cmd" >&2
    exit 1
  fi
done


if [[ -z "$SF_APP_VERSION" ]]; then
  echo "Usage: $0 <SF_APP_VERSION>" >&2
  exit 1
fi

# --- Variables CI obligatoires ---
: "${COOLIFY_API_URL:?COOLIFY_API_URL non défini}"
: "${COOLIFY_TOKEN:?COOLIFY_TOKEN non défini}"
: "${COOLIFY_APP_UUID:?COOLIFY_APP_UUID non défini}"
: "${CI_REGISTRY_IMAGE:?CI_REGISTRY_IMAGE non défini}"

API_URL="$COOLIFY_API_URL"
TOKEN="$COOLIFY_TOKEN"
APP_UUID="$COOLIFY_APP_UUID"

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

cleanup() { rm -f "$TMP_OUT" "$TMP_ENV"; }
trap cleanup EXIT

TMP_OUT=$(mktemp)
TMP_ENV=$(mktemp)

# 1) Extraction des SF_ puis suppression du préfixe
log "1/4 | Extraction et renommage des variables SF_"
env | grep -E '^SF_' > "$TMP_ENV" || { log "❌ Impossible de lister env"; exit 1; }

# Construct payload with stripped keys
payload=$(jq -Rn '
  [inputs
    | capture("(?<raw>SF_(?<key>[^=]+))=(?<value>.*)")
    | { key: .key, value: .value }
  ]
  | { data: . }' < "$TMP_ENV") || { log "❌ Échec JSON"; exit 1; }

mapfile -t KEYS < <(jq -r '.data[].key' <<<"$payload")
log "📋 Variables à synchroniser sans SF_: ${KEYS[*]}"

# 2) Suppression des variables obsolètes (sans SF_)
log "2/4 | Suppression des variables obsolètes"
existing=$(curl_retry "${AUTH_HEADER[@]}" -X GET "$API_URL/applications/$APP_UUID/envs")

echo "$existing" | jq -r '.[] | "\(.uuid)\t\(.key)"' \
  | while IFS=$'\t' read -r uuid key; do
    if ! printf '%s\n' "${KEYS[@]}" | grep -Fxq -- "$key"; then
      log "🗑 Suppression $key (UUID $uuid)"
      curl_retry "${AUTH_HEADER[@]}" -X DELETE "$API_URL/applications/$APP_UUID/envs/$uuid" &>/dev/null ||
        log "⚠️ Échec suppression $key"
    fi
done

# 3) Bulk update (clé sans SF_)
log "3/4 | Bulk update des variables (sans SF_)"
bulk_code=$(curl -s --max-time $TIMEOUT -w "%{http_code}" -o "$TMP_OUT" \
  "${AUTH_HEADER[@]}" "${JSON_HEADER[@]}" \
  -X PATCH "$API_URL/applications/$APP_UUID/envs/bulk" \
  -d "$payload"
)
if [[ "$bulk_code" =~ ^2 ]]; then
  log "✅ Bulk update OK"
else
  log "⚠️ Bulk KO ($bulk_code), fallback individuel"
  while IFS=$'\t' read -r raw_line; do
    # raw_line format SF_KEY=VALUE
    IFS='=' read -r raw val <<<"$raw_line"
    key=${raw#SF_}
    if [[ " ${KEYS[*]} " =~ " $key " ]]; then
      single=$(jq -n --arg k "$key" --arg v "$val" '{key:$k,value:$v,is_build_time:true,is_literal:true}')
      curl_retry "${AUTH_HEADER[@]}" "${JSON_HEADER[@]}" -X PATCH "$API_URL/applications/$APP_UUID/envs" -d "$single" \
        || curl_retry "${AUTH_HEADER[@]}" "${JSON_HEADER[@]}" -X POST "$API_URL/applications/$APP_UUID/envs" -d "$single"
    fi
done < "$TMP_ENV"
  log "✅ Fallback terminé"
fi

# 4) Déploiement
log "4/4 | Déploiement version $SF_APP_VERSION"
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
