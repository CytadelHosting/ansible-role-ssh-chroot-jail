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
- Systemd

## Variables principales

### Configuration du service

```yaml
# Port d'écoute pour les comptes jailed (défaut: 22)
sshd_jail_port: 22

# Umask SFTP (défaut: 007 = rwxrwx---)
sshd_jail_sftp_umask: '007'

# Chemin racine des jails
ssh_chroot_jail_path: /jails
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
  - name: charlie
    home: /home_local/charlie
    ssh_match_options:
      AllowTcpForwarding: 'yes'
      PermitOpen: '127.0.0.1:3306'

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

Le rôle installe un service `sshd@jail` basé sur un template systemd :
- Service : `/lib/systemd/system/sshd@.service`
- Config : `/etc/ssh/sshd_config_jail`
- Commandes : `systemctl restart sshd@jail`

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
