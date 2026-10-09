# sshd-jail-diag

Trouve pourquoi un client n'arrive pas à se connecter au daemon `sshd-jail`, uniquement depuis le serveur. Pas besoin des logs du client.

Source : [`files/sshd-jail-diag.sh`](../files/sshd-jail-diag.sh). Le rôle l'installe dans `/usr/local/sbin/sshd-jail-diag`, en `root:root 0750`.

## Quand s'en servir

- Un client échoue alors que les autres passent.
- Les échecs ont commencé après une mise à jour d'OpenSSH, par exemple Debian 12 → 13 (OpenSSH 9.2 → 10.0).
- Les journaux du serveur ne montrent rien de clair.

## Prérequis

| Outil | Rôle dans le script | Si absent |
|---|---|---|
| root | lecture des clés d'hôte, journal, capture | le script refuse de démarrer |
| `tcpdump` | capture des premiers paquets du client | étapes 1 à 3 seulement (`apt install tcpdump`) |
| `python3` | décodage de la capture | étapes 1 à 3 seulement |
| `fail2ban-client` ≥ 0.11 | `fail2ban-client banned` | vérification fail2ban ignorée |

Le script ne modifie rien : il lit la configuration, les journaux et les règles pare-feu. Il écrit seulement dans un répertoire `/tmp/sshd-jail-diag.XXXXXX`, supprimé à la sortie.

## Usage

```bash
sshd-jail-diag <ip_client> [durée_capture_s]
```

| Paramètre | Défaut | Effet |
|---|---|---|
| `ip_client` | obligatoire | IP **vue par le serveur**. Derrière un NAT, c'est l'IP publique du NAT. |
| `durée_capture_s` | `180` | Fenêtre d'attente de la tentative du client. La capture s'arrête dès 40 paquets reçus. |
| `JAIL_CONFIG` | `/etc/ssh/sshd_config_jail` | Config du daemon. À changer si `ssh_chroot_service_name` n'est pas `jail`. |
| `SINCE` | `2 days ago` | Fenêtre des journaux. Tout format accepté par `journalctl --since`. |

```bash
# Cas standard : lancer, puis faire tenter une connexion au client
sshd-jail-diag 203.0.113.10

# Journaux d'une semaine, 5 minutes pour que le client essaie
SINCE="7 days ago" sshd-jail-diag 203.0.113.10 300

# Autre instance du rôle
JAIL_CONFIG=/etc/ssh/sshd_config_sftp sshd-jail-diag 203.0.113.10
```

Le client ne connaît pas son IP publique ? Demande-lui d'ouvrir <https://ifconfig.me>. À défaut, lance `ss -tn 'sport = :22'` pendant qu'il tente de se connecter.

### Sur un serveur où le rôle n'est pas encore déployé

```bash
scp roles/CytadelHosting.ssh-chroot-jail/files/sshd-jail-diag.sh prod:/usr/local/sbin/sshd-jail-diag
ssh prod 'chmod 0750 /usr/local/sbin/sshd-jail-diag && sshd-jail-diag 203.0.113.10'
```

## Ce que fait le script, étape par étape

### 1. Offre du serveur

Le script lance `sshd -T -f $JAIL_CONFIG` et affiche ces valeurs effectives : `port`, `allowgroups`, `loglevel`, `logingracetime`, `maxauthtries`, `persourcepenalties`, `persourcepenaltyexemptlist`, `requiredrsasize`.

Il liste aussi les clés d'hôte présentes, via `ssh-keygen -l` sur les `HostKey`. Le serveur ne propose `rsa-sha2-512` que s'il a une clé RSA, même si `HostKeyAlgorithms` le cite.

Si `sshd -T` refuse la config, le script affiche l'erreur et s'arrête. Le daemon ne démarrerait pas non plus.

Il affiche enfin qui écoute sur le port (`ss -ltnp`). Si ce n'est pas sshd-jail, le client parle à un autre daemon.

### 2. Blocage réseau

- `fail2ban-client banned` : est-ce que l'IP est bannie dans un jail ? Le jail `[sshd]` fourni par Debian bannit le port `ssh`, c'est-à-dire 22, donc le daemon jail. Une IP bannie ne laisse **aucune** trace dans les journaux sshd.
- `nft list ruleset`, `iptables-save`, `ip6tables-save` : est-ce qu'une règle mentionne l'IP ? Le script affiche la règle sans juger si c'est un `accept` ou un `drop`.

### 3. Journaux

Le script lit `journalctl _COMM=sshd _COMM=sshd-session _COMM=sshd-auth`, filtré sur l'IP avec des bornes : `1.2.3.4` ne matche pas `11.2.3.45`. Si le journal ne renvoie rien, il lit `/var/log/auth.log`.

Les trois noms de processus comptent :

| Processus | Depuis | Ce qu'il journalise |
|---|---|---|
| `sshd` | toujours | le listener : acceptation TCP, `drop connection … penalty` |
| `sshd-session` | OpenSSH 9.8 | la connexion : négociation, authentification, session |
| `sshd-auth` | OpenSSH 10.0 | la phase avant authentification |

