#!/usr/bin/env bash
# =============================================================================
# sshd-jail-diag : pourquoi un client n'arrive pas à se connecter au sshd jail
# =============================================================================
# Usage : sshd-jail-diag <ip_client> [durée_capture_s]
#   JAIL_CONFIG=/etc/ssh/sshd_config_jail  config du daemon jail
#   SINCE="2 days ago"                     fenêtre des journaux
#
# 1. Ce que le serveur propose réellement (sshd -T + clés d'hôte présentes)
# 2. Blocages silencieux : fail2ban, nftables/iptables, PerSourcePenalties
# 3. Journaux sshd / sshd-session / sshd-auth filtrés sur l'IP
#    (depuis OpenSSH 9.8, les connexions ne loggent plus sous "sshd[")
# 4. Capture des premiers paquets du client : bannière + KEXINIT en clair,
#    comparés à l'offre serveur. Aucun log client nécessaire.
#
# Lecture des résultats : docs/sshd-jail-diag.md du rôle CytadelHosting.ssh-chroot-jail
# =============================================================================
set -euo pipefail

readonly GREEN=$'\e[32m' RED=$'\e[31m' YELLOW=$'\e[33m' BOLD=$'\e[1m' RESET=$'\e[0m'
readonly JAIL_CONFIG="${JAIL_CONFIG:-/etc/ssh/sshd_config_jail}"
readonly SINCE="${SINCE:-2 days ago}"

