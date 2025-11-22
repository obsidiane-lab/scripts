#!/bin/sh
# Compatibilité POSIX (/bin/sh)
# Calcule un tag MAJOR.MINOR.PATCH[-suffix] d’après :
#   - le dernier tag Git (x.y ou x.y.z, avec ou sans préfixe “v”)
#   - la branche courante (CI_COMMIT_REF_NAME)
#   - une éventuelle variable NEW_TAG définie dans GitLab CI

set -eu

# 1) Récupérer les tags à jour
git fetch --tags --quiet || {
  printf 'Échec du fetch des tags Git\n' >&2
  exit 1
}

# 2) Si on est déjà sur un tag Git (p.ex. en CI), on renvoie directement ce tag
[ -n "${CI_COMMIT_TAG:-}" ] && {
  printf '%s\n' "$CI_COMMIT_TAG"
  exit 0
}

# 3) Lister et trier les tags valides (optionnellement préfixés "v")
TAGS=$(git tag --list | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' || true)
LAST_TAG=$(printf '%s\n' "$TAGS" \
  | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n \
  | tail -1)

[ -z "$LAST_TAG" ] && LAST_TAG="0.0.0"

# 4) Extraire MAJOR, MINOR, PATCH (on retire un éventuel "v" au début)
TAG_NO_V=${LAST_TAG#v}
IFS=. read MAJOR MINOR PATCH <<EOF
$TAG_NO_V
EOF
PATCH=${PATCH:-0}

# 5) Validation numérique stricte
for v in "$MAJOR" "$MINOR" "$PATCH"; do
  case $v in
    (*[!0-9]*|'' )
      printf 'Numéro de version invalide : %s\n' "$v" >&2
      exit 1
      ;;
  esac
done

# 6) Récupération de la branche courante et de la branche par défaut
BRANCH=${CI_COMMIT_REF_NAME:-}
[ -z "$BRANCH" ] && {
  printf 'Impossible de déterminer la branche (CI_COMMIT_REF_NAME vide)\n' >&2
  exit 1
}

DEFAULT_BR=${CI_DEFAULT_BRANCH:-}
[ -z "$DEFAULT_BR" ] && {
  printf 'Variable CI_DEFAULT_BRANCH non définie\n' >&2
  exit 1
}

# 7) Initial bump : PATCH+1
NEW_MAJOR=$MAJOR
NEW_MINOR=$MINOR
NEW_PATCH=$((PATCH + 1))
SUFFIX=

case "$BRANCH" in
  dev)
    # Sur la branche dev : incrément MINOR, reset PATCH, suffixe "dev"
    NEW_MINOR=$((MINOR + 1))
    NEW_PATCH=0
    SUFFIX=dev
    ;;

  "$DEFAULT_BR")
    # Sur la branche par défaut (master/main) : incrément MINOR, reset PATCH
    NEW_MINOR=$((MINOR + 1))
    NEW_PATCH=0

    # Possibilité d'override via la variable NEW_TAG
    if [ -n "${NEW_TAG:-}" ]; then
      if printf '%s\n' "$NEW_TAG" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
        printf '%s\n' "$NEW_TAG"
        exit 0
      else
        printf 'NEW_TAG invalide, format attendu MAJOR.MINOR[.PATCH]\n' >&2
        exit 1
      fi
    fi
    ;;

  feature/*)
    # Branches feature/foo : incrément MINOR, reset PATCH, suffixe "feature-<safe>"
    NEW_MINOR=$((MINOR + 1))
    NEW_PATCH=0
    NAME=${BRANCH#feature/}
    SAFE=$(printf '%s' "$NAME" \
      | tr -c '[:alnum:]-' '-' \
      | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')
    SUFFIX="feature-$SAFE"
    ;;

  fix/*)
    # Branches fix/bar : incrément PATCH, suffixe "fix-<safe>"
    NEW_PATCH=$((PATCH + 1))
    NAME=${BRANCH#fix/}
    SAFE=$(printf '%s' "$NAME" \
      | tr -c '[:alnum:]-' '-' \
      | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')
    SUFFIX="fix-$SAFE"
    ;;

  *)
    # Autres branches : on conserve PATCH+1 sans suffixe
    ;;
esac

# 8) Assemblage du tag final et sortie
TAG="$NEW_MAJOR.$NEW_MINOR.$NEW_PATCH"
[ -n "$SUFFIX" ] && TAG="$TAG-$SUFFIX"
printf '%s\n' "$TAG"
