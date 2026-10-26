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

# --- Tests : comptes et droits (membre 1) ---------------------------------
# Une fonction par exigence. Une fonction peut appeler ok/ko plusieurs
# fois : c'est ainsi qu'on atteint les 25 tests demandés.

test_C1() {
    a_faire "C1" "comptes et groupes conformes à $FICHIER_COMPTES"
}

test_C2() {
    a_faire "C2" "droits et ACL des répertoires de /srv"
}

test_C3() {
    a_faire "C3" "sudo réservé à admins, support limité à analyse_logs.sh"
}

test_C4() {
    a_faire "C4" "root verrouillé, répertoires personnels privés"
}

# --- Tests : accès SSH (membre 2) -----------------------------------------

test_S1() {
    a_faire "S1" "authentification par clé uniquement"
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
    a_faire "S3" "AllowGroups limité à acces_ssh"
}

test_S4() {
    a_faire "S4" "4 essais au plus, session inactive fermée en 15 min au plus"
}

test_S5() {
    a_faire "S5" "configuration dans sshd_config.d, validée par sshd -t"
}

# --- Tests : journaux et défense ------------------------------------------

test_J1() {
    a_faire "J1" "fail2ban protège SSH"
}

test_J2() {
    a_faire "J2" "nftables : politique drop en entrée, SSH et établies acceptés"
}

test_J3() {
    a_faire "J3" "journal système persistant"
}

test_J4() {
    a_faire "J4" "analyse_logs.sh présent, protégé, code de sortie exploitable"
}

# --- Tests : sauvegarde (membre 1) ----------------------------------------

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
    a_faire "D1" "mises à jour de sécurité automatiques"
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
