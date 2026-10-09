# CytadelHosting.ssh-chroot-jail

Rôle Ansible pour gérer des comptes SSH/SFTP jailed avec isolation complète par utilisateur.

## Fonctionnalités

- **Jails individuelles** : chaque utilisateur a sa propre jail dans `/jails/<username>/`
- **Deux modes d'accès** :
  - `sftpjail` : SFTP uniquement (ForceCommand internal-sftp)
  - `sshjail` : Shell interactif dans la jail
- **Binaires personnalisables** : liste globale + binaires additionnels par utilisateur
- **Bind mounts** : montage de répertoires externes dans les jails
- **Exceptions SSH** : configuration spécifique par utilisateur (tunneling, etc.)
- **Gestion du cycle de vie** : création, mise à jour, archivage et suppression

## Prérequis

- Ansible >= 2.9
- Debian/Ubuntu ou RedHat/CentOS
- systemd, ou SysV LSB sur famille Debian (Devuan)
- Package `acl` installé (pour les permissions sur les bind mounts)

## Variables principales

### Configuration du service

```yaml
# Port d'écoute pour les comptes jailed (défaut: 22)
sshd_jail_port: 22

# Umask SFTP (défaut: 007 = rwxrwx---)
sshd_jail_sftp_umask: '007'

# Chemin racine des jails
ssh_chroot_jail_path: /jails

# Profil crypto. Défaut : modern (defaults du paquet OpenSSH, comme cytadel.common)
# compatible : + KEX modp pour les clients sans curve25519 / post-quantique
# legacy     : + ssh-rsa, hmac-sha1, group14-sha1, aes-cbc
sshd_jail_crypto_profile: modern
```

### Définition des utilisateurs

```yaml
ssh_chroot_jail_users:
  # Exemple 1 : SFTP only (défaut)
  - name: alice
    home: /home_local/alice
    allow_interactive: false          # false = SFTP only (défaut)
    authorized_keys:
      - 'files/ssh_keys/alice.pub'
    bind_remounts:
      - src_dir: '/var/www/alice_site'
        mount_point: '/home_local/alice/www'
        rw: yes

  # Exemple 2 : Shell interactif
  - name: bob
    home: /home_local/bob
    allow_interactive: true           # true = shell interactif dans la jail
    authorized_keys:
      - 'files/ssh_keys/bob.pub'
    extra_bins:                       # binaires additionnels pour cet utilisateur
      - /usr/bin/git
      - /usr/bin/composer

  # Exemple 3 : SFTP avec exceptions (tunnel MySQL)
  # sshd_user_options est émis dans un Match User placé AVANT le Match Group :
  # OpenSSH conserve la première occurrence de chaque mot-clé.
  - name: charlie
    home: /home_local/charlie
    sshd_user_options:
      - 'AllowTcpForwarding yes'
      - 'PermitOpen 127.0.0.1:3306'

  # Exemple 4 : Suppression d'un utilisateur
  - name: old_user
    state: absent                     # déclenche archivage + suppression
```

### Binaires disponibles dans les jails

```yaml
# Liste globale (tous les utilisateurs)
ssh_chroot_bins:
  - /bin/bash
  - /bin/ls
  - /usr/bin/vim
  # ...

# Forcer la resynchronisation des binaires (après mise à jour OS)
ssh_chroot_jail_sync_bins: false
```

## Architecture

### Service SSHD

Daemon autonome, indépendant de `ssh.service` :

| | systemd | SysV (Debian, `ansible_facts.service_mgr != systemd`) |
|---|---|---|
| Définition | `/etc/systemd/system/sshd-jail.service` | `/etc/init.d/sshd-jail` |
| Modèle | `ssh.service` du paquet Debian (`Type=notify`, `RestartPreventExitStatus=255`) | `/etc/init.d/ssh` (LSB, `start-stop-daemon`, pid file dédié) |
| Environnement | `/etc/default/sshd-jail` (`SSHD_OPTS`) | idem |

- Config : `/etc/ssh/sshd_config_jail`, validée par `sshd -t` avant écriture, au `ExecStartPre` et au `reload`
- Pid : `/run/sshd-jail.pid` (ne pas écraser `/run/sshd.pid`)
- Coupure : créer `/etc/ssh/sshd-jail_not_to_be_run` (même convention que `sshd_not_to_be_run`)
- `RuntimeDirectory=sshd` n'est pas posé : ce répertoire est partagé avec le SSH d'admin, systemd le retirerait à l'arrêt de la jail

`sshd@.service` du paquet est per-connection (`sshd -i`). Le rôle ne s'en sert pas et arrête une ancienne instance `sshd@jail`.

### Profils crypto

Alignés sur `cytadel.common` : pas de liste figée par défaut, les algorithmes suivent le paquet OpenSSH.

| Profil | Effet |
|---|---|
| `modern` (défaut) | aucune directive `Ciphers` / `KexAlgorithms` / `MACs` / `HostKeyAlgorithms` |
| `compatible` | `modern` + KEX `diffie-hellman-group14-sha256`, group16, group18, group-exchange-sha256 |
| `legacy` | `compatible` + `ssh-rsa`, `hmac-sha1`, `group14-sha1`, `aes128-cbc`, `aes256-cbc` |

