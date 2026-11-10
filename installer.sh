set -euo pipefail

shopt -s nullglob

trap 'echo "Erreur inattendue à la ligne $LINENO (code $?)." >&2' ERR

REPERTOIRE_DEPOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$REPERTOIRE_DEPOT/config"

REPERTOIRE_SCRIPTS="/usr/local/sbin"

POINT_MONTAGE="/backup"

PAQUETS=(
    sudo
    acl
    openssh-server
    nftables
    fail2ban
    python3-systemd
    rsync
    unattended-upgrades
)

ABSENTS=()


etape() {
    printf '\n==> %s\n' "$1"
}

info() {
    printf '    %s\n' "$1"
}

absent() {
    printf '    [absent] %s, étape sautée\n' "$1"
    ABSENTS+=("$1")
}

erreur() {
    echo "Erreur : $1" >&2
    exit 1
}

copier() {
    install -D -o root -g root -m "$3" "$1" "$2"
}

membres_du_groupe() {
    local ligne
    ligne="$(getent group "$1")" || return 0
    tr ',' '\n' <<< "${ligne##*:}" | sed '/^$/d'
}


installer_paquets() {
    etape "Paquets"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
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
        if [[ "$nom" == *.* || "$nom" == *~ ]]; then
            erreur "config/sudoers.d/$nom serait ignoré par sudo (point ou ~ dans le nom)"
        fi
        visudo -cqf "$f" || erreur "syntaxe invalide dans config/sudoers.d/$nom"
        copier "$f" "/etc/sudoers.d/$nom" 440
        info "installé : /etc/sudoers.d/$nom"
    done

    local membre
    for membre in $(membres_du_groupe sudo); do
        gpasswd -d "$membre" sudo >/dev/null
        info "retiré du groupe sudo : $membre"
    done
}

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

    local repertoire
    for repertoire in /home/*/; do
        chmod 700 "$repertoire"
    done

    if grep -q '^HOME_MODE' /etc/login.defs; then
        sed -i 's/^HOME_MODE.*/HOME_MODE\t0700/' /etc/login.defs
    else
        printf 'HOME_MODE\t0700\n' >> /etc/login.defs
    fi
    info "répertoires personnels en 700, HOME_MODE 0700"
}

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

    local ancienne
    ancienne="$(mktemp -d)"
    cp -a /etc/ssh/sshd_config.d/. "$ancienne"/

    local f
    for f in "${fichiers[@]}"; do
        copier "$f" "/etc/ssh/sshd_config.d/$(basename "$f")" 644
    done

    if ! sshd -t; then
        rm -f /etc/ssh/sshd_config.d/*
        cp -a "$ancienne"/. /etc/ssh/sshd_config.d/
        rm -rf "$ancienne"
        erreur "configuration SSH invalide (sshd -t), ancienne configuration restaurée"
    fi
    rm -rf "$ancienne"

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
    nft -c -f "$source" || erreur "règles invalides dans config/nftables.conf"
    copier "$source" /etc/nftables.conf 644
    systemctl enable nftables >/dev/null 2>&1
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
    local disque="/dev/sdb" uuid
    [[ -b "$disque" ]] || erreur "disque de sauvegarde $disque introuvable"
    if blkid "$disque" >/dev/null 2>&1; then
        info "$disque a déjà un système de fichiers, pas de formatage"
    else
        mkfs.ext4 -q -L sauvegarde "$disque"
        info "$disque formaté en ext4"
    fi
    uuid="$(blkid -s UUID -o value "$disque")"
    mkdir -p "$POINT_MONTAGE"
    if ! grep -q "UUID=$uuid" /etc/fstab; then
        echo "UUID=$uuid $POINT_MONTAGE ext4 defaults,nofail 0 2" >> /etc/fstab
        info "ajouté à /etc/fstab"
    fi
    systemctl daemon-reload
    mountpoint -q "$POINT_MONTAGE" || mount "$POINT_MONTAGE"
    chown root:admins "$POINT_MONTAGE"
    chmod 750 "$POINT_MONTAGE"
    info "monté sur $POINT_MONTAGE (root:admins, 750)"
}

installer_scripts() {
    etape "Scripts d'exploitation (J4, B1)"
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
