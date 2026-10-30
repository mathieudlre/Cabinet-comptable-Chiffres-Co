#!/usr/bin/env bash
# analyse_logs.sh - rapport des connexions SSH (J4)
# Usage : analyse_logs.sh [-s SEUIL] [-p PERIODE]
# Code de sortie : 0 conforme, 1 alerte (seuil dépassé), 2 erreur d'usage
set -euo pipefail

SEUIL=5
PERIODE="24 hours ago"

usage() {
    echo "Usage : $0 [-s SEUIL] [-p PERIODE]   ex : $0 -s 5 -p '1 hour ago'"
}

while getopts "s:p:h" opt; do
    case "$opt" in
        s) SEUIL="$OPTARG" ;;
        p) PERIODE="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Erreur : ce script doit être lancé en root" >&2
    exit 2
fi
if [[ ! "$SEUIL" =~ ^[0-9]+$ ]]; then
    echo "Erreur : le seuil doit être un nombre entier" >&2
    exit 2
fi

JOURNAL="$(journalctl -u ssh --since "$PERIODE" -o cat --no-pager 2>/dev/null)" || {
    echo "Erreur : période invalide : $PERIODE" >&2
    exit 2
}

ECHECS="$(grep -oE 'by (invalid|authenticating) user [^ ]+ [^ ]+ port' <<< "$JOURNAL" | awk '{print $4, $5}' || true)"
REUSSITES="$(grep -oE 'Accepted [a-z]+ for [^ ]+ from [^ ]+' <<< "$JOURNAL" | awk '{print $4, $6}' || true)"

echo "=== Rapport SSH depuis : $PERIODE (seuil : $SEUIL échecs par IP) ==="

echo "--- Échecs par IP ---"
if [[ -n "$ECHECS" ]]; then awk '{print $2}' <<< "$ECHECS" | sort | uniq -c | sort -rn; else echo "aucun"; fi

echo "--- Comptes visés ---"
if [[ -n "$ECHECS" ]]; then awk '{print $1}' <<< "$ECHECS" | sort | uniq -c | sort -rn; else echo "aucun"; fi

echo "--- Connexions réussies ---"
if [[ -n "$REUSSITES" ]]; then awk '{print $1 " depuis " $2}' <<< "$REUSSITES" | sort | uniq -c; else echo "aucune"; fi

if [[ -n "$ECHECS" ]]; then
    MAX="$(awk '{print $2}' <<< "$ECHECS" | sort | uniq -c | sort -rn | awk 'NR==1 {print $1}')"
    if (( MAX > SEUIL )); then
        echo "ALERTE : une IP a dépassé $SEUIL échecs ($MAX)"
        exit 1
    fi
fi
echo "Conforme : aucune IP au-dessus du seuil"
exit 0
