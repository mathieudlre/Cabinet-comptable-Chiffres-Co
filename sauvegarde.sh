#!/usr/bin/env bash
# sauvegarde.sh - sauvegarde incrémentale versionnée de /srv et /etc (B1)
# Code de sortie : 0 succès, 1 échec, 2 erreur d'utilisation
set -euo pipefail

DESTINATION="/backup"
SOURCES=(/srv /etc)
GARDER=7

journal() {
    logger -t sauvegarde "$1"
    echo "$1"
}

if [[ $EUID -ne 0 ]]; then
    echo "Erreur : ce script doit être lancé en root" >&2
    exit 2
fi
if ! mountpoint -q "$DESTINATION"; then
    echo "Erreur : $DESTINATION n'est pas monté" >&2
    exit 1
fi

# Empêche deux sauvegardes simultanées
exec 9>/run/sauvegarde.lock
if ! flock -n 9; then
    echo "Erreur : une sauvegarde est déjà en cours" >&2
    exit 1
fi

NOUVELLE="$DESTINATION/$(date +%Y-%m-%d_%H%M%S)"
PRECEDENTE="$(ls -1d "$DESTINATION"/20* 2>/dev/null | tail -n 1 || true)"

# -A : ACL, -X : attributs étendus, --link-dest : fichiers inchangés partagés avec la version précédente
OPTIONS=(-aAXH --delete --relative)
if [[ -n "$PRECEDENTE" ]]; then
    OPTIONS+=(--link-dest="$PRECEDENTE")
fi

journal "début de la sauvegarde vers $NOUVELLE"
if rsync "${OPTIONS[@]}" "${SOURCES[@]}" "$NOUVELLE/"; then
    journal "sauvegarde réussie : $NOUVELLE"
else
    rm -rf "$NOUVELLE"
    journal "ÉCHEC de la sauvegarde"
    exit 1
fi

# Rotation : on garde les $GARDER versions les plus récentes
mapfile -t VERSIONS < <(ls -1d "$DESTINATION"/20*)
NB=${#VERSIONS[@]}
if (( NB > GARDER )); then
    for v in "${VERSIONS[@]:0:NB-GARDER}"; do
        rm -rf "$v"
        journal "ancienne version supprimée : $v"
    done
fi
exit 0
