# Dossier – Durcissement du serveur de Chiffres & Co

## 1. Tableau de conformité

| ID | Ce que nous avons fait | Test dans verifier.sh | Recommandation ANSSI |
| --- | --- | --- | --- |
| C1 | `creer_comptes.sh` lit `comptes.csv` et crée les groupes, les comptes et installe les clés SSH (une clé par compte). Il teste l'existence avant chaque création : on peut le relancer sans doublon. Les administrateurs ont des comptes nominatifs, sans mot de passe. | `test_C1` | R33 |
| C2 | `creer_comptes.sh` crée les 4 répertoires de `/srv` : `chmod 770`, puis ACL (`setfacl -m`) et ACL par défaut (`setfacl -d -m`) pour les fichiers futurs. `depot` : stagiaires en dépôt seul, sticky bit (`1770`) et `default:group::---`. | `test_C2` | §3.2 (moindre privilège) |
| C3 | | `test_C3` | |
| C4 | | `test_C4` | |
| S1 | | `test_S1` | |
| S2 | | `test_S2` | |
| S3 | | `test_S3` | |
| S4 | | `test_S4` | |
| S5 | | `test_S5` | |
| J1 | | `test_J1` | |
| J2 | | `test_J2` | |
| J3 | | `test_J3` | |
| J4 | | `test_J4` | |
| B1 | | `test_B1` | |
| B2 | | `test_B2` | |
| B3 | | `test_B3` | |
| B4 | | `test_B4` | |
| D1 | `unattended-upgrades` installé ; `config/apt/20auto-upgrades` lance la mise à jour des listes et l'installation une fois par jour. Origines autorisées (vérifié avec `--dry-run --debug`) : Debian stable `trixie` et Debian-Security ; `trixie-updates` exclue. | `test_D1` | R61 |
| D2 | | `test_D2` | |
| D3 | Aucun fichier modifiable par tous hors `/tmp` et `/var/tmp` (sticky bit). Les 12 fichiers SUID sont listés dans `config/suid_attendus.txt`, expliqués, et comparés à l'état réel (on ne les supprime pas : le système en a besoin). | `test_D3` | R54, R56, R57 |

## 2. Choix techniques

### C1 : comptes et groupes

- Les comptes n'ont pas de mot de passe : le CSV n'en contient aucun, la connexion se fait par clé SSH (une clé par compte).
- `usermod -aG` : le `-a` ajoute les groupes. Sans lui, le compte perdrait ses autres groupes.
- Avant chaque création, on teste l'existence (`getent`), et la clé n'est ajoutée à `authorized_keys` que si elle n'y est pas déjà (`grep -qxF`) : le script est idempotent.
- `.ssh` en 700 et `authorized_keys` en 600 : `sshd` refuse une clé si ces droits sont trop larges (`StrictModes`, activé par défaut).

### C2 : répertoires de /srv et ACL

- `chmod 770` avant `setfacl`, parce que `chmod` modifie le masque des ACL. Les « autres » n'ont aucun droit : ce qui n'est pas autorisé est refusé.
- ACL par défaut (`setfacl -d`) : elles s'appliquent aux fichiers créés plus tard, comme le demande le sujet.
- Les ACL de `depot` sont posées explicitement après celles de `commun`, pour ne dépendre d'aucun héritage.
- Stagiaires en `-wx` sur `depot` : ils déposent et traversent, sans lister.
- `default:group::---` : le groupe propriétaire d'un fichier déposé est `stagiaire`. Avant cette ligne, un stagiaire pouvait lire le fichier d'un autre (testé) ; après, c'est refusé.
- Sticky bit (`1770`) : seuls le propriétaire du fichier, celui du répertoire et root peuvent supprimer ou renommer. Testé : `rm` et `mv` par un autre stagiaire donnent « Opération non permise ».
- Contrepartie : comptables, rh et direction lisent et modifient un fichier déposé, mais ne peuvent pas le supprimer.

### D1 : mises à jour automatiques

- Mise à jour quotidienne : une faille connue est corrigée vite, sans intervention.
- Origines autorisées par défaut : Debian stable (`trixie`) et Debian-Security. `trixie-updates` n'est pas autorisée.
- L'essai à blanc (`--dry-run`) a confirmé ces origines avant le déploiement.

### D3 : permissions

- `find / -xdev` : reste sur le système de fichiers racine, donc exclut `/proc`, `/sys` et `/dev`. On ne retient que les fichiers et les répertoires, pas les liens symboliques.
- `/tmp` et `/var/tmp` sont exclus : modifiables par tous, mais protégés par le sticky bit (`drwxrwxrwt`).
- Les SUID sont comparés à une liste de référence (`config/suid_attendus.txt`) : un nouveau SUID est suspect (risque d'élévation de privilèges).


## 3. Défense

- **Utilisateur curieux** : un comptable ne peut ni lire ni écrire dans `/srv/rh` (ACL, `other::---`, `test_C2`). Non couvert : root et les administrateurs voient tout.
- **Compte stagiaire compromis** : il peut déposer, mais ni lister, ni lire, ni supprimer, ni renommer les fichiers des autres (sticky bit, `default:group::---`). Non couvert : il peut déposer un fichier malveillant que les autres groupes ouvriront.
- **Faille connue non corrigée** : correctifs de sécurité installés chaque jour (`unattended-upgrades`). Non couvert : une faille sans correctif publié.
- **Élévation de privilèges par un binaire SUID ou un fichier modifiable par tous** : `test_D3` détecte un nouveau SUID ou un fichier modifiable. Non couvert : le test ne détecte qu'au moment où on lance `verifier.sh`, pas en temps réel.

## 4. Procédure de restauration
