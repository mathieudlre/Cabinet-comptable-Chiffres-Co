#!/usr/bin/env bash
# creer_comptes.sh : crée groupes et comptes depuis comptes.csv (idempotent)
set -euo pipefail

CSV="${1:-comptes.csv}"

if [[ $EUID -ne 0 ]]; then
    echo "Ce script doit être lancé en root" >&2
    exit 1
fi
if [[ ! -f "$CSV" ]]; then
    echo "Fichier introuvable : $CSV" >&2
    exit 2
fi

creer_groupe() {
    local groupe="$1"
    if ! getent group "$groupe" > /dev/null; then
        groupadd "$groupe"
        echo "Groupe créé : $groupe"
    fi
}

# tail saute l'en-tête, tr enlève les \r si le CSV vient de Windows
while IFS=';' read -r login nom groupe_principal groupes_secondaires; do
    creer_groupe "$groupe_principal"

    # groupes secondaires : liste séparée par des virgules, parfois vide
    IFS=',' read -ra secondaires <<< "$groupes_secondaires"
    for g in "${secondaires[@]}"; do
        if [[ -n "$g" ]]; then
            creer_groupe "$g"
        fi
    done

    if ! getent passwd "$login" > /dev/null; then
        useradd -m -s /bin/bash -g "$groupe_principal" -c "$nom" "$login"
        echo "Compte créé : $login"
    fi

    if [[ -n "$groupes_secondaires" ]]; then
        usermod -aG "$groupes_secondaires" "$login"
    fi
done < <(tail -n +2 "$CSV" | tr -d '\r')
