#!/usr/bin/env bash
#
# installer.sh - reconstruit toute la configuration du serveur
# Projet XTI302-CYB, contexte B : cabinet comptable Chiffres & Co.
#
# Usage : ./installer.sh     (en root, depuis le dépôt cloné sur la VM)
#
# Tant que le projet n'est pas terminé, une étape dont le fichier de config
# n'existe pas encore dans le dépôt est signalée « absent » puis sautée.
# Version finale attendue : aucun « absent » dans le résumé.
#
# Code de sortie : 0 si l'installation s'est déroulée jusqu'au bout,
#                  1 si une étape a échoué (le script s'arrête aussitôt),
#                  2 en cas d'erreur d'utilisation.

# Ici, contrairement à verifier.sh, on veut s'arrêter à la première erreur :
# continuer après un échec pourrait laisser le serveur à moitié configuré.
set -euo pipefail

# Un motif qui ne correspond à aucun fichier donne une liste vide
# (et non le motif lui-même, comme « config/fail2ban/jail.d/*.conf »).
shopt -s nullglob

# Si une commande échoue sans être gérée, dire où avant de s'arrêter
trap 'echo "Erreur inattendue à la ligne $LINENO (code $?)." >&2' ERR

# --- Paramètres -----------------------------------------------------------

REPERTOIRE_DEPOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$REPERTOIRE_DEPOT/config"

# Où sont installés les scripts lancés par root ou via sudo
REPERTOIRE_SCRIPTS="/usr/local/sbin"

# Point de montage du disque de sauvegarde (convenu avec le membre 1)
POINT_MONTAGE="/backup"

PAQUETS=(
    sudo                  # C3 : délégation des droits
    acl                   # C2 : setfacl, getfacl
    openssh-server        # S1 à S5
    nftables              # J2 : pare-feu
    fail2ban              # J1 : bannissement après échecs
    python3-systemd       # J1 : permet à fail2ban de lire le journal systemd
    rsync                 # B1 : sauvegarde incrémentale
    unattended-upgrades   # D1 : mises à jour de sécurité automatiques
)

# Éléments sautés faute de fichier dans le dépôt (affichés à la fin)
ABSENTS=()

# --- Messages -------------------------------------------------------------

etape() {
    printf '\n==> %s\n' "$1"
}

info() {
    printf '    %s\n' "$1"
}

# absent CHEMIN : un fichier attendu n'existe pas encore dans le dépôt
absent() {
    printf '    [absent] %s, étape sautée\n' "$1"
    ABSENTS+=("$1")
}

# erreur MESSAGE : arrêt immédiat, avec un message clair
erreur() {
    echo "Erreur : $1" >&2
    exit 1
}

# --- Outils ---------------------------------------------------------------

# copier SOURCE DESTINATION MODE : installe un fichier du dépôt sur le
# système, propriétaire root, avec le mode donné. -D crée les dossiers
# parents si besoin.
copier() {
    install -D -o root -g root -m "$3" "$1" "$2"
}

# membres_du_groupe GROUPE : affiche les membres secondaires, un par ligne.
# Ne renvoie rien (sans erreur) si le groupe n'existe pas.
membres_du_groupe() {
    local ligne
    ligne="$(getent group "$1")" || return 0
    tr ',' '\n' <<< "${ligne##*:}" | sed '/^$/d'
}

# --- Étapes ---------------------------------------------------------------

installer_paquets() {
    etape "Paquets"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # Un paquet déjà installé est simplement ignoré : étape idempotente
    apt-get install -y -qq "${PAQUETS[@]}" >/dev/null
    info "installés : ${PAQUETS[*]}"
}

creer_les_comptes() {
    etape "Comptes, groupes et répertoires (C1, C2)"
    local script="$REPERTOIRE_DEPOT/creer_comptes.sh"
    local csv="$REPERTOIRE_DEPOT/comptes.csv"
    if [[ ! -f "$script" ]]; then absent "creer_comptes.sh"; return 0; fi
    if [[ ! -f "$csv" ]]; then absent "comptes.csv"; return 0; fi
    bash "$script" "$csv"
}

