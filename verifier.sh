#!/usr/bin/env bash
#
# verifier.sh - vérifie la conformité du serveur au cahier des charges
# Projet XTI302-CYB, contexte B : cabinet comptable Chiffres & Co.
#
# Usage : ./verifier.sh                 lance tous les tests
#         ./verifier.sh test_S2 test_C3  lance seulement les tests nommés
#
# Code de sortie : 0 si tout est conforme,
#                  1 si au moins un test échoue,
#                  2 en cas d'erreur d'utilisation.

set -u

# --- Emplacements ---------------------------------------------------------

# Dossier du dépôt, quel que soit le répertoire d'où le script est lancé
REPERTOIRE_DEPOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FICHIER_COMPTES="$REPERTOIRE_DEPOT/comptes.csv"

# --- Compteurs et état ----------------------------------------------------

NB_TESTS=0
NB_OK=0

# Fichiers de test à supprimer en fin de script
A_NETTOYER=()

# Couleurs seulement si la sortie est un terminal (pas dans un fichier)
if [[ -t 1 ]]; then
    VERT=$'\e[32m'
    ROUGE=$'\e[31m'
    NORMAL=$'\e[0m'
else
    VERT=""
    ROUGE=""
    NORMAL=""
fi

# --- Affichage des résultats ----------------------------------------------

# ok ID MESSAGE : enregistre et affiche un test réussi
ok() {
    NB_TESTS=$((NB_TESTS + 1))
    NB_OK=$((NB_OK + 1))
    printf '%s[OK]%s %s %s\n' "$VERT" "$NORMAL" "$1" "$2"
}

# ko ID MESSAGE : enregistre et affiche un test échoué.
# Le message doit dire ce qui est attendu, pour guider la correction.
ko() {
    NB_TESTS=$((NB_TESTS + 1))
    printf '%s[KO]%s %s %s\n' "$ROUGE" "$NORMAL" "$1" "$2"
}

# a_faire ID DESCRIPTION : test pas encore écrit, compté comme un échec
# pour qu'un oubli ne passe jamais pour une conformité.
a_faire() {
    ko "$1" "non implémenté : $2"
}

# --- Outils pour les tests ------------------------------------------------

# en_tant_que UTILISATEUR COMMANDE... : lance une commande avec les droits
# d'un autre utilisateur, sans afficher sa sortie, et renvoie son code.
# Exemple : en_tant_que stagiaire1 test -r /srv/rh
en_tant_que() {
    local utilisateur="$1"
    shift
    sudo -n -u "$utilisateur" -- "$@" >/dev/null 2>&1
}

# sshd_valeur MOT_CLE : valeur effective d'une option du serveur SSH.
# sshd -T affiche la configuration finale, mots-clés en minuscules.
# awk lit toute la sortie (pas de sortie anticipée, donc pas de SIGPIPE).
sshd_valeur() {
    sshd -T 2>/dev/null | awk -v cle="$1" '$1 == cle { print $2 }'
}

# en_secondes DUREE : convertit une durée au format sshd (600, 90s, 10m,
# 1h) en secondes. N'affiche rien si le format n'est pas reconnu.
en_secondes() {
    if [[ "$1" =~ ^([0-9]+)([smh]?)$ ]]; then
        local nombre="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2]}" in
            h) echo $((nombre * 3600)) ;;
            m) echo $((nombre * 60)) ;;
            *) echo "$nombre" ;;
        esac
    fi
}

# a_nettoyer CHEMIN : note un fichier de test à supprimer à la fin
a_nettoyer() {
    A_NETTOYER+=("$1")
}

# nettoyer : supprime les fichiers de test. Appelée automatiquement à la
# sortie du script, même en cas d'erreur ou de Ctrl+C, grâce à trap.
nettoyer() {
    local chemin
    for chemin in "${A_NETTOYER[@]}"; do
        rm -rf -- "$chemin"
    done
}
trap nettoyer EXIT

# --- Tests : comptes et droits (Charles) ---------------------------------
# Une fonction par exigence. Une fonction peut appeler ok/ko plusieurs
# fois : c'est ainsi qu'on atteint les 25 tests demandés.


