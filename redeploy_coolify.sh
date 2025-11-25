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

cleanup() { rm -f "$TMP_OUT" "$TMP_ENV" "$TMP_UPDATES"; }
trap cleanup EXIT

TMP_OUT=$(mktemp)
TMP_ENV=$(mktemp)
TMP_UPDATES=$(mktemp)

# 1) Extraction des SF_ puis suppression du préfixe (sans suppression des variables existantes)
log "1/3 | Extraction et renommage des variables SF_"
mapfile -t SF_VARS < <(env | grep -E '^SF_' || true)
if ((${#SF_VARS[@]} == 0)); then
  log "ℹ️ Aucune variable SF_ détectée; aucune synchro nécessaire côté env"
else
  printf '%s\n' "${SF_VARS[@]}" > "$TMP_ENV"
fi

if [[ -s "$TMP_ENV" ]]; then
  existing=$(curl_retry "${AUTH_HEADER[@]}" -X GET "$API_URL/applications/$APP_UUID/envs") || { log "❌ Impossible de récupérer les variables existantes"; exit 1; }

  declare -A CURRENT_VALUES
  while IFS=$'\t' read -r key value; do
    CURRENT_VALUES["$key"]="$value"
  done < <(echo "$existing" | jq -r '.[] | "\(.key)\t\(.value)"')

  KEYS=()
  while IFS= read -r line; do
    raw_key="${line%%=*}"
    value="${line#*=}"
    key="${raw_key#SF_}"
    KEYS+=("$key")

    if [[ -v CURRENT_VALUES["$key"] && "${CURRENT_VALUES[$key]}" == "$value" ]]; then
      continue
    fi

    jq -n --arg k "$key" --arg v "$value" \
      '{key:$k,value:$v,is_build_time:true,is_literal:true}' >> "$TMP_UPDATES"
  done < "$TMP_ENV"

  log "📋 Variables SF_ détectées (préfixe retiré): ${KEYS[*]}"
fi

# 2) Mises à jour ou ajouts ciblés des variables SF_ (sans toucher aux autres)
if [[ -s "$TMP_UPDATES" ]]; then
  payload=$(jq -s '{data: .}' "$TMP_UPDATES") || { log "❌ Échec construction JSON"; exit 1; }
  log "2/3 | Mise à jour/ajout des variables SF_ (aucune suppression des existantes)"
  bulk_code=$(curl -s --max-time $TIMEOUT -w "%{http_code}" -o "$TMP_OUT" \
    "${AUTH_HEADER[@]}" "${JSON_HEADER[@]}" \
    -X PATCH "$API_URL/applications/$APP_UUID/envs/bulk" \
    -d "$payload"
  )
  if [[ "$bulk_code" =~ ^2 ]]; then
    log "✅ Variables SF_ synchronisées (bulk)"
  else
    log "⚠️ Bulk KO ($bulk_code), fallback individuel"
    while IFS= read -r update_line; do
      [[ -z "$update_line" ]] && continue
      key=$(jq -r '.key' <<<"$update_line")
      val=$(jq -r '.value' <<<"$update_line")
      single=$(jq -n --arg k "$key" --arg v "$val" '{key:$k,value:$v,is_build_time:true,is_literal:true}')
      curl_retry "${AUTH_HEADER[@]}" "${JSON_HEADER[@]}" -X PATCH "$API_URL/applications/$APP_UUID/envs" -d "$single" \
        || curl_retry "${AUTH_HEADER[@]}" "${JSON_HEADER[@]}" -X POST "$API_URL/applications/$APP_UUID/envs" -d "$single"
    done < "$TMP_UPDATES"
    log "✅ Fallback terminé"
  fi
else
  log "ℹ️ Variables SF_ déjà alignées; aucune requête envoyée"
fi

# 3) Déploiement
log "3/3 | Déploiement version $APP_VERSION"
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