Le préfixe `+` ajoute aux defaults du binaire : sur Debian 13 le post-quantique reste proposé en premier. Une variable `sshd_jail_ciphers` (ou kex, macs, host key, pubkey) non vide remplace la ligne du profil.

`legacy` fait échouer `sshd -t` si l'OpenSSH de la machine a retiré l'algorithme à la compilation. Ne l'activer que pour un client qui ne négocie rien d'autre.

### Groupes hors jail et pénalités

```yaml
# Groupes autorisés en plus de sshjail/sftpjail. Aucun chroot pour eux.
sshd_jail_allow_groups_extra: []

# OpenSSH >= 9.8 (Debian 13) : PerSourcePenalties actif par défaut
sshd_jail_per_source_penalties: ''               # '' = défaut, 'no' = off
sshd_jail_per_source_penalty_exempt_list: []     # ex : ['203.0.113.10/32']
```

## Diagnostic d'un client qui ne se connecte plus

Le rôle installe `/usr/local/sbin/sshd-jail-diag <ip_client>`. Il trouve la cause côté serveur, sans log client. Documentation complète : [docs/sshd-jail-diag.md](docs/sshd-jail-diag.md).

### Structure d'une jail

```
/jails/alice/
├── bin/                    # Binaires (/bin/bash, /bin/ls, ...)
├── dev/                    # Devices (null, zero, tty, random, urandom)
├── etc/
│   ├── passwd              # Minimal (root + alice)
│   └── group               # Minimal
├── home_local/alice/       # Home directory
├── lib/, lib64/            # Librairies partagées
├── tmp/                    # chmod 1777
└── usr/bin/, usr/lib/      # Binaires et libs /usr
```

### Groupes système

| Groupe | allow_interactive | Shell | Accès |
|--------|-------------------|-------|-------|
| `sftpjail` | `false` (défaut) | `/usr/sbin/nologin` | SFTP uniquement |
| `sshjail` | `true` | `/bin/bash` | Shell interactif dans jail |

### Bind mounts et ACL

Quand un répertoire externe est monté dans la jail avec `rw: yes`, le rôle :

1. **Ajoute automatiquement le owner/group du dossier source** dans `/etc/passwd` et `/etc/group` de la jail, permettant à l'utilisateur de voir correctement les propriétaires des fichiers.

2. **Applique des ACL** sur le dossier source pour donner les droits `rwX` à l'utilisateur jailed :
   - ACL sur les fichiers/dossiers existants (récursif)
   - ACL par défaut pour les nouveaux fichiers créés

Exemple de bind mount :
```yaml
bind_remounts:
  - src_dir: '/var/www/monsite'      # dossier source (propriétaire: www-data)
    mount_point: '/home_local/user/www'  # point de montage dans la jail
    rw: yes                          # lecture/écriture (déclenche les ACL)
```

Résultat :
- L'utilisateur `www-data` apparaît dans `/jails/user/etc/passwd`
- L'utilisateur jailed peut écrire dans `/var/www/monsite` via les ACL

### `/etc/passwd` et `/etc/group` de la jail

Les lignes sont recopiées depuis l'OS (`getent`), jamais recomposées : un UID/GID garde toujours son vrai nom. Le champ mot de passe est forcé à `x`. La liste des membres des groupes est vidée, sinon `sshjail` révélerait tous les comptes jailés.

| Contenu | Source |
|---|---|
| `root`, l'utilisateur | toujours |
| tous les groupes de l'utilisateur | `id -G` (primaire et secondaires) |
| owner et groupe de chaque `src_dir` | `stat` des bind mounts |
| comptes et groupes supplémentaires | `ssh_chroot_jail_visible_users` / `_groups`, et `visible_users` / `visible_groups` par utilisateur |

Une clé inconnue de l'OS est ignorée. Les lectures tournent aussi en `--check` : le diff simulé correspond à ce qu'écrirait un vrai run.

## Suppression d'un utilisateur

Quand `state: absent` :
1. Démontage des bind mounts
2. Archivage : `/jails/<user>_<timestamp>.tar.gz`
3. Suppression de l'utilisateur système
4. Suppression du répertoire jail

## Exemples de playbook

### Création simple

```yaml
- hosts: webservers
  roles:
    - role: CytadelHosting.ssh-chroot-jail
      vars:
        ssh_chroot_jail_users:
          - name: webmaster
            home: /home_local/webmaster
            authorized_keys:
              - 'files/ssh_keys/webmaster.pub'
            bind_remounts:
              - src_dir: '/var/www/html'
                mount_point: '/home_local/webmaster/www'
                rw: yes
```

### Mise à jour des binaires après upgrade OS

```yaml
- hosts: webservers
  roles:
    - role: CytadelHosting.ssh-chroot-jail
      vars:
        ssh_chroot_jail_sync_bins: true
```

## Compatibilité

| OS | Version | Testé |
|----|---------|-------|
| Debian | 10, 11, 12 | ✓ |
| Ubuntu | 20.04, 22.04 | ✓ |
| Rocky Linux | 8, 9 | ✓ |

## Licence

MIT

## Auteur

CytadelHosting
