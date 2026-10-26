# Durcissement d'un serveur Debian – Chiffres & Co

Projet XTI302-CYB, Administration systèmes avancée et scripting.
Contexte B : cabinet comptable Chiffres & Co.

## Équipe

| Membre | Périmètre |
| --- | --- |
| Charles | Comptes, droits, journaux, sauvegarde (C1–C4, J3, J4, D1, B1–B4) |
| Mathieu | SSH, pare-feu, fail2ban, intégration (S1–S5, J1, J2, D2, D3) |

## Prérequis

- VM Debian 13 minimale, sans interface graphique, avec le serveur SSH
- Second disque virtuel de 1 à 2 Go, réservé aux sauvegardes
- Accès root sur la VM pour la première exécution
- Paquets des dépôts Debian officiels uniquement

## Installation

Sur la VM, en root :

```bash
git clone https://github.com/mathieudlre/Cabinet-comptable-Chiffres-Co durcissement
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
    ├── nftables.conf
    └── journald.conf
```

## Conventions

- Une branche par exigence (`feat/S1-ssh-cle`, `feat/C2-acl`), fusion par pull request relue par l'autre membre
- Message de commit préfixé par l'identifiant d'exigence : `S3: AllowGroups acces_ssh`
- Aucun mot de passe ni clé privée dans le dépôt
