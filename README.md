# Durcissement d'un serveur Debian – Chiffres & Co

Projet XTI302-CYB, Administration systèmes avancée et scripting.
Contexte B : cabinet comptable Chiffres & Co.

## Équipe

| Membre | Périmètre |
| --- | --- |
| Charles | Comptes, ACL, mises à jour, permissions (C1, C2, D1, D3) |
| Mathieu | SSH, pare-feu, fail2ban, écoutes réseau, intégration d'`installer.sh` (S1–S5, J1, J2, D2) |
| Hussein | sudo, root, journaux, sauvegarde (C3, C4, J3, J4, B1–B4) |

## Prérequis

- VM Debian 13 minimale, sans interface graphique, avec le serveur SSH
- Second disque virtuel de 1 à 2 Go, réservé aux sauvegardes
- Accès root sur la VM pour la première exécution
- Paquets des dépôts Debian officiels uniquement

## Installation

Sur la VM, en root :

```bash
git clone <url-du-depot> durcissement
cd durcissement
./installer.sh
```

`installer.sh` peut être relancé sans danger : il ne recrée pas les comptes existants et ne reformate pas le disque de sauvegarde.

## Vérification

```bash
./verifier.sh
```

Le script affiche un résultat `[OK]` ou `[KO]` par exigence, puis un résumé. Code de sortie : 0 si tout est conforme, 1 sinon.

## Arborescence

```
.
├── README.md
├── DOSSIER.md
├── comptes.csv
├── installer.sh
├── creer_comptes.sh
├── analyse_logs.sh
├── sauvegarde.sh
├── verifier.sh
└── config/
    ├── ssh/sshd_config.d/
    ├── sudoers.d/
    ├── fail2ban/jail.d/
    ├── keys/            (clés publiques uniquement)
    ├── apt/20auto-upgrades
    ├── systemd/         (sauvegarde.service, sauvegarde.timer)
    ├── nftables.conf
    └── journald.conf
```

## Ce qu'`installer.sh` attend de chacun

`installer.sh` va chercher chaque fichier à un emplacement précis. Un fichier absent est signalé « absent » dans le résumé, puis l'étape est sautée.

| Fichier dans le dépôt | Installé vers | Qui | Point d'attention |
| --- | --- | --- | --- |
| `comptes.csv`, `creer_comptes.sh` | lancé par `bash creer_comptes.sh comptes.csv` | Charles | Le CSV est passé en argument ; doit être idempotent |
| `config/keys/<login>.pub` | lu par `creer_comptes.sh` | Chacun | Une clé publique par compte, nommée d'après le login |
| `config/sudoers.d/admins`, `config/sudoers.d/support` | `/etc/sudoers.d/`, mode 440 | Hussein | **Pas de point dans le nom** : sudo ignorerait le fichier sans rien dire |
| (dans `installer.sh`) `durcir_comptes` | verrouillage de root, `HOME_MODE` | Hussein | Déjà écrit : à relire et valider |
| `config/ssh/sshd_config.d/10-durcissement.conf` | `/etc/ssh/sshd_config.d/` | Mathieu | |
| `config/journald.conf` | `/etc/systemd/journald.conf.d/50-persistant.conf` | Hussein | |
| `config/nftables.conf` | `/etc/nftables.conf` | Mathieu | |
| `config/fail2ban/jail.d/*.conf` | `/etc/fail2ban/jail.d/` | Mathieu | |
| `config/apt/20auto-upgrades` | `/etc/apt/apt.conf.d/20auto-upgrades` | Charles | |
| `analyse_logs.sh`, `sauvegarde.sh` | `/usr/local/sbin/`, `root:root` 755 | Hussein | La règle sudo de `support` pointe vers `/usr/local/sbin/analyse_logs.sh` |
| `config/systemd/sauvegarde.service`, `.timer` | `/etc/systemd/system/` | Hussein | |
| (dans `installer.sh`) `preparer_disque_sauvegarde` | montage sur `/backup` | Hussein | Ne jamais reformater un disque déjà prêt |

Un emplacement qui ne convient pas se change dans `installer.sh` et dans ce tableau, dans la même pull request.

## Conventions

- Une branche par exigence (`feat/S1-ssh-cle`, `feat/C2-acl`), fusion par pull request
- Relectures en rotation : Charles relit Mathieu, Mathieu relit Hussein, Hussein relit Charles
- Message de commit préfixé par l'identifiant d'exigence : `S3: AllowGroups acces_ssh`
- Aucun mot de passe ni clé privée dans le dépôt