configurer_sudo() {
    etape "sudo (C3)"
    local fichiers=("$CONFIG"/sudoers.d/*)
    if [[ ${#fichiers[@]} -eq 0 ]]; then absent "config/sudoers.d/*"; return 0; fi

    local f nom
    for f in "${fichiers[@]}"; do
        nom="$(basename "$f")"
        # sudo ignore en silence les fichiers de sudoers.d dont le nom
        # contient un point ou finit par ~ (voir man sudoers)
        if [[ "$nom" == *.* || "$nom" == *~ ]]; then
            erreur "config/sudoers.d/$nom serait ignoré par sudo (point ou ~ dans le nom)"
        fi
        # Valider AVANT de copier : un sudoers invalide peut casser sudo
        visudo -cqf "$f" || erreur "syntaxe invalide dans config/sudoers.d/$nom"
        copier "$f" "/etc/sudoers.d/$nom" 440
        info "installé : /etc/sudoers.d/$nom"
    done

    # À COMPLÉTER (C3) : une Debian fraîche donne peut-être déjà sudo à un
    # compte. Le repérer et le retirer (voir « Pièges fréquents » du sujet).
}

# admin_disponible : vrai si au moins un administrateur existe et que
# le groupe admins a une règle sudo. Sans cela, verrouiller root
# rendrait la machine inadministrable.
admin_disponible() {
    [[ -n "$(membres_du_groupe admins)" ]] || return 1
    grep -rqs '^%admins' /etc/sudoers.d/
}

durcir_comptes() {
    etape "Compte root et répertoires personnels (C4)"

    if admin_disponible; then
        passwd -l root >/dev/null
        info "compte root verrouillé"
    else
        info "root NON verrouillé : aucun membre d'admins avec une règle sudo"
        ABSENTS+=("verrouillage de root (dépend de C1 et C3)")
    fi

    # Répertoires personnels existants : pas de lecture pour les autres
    local repertoire
    for repertoire in /home/*/; do
        chmod 700 "$repertoire"
    done

    # Comptes créés plus tard : même droit, réglé dans /etc/login.defs
    if grep -q '^HOME_MODE' /etc/login.defs; then
        sed -i 's/^HOME_MODE.*/HOME_MODE\t0700/' /etc/login.defs
    else
        printf 'HOME_MODE\t0700\n' >> /etc/login.defs
    fi
    info "répertoires personnels en 700, HOME_MODE 0700"
}

# acces_ssh_possible : vrai si au moins un membre d'acces_ssh a une clé
# installée. Sinon, AllowGroups + clé seule bloqueraient tout le monde.
acces_ssh_possible() {
    local utilisateur personnel
    while read -r utilisateur; do
        personnel="$(getent passwd "$utilisateur" | cut -d: -f6)" || continue
        [[ -s "$personnel/.ssh/authorized_keys" ]] && return 0
    done < <(membres_du_groupe acces_ssh)
    return 1
}

configurer_ssh() {
    etape "Serveur SSH (S1 à S5)"
    local fichiers=("$CONFIG"/ssh/sshd_config.d/*.conf)
    if [[ ${#fichiers[@]} -eq 0 ]]; then absent "config/ssh/sshd_config.d/*.conf"; return 0; fi

    acces_ssh_possible \
        || erreur "aucun membre d'acces_ssh n'a de clé installée : la config SSH vous enfermerait dehors"

    # Sauvegarde de la config actuelle, pour revenir en arrière si besoin
    local ancienne
    ancienne="$(mktemp -d)"
    cp -a /etc/ssh/sshd_config.d/. "$ancienne"/

    local f
    for f in "${fichiers[@]}"; do
        copier "$f" "/etc/ssh/sshd_config.d/$(basename "$f")" 644
    done

    # S5 : valider avant de redémarrer. En cas d'erreur, on restaure
    # l'ancienne config et le service tourne toujours avec elle.
    if ! sshd -t; then
        rm -f /etc/ssh/sshd_config.d/*
        cp -a "$ancienne"/. /etc/ssh/sshd_config.d/
        rm -rf "$ancienne"
        erreur "configuration SSH invalide (sshd -t), ancienne configuration restaurée"
    fi
    rm -rf "$ancienne"

    # Les sessions déjà ouvertes ne sont pas coupées par le redémarrage
    systemctl restart ssh
    info "configuration validée par sshd -t, service redémarré"
}

configurer_journald() {
    etape "Journal persistant (J3)"
    local source="$CONFIG/journald.conf"
    if [[ ! -f "$source" ]]; then absent "config/journald.conf"; return 0; fi
    copier "$source" /etc/systemd/journald.conf.d/50-persistant.conf 644
    systemctl restart systemd-journald
    info "installé : /etc/systemd/journald.conf.d/50-persistant.conf"
}

configurer_pare_feu() {
    etape "Pare-feu nftables (J2)"
    local source="$CONFIG/nftables.conf"
    if [[ ! -f "$source" ]]; then absent "config/nftables.conf"; return 0; fi
    # -c : vérifie les règles sans les appliquer
    nft -c -f "$source" || erreur "règles invalides dans config/nftables.conf"
    copier "$source" /etc/nftables.conf 644
    # enable : règles rechargées à chaque démarrage (J2 : la règle survit
    # au redémarrage).
    systemctl enable nftables >/dev/null 2>&1
    # Jamais « restart » : l'arrêt du service lance « nft flush ruleset »,
    # qui effacerait aussi la table de fail2ban et ses bannissements (J1).
    # « reload » relit seulement le fichier, qui ne remplace que notre table.
    if systemctl is-active --quiet nftables; then
        systemctl reload nftables
    else
        systemctl start nftables
    fi
    info "règles validées par nft -c, service activé"
}

configurer_fail2ban() {
    etape "fail2ban (J1)"
    local fichiers=("$CONFIG"/fail2ban/jail.d/*.conf)
    if [[ ${#fichiers[@]} -eq 0 ]]; then absent "config/fail2ban/jail.d/*.conf"; return 0; fi
    local f
    for f in "${fichiers[@]}"; do
        copier "$f" "/etc/fail2ban/jail.d/$(basename "$f")" 644
    done
    fail2ban-client -t >/dev/null || erreur "configuration fail2ban invalide (fail2ban-client -t)"
    # Lancé après nftables, pour que ses règles s'ajoutent aux nôtres
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    info "configuration validée, service redémarré"
}

configurer_mises_a_jour() {
    etape "Mises à jour automatiques (D1)"
    local source="$CONFIG/apt/20auto-upgrades"
    if [[ ! -f "$source" ]]; then absent "config/apt/20auto-upgrades"; return 0; fi
    copier "$source" /etc/apt/apt.conf.d/20auto-upgrades 644
    info "installé : /etc/apt/apt.conf.d/20auto-upgrades"
}

preparer_disque_sauvegarde() {
    etape "Disque de sauvegarde (B1, B3)"
    # À FOURNIR PAR LE MEMBRE 1 : identifier le second disque, le formater
    # UNIQUEMENT s'il n'a pas de système de fichiers, le monter par UUID
    # sur $POINT_MONTAGE via /etc/fstab, droits réservés aux admins (B3).
    # Règle absolue : une relance ne doit jamais effacer les sauvegardes.
    absent "préparation du disque monté sur $POINT_MONTAGE"
}

installer_scripts() {
    etape "Scripts d'exploitation (J4, B1)"
    # Appartenant à root et modifiables par lui seul : sinon, celui qui
    # peut modifier analyse_logs.sh obtient root via la règle sudo de support.
    local script
    for script in analyse_logs.sh sauvegarde.sh; do
        if [[ -f "$REPERTOIRE_DEPOT/$script" ]]; then
            copier "$REPERTOIRE_DEPOT/$script" "$REPERTOIRE_SCRIPTS/$script" 755
            info "installé : $REPERTOIRE_SCRIPTS/$script (root:root, 755)"
        else
            absent "$script"
        fi
    done
}

planifier_sauvegarde() {
    etape "Planification de la sauvegarde (B2)"
    local service="$CONFIG/systemd/sauvegarde.service"
    local minuterie="$CONFIG/systemd/sauvegarde.timer"
    if [[ ! -f "$service" || ! -f "$minuterie" ]]; then
        absent "config/systemd/sauvegarde.service et .timer"
        return 0
    fi
    copier "$service" /etc/systemd/system/sauvegarde.service 644
    copier "$minuterie" /etc/systemd/system/sauvegarde.timer 644
    systemctl daemon-reload
    systemctl enable --now sauvegarde.timer >/dev/null 2>&1
    info "timer sauvegarde.timer activé"
}

# --- Programme principal --------------------------------------------------

usage() {
    echo "Usage : $0"
    echo "À lancer en root, depuis le dépôt cloné sur la VM."
}

verifier_prerequis() {
    if [[ $EUID -ne 0 ]]; then
        echo "Erreur : ce script doit être lancé en root." >&2
        exit 2
    fi
    if [[ ! -d "$CONFIG" ]]; then
        echo "Erreur : dossier config/ introuvable dans $REPERTOIRE_DEPOT." >&2
        exit 2
    fi
}

main() {
    if [[ $# -gt 0 ]]; then
        if [[ "$1" == "-h" || "$1" == "--help" ]]; then
            usage
            exit 0
        fi
        usage >&2
        exit 2
    fi

    verifier_prerequis

    # L'ordre compte : les comptes (groupe acces_ssh, clés, admins)
    # doivent exister avant sudo, le verrouillage de root et SSH.
    installer_paquets
    creer_les_comptes
    configurer_sudo
    durcir_comptes
    configurer_ssh
    configurer_journald
    configurer_pare_feu
    configurer_fail2ban
    configurer_mises_a_jour
    preparer_disque_sauvegarde
    installer_scripts
    planifier_sauvegarde

    etape "Résumé"
    if [[ ${#ABSENTS[@]} -eq 0 ]]; then
        info "installation complète."
    else
        info "installation partielle, ${#ABSENTS[@]} élément(s) absent(s) :"
        local element
        for element in "${ABSENTS[@]}"; do
            info "  - $element"
        done
    fi
    info "Vérifiez maintenant avec : $REPERTOIRE_DEPOT/verifier.sh"
}

main "$@"