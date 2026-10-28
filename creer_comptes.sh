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

# dossier du dépôt, pour retrouver config/keys/ quelle que soit la façon de lancer le script
REPERTOIRE_DEPOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

installer_cle() {
    local login="$1"
    local cle="$REPERTOIRE_DEPOT/config/keys/$login.pub"
    local groupe home_dir

    # pas de clé pour ce compte : rien à faire
    if [[ ! -f "$cle" ]]; then
        return 0
    fi

    groupe="$(id -gn "$login")"
    home_dir="$(getent passwd "$login" | cut -d: -f6)"

    install -d -m 700 -o "$login" -g "$groupe" "$home_dir/.ssh"
    touch "$home_dir/.ssh/authorized_keys"

    # on n'ajoute la clé que si cette ligne exacte n'y est pas déjà
    if ! grep -qxF "$(cat "$cle")" "$home_dir/.ssh/authorized_keys"; then
        cat "$cle" >> "$home_dir/.ssh/authorized_keys"
        echo "Clé installée : $login"
    fi

    chown "$login:$groupe" "$home_dir/.ssh/authorized_keys"
    chmod 600 "$home_dir/.ssh/authorized_keys"
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
    installer_cle "$login"
done < <(tail -n +2 "$CSV" | tr -d '\r')