C'est la raison principale pour laquelle « on ne trouve rien » après une mise à jour : `grep 'sshd\['` ou `journalctl -t sshd` ne voit plus que le listener.

Le script affiche ensuite les 25 dernières lignes et les classe :

| Motif dans le journal | Signification | Correctif |
|---|---|---|
| `penalty`, `drop connection` | PerSourcePenalties : l'IP est bloquée de 15 à 600 s | `sshd_jail_per_source_penalty_exempt_list` ou `sshd_jail_per_source_penalties: 'no'` |
| `Unable to negotiate`, `no matching` | aucun algorithme commun | `sshd_jail_crypto_profile: compatible`, puis `legacy` |
| `ssh-rsa not in`, `key type ssh-rsa` | le client signe en SHA-1 | `legacy`, ou une clé ed25519 côté client |
| `Invalid key length`, `refusing RSA key` | clé RSA plus courte que `RequiredRSASize` (1024) | nouvelle clé côté client |
| `Too many authentication failures` | `MaxAuthTries` atteint : l'agent propose plusieurs clés | `IdentitiesOnly yes` côté client, ou `sshd_jail_max_auth_tries` |
| `Timeout before authentication` | `LoginGraceTime` dépassé | `sshd_jail_login_grace_time` |
| `not allowed because` | `AllowGroups` refuse le compte | ajouter le groupe, ou `sshd_jail_allow_groups_extra` |
| `bad ownership or modes` | droits incorrects (StrictModes ou chroot) | chaîne du chroot en `root:root 0755` |
| `kex_exchange_identification`, `banner exchange` | le client coupe à la bannière | mettre à jour le client |
| `Connection closed/reset … [preauth]` | le client coupe pendant la négociation | lire l'étape 4 |
| `Accepted` | l'authentification a réussi | le problème vient après : chroot, shell, sftp |

Les pénalités se cumulent. Un client derrière un NAT d'entreprise suffit : un collègue qui se trompe de mot de passe, ou une supervision qui ouvre le port sans s'authentifier, et toute l'IP est bloquée.

### 4. Capture du client

```text
tcpdump -i any -c 40 "src host <ip> and tcp dst port <port>"
```

Le script ne capture que le sens client → serveur. Avant l'échange de clés, deux éléments passent **en clair** :

- la bannière du client, qui donne le logiciel et sa version : `SSH-2.0-JSCH-0.1.54`, `SSH-2.0-PuTTY_Release_0.70`, `SSH-2.0-WinSCP_release_5.13`, etc. ;
- son message `KEXINIT`, qui donne ses listes d'algorithmes dans son ordre de préférence.

Le décodeur Python reconstitue le flux TCP, en ignorant les retransmissions. Il lit ces deux éléments et applique la règle SSH : on retient le premier algorithme **du client** que le serveur propose aussi.

Formats de capture pris en charge : Ethernet (avec 802.1Q), Linux cooked SLL et SLL2 (`-i any`), IP brut, loopback.

## Lire le résultat de la capture

```text
--- connexion depuis le port 50001
    logiciel client : SSH-2.0-JSCH-0.1.54
[ KO ] kex        AUCUN algorithme commun
       client  : diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
       serveur : curve25519-sha256,…,diffie-hellman-group-exchange-sha256
[ KO ] hostkey    AUCUN algorithme commun
       client  : ssh-rsa
       serveur : ssh-ed25519,rsa-sha2-512,rsa-sha2-256
[ OK ] cipher     aes128-ctr
[ KO ] mac        AUCUN algorithme commun
       client  : hmac-sha1
[INFO] client sans strict-kex (antérieur au correctif Terrapin, fin 2023)
```

| Sortie | Conclusion | Action |
|---|---|---|
| `aucun paquet de <ip>` | rien n'arrive au serveur | mauvaise IP (NAT, IPv6), pare-feu en amont, ban fail2ban |
| `paquets reçus mais sans données` | TCP s'ouvre, le client n'envoie rien | ce n'est pas un client SSH, ou un proxy est entre les deux |
| `pas de bannière SSH` | des données, mais pas du SSH | proxy HTTP, mauvais protocole configuré chez le client |
| `bannière reçue, pas de KEXINIT` | le client coupe après avoir lu la bannière du serveur | client qui interprète mal `OpenSSH_10.0` : le mettre à jour |
| `[ KO ] kex` | échange de clés impossible | `sshd_jail_crypto_profile: compatible` (modp sha256), sinon `legacy` (group14-sha1) |
| `[ KO ] hostkey` sur `ssh-rsa` seul | le client ne vérifie l'hôte qu'en SHA-1 | `legacy` |
| `[ KO ] cipher` sur `*-cbc` | client sans CTR ni GCM | `legacy` |
| `[ KO ] mac` sur `hmac-sha1` | client sans SHA-2 | `legacy` |
| `[INFO] … strict-kex` | client ancien, mais la connexion peut marcher | aucune, information seulement |
| tout `[ OK ]` | la négociation passe | l'échec vient après le chiffrement : lire l'étape 3 |

Le profil `legacy` ajoute ces algorithmes pour tous les clients du daemon. Si un seul client est concerné, mieux vaut une surcharge ciblée, par exemple `sshd_jail_kex_algorithms: '+diffie-hellman-group14-sha1'`. Encore mieux : mettre à jour le client.

## Limites

- Tout ce qui suit `NEWKEYS` est chiffré : l'algorithme de la clé utilisateur, l'authentification, la session. Pour ces étapes, il ne reste que les journaux.
- Le parseur IPv6 ne gère pas les en-têtes d'extension. Un client IPv6 qui en utilise s'affiche comme `sans données`.
- Seuls les 40 premiers paquets sont capturés. Si le client se reconnecte en boucle, plusieurs connexions apparaissent, une par port source.
- La lecture des journaux repose sur les messages d'OpenSSH. Un motif inconnu donne `aucun motif connu` : les 25 dernières lignes restent affichées au-dessus.