ok()    { printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
ko()    { printf '%s[ KO ]%s %s\n' "$RED" "$RESET" "$*"; }
title() { printf '\n%s== %s ==%s\n' "$BOLD" "$*" "$RESET"; }

client_ip="${1:-}"
capture_seconds="${2:-180}"

if [[ -z "$client_ip" ]]; then
    echo "Usage : $0 <ip_client> [durée_capture_s]" >&2
    exit 2
fi
if [[ $EUID -ne 0 ]]; then
    ko "à lancer en root (lecture des clés d'hôte, journaux, capture)"
    exit 1
fi
if [[ ! -r "$JAIL_CONFIG" ]]; then
    ko "config introuvable : $JAIL_CONFIG (variable JAIL_CONFIG)"
    exit 1
fi

work_dir=$(mktemp -d /tmp/sshd-jail-diag.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT

# IP en regex, bornée : 1.2.3.4 ne doit pas matcher 11.2.3.45
client_ip_regex="(^|[^0-9a-fA-F.:])${client_ip//./\\.}([^0-9a-fA-F.:]|$)"

# -----------------------------------------------------------------------------
# 1. Offre serveur effective
# -----------------------------------------------------------------------------
title "Serveur"
ssh -V 2>&1 | sed 's/^/    /'

if ! effective_config=$(sshd -T -f "$JAIL_CONFIG" 2>&1); then
    ko "sshd -T refuse la config :"
    printf '%s\n' "$effective_config" | sed 's/^/    /'
    exit 1
fi

config_value() {
    awk -v key="$1" '$1 == key { $1 = ""; sub(/^ /, ""); print; exit }' <<<"$effective_config"
}

jail_port=$(config_value port)
for key in port allowgroups loglevel logingracetime maxauthtries persourcepenalties persourcepenaltyexemptlist requiredrsasize; do
    value=$(config_value "$key")
    printf '    %-28s %s\n' "$key" "${value:-(absent : OpenSSH < 9.8 ou non applicable)}"
done

# Le serveur n'annonce un algo d'hôte que s'il possède la clé correspondante
hostkey_types=()
while read -r hostkey_file; do
    if [[ -r "${hostkey_file}.pub" ]]; then
        hostkey_types+=("$(ssh-keygen -l -f "${hostkey_file}.pub" | awk '{ gsub(/[()]/, "", $NF); print $NF }')")
    fi
done < <(awk '$1 == "hostkey" { print $2 }' <<<"$effective_config")
printf '    %-28s %s\n' "clés d'hôte présentes" "${hostkey_types[*]:-aucune}"

{
    echo "kexalgorithms $(config_value kexalgorithms)"
    echo "hostkeyalgorithms $(config_value hostkeyalgorithms)"
    echo "ciphers $(config_value ciphers)"
    echo "macs $(config_value macs)"
    echo "hostkeytypes $(IFS=,; echo "${hostkey_types[*]}")"
} >"$work_dir/server.txt"

title "Qui écoute sur le port $jail_port"
ss -H -ltnp "sport = :$jail_port" | sed 's/^/    /' || true

# -----------------------------------------------------------------------------
# 2. Blocages silencieux : rien dans les logs sshd si la connexion n'arrive pas
# -----------------------------------------------------------------------------
title "Blocage réseau"
if command -v fail2ban-client >/dev/null 2>&1; then
    if fail2ban-client banned 2>/dev/null | grep -qF -- "'$client_ip'"; then
        ko "fail2ban bannit $client_ip :"
        fail2ban-client banned | tr '{' '\n' | grep -F -- "'$client_ip'" | sed 's/^/    /'
        echo "    -> fail2ban-client unban $client_ip, puis ignoreip si c'est un client légitime"
    else
        ok "fail2ban : $client_ip non banni"
    fi
else
    ok "fail2ban absent"
fi

firewall_hits=$( { nft list ruleset 2>/dev/null; iptables-save 2>/dev/null; ip6tables-save 2>/dev/null; } \
    | grep -E -- "$client_ip_regex" || true)
if [[ -n "$firewall_hits" ]]; then
    warn "$client_ip apparaît dans le pare-feu (règle allow ou drop, à lire) :"
    printf '%s\n' "$firewall_hits" | sed 's/^/    /'
else
    ok "pare-feu local : aucune règle sur $client_ip"
fi

# -----------------------------------------------------------------------------
# 3. Journaux : sshd (listener), sshd-session et sshd-auth (OpenSSH >= 9.8 / 10)
# -----------------------------------------------------------------------------
title "Journaux depuis '$SINCE' pour $client_ip"
log_lines=$(journalctl --since "$SINCE" --no-pager -o short-iso \
    _COMM=sshd _COMM=sshd-session _COMM=sshd-auth 2>/dev/null \
    | grep -E -- "$client_ip_regex" || true)
if [[ -z "$log_lines" && -r /var/log/auth.log ]]; then
    log_lines=$(grep -E -- "$client_ip_regex" /var/log/auth.log | grep -E 'sshd(-session|-auth)?\[' || true)
fi

if [[ -z "$log_lines" ]]; then
    warn "aucune ligne sshd pour $client_ip : la connexion n'atteint pas sshd (IP source, NAT, IPv6, pare-feu amont)"
else
    printf '%s\n' "$log_lines" | tail -n 25 | sed 's/^/    /'

    # motif | diagnostic | correctif côté rôle
    diagnostics=(
        'penalty|drop connection|PerSourcePenalties : IP bloquée temporairement (NAT partagé, clés multiples, grace dépassée)|sshd_jail_per_source_penalty_exempt_list ou sshd_jail_per_source_penalties'
        'Unable to negotiate|no matching|aucun algorithme commun|sshd_jail_crypto_profile: compatible puis legacy'
        'ssh-rsa not in|key type ssh-rsa|signature SHA-1 (ssh-rsa) refusée|sshd_jail_crypto_profile: legacy ou clé ed25519 côté client'
        'Invalid key length|refusing RSA key|clé RSA trop courte (< RequiredRSASize)|nouvelle clé côté client'
        'Too many authentication failures|maximum authentication attempts|MaxAuthTries 3 atteint (agent avec plusieurs clés)|IdentitiesOnly côté client ou sshd_jail_max_auth_tries'
        'Timeout before authentication|LoginGraceTime dépassé|sshd_jail_login_grace_time'
        'not allowed because|AllowGroups / DenyUsers refuse le compte|sshd_jail_allow_groups_extra ou groupe jail'
        'bad ownership or modes|StrictModes / ChrootDirectory : droits incorrects|chown root, chmod 755 sur la chaîne de chroot'
        'kex_exchange_identification|banner exchange|le client coupe à la bannière (ex : parseur de version qui lit OpenSSH_10 comme 1.x)|mise à jour du client'
        'Connection (closed|reset) by .*preauth|le client coupe en négociation : voir la capture ci-dessous|-'
        'Accepted |authentification OK : le problème est après (chroot, shell, sftp)|journal complet de la session'
    )
    title "Lecture"
    found_pattern=false
    for entry in "${diagnostics[@]}"; do
        IFS='|' read -r -a parts <<<"$entry"
        pattern_count=$(( ${#parts[@]} - 2 ))
        pattern=$(IFS='|'; echo "${parts[*]:0:$pattern_count}")
        hits=$(grep -cE -- "$pattern" <<<"$log_lines" || true)
        if (( hits > 0 )); then
            found_pattern=true
            ko "${hits}x ${parts[$pattern_count]}"
            echo "    -> ${parts[$((pattern_count + 1))]}"
        fi
    done
    [[ "$found_pattern" == true ]] || ok "aucun motif connu"
fi

# -----------------------------------------------------------------------------
# 4. Capture : bannière et KEXINIT du client (non chiffrés)
# -----------------------------------------------------------------------------
title "Capture du client ($capture_seconds s max)"
if ! command -v tcpdump >/dev/null 2>&1; then
    warn "tcpdump absent : apt install tcpdump, puis relancer"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 absent : capture impossible à décoder"
    exit 0
fi

echo "    ${BOLD}Fais tenter une connexion au client maintenant.${RESET}"
# -Z root : sans ça tcpdump perd ses droits avant d'écrire dans le répertoire temporaire
timeout "$capture_seconds" tcpdump -i any -nn -s 0 -U -Z root -c 40 \
    -w "$work_dir/client.pcap" "src host $client_ip and tcp dst port $jail_port" 2>/dev/null || true

if [[ ! -s "$work_dir/client.pcap" ]]; then
    ko "aucun paquet de $client_ip vers le port $jail_port"
    echo "    -> le client sort par une autre IP (NAT, IPv6) ou un pare-feu amont le coupe"
    exit 0
fi

python3 - "$work_dir/client.pcap" "$work_dir/server.txt" <<'PYTHON'
"""Extrait bannière et KEXINIT du client depuis un pcap, compare à l'offre serveur."""
import struct
import sys

GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
PSEUDO_ALGOS = ("ext-info-c", "kex-strict-c-v00@openssh.com")
AEAD_CIPHERS = ("chacha20-poly1305@openssh.com", "aes128-gcm@openssh.com", "aes256-gcm@openssh.com")
NAME_LISTS = ("kex", "hostkey", "cipher_c2s", "cipher_s2c", "mac_c2s", "mac_s2c", "comp_c2s", "comp_s2c")
HOSTKEY_TYPE_PREFIX = {"ED25519": ("ssh-ed25519",), "RSA": ("rsa-sha2-", "ssh-rsa"), "ECDSA": ("ecdsa-sha2-",)}


def load_server(path):
    server = {}
    with open(path) as handle:
        for line in handle:
            key, _, value = line.strip().partition(" ")
            server[key] = [algo for algo in value.split(",") if algo]
    # Pas d'algo -cert sans HostCertificate ; pas d'algo sans la clé correspondante
    prefixes = tuple(p for t in server.get("hostkeytypes", []) for p in HOSTKEY_TYPE_PREFIX.get(t, ()))
    server["hostkey_offered"] = [
        a for a in server.get("hostkeyalgorithms", []) if "-cert-" not in a and a.startswith(prefixes)
    ]
    return server


def layer3_offset(linktype, packet):
    if linktype == 1:  # Ethernet (+ 802.1Q)
        offset, ethertype = 14, struct.unpack(">H", packet[12:14])[0]
        while ethertype == 0x8100:
            ethertype = struct.unpack(">H", packet[offset + 2:offset + 4])[0]
            offset += 4
        return offset
    return {113: 16, 276: 20, 101: 0, 12: 0, 0: 4}.get(linktype)  # SLL, SLL2, raw, raw, loopback


def read_tcp_streams(path):
    data = open(path, "rb").read()
    if data[:4] in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        endian = "<"
    elif data[:4] in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        endian = ">"
    else:
        sys.exit("capture illisible (format pcap attendu)")
    linktype = struct.unpack(endian + "I", data[20:24])[0] & 0x0FFFFFFF
    streams, position = {}, 24
    while position + 16 <= len(data):
        captured_length = struct.unpack(endian + "I", data[position + 8:position + 12])[0]
        packet = data[position + 16:position + 16 + captured_length]
        position += 16 + captured_length
        l3 = layer3_offset(linktype, packet)
        if l3 is None or len(packet) <= l3:
            continue
        ip_version = packet[l3] >> 4
        if ip_version == 4:
            l4, protocol = l3 + (packet[l3] & 0x0F) * 4, packet[l3 + 9]
        elif ip_version == 6:
            l4, protocol = l3 + 40, packet[l3 + 6]
        else:
            continue
        if protocol != 6 or len(packet) < l4 + 20:
            continue
        source_port = struct.unpack(">H", packet[l4:l4 + 2])[0]
        sequence = struct.unpack(">I", packet[l4 + 4:l4 + 8])[0]
        payload = packet[l4 + (packet[l4 + 12] >> 4) * 4:]
        if payload:
            streams.setdefault(source_port, {}).setdefault(sequence, payload)
    return streams


def reassemble(segments):
    stream, expected = b"", None
    for sequence in sorted(segments):
        chunk = segments[sequence]
        if expected is not None:
            if sequence > expected:
                break  # segment manquant : on s'arrête là
            chunk = chunk[expected - sequence:]
        stream += chunk
        expected = (sequence if expected is None else expected) + len(chunk)
    return stream


def parse_client(stream):
    start = stream.find(b"SSH-")
    if start < 0:
        return None, None
    end = stream.find(b"\n", start)
    if end < 0:
        return stream[start:].decode(errors="replace"), None
    banner = stream[start:end].rstrip(b"\r").decode(errors="replace")
    packet = stream[end + 1:]
    if len(packet) < 22 or packet[5] != 20:  # SSH_MSG_KEXINIT
        return banner, None
    position, lists = 22, {}
    for name in NAME_LISTS:
        if position + 4 > len(packet):
            return banner, None
        length = struct.unpack(">I", packet[position:position + 4])[0]
        lists[name] = packet[position + 4:position + 4 + length].decode(errors="replace").split(",")
        position += 4 + length
    return banner, lists


def first_common(client_algos, server_algos):
    return next((a for a in client_algos if a in server_algos and a not in PSEUDO_ALGOS), None)


def report(label, client_algos, server_algos):
    chosen = first_common(client_algos, server_algos)
    if chosen:
        print(f"{GREEN}[ OK ]{RESET} {label:<10} {chosen}")
    else:
        print(f"{RED}[ KO ]{RESET} {label:<10} AUCUN algorithme commun")
        print(f"       client  : {','.join(a for a in client_algos if a not in PSEUDO_ALGOS)}")
        print(f"       serveur : {','.join(server_algos)}")
    return chosen


server = load_server(sys.argv[2])
streams = read_tcp_streams(sys.argv[1])
if not streams:
    print(f"{RED}[ KO ]{RESET} paquets reçus mais sans données : le client ouvre TCP puis abandonne avant sa bannière")
    sys.exit(0)

for source_port, segments in streams.items():
    banner, lists = parse_client(reassemble(segments))
    print(f"\n--- connexion depuis le port {source_port}")
    if banner is None:
        print(f"{RED}[ KO ]{RESET} pas de bannière SSH : ce n'est pas un client SSH, ou il parle à travers un proxy")
        continue
    print(f"    logiciel client : {banner}")
    if lists is None:
        print(f"{YELLOW}[WARN]{RESET} bannière reçue, pas de KEXINIT : le client coupe après avoir lu la bannière serveur")
        print("       -> typique d'un client qui parse mal 'OpenSSH_10.0' : seule issue, le mettre à jour")
        continue
    report("kex", lists["kex"], server.get("kexalgorithms", []))
    report("hostkey", lists["hostkey"], server["hostkey_offered"])
    cipher = report("cipher", lists["cipher_c2s"], server.get("ciphers", []))
    if cipher in AEAD_CIPHERS:
        print(f"{GREEN}[ OK ]{RESET} {'mac':<10} implicite ({cipher} est AEAD)")
    else:
        report("mac", lists["mac_c2s"], server.get("macs", []))
    if "kex-strict-c-v00@openssh.com" not in lists["kex"]:
        print(f"{YELLOW}[INFO]{RESET} client sans strict-kex (antérieur au correctif Terrapin, fin 2023)")
PYTHON

echo
echo "    Négociation OK partout mais échec quand même : regarder la partie Journaux"
echo "    (pénalités, clé refusée, groupe, chroot). Elle se joue après le chiffrement."
