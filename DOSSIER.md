# Dossier – Durcissement du serveur de Chiffres & Co

## 1. Tableau de conformité

| ID | Ce que nous avons fait | Test dans verifier.sh | Recommandation ANSSI |
| --- | --- | --- | --- |
| C1 | `creer_comptes.sh` lit `comptes.csv` et crée les groupes, les comptes et installe les clés SSH (une clé par compte). Il teste l'existence avant chaque création : on peut le relancer sans doublon. Les administrateurs ont des comptes nominatifs, sans mot de passe. | `test_C1` | R33 |
| C2 | `creer_comptes.sh` crée les 4 répertoires de `/srv` : `chmod 770`, puis ACL (`setfacl -m`) et ACL par défaut (`setfacl -d -m`) pour les fichiers futurs. `depot` : stagiaires en dépôt seul, sticky bit (`1770`) et `default:group::---`. | `test_C2` | §3.2 (moindre privilège) |
| C3 | `config/sudoers.d/admins_support` : `%admins` a tous les droits ; `support` peut lancer uniquement `/usr/local/sbin/analyse_logs.sh` en root (`NOPASSWD`). `installer.sh` valide le fichier avec `visudo -cf` et vide le groupe `sudo` de Debian (compte créé à l'installation). | `test_C3` | |
| C4 | `installer.sh` verrouille root (`passwd -l root`) seulement si un admin avec une règle sudo existe ; répertoires personnels en 700 ; `HOME_MODE 0700` dans `/etc/login.defs` pour les futurs comptes. | `test_C4` | |
| S1 | `config/ssh/sshd_config.d/10-durcissement.conf` : `PubkeyAuthentication yes`, `PasswordAuthentication no` et `KbdInteractiveAuthentication no` (sinon PAM pourrait encore demander un mot de passe). | `test_S1` | NT OpenSSH R17 |
| S2 | `PermitRootLogin no` : chaque administrateur se connecte avec son compte nominatif, puis utilise sudo. | `test_S2` | NT OpenSSH §4.3.3 |
| S3 | `AllowGroups acces_ssh` : seuls les administrateurs et `support` (membres d'`acces_ssh`) peuvent se connecter. Le refus a lieu avant l'authentification. | `test_S3` | NT OpenSSH R22 |
| S4 | `MaxAuthTries 3`, `ChannelTimeout session=10m` (session inactive fermée après 10 min) et `UnusedConnectionTimeout 10m`. `ClientAliveInterval 300` et `ClientAliveCountMax 2` détectent en plus un client disparu. | `test_S4` | NT OpenSSH §4.3.1 |
| S5 | Fichier préfixé `10-` dans `/etc/ssh/sshd_config.d/`, lu avant les autres. `installer.sh` lance `sshd -t` avant de redémarrer ; en cas d'erreur, il restaure l'ancienne configuration. Il refuse aussi d'appliquer la configuration si aucun membre d'`acces_ssh` n'a de clé installée. | `test_S5` | R79 |
| J1 | `config/fail2ban/jail.d/sshd.conf` : bannissement de l'IP après 3 échecs en 10 min, pendant 10 min. Lecture du journal systemd (`backend = systemd`), bannissement par nftables dans la table `inet f2b-table`, créée dès le démarrage. | `test_J1` | R79 |
| J2 | `config/nftables.conf` : table `inet filtre`, politique `drop` en entrée ; seuls passent les connexions établies, la boucle locale, SSH (port 22) et la découverte des voisins IPv6. Service `nftables` activé au démarrage. Le fichier ne remplace que sa propre table (pas de `flush ruleset`) : les bannissements de fail2ban sont conservés. | `test_J2` | R78 |
| J3 | `config/journald.conf` (`Storage=persistent`) installé dans `/etc/systemd/journald.conf.d/` : les journaux sont gardés sur disque dans `/var/log/journal`. | `test_J3` | |
| J4 | `analyse_logs.sh` lit `journalctl -u ssh` : échecs par IP, comptes visés, connexions réussies. Seuil (`-s`, 5 par défaut) et période (`-p`) en arguments. Codes de sortie : 0 conforme, 1 alerte, 2 erreur d'usage. Installé en `root:root 755` dans `/usr/local/sbin`. | `test_J4` | |
| B1 | `sauvegarde.sh` : `rsync -aAXH` de `/srv` et `/etc` vers un dossier daté de `/backup`, `--link-dest` vers la version précédente (fichiers inchangés partagés), rotation à 7 versions, `flock` contre deux exécutions simultanées. | `test_B1` | |
| B2 | `sauvegarde.timer` (systemd) : tous les jours à 02:00, `Persistent=true`. Chaque exécution est journalisée (`logger`, visible avec `journalctl -u sauvegarde.service`). | `test_B2` | |
| B3 | Second disque formaté uniquement s'il est vierge (`blkid`), monté par UUID sur `/backup` via `/etc/fstab` (`nofail`), en `root:admins 750`. | `test_B3` | |
| B4 | Restauration testée : fichier de `/srv` supprimé puis restauré avec `cp -a`, contenu et ACL identiques (`getfacl`). Procédure détaillée en partie 4. | `test_B4` | |
| D1 | `unattended-upgrades` installé ; `config/apt/20auto-upgrades` lance la mise à jour des listes et l'installation une fois par jour. Origines autorisées (vérifié avec `--dry-run --debug`) : Debian stable `trixie` et Debian-Security ; `trixie-updates` exclue. | `test_D1` | R61 |
| D2 | `ss -tulpn` : seul `sshd` (TCP 22) offre un service. Les deux autres écoutes sont les ports clients de `dhcpcd` (UDP 68 et 546), justifiés en partie 2. `test_D2` compare les écoutes joignables depuis le réseau à une liste autorisée. | `test_D2` | R62, R80 |
| D3 | Aucun fichier modifiable par tous hors `/tmp` et `/var/tmp` (sticky bit). Les 12 fichiers SUID sont listés dans `config/suid_attendus.txt`, expliqués, et comparés à l'état réel (on ne les supprime pas : le système en a besoin). | `test_D3` | R54, R56, R57 |

Références : « R… » renvoie au guide ANSSI *Recommandations de configuration d'un système GNU/Linux* (BP-028) ; « NT OpenSSH » à la note technique ANSSI *Recommandations pour un usage sécurisé d'(Open)SSH*.

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

### C3 : sudo

- Une règle par groupe (`%admins`) plutôt que par personne : ajouter un administrateur se fait dans `comptes.csv`, sans toucher au sudoers.
- `support` : une seule commande, en chemin absolu. Sans chemin absolu, il pourrait lancer un autre script portant le même nom.
- `NOPASSWD` pour `support` uniquement : les comptes n'ont pas de mot de passe (connexion par clé), donc sans lui `support` ne pourrait jamais lancer le script. Le risque reste limité : une seule commande, et le script appartient à root et n'est pas modifiable par `support` (sinon il y mettrait `bash` et deviendrait root).
- Fichier nommé `admins_support`, sans point : sudo ignore en silence les fichiers de `sudoers.d` dont le nom contient un point.
- Validation avec `visudo -cf` avant installation : un sudoers invalide peut casser sudo pour tout le monde.
- Debian donne sudo au compte créé à l'installation (groupe `sudo`) : `installer.sh` vide ce groupe.

### C4 : root et répertoires personnels

- Root n'est verrouillé que si un membre d'`admins` a une règle sudo : sinon la machine deviendrait inadministrable.
- `HOME_MODE 0700` dans `/etc/login.defs` : les comptes créés plus tard ont aussi un répertoire privé, pas seulement ceux qui existent aujourd'hui.

### S1 à S5 : accès SSH

- Un fichier dans `sshd_config.d` plutôt qu'une modification de `sshd_config` : une mise à jour du paquet ne crée pas de conflit, et tout le durcissement tient dans un seul fichier versionné.
- Préfixe `10-` : pour sshd, la première valeur lue l'emporte, et les fichiers sont lus par ordre alphabétique. Nos réglages passent avant ceux des autres fichiers.
- `KbdInteractiveAuthentication no` en plus de `PasswordAuthentication no` : avec PAM, sshd pourrait encore demander un mot de passe par la méthode « keyboard-interactive ».
- `MaxAuthTries 3` : 4 au plus étaient exigés. Avec la connexion par clé seule, un utilisateur légitime n'échoue pas. Chaque clé proposée par l'agent SSH compte comme un essai : un administrateur qui en a plusieurs utilise `-o IdentitiesOnly=yes`.
- 10 minutes d'inactivité (15 au plus exigées) avec `ChannelTimeout`, et non `ClientAliveInterval` : le client SSH répond automatiquement aux sondes `ClientAlive`, qui ne détectent donc qu'un client disparu, pas un utilisateur inactif. Contrepartie : une commande longue et silencieuse est coupée elle aussi.
- Port 22 conservé : changer de port masque le service sans le protéger. La protection vient de la clé seule, de fail2ban et du pare-feu.
- `sshd -t` vérifie la syntaxe, pas le sens : `AllowGroups acces_sshh` passerait la validation et bloquerait tout le monde. D'où le garde-fou d'`installer.sh` et les tests qui lisent la configuration effective (`sshd -T`).

### J1 : fail2ban

- `backend = systemd` : Debian 13 n'installe pas rsyslog, il n'y a donc pas de `/var/log/auth.log`. fail2ban lit directement le journal (paquet `python3-systemd`).
- 3 échecs en 10 minutes : un robot échoue en boucle, un utilisateur légitime avec sa clé n'échoue pas.
- 10 minutes de bannissement : assez pour casser une attaque automatique, assez court pour qu'une erreur humaine ne bloque pas longtemps. Débannissement immédiat : `fail2ban-client set sshd unbanip <IP>`.
- `actionstart_on_demand=false` : par défaut, fail2ban ne crée sa table nftables qu'au premier bannissement. Créée dès le démarrage, elle permet de vérifier à tout moment la cohabitation avec le pare-feu (`test_J1`).
- L'hôte n'est pas dans `ignoreip`, pour pouvoir démontrer le bannissement depuis lui.
- Complémentaire de `MaxAuthTries` : `MaxAuthTries` limite les essais dans une connexion, fail2ban bannit une IP qui enchaîne les connexions.
- Pour fail2ban, c'est la dernière valeur lue qui l'emporte : notre fichier passe après `defaults-debian.conf`, fourni par le paquet.

### J2 : pare-feu nftables

- Pas de `flush ruleset` : il effacerait aussi la table de fail2ban et ses bannissements. Le fichier crée notre table si elle n'existe pas, la supprime, puis la redéfinit, le tout appliqué d'un bloc : il n'y a jamais d'instant sans pare-feu.
- Pour la même raison, `installer.sh` recharge le pare-feu avec `systemctl reload nftables`, jamais `restart` : l'arrêt du service lance `nft flush ruleset`. Testé : la table de fail2ban survit au rechargement.
- Table `inet` : une seule table pour IPv4 et IPv6.
- `ct state established,related accept` : les réponses aux connexions ouvertes par le serveur (mises à jour, DNS) passent, ainsi que les erreurs ICMP qui les concernent.
- Découverte des voisins IPv6 acceptée : sans elle, IPv6 ne fonctionne pas (c'est l'équivalent d'ARP, qui n'est pas filtré en IPv4).
- Ping refusé : le serveur ne répond pas aux balayages simples. Contrepartie : on ne peut plus vérifier d'un ping qu'il est en ligne. Deux lignes commentées permettent de l'autoriser.
- Paquets refusés journalisés, 5 par minute au plus pour ne pas saturer le journal : `journalctl -k | grep nft-refus`.
- Chaîne `forward` en `drop` (le serveur n'est pas un routeur), chaîne `output` en `accept`.

### D2 : écoutes réseau

- Les écoutes sur la boucle locale (`127.0.0.1`, `::1`) ne sont pas comptées : elles ne sont pas joignables depuis le réseau.
- UDP 68 et 546 : ports clients de `dhcpcd`, qui obtient l'adresse IPv4 et la configuration IPv6 de la VM. Ils n'offrent aucun service : ils reçoivent les réponses du serveur DHCP.
- Pas d'adresse fixe : elle rendrait `installer.sh` dépendant du réseau de chaque VM (les nôtres sont toutes sur des réseaux différents).
- Défense en profondeur : même si le pare-feu bloque déjà tout sauf SSH, aucun service inutile n'est exposé si le pare-feu tombe.

### J3 : journal persistant

- `Storage=persistent` plutôt que `auto` : avec `auto`, le journal n'est gardé sur disque que si `/var/log/journal` existe déjà. `persistent` crée le dossier lui-même, donc les journaux survivent toujours à un redémarrage.

### J4 : analyse des journaux

- Debian 13 minimale n'a pas de `/var/log/auth.log` : sshd écrit dans le journal systemd, lu avec `journalctl -u ssh`.
- La connexion par mot de passe étant désactivée, il n'y a pas de lignes `Failed password` : un échec apparaît comme `Connection reset by invalid user <compte> <IP>`. Le script a été écrit à partir de ces lignes réelles.
- Seuil par défaut : 5 échecs par IP sur la période. Au-delà, ce n'est plus une faute de frappe mais une tentative répétée, cohérente avec le bannissement de fail2ban.
- Codes de sortie distincts (0, 1, 2) : le script peut être utilisé par un autre outil (supervision, cron) sans lire son texte.

### B : sauvegarde

- Second disque : une panne ou un effacement du disque système ne touche pas les sauvegardes.
- Formatage uniquement si `blkid` ne trouve aucun système de fichiers : relancer `installer.sh` n'efface jamais les sauvegardes.
- Montage par UUID : le nom `sdb` peut changer d'un démarrage à l'autre, l'UUID non. `nofail` : si le disque manque, la machine démarre quand même.
- `rsync -aAX` : conserve droits, propriétaires, ACL et attributs étendus, indispensables pour restaurer `/srv`.
- `--link-dest` : un fichier inchangé n'est stocké qu'une fois et partagé entre les versions. Chaque version est complète, mais ne prend que la place des fichiers modifiés.
- 7 versions avec une sauvegarde par jour : une semaine d'historique, sur un disque de 2 Go.
- 02:00 : personne ne travaille au cabinet à cette heure-là. `Persistent=true` : si la machine était éteinte à 2 h, la sauvegarde est rattrapée au démarrage.
- `flock` : deux sauvegardes simultanées (timer + lancement manuel) pourraient corrompre une version.
- `/backup` en `root:admins 750` : les sauvegardes contiennent les données de tous les services ; un comptable ne doit pas pouvoir y lire les fichiers RH.

### D1 : mises à jour automatiques

- Mise à jour quotidienne : une faille connue est corrigée vite, sans intervention.
- Origines autorisées par défaut : Debian stable (`trixie`) et Debian-Security. `trixie-updates` n'est pas autorisée.
- L'essai à blanc (`--dry-run`) a confirmé ces origines avant le déploiement.

### D3 : permissions

- `find / -xdev` : reste sur le système de fichiers racine, donc exclut `/proc`, `/sys` et `/dev`. On ne retient que les fichiers et les répertoires, pas les liens symboliques.
- `/tmp` et `/var/tmp` sont exclus : modifiables par tous, mais protégés par le sticky bit (`drwxrwxrwt`).
- Les SUID sont comparés à une liste de référence (`config/suid_attendus.txt`) : un nouveau SUID est suspect (risque d'élévation de privilèges).


## 3. Défense

- **Force brute SSH** : sans mot de passe accepté, deviner un identifiant ne suffit plus ; chaque connexion est limitée à 3 essais (`MaxAuthTries`), et l'IP est bannie après 3 échecs en 10 minutes (fail2ban). `analyse_logs.sh` signale l'attaque. Non couvert : une attaque répartie sur de nombreuses IP, chacune sous le seuil.
- **Vol de mot de passe** : un mot de passe volé (hameçonnage, réutilisation) n'ouvre pas de session SSH, qui exige une clé ; root est interdit en SSH et verrouillé. Non couvert : le vol de la clé privée d'un administrateur. Une passphrase la protège, mais le serveur ne peut pas l'imposer, et `creer_comptes.sh` ajoute les clés sans retirer les anciennes : une clé révoquée doit être supprimée à la main d'`authorized_keys`.
- **Service exposé par erreur** : le pare-feu refuse tout ce qui entre sauf SSH, et `test_D2` signale toute nouvelle écoute réseau. Non couvert : une faille dans sshd lui-même, seul service exposé (atténuée par les mises à jour automatiques).
- **Utilisateur curieux** : un comptable ne peut ni lire ni écrire dans `/srv/rh` (ACL, `other::---`, `test_C2`). Non couvert : root et les administrateurs voient tout.
- **Compte stagiaire compromis** : il peut déposer, mais ni lister, ni lire, ni supprimer, ni renommer les fichiers des autres (sticky bit, `default:group::---`). Non couvert : il peut déposer un fichier malveillant que les autres groupes ouvriront.
- **Faille connue non corrigée** : correctifs de sécurité installés chaque jour (`unattended-upgrades`). Non couvert : une faille sans correctif publié.
- **Élévation de privilèges par un binaire SUID ou un fichier modifiable par tous** : `test_D3` détecte un nouveau SUID ou un fichier modifiable. Non couvert : le test ne détecte qu'au moment où on lance `verifier.sh`, pas en temps réel.

## 4. Procédure de restauration

Les sauvegardes sont sur le second disque, monté sur `/backup` (accessible aux seuls membres d'`admins`).
Chaque version est un dossier daté `AAAA-MM-JJ_HHMMSS` qui contient une copie complète de `/srv` et `/etc`.

**Restaurer un fichier supprimé** (exemple : `/srv/dossiers_clients/facture.txt`) :

1. Se connecter avec un compte du groupe `admins`.
2. Lister les versions disponibles et choisir celle d'avant la suppression :
   `sudo ls /backup`
3. Vérifier que le fichier est présent dans cette version :
   `sudo ls -l /backup/2026-10-31_003455/srv/dossiers_clients/`
4. Le recopier à sa place en conservant droits, propriétaire et ACL (`-a`) :
   `sudo cp -a /backup/2026-10-31_003455/srv/dossiers_clients/facture.txt /srv/dossiers_clients/`
5. Vérifier le contenu et les ACL :
   `sudo cat /srv/dossiers_clients/facture.txt`
   `sudo getfacl /srv/dossiers_clients/facture.txt`

**Test réalisé :** fichier créé, sauvegardé, supprimé puis restauré. Le contenu et les ACL
(`group:comptables:rwx`, `group:direction:r-x`) sont identiques avant et après.

**Restaurer un répertoire entier** : même principe avec `rsync -aAX`, qui conserve aussi
les ACL et les attributs étendus :
`sudo rsync -aAX /backup/<version>/srv/rh/ /srv/rh/`