# "C1" "comptes et groupes conformes à $FICHIER_COMPTES"
test_C1() {
    local erreurs="" login nom principal secondaires g
    while IFS=';' read -r login nom principal secondaires; do
        if ! getent passwd "$login" > /dev/null; then
            erreurs="$erreurs $login(absent)"
            continue
        fi
        if [[ "$(id -gn "$login")" != "$principal" ]]; then
            erreurs="$erreurs $login(mauvais groupe principal)"
        fi
        for g in ${secondaires//,/ }; do
            if ! id -nG "$login" | grep -qw "$g"; then
                erreurs="$erreurs $login(pas dans $g)"
            fi
        done
    done < <(tail -n +2 "$FICHIER_COMPTES")

    if [[ -z "$erreurs" ]]; then
        ok "C1" "tous les comptes et groupes de comptes.csv existent"
    else
        ko "C1" "écarts avec comptes.csv :$erreurs"
    fi
}


#"C2" "droits et ACL des répertoires de /srv"
test_C2() {
    local erreurs=""
    local f="/srv/dossiers_clients/.verif_c2_$$"
    A_NETTOYER+=("$f")

    # Ce qui doit marcher
    sudo -u mdupuis test -w /srv/dossiers_clients || erreurs="$erreurs [comptable devrait écrire dans dossiers_clients]"
    sudo -u fgarcia test -r /srv/dossiers_clients || erreurs="$erreurs [direction devrait lire dossiers_clients]"
    sudo -u cmoreau test -w /srv/rh || erreurs="$erreurs [rh devrait écrire dans rh]"
    sudo -u fgarcia test -r /srv/rh || erreurs="$erreurs [direction devrait lire rh]"
    sudo -u tbernard test -r /srv/commun || erreurs="$erreurs [stagiaire devrait lire commun]"
    sudo -u tbernard test -w /srv/commun/depot || erreurs="$erreurs [stagiaire devrait déposer dans depot]"

    # Ce qui doit être refusé
    sudo -u cmoreau test -r /srv/dossiers_clients && erreurs="$erreurs [rh ne devrait pas lire dossiers_clients]"
    sudo -u tbernard test -r /srv/dossiers_clients && erreurs="$erreurs [stagiaire ne devrait pas lire dossiers_clients]"
    sudo -u fgarcia test -w /srv/dossiers_clients && erreurs="$erreurs [direction ne devrait pas écrire dans dossiers_clients]"
    sudo -u mdupuis test -r /srv/rh && erreurs="$erreurs [comptable ne devrait pas lire rh]"
    sudo -u tbernard test -w /srv/commun && erreurs="$erreurs [stagiaire ne devrait pas écrire dans commun]"
    sudo -u tbernard test -r /srv/commun/depot && erreurs="$erreurs [stagiaire ne devrait pas lister depot]"

    # Fichier créé après coup : l'ACL par défaut doit s'appliquer
    sudo -u mdupuis touch "$f" 2>/dev/null
    sudo -u fgarcia test -r "$f" || erreurs="$erreurs [direction devrait lire un fichier créé après coup]"
    sudo -u cmoreau test -r "$f" && erreurs="$erreurs [rh ne devrait pas lire un fichier créé après coup]"

    # Dépôt des stagiaires : déposer oui, lister / lire / supprimer non
    local d="/srv/commun/depot/.verif_depot_$$"
    A_NETTOYER+=("$d")
    echo "test" | sudo -u tbernard tee "$d" > /dev/null 2>&1
    [[ -f "$d" ]] || erreurs="$erreurs [stagiaire devrait pouvoir déposer dans depot]"
    sudo -u tbernard ls /srv/commun/depot > /dev/null 2>&1 && erreurs="$erreurs [stagiaire ne devrait pas lister depot]"
    sudo -u emeunier cat "$d" > /dev/null 2>&1 && erreurs="$erreurs [un stagiaire ne devrait pas lire le fichier d'un autre]"
    sudo -u fgarcia cat "$d" > /dev/null 2>&1 || erreurs="$erreurs [direction devrait lire un fichier déposé]"
    sudo -u emeunier rm -f "$d" 2>/dev/null
    [[ -e "$d" ]] || erreurs="$erreurs [un stagiaire a pu supprimer le fichier d'un autre (sticky bit)]"

    if [[ -z "$erreurs" ]]; then
        ok "C2" "droits de /srv conformes, y compris sur un fichier créé après coup"
    else
        ko "C2" "droits non conformes :$erreurs"
    fi
}

test_C3() {
    local sortie
    sortie="$(LC_ALL=C sudo -l -U hussein 2>/dev/null)"
    if grep -q '(ALL : ALL) ALL' <<< "$sortie"; then
        ok "C3" "un membre d'admins a tous les droits sudo"
    else
        ko "C3" "hussein (admins) n'a pas (ALL : ALL) ALL"
    fi
    sortie="$(LC_ALL=C sudo -l -U support 2>/dev/null)"
    if grep -q '(root) /usr/local/sbin/analyse_logs.sh' <<< "$sortie" && ! grep -q 'ALL) ALL' <<< "$sortie"; then
        ok "C3" "support ne peut lancer que analyse_logs.sh"
    else
        ko "C3" "support n'est pas limité à analyse_logs.sh"
    fi
    if [[ -z "$(getent group sudo | cut -d: -f4)" ]]; then
        ok "C3" "le groupe sudo est vide"
    else
        ko "C3" "membres dans le groupe sudo : $(getent group sudo | cut -d: -f4)"
    fi
}

test_C4() {
    local etat d erreurs=""
    etat="$(passwd -S root 2>/dev/null | awk '{print $2}')"
    if [[ "$etat" == "L" ]]; then
        ok "C4" "compte root verrouillé"
    else
        ko "C4" "root n'est pas verrouillé (état '$etat')"
    fi
    for d in /home/*/; do
        [[ "$(stat -c %a "$d")" == "700" ]] || erreurs="$erreurs $d"
    done
    if [[ -z "$erreurs" ]]; then
        ok "C4" "répertoires personnels en 700"
    else
        ko "C4" "répertoires trop ouverts :$erreurs"
    fi
}

# --- Tests : accès SSH (Mathieu) -----------------------------------------

test_S1() {
    local valeur cle
    valeur="$(sshd_valeur pubkeyauthentication)"
    if [[ "$valeur" == "yes" ]]; then
        ok "S1" "authentification par clé activée"
    else
        ko "S1" "PubkeyAuthentication vaut '${valeur:-?}' (attendu : yes)"
    fi
    for cle in passwordauthentication kbdinteractiveauthentication; do
        valeur="$(sshd_valeur "$cle")"
        if [[ "$valeur" == "no" ]]; then
            ok "S1" "$cle désactivé"
        else
            ko "S1" "$cle vaut '${valeur:-?}' (attendu : no)"
        fi
    done
}

# Exemple de test complet, sur le modèle du sujet
test_S2() {
    local valeur
    valeur="$(sshd_valeur permitrootlogin)"
    if [[ "$valeur" == "no" ]]; then
        ok "S2" "connexion root refusée"
    else
        ko "S2" "PermitRootLogin vaut '${valeur:-?}' (attendu : no)"
    fi
}

test_S3() {
        local valeur
    valeur="$(sshd_valeur allowgroups)"
    if [[ "$valeur" == "acces_ssh" ]]; then
        ok "S3" "seul le groupe acces_ssh est autorisé"
    else
        ko "S3" "AllowGroups vaut '${valeur:-?}' (attendu : acces_ssh seul)"
    fi
    # Un AllowGroups vers un groupe inexistant refuserait tout le monde
    if getent group acces_ssh >/dev/null; then
        ok "S3" "le groupe acces_ssh existe"
    else
        ko "S3" "le groupe acces_ssh n'existe pas"
    fi
}

# Valeurs maximales imposées par le cahier des charges
MAX_ESSAIS=4
MAX_INACTIVITE=900    # 15 minutes, en secondes

test_S4() {
    local valeur ligne duree
    valeur="$(sshd_valeur maxauthtries)"
    if [[ "$valeur" =~ ^[0-9]+$ ]] && (( valeur <= MAX_ESSAIS )); then
        ok "S4" "au plus $valeur essais d'authentification par connexion"
    else
        ko "S4" "MaxAuthTries vaut '${valeur:-?}' (attendu : $MAX_ESSAIS au plus)"
    fi
 
    # ChannelTimeout peut lister plusieurs types (session=..., x11=...) :
    # on extrait celui des sessions.
    ligne="$(sshd -T 2>/dev/null | awk '$1 == "channeltimeout"')"
    valeur="$(grep -o 'session=[^ ]*' <<< "$ligne")"
    duree="$(en_secondes "${valeur#session=}")"
    if [[ -n "$duree" ]] && (( duree > 0 && duree <= MAX_INACTIVITE )); then
        ok "S4" "session inactive fermée après $duree s"
    else
        ko "S4" "ChannelTimeout session vaut '${valeur:-absent}' (attendu : entre 1 s et $MAX_INACTIVITE s)"
    fi
 
    valeur="$(sshd_valeur unusedconnectiontimeout)"
    duree="$(en_secondes "$valeur")"
    if [[ -n "$duree" ]] && (( duree > 0 && duree <= MAX_INACTIVITE )); then
        ok "S4" "connexion sans session fermée après $duree s"
    else
        ko "S4" "UnusedConnectionTimeout vaut '${valeur:-?}' (attendu : entre 1 s et $MAX_INACTIVITE s)"
    fi
}

SSH_CONF_DEPOT="$REPERTOIRE_DEPOT/config/ssh/sshd_config.d/10-durcissement.conf"
SSH_CONF_SYSTEME="/etc/ssh/sshd_config.d/10-durcissement.conf"
 
test_S5() {
    # La config installée doit être identique à celle du dépôt :
    # toute modification à la main est détectée.
    if cmp -s "$SSH_CONF_DEPOT" "$SSH_CONF_SYSTEME"; then
        ok "S5" "$SSH_CONF_SYSTEME identique à la version du dépôt"
    else
        ko "S5" "$SSH_CONF_SYSTEME absent ou différent du dépôt (relancer installer.sh)"
    fi
    # Sans la ligne Include, les fichiers de sshd_config.d sont ignorés
    if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        ok "S5" "sshd_config inclut bien sshd_config.d"
    else
        ko "S5" "la ligne Include /etc/ssh/sshd_config.d/*.conf manque dans sshd_config"
    fi
    if sshd -t >/dev/null 2>&1; then
        ok "S5" "configuration validée par sshd -t"
    else
        ko "S5" "sshd -t signale une erreur de configuration"
    fi
}

# --- Tests : journaux et défense ------------------------------------------

# Prison fail2ban du dépôt, sur le système, et seuil d'échecs maximal
F2B_CONF_DEPOT="$REPERTOIRE_DEPOT/config/fail2ban/jail.d/sshd.conf"
F2B_CONF_SYSTEME="/etc/fail2ban/jail.d/sshd.conf"
F2B_MAX_ECHECS=5      # « après quelques échecs »

test_J1() {
    local valeur
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        ok "J1" "service fail2ban actif"
    else
        ko "J1" "service fail2ban arrêté (attendu : actif)"
    fi
    if fail2ban-client status sshd >/dev/null 2>&1; then
        ok "J1" "prison sshd active"
    else
        ko "J1" "prison sshd inactive (voir fail2ban-client status)"
    fi
    valeur="$(fail2ban-client get sshd maxretry 2>/dev/null)"
    if [[ "$valeur" =~ ^[0-9]+$ ]] && (( valeur <= F2B_MAX_ECHECS )); then
        ok "J1" "bannissement après $valeur échecs"
    else
        ko "J1" "maxretry vaut '${valeur:-?}' (attendu : $F2B_MAX_ECHECS au plus)"
    fi
    # Cohabitation avec le pare-feu (J2) : la table de fail2ban doit
    # toujours être là, même après un rechargement de nftables.conf
    if nft list table inet f2b-table >/dev/null 2>&1; then
        ok "J1" "règles de fail2ban présentes dans nftables (table inet f2b-table)"
    else
        ko "J1" "table inet f2b-table absente de nftables (effacée par un flush ruleset ?)"
    fi
    if cmp -s "$F2B_CONF_DEPOT" "$F2B_CONF_SYSTEME"; then
        ok "J1" "$F2B_CONF_SYSTEME identique à la version du dépôt"
    else
        ko "J1" "$F2B_CONF_SYSTEME absent ou différent du dépôt (relancer installer.sh)"
    fi
}

# Fichier du pare-feu dans le dépôt, sur le système, et chaîne d'entrée
NFT_CONF_DEPOT="$REPERTOIRE_DEPOT/config/nftables.conf"
NFT_CONF_SYSTEME="/etc/nftables.conf"
NFT_CHAINE_ENTREE="inet filtre entree"

test_J2() {
    # Règles réellement chargées dans le noyau (pas celles du fichier)
    local regles politique
    # shellcheck disable=SC2086  # découpage voulu : famille, table, chaîne
    regles="$(nft list chain $NFT_CHAINE_ENTREE 2>/dev/null)"
    if [[ -z "$regles" ]]; then
        ko "J2" "chaîne $NFT_CHAINE_ENTREE absente : pare-feu non chargé"
    else
        politique="$(grep -o 'policy [a-z]*' <<< "$regles" | awk '{ print $2 }')"
        if [[ "$politique" == "drop" ]]; then
            ok "J2" "politique par défaut du pare-feu en entrée : drop"
        else
            ko "J2" "politique par défaut du pare-feu : ${politique:-?} (attendu : drop)"
        fi
        if grep -Eq 'tcp dport (22|ssh) accept' <<< "$regles"; then
            ok "J2" "SSH (port 22) accepté en entrée"
        else
            ko "J2" "aucune règle n'accepte SSH (attendu : tcp dport 22 accept)"
        fi
        if grep -Eq 'ct state (established,related|related,established) accept' <<< "$regles"; then
            ok "J2" "connexions établies acceptées"
        else
            ko "J2" "connexions établies non acceptées (attendu : ct state established,related accept)"
        fi
    fi

    # La règle survit au redémarrage : service activé, fichier conforme
    if systemctl is-enabled --quiet nftables 2>/dev/null; then
        ok "J2" "service nftables activé au démarrage"
    else
        ko "J2" "service nftables non activé (attendu : systemctl enable nftables)"
    fi
    if cmp -s "$NFT_CONF_DEPOT" "$NFT_CONF_SYSTEME"; then
        ok "J2" "$NFT_CONF_SYSTEME identique à la version du dépôt"
    else
        ko "J2" "$NFT_CONF_SYSTEME absent ou différent du dépôt (relancer installer.sh)"
    fi
}

test_J3() {
    a_faire "J3" "journal système persistant"
}

test_J4() {
    a_faire "J4" "analyse_logs.sh présent, protégé, code de sortie exploitable"
}

# --- Tests : sauvegarde (Hussein) ----------------------------------------

test_B1() {
    a_faire "B1" "sauvegarde incrémentale versionnée, au moins 7 versions gardées"
}

test_B2() {
    a_faire "B2" "sauvegarde planifiée et journalisée"
}

test_B3() {
    a_faire "B3" "répertoire de sauvegarde réservé aux administrateurs"
}

test_B4() {
    a_faire "B4" "restauration possible depuis une version antérieure"
}

# --- Tests : système ------------------------------------------------------

test_D1() {
    local erreurs=""
    dpkg -s unattended-upgrades 2>/dev/null | grep -q "Status: install ok installed" || erreurs="$erreurs [paquet unattended-upgrades non installé]"
    apt-config dump APT::Periodic::Update-Package-Lists | grep -q '"1"' || erreurs="$erreurs [Update-Package-Lists n'est pas à 1]"
    apt-config dump APT::Periodic::Unattended-Upgrade | grep -q '"1"' || erreurs="$erreurs [Unattended-Upgrade n'est pas à 1]"
    systemctl is-enabled --quiet apt-daily-upgrade.timer || erreurs="$erreurs [timer apt-daily-upgrade non activé]"
    systemctl is-active --quiet apt-daily-upgrade.timer || erreurs="$erreurs [timer apt-daily-upgrade inactif]"

    if [[ -z "$erreurs" ]]; then
        ok "D1" "mises à jour de sécurité automatiques actives (paquet, configuration, timer)"
    else
        ko "D1" "mises à jour automatiques non conformes :$erreurs"
    fi
}

test_D2() {
    a_faire "D2" "aucune écoute réseau hors SSH (ou justifiée)"
}

test_D3() {
    a_faire "D3" "aucun fichier modifiable par tous, SUID conformes à la liste"
}

# --- Programme principal --------------------------------------------------

# Ordre d'exécution de tous les tests
TOUS_LES_TESTS=(
    test_C1 test_C2 test_C3 test_C4
    test_S1 test_S2 test_S3 test_S4 test_S5
    test_J1 test_J2 test_J3 test_J4
    test_B1 test_B2 test_B3 test_B4
    test_D1 test_D2 test_D3
)

usage() {
    echo "Usage : $0 [test_XX ...]"
    echo "Sans argument, lance tous les tests."
}

verifier_prerequis() {
    if [[ $EUID -ne 0 ]]; then
        echo "Erreur : ce script doit être lancé en root." >&2
        exit 2
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Erreur : sudo est absent, lancez d'abord installer.sh." >&2
        exit 2
    fi
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    verifier_prerequis

    # Tests demandés en argument, sinon tous
    local tests=("$@")
    if [[ ${#tests[@]} -eq 0 ]]; then
        tests=("${TOUS_LES_TESTS[@]}")
    fi

    # Refuser un nom inconnu avant de lancer quoi que ce soit
    local t
    for t in "${tests[@]}"; do
        if ! declare -F "$t" >/dev/null; then
            echo "Erreur : test inconnu « $t »." >&2
            usage >&2
            exit 2
        fi
    done

    for t in "${tests[@]}"; do
        "$t"
    done

    echo "--- $NB_OK / $NB_TESTS tests réussis"
    if [[ $NB_OK -eq $NB_TESTS ]]; then
        exit 0
    fi
    exit 1
}

main "$@"