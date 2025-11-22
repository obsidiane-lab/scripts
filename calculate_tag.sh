#!/bin/sh
# Compatibilité POSIX (/bin/sh)
# Calcule un tag MAJOR.MINOR.PATCH[-suffix] d’après :
#   - le dernier tag Git (x.y ou x.y.z, SANS préfixe "v")
#   - la branche courante (CI_COMMIT_REF_NAME ou fallback local)
#   - une éventuelle variable NEW_TAG=major|minor|fix sur la branche par défaut
#
# Variables d’entrée :
#   CI_COMMIT_REF_NAME : branche courante (CI), fallback sur git rev-parse --abbrev-ref HEAD
#   CI_DEFAULT_BRANCH  : branche par défaut (CI), fallback sur origin/HEAD ou "main"
#   CI_COMMIT_TAG      : si défini, renvoyé tel quel
#   NEW_TAG            : major|majeur | minor|mineur (défaut) | fix|patch (seulement sur la branche par défaut)
#   SKIP_FETCH_TAGS    : 1 pour ne pas faire de git fetch --tags
#   DEBUG              : 1 pour logs sur stderr

set -eu

DEBUG=${DEBUG:-0}
log() {
  [ "$DEBUG" = "1" ] && printf '[DEBUG] %s\n' "$*" >&2
}

safe_slug() {
  printf '%s\n' "$1" \
    | tr -c '[:alnum:]-' '-' \
    | sed 's/-\{2,\}/-/g; s/^-//; s/-$//'
}

# 1) Récupérer les tags à jour (désactivable avec SKIP_FETCH_TAGS=1)
if [ "${SKIP_FETCH_TAGS:-0}" != "1" ]; then
  GIT_TERMINAL_PROMPT=0 git fetch --tags --quiet || {
    printf 'Échec du fetch des tags Git\n' >&2
    exit 1
  }
fi

# 2) Si on est déjà sur un tag Git (p.ex. en CI), on renvoie directement ce tag
if [ -n "${CI_COMMIT_TAG:-}" ]; then
  printf '%s\n' "$CI_COMMIT_TAG"
  exit 0
fi

###############################################################################
# 3) Déterminer le dernier tag "version" (x.y ou x.y.z, SANS préfixe v)
#    -> on s'appuie sur le tri version de Git : --sort=-v:refname
###############################################################################
TAGS_SORTED=$(git tag --list --sort=-v:refname)
LAST_TAG=$(
  printf '%s\n' "$TAGS_SORTED" \
  | grep -m1 -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
  || true
)

[ -z "${LAST_TAG:-}" ] && LAST_TAG="0.0.0"

# 4) Extraire MAJOR, MINOR, PATCH
IFS=. read MAJOR MINOR PATCH <<EOF
$LAST_TAG
EOF
PATCH=${PATCH:-0}

# 5) Validation numérique stricte
for v in "$MAJOR" "$MINOR" "$PATCH"; do
  case $v in
    (*[!0-9]*|'')
      printf 'Numéro de version invalide : %s\n' "$v" >&2
      exit 1
      ;;
  esac
done

log "LAST_TAG=$LAST_TAG (MAJOR=$MAJOR MINOR=$MINOR PATCH=$PATCH)"

# 6) Récupération de la branche courante et de la branche par défaut
BRANCH=${CI_COMMIT_REF_NAME:-}
if [ -z "$BRANCH" ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi

if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  printf 'Impossible de déterminer la branche (CI_COMMIT_REF_NAME et HEAD vides)\n' >&2
  exit 1
fi

DEFAULT_BR=${CI_DEFAULT_BRANCH:-}
if [ -z "$DEFAULT_BR" ]; then
  DEFAULT_BR=$(
    git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
      | sed 's#^origin/##'
  )
fi
if [ -z "$DEFAULT_BR" ]; then
  DEFAULT_BR=$(
    git remote show origin 2>/dev/null \
      | sed -n 's/.*HEAD branch: //p' \
      | head -1
  )
fi
[ -z "$DEFAULT_BR" ] && DEFAULT_BR=main

log "BRANCH=$BRANCH DEFAULT_BR=$DEFAULT_BR"

# 7) Calcul du bump (base = version actuelle)
NEW_MAJOR=$MAJOR
NEW_MINOR=$MINOR
NEW_PATCH=$PATCH
SUFFIX=

case "$BRANCH" in
  dev)
    # Sur la branche dev : incrément MINOR, reset PATCH, suffixe "dev"
    NEW_MINOR=$((MINOR + 1))
    NEW_PATCH=0
    SUFFIX=dev
    ;;

  "$DEFAULT_BR")
    # Sur la branche par défaut : NEW_TAG=major|minor|fix (minor par défaut)
    NEW_TAG_MODE=$(printf '%s\n' "${NEW_TAG:-}" | tr '[:upper:]' '[:lower:]')
    case "$NEW_TAG_MODE" in
      ''|minor|mineur)
        NEW_MINOR=$((MINOR + 1))
        NEW_PATCH=0
        ;;
      major|majeur)
        NEW_MAJOR=$((MAJOR + 1))
        NEW_MINOR=0
        NEW_PATCH=0
        ;;
      fix|patch)
        NEW_PATCH=$((PATCH + 1))
        ;;
      *)
        printf 'NEW_TAG invalide (%s), valeurs possibles : major/majeur, minor/mineur, fix/patch\n' "$NEW_TAG" >&2
        exit 1
        ;;
    esac
    ;;

  feature/*)
    # Branches feature/foo : incrément MINOR, reset PATCH, suffixe "feature-<safe>"
    NEW_MINOR=$((MINOR + 1))
    NEW_PATCH=0
    NAME=${BRANCH#feature/}
    SUFFIX="feature-$(safe_slug "$NAME")"
    ;;

  fix/*)
    # Branches fix/bar : incrément PATCH, suffixe "fix-<safe>"
    NEW_PATCH=$((PATCH + 1))
    NAME=${BRANCH#fix/}
    SUFFIX="fix-$(safe_slug "$NAME")"
    ;;

  *)
    # Autres branches : patch +1
    NEW_PATCH=$((PATCH + 1))
    ;;
esac

# 8) Assemblage du tag final (sans préfixe v) et sortie
TAG="$NEW_MAJOR.$NEW_MINOR.$NEW_PATCH"
[ -n "$SUFFIX" ] && TAG="$TAG-$SUFFIX"

log "TAG_CALCULE=$TAG"
printf '%s\n' "$TAG"
