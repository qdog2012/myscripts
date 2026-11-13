#!/usr/bin/env bash
# Debian 12: 1Panel, Docker, OpenResty, Trojan, Node.js, XFCE, Chrome, and TigerVNC.
set -Eeuo pipefail
umask 077

PANEL_VERSION=v1.10.34-lts
PANEL_PORT=${PANEL_PORT:-8080}
PANEL_ENTRANCE=admin
PANEL_BASE_DIR=/serverdata
PANEL_DATA_DIR=$PANEL_BASE_DIR/1panel
NODE_VERSION=v24.21.0
NODE_INSTALL_DIR=$PANEL_BASE_DIR/node
NODE_BASHRC_FILE=/etc/bash.bashrc
NODE_SHA256=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
NODE_STAGE_DIR=
OPENRESTY_HTTPS_PORT=18443
STREAM_CONFIG_DIR=$PANEL_DATA_DIR/www/stream.d
INSTALL_DOCKER=${INSTALL_DOCKER:-1}
INSTALL_OPENRESTY=${INSTALL_OPENRESTY:-$INSTALL_DOCKER}
INSTALL_TROJAN=${INSTALL_TROJAN:-1}
TROJAN_PORT=${TROJAN_PORT:-8443}
TROJAN_DOMAIN=
TROJAN_PASSWORD=
TROJAN_CREDENTIALS_FILE=/root/.config/debian12-init/trojan
TROJAN_TLS_DIR=/etc/trojan/tls
SERVER_TIMEZONE=${SERVER_TIMEZONE:-auto}
DATE_LOCALE=${DATE_LOCALE:-auto}
DESKTOP_USER=${DESKTOP_USER:-desktop}
VNC_DISPLAY=:1
VNC_PORT=5901
VNC_GEOMETRY=${VNC_GEOMETRY:-1680x1050}
SSH_PORT=2424
CREDENTIALS_FILE=/root/.config/debian12-init/credentials
WORK_DIR=

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
    if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi
    if [[ -n $NODE_STAGE_DIR && -d $NODE_STAGE_DIR ]]; then rm -rf -- "$NODE_STAGE_DIR"; fi
}
trap cleanup EXIT

activate_public_dns() {
    systemctl enable --now systemd-resolved.service
    systemctl restart systemd-resolved.service
    [[ -f /run/systemd/resolve/stub-resolv.conf ]] || die 'systemd-resolved did not create its DNS stub configuration.'
    ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    systemctl is-active --quiet systemd-resolved.service || die 'systemd-resolved is not active.'
    systemctl is-enabled --quiet systemd-resolved.service || die 'systemd-resolved is not enabled at boot.'
}

rewrite_ssh_port() {
    python3 - "$@" <<'SSH_CONFIG_PYTHON'
import glob
import json
from pathlib import Path
import re
import shlex
import shutil
import sys

mode, main, backup, port = sys.argv[1:]
include_base = Path(main).absolute().parent
main, backup = Path(main).resolve(), Path(backup)
manifest = backup / 'manifest.json'
if mode == 'restore':
    if manifest.exists():
        for item in json.loads(manifest.read_text()):
            shutil.copyfile(backup / item['backup'], item['path'])
    raise SystemExit(0)

files = {}
directive = re.compile(r'^\s*([A-Za-z]+)(?:\s*=\s*|\s+)(.*?)\s*$')
marker = '# debian12-init SSH port\n'


def read_config(path):
    path = path.resolve()
    if path in files:
        return
    text = path.read_text()
    files[path] = text
    for line in text.splitlines():
        match = directive.match(line)
        if match and match[1].lower() == 'match':
            criteria = shlex.split(match[2], comments=True)
            for index in range(0, len(criteria), 2):
                if criteria[index].lower() == 'localport' and criteria[index + 1] != port:
                    raise SystemExit(
                        f'{path}: Match LocalPort policy needs manual migration '
                        f'before switching SSH to {port}; SSH configs were not changed.')
        if match and match[1].lower() == 'include':
            for pattern in shlex.split(match[2], comments=True):
                pattern = Path(pattern)
                if not pattern.is_absolute():
                    pattern = include_base / pattern
                for included in sorted(glob.glob(str(pattern))):
                    read_config(Path(included))


read_config(main)
changes = {}
for path, original in files.items():
    text = original
    if path == main and text.startswith(marker):
        text = text[len(marker):].split('\n', 1)[1].lstrip('\n')
    lines = []
    for line in text.splitlines(keepends=True):
        match = directive.match(line)
        key = match[1].lower() if match else ''
        if key == 'port':
            line = '# debian12-init disabled old port: ' + line.lstrip()
        elif key == 'listenaddress':
            tokens = shlex.split(match[2], comments=True)
            address = tokens[0]
            if re.fullmatch(r'\[[^\]]+\]:[0-9]+', address) or re.fullmatch(r'[^:]+:[0-9]+', address):
                tokens[0] = address.rsplit(':', 1)[0] + ':' + port
                line = 'ListenAddress ' + ' '.join(tokens) + '\n'
        lines.append(line)
    updated = ''.join(lines)
    if path == main:
        updated = marker + 'Port ' + port + '\n\n' + updated
    if updated != original:
        changes[path] = updated

# Prepare every backup before writing any config, including files outside the
# usual config.d directory that are reached through Include directives.
backup.mkdir(parents=True, mode=0o700, exist_ok=True)
records = []
for index, path in enumerate(changes):
    name = f'{index}.conf'
    shutil.copy2(path, backup / name)
    records.append({'path': str(path), 'backup': name})
manifest.write_text(json.dumps(records, indent=2) + '\n')
for path, updated in changes.items():
    path.write_text(updated)
SSH_CONFIG_PYTHON
}

configure_ssh_port() {
    local config=/etc/ssh/sshd_config backup ready=0 ssh_pid
    local service_active=0 service_enabled=0 socket_active=0 socket_enabled=0 socket_loaded=0
    log "Configuring SSH on TCP $SSH_PORT; allow this port in the cloud security group and local firewall"
    install -d -m 755 /run/sshd
    /usr/sbin/sshd -t || die 'Existing SSH config is invalid; correct it before changing the port.'
    [[ -n $WORK_DIR ]] || WORK_DIR=$(mktemp -d /tmp/debian12-init.XXXXXXXX)
    backup="/root/.config/debian12-init/ssh-backup-$(date +%Y%m%d-%H%M%S)-$$"
    install -d -m 700 "$backup"
    if systemctl is-active --quiet ssh.service; then service_active=1; fi
    if systemctl is-enabled --quiet ssh.service; then service_enabled=1; fi
    if [[ $(systemctl show -p LoadState --value ssh.socket) == loaded ]]; then
        socket_loaded=1
        if systemctl is-active --quiet ssh.socket; then socket_active=1; fi
        if systemctl is-enabled --quiet ssh.socket; then socket_enabled=1; fi
    fi
    if [[ $socket_active == 1 && $service_active == 1 ]]; then
        [[ $(systemctl show -p KillMode --value ssh.service) == process ]] ||
            die 'Socket-activated SSH migration requires ssh.service KillMode=process to preserve current sessions.'
    fi
    if rewrite_ssh_port configure "$config" "$backup" "$SSH_PORT" &&
       /usr/sbin/sshd -t && /usr/sbin/sshd -T > "$WORK_DIR/ssh-effective.conf" &&
       awk -v port="$SSH_PORT" '
           $1 == "port" { found=1; if ($2 != port) bad=1 }
           $1 == "listenaddress" && $2 !~ (":" port "$") { bad=1 }
           END { exit (!found || bad) }
       ' "$WORK_DIR/ssh-effective.conf" &&
       { [[ $socket_loaded == 0 ]] || systemctl disable --now ssh.socket; } &&
       systemctl enable ssh.service &&
       { if [[ $service_active == 1 && $socket_active == 0 ]]; then
             systemctl reload ssh.service
         elif [[ $service_active == 1 ]]; then
             # Drop inherited socket FDs; Debian's KillMode=process leaves all
             # established SSH session processes running during this restart.
             systemctl restart ssh.service
         else
             systemctl start ssh.service
         fi; }; then
        for _ in {1..15}; do
            ssh_pid=$(systemctl show -p MainPID --value ssh.service)
            if systemctl is-active --quiet ssh.service &&
               systemctl is-enabled --quiet ssh.service &&
               ss -ltnpH | awk -v pid="$ssh_pid" -v port="$SSH_PORT" '
                   $0 ~ ("pid=" pid ",") { found=1; if ($4 !~ (":" port "$")) bad=1 }
                   END { exit (!found || bad) }
               '; then
                ready=1
                break
            fi
            sleep 1
        done
    fi
    if [[ $ready != 1 ]]; then
        log 'SSH port change failed; restoring the previous configuration'
        rewrite_ssh_port restore "$config" "$backup" "$SSH_PORT"
        if /usr/sbin/sshd -t; then
            if [[ $socket_active == 1 ]]; then
                systemctl stop ssh.service || true
                systemctl start ssh.socket || true
                if [[ $service_active == 1 ]]; then systemctl start ssh.service || true; fi
            elif [[ $service_active == 1 ]]; then
                systemctl reload ssh.service || systemctl start ssh.service || true
            else
                systemctl stop ssh.service || true
            fi
        fi
        if [[ $service_enabled == 0 ]]; then systemctl disable ssh.service || true; fi
        if [[ $socket_enabled == 1 ]]; then systemctl enable ssh.socket || true; fi
        journalctl -u ssh.service -n 20 --no-pager >&2
        die "SSH port change failed; backups are at $backup. Check /etc/default/ssh and systemd overrides for command-line port settings."
    fi
    log "SSH is listening on TCP $SSH_PORT and enabled at boot; current SSH sessions remain connected"
    log "SSH config backups: $backup"
}

ensure_chrome_key() {
    if [[ -s /usr/share/keyrings/google-chrome.gpg ]] &&
       gpg --batch --quiet --show-keys /usr/share/keyrings/google-chrome.gpg >/dev/null 2>&1; then
        return
    fi
    [[ -n $WORK_DIR ]] || WORK_DIR=$(mktemp -d /tmp/debian12-init.XXXXXXXX)
    curl -4 --http1.1 -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
        -o "$WORK_DIR/google-linux-signing-key.pub" \
        https://dl.google.com/linux/linux_signing_key.pub
    gpg --batch --yes --dearmor -o "$WORK_DIR/google-chrome.gpg" "$WORK_DIR/google-linux-signing-key.pub"
    install -m 644 "$WORK_DIR/google-chrome.gpg" /usr/share/keyrings/google-chrome.gpg
}

install_node() {
    local package="node-${NODE_VERSION}-linux-x64.tar.xz" staged_node backup_dir= path_line
    if [[ -x $NODE_INSTALL_DIR/bin/node ]] &&
       [[ $("$NODE_INSTALL_DIR/bin/node" --version 2>/dev/null) == "$NODE_VERSION" ]]; then
        log "Keeping existing Node.js $NODE_VERSION at $NODE_INSTALL_DIR"
    else
        log "Installing Node.js $NODE_VERSION"
        [[ -d $PANEL_BASE_DIR ]] || install -d -m 755 "$PANEL_BASE_DIR"
        NODE_STAGE_DIR=$(mktemp -d "$PANEL_BASE_DIR/.node-install.XXXXXXXX")
        curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 \
            -o "$NODE_STAGE_DIR/$package" "https://nodejs.org/dist/$NODE_VERSION/$package"
        printf '%s  %s\n' "$NODE_SHA256" "$NODE_STAGE_DIR/$package" | sha256sum --check --status ||
            die 'Node.js SHA-256 verification failed.'
        tar -xJf "$NODE_STAGE_DIR/$package" --no-same-owner -C "$NODE_STAGE_DIR"
        staged_node="$NODE_STAGE_DIR/node-${NODE_VERSION}-linux-x64"
        [[ -x $staged_node/bin/node &&
           $("$staged_node/bin/node" --version) == "$NODE_VERSION" ]] || die 'Unexpected Node.js archive contents.'
        "$staged_node/bin/node" "$staged_node/lib/node_modules/npm/bin/npm-cli.js" --version

        if [[ -e $NODE_INSTALL_DIR || -L $NODE_INSTALL_DIR ]]; then
            backup_dir="$NODE_INSTALL_DIR.backup-$(date +%Y%m%d-%H%M%S)-$$"
            [[ ! -e $backup_dir && ! -L $backup_dir ]] || die "Backup path already exists: $backup_dir"
            mv -T -- "$NODE_INSTALL_DIR" "$backup_dir"
        fi
        if ! mv -T -- "$staged_node" "$NODE_INSTALL_DIR"; then
            if [[ -n $backup_dir && ! -e $NODE_INSTALL_DIR && ! -L $NODE_INSTALL_DIR ]]; then
                mv -T -- "$backup_dir" "$NODE_INSTALL_DIR"
            fi
            die "Could not install Node.js at $NODE_INSTALL_DIR."
        fi
        [[ -z $backup_dir ]] || log "Previous Node.js installation preserved at $backup_dir"
        rm -rf -- "$NODE_STAGE_DIR"
        NODE_STAGE_DIR=
    fi

    path_line="export PATH=\"$NODE_INSTALL_DIR/bin:\$PATH\""
    if ! grep -Fqx "$path_line" "$NODE_BASHRC_FILE"; then
        printf '\n# debian12-init Node.js\n%s\n' "$path_line" >> "$NODE_BASHRC_FILE"
    fi
    export PATH="$NODE_INSTALL_DIR/bin:$PATH"
    hash -r
    [[ $(node --version) == "$NODE_VERSION" ]] || die 'Node.js is not available through PATH.'
    npm --version
}

valid_trojan_domain() {
    local domain=$1 label
    local -a labels
    [[ ${#domain} -le 253 && $domain == *.* && $domain != *..* &&
       $domain != .* && $domain != *. && ${domain##*.} =~ [a-z] ]] || return 1
    IFS=. read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ $label =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
    done
}

prompt_trojan_domain() {
    [[ $INSTALL_TROJAN == 1 ]] || return 0
    local input_fd answer prompt
    if [[ -e $TROJAN_CREDENTIALS_FILE ]]; then
        [[ $(stat -c '%u:%a' "$TROJAN_CREDENTIALS_FILE") == "$EUID:600" ]] ||
            die "$TROJAN_CREDENTIALS_FILE must be owned by root with mode 600."
        # shellcheck source=/dev/null
        source "$TROJAN_CREDENTIALS_FILE"
        valid_trojan_domain "$TROJAN_DOMAIN" || die 'Invalid saved Trojan domain.'
        [[ $TROJAN_PASSWORD =~ ^[0-9a-f]{48}$ ]] || die 'Invalid saved Trojan password.'
    fi
    if [[ -t 0 ]]; then
        input_fd=0
    elif ! { exec {input_fd}</dev/tty; } 2>/dev/null; then
        die 'Trojan domain input requires a terminal. Download the script, then run bash debian12-init.sh interactively (or set INSTALL_TROJAN=0).'
    fi
    printf '\nTrojan 使用自签证书，监听 TCP %s。请将域名解析到本机，并放行该端口。\n' "$TROJAN_PORT"
    while true; do
        prompt='请输入 Trojan 域名（不含 https://、端口或路径）'
        [[ -z $TROJAN_DOMAIN ]] || prompt+=" [$TROJAN_DOMAIN]"
        if ! read -r -u "$input_fd" -p "$prompt: " answer; then
            die 'Trojan domain input cancelled; installation has not started.'
        fi
        answer=${answer:-$TROJAN_DOMAIN}
        answer=${answer,,}
        answer=${answer%.}
        if valid_trojan_domain "$answer"; then
            TROJAN_DOMAIN=$answer
            break
        fi
        printf '域名无效，请输入完整域名；不能使用 IP、URL 或通配符。\n' >&2
    done
    if [[ $input_fd != 0 ]]; then exec {input_fd}<&-; fi
    log "Trojan domain: $TROJAN_DOMAIN; TCP port: $TROJAN_PORT"
}

save_trojan_credentials() {
    [[ -n $TROJAN_PASSWORD ]] || TROJAN_PASSWORD=$(openssl rand -hex 24)
    install -d -m 700 "$(dirname -- "$TROJAN_CREDENTIALS_FILE")"
    printf 'TROJAN_DOMAIN=%q\nTROJAN_PASSWORD=%q\n' \
        "$TROJAN_DOMAIN" "$TROJAN_PASSWORD" > "$TROJAN_CREDENTIALS_FILE"
    chmod 600 "$TROJAN_CREDENTIALS_FILE"
}

generate_trojan_certificate() {
    local cert="$TROJAN_TLS_DIR/server.crt" key="$TROJAN_TLS_DIR/server.key" backup common_name=$TROJAN_DOMAIN
    install -d -m 700 "$TROJAN_TLS_DIR"
    if [[ -s $cert && -s $key ]] &&
       openssl x509 -in "$cert" -noout -checkend 2592000 >/dev/null 2>&1 &&
       openssl verify -CAfile "$cert" -verify_hostname "$TROJAN_DOMAIN" "$cert" >/dev/null 2>&1 &&
       [[ $(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null) == \
          "$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null)" ]]; then
        chmod 600 "$cert" "$key"
        log "Keeping the existing self-signed Trojan certificate for $TROJAN_DOMAIN"
        return
    fi
    log "Generating a self-signed Trojan certificate for $TROJAN_DOMAIN (3650 days)"
    [[ -n $WORK_DIR ]] || WORK_DIR=$(mktemp -d /tmp/debian12-init.XXXXXXXX)
    # X.509 common names are limited to 64 bytes; SAN carries the full domain.
    (( ${#common_name} <= 64 )) || common_name='Trojan server'
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -keyout "$WORK_DIR/trojan-server.key" -out "$WORK_DIR/trojan-server.crt" \
        -subj "/CN=$common_name" -addext "subjectAltName=DNS:$TROJAN_DOMAIN" \
        -addext 'basicConstraints=critical,CA:FALSE' \
        -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
        -addext 'extendedKeyUsage=serverAuth' 2> "$WORK_DIR/trojan-cert.log" || {
            cat "$WORK_DIR/trojan-cert.log" >&2
            die 'Could not generate the self-signed Trojan certificate.'
        }
    if [[ -e $cert || -e $key ]]; then
        backup="$TROJAN_TLS_DIR/backup-$(date +%Y%m%d-%H%M%S)-$$"
        install -d -m 700 "$backup"
        [[ ! -e $cert ]] || cp -a -- "$cert" "$backup/server.crt"
        [[ ! -e $key ]] || cp -a -- "$key" "$backup/server.key"
        log "Previous Trojan certificate and key preserved at $backup"
    fi
    install -m 600 "$WORK_DIR/trojan-server.crt" "$cert"
    install -m 600 "$WORK_DIR/trojan-server.key" "$key"
}

write_trojan_config() {
    local config=$1 dropin=$2
    install -d -m 755 "$(dirname -- "$config")" "$(dirname -- "$dropin")"
    cat > "$config" <<EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": $TROJAN_PORT,
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "password": ["$TROJAN_PASSWORD"],
    "log_level": 1,
    "ssl": {
        "cert": "/run/credentials/trojan.service/fullchain.pem",
        "key": "/run/credentials/trojan.service/privkey.pem",
        "alpn": ["http/1.1"]
    }
}
EOF
    chmod 600 "$config"
    # The Debian service runs as nobody. systemd supplies private copies of the
    # config and certificate files without opening up the private key.
    cat > "$dropin" <<EOF
[Service]
LoadCredential=config.json:$config
LoadCredential=fullchain.pem:$TROJAN_TLS_DIR/server.crt
LoadCredential=privkey.pem:$TROJAN_TLS_DIR/server.key
ExecStart=
ExecStart=/usr/bin/trojan %d/config.json
EOF
    chmod 644 "$dropin"
}

install_trojan() {
    [[ $INSTALL_TROJAN == 1 ]] || return 0
    local tls_ready=0
    log "Installing Trojan with self-signed TLS for $TROJAN_DOMAIN:$TROJAN_PORT"
    if command -v trojan >/dev/null 2>&1 && [[ ! -e $TROJAN_CREDENTIALS_FILE ]]; then
        die 'An unmanaged Trojan installation exists; migrate its config before using this installer.'
    fi
    # Save the password before network work so an interrupted run can resume.
    save_trojan_credentials
    [[ -n $WORK_DIR ]] || WORK_DIR=$(mktemp -d /tmp/debian12-init.XXXXXXXX)
    generate_trojan_certificate
    write_trojan_config /etc/trojan/debian12-init.json \
        /etc/systemd/system/trojan.service.d/credentials.conf
    # Install the override before the package so its post-install start uses our
    # valid config, rather than the packaged example listening on port 443.
    systemctl daemon-reload
    apt-get install -y --no-install-recommends trojan
    systemctl daemon-reload
    systemctl enable trojan.service
    if ! systemctl restart trojan.service; then
        journalctl -u trojan.service -n 30 --no-pager >&2
        die 'Trojan could not start; check its config and whether the port is occupied.'
    fi
    for _ in {1..15}; do
        if timeout 8 openssl s_client -connect "127.0.0.1:$TROJAN_PORT" \
            -servername "$TROJAN_DOMAIN" -verify_hostname "$TROJAN_DOMAIN" \
            -CAfile "$TROJAN_TLS_DIR/server.crt" -verify_return_error \
            </dev/null > "$WORK_DIR/trojan-tls-check.log" 2>&1; then
            tls_ready=1
            break
        fi
        sleep 1
    done
    if [[ $tls_ready != 1 ]]; then
        cat "$WORK_DIR/trojan-tls-check.log" >&2
        journalctl -u trojan.service -n 30 --no-pager >&2
        die 'Trojan TLS verification failed.'
    fi
    systemctl is-active --quiet trojan.service || die 'Trojan service is not active.'
    systemctl is-enabled --quiet trojan.service || die 'Trojan service is not enabled at boot.'
}

[[ $EUID -eq 0 ]] || die 'Run this script as root.'
[[ $(. /etc/os-release; printf '%s' "$ID:$VERSION_ID") == debian:12 ]] || die 'Debian 12 is required.'
[[ $(uname -m) == x86_64 ]] || die 'This script currently supports x86_64 only (Chrome amd64 package).'
[[ $DESKTOP_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ && $DESKTOP_USER != root ]] || die 'Invalid DESKTOP_USER.'
[[ $PANEL_PORT =~ ^[0-9]{2,5}$ ]] && (( PANEL_PORT >= 1024 && PANEL_PORT <= 65535 )) || die 'Invalid PANEL_PORT.'
[[ $PANEL_PORT -ne $VNC_PORT ]] || die 'PANEL_PORT conflicts with VNC.'
[[ $PANEL_PORT -ne $SSH_PORT ]] || die 'PANEL_PORT conflicts with SSH.'
[[ $INSTALL_DOCKER == 0 || $INSTALL_DOCKER == 1 ]] || die 'INSTALL_DOCKER must be 0 or 1.'
[[ $INSTALL_OPENRESTY == 0 || $INSTALL_OPENRESTY == 1 ]] || die 'INSTALL_OPENRESTY must be 0 or 1.'
[[ $INSTALL_OPENRESTY == 0 || $INSTALL_DOCKER == 1 ]] || die 'OpenResty requires Docker (set INSTALL_DOCKER=1).'
[[ $VNC_GEOMETRY =~ ^[0-9]{3,4}x[0-9]{3,4}$ ]] || die 'Invalid VNC_GEOMETRY (expected WIDTHxHEIGHT).'
[[ $INSTALL_TROJAN == 0 || $INSTALL_TROJAN == 1 ]] || die 'INSTALL_TROJAN must be 0 or 1.'
if [[ $INSTALL_TROJAN == 1 ]]; then
    [[ $TROJAN_PORT =~ ^[1-9][0-9]{3,4}$ ]] && (( TROJAN_PORT >= 1024 && TROJAN_PORT <= 65535 )) || die 'Invalid TROJAN_PORT.'
    [[ $TROJAN_PORT -ne $PANEL_PORT && $TROJAN_PORT -ne $VNC_PORT &&
       $TROJAN_PORT -ne $OPENRESTY_HTTPS_PORT && $TROJAN_PORT -ne $SSH_PORT ]] || die 'TROJAN_PORT conflicts with another configured service.'
fi

# Ask before DNS changes, apt, or any other system mutation. /dev/tty also
# supports curl | bash when run from an interactive SSH terminal.
prompt_trojan_domain

export DEBIAN_FRONTEND=noninteractive

# Repair DNS before the first apt/curl request, including on minimal images
# where systemd-resolved has not been installed yet.
log 'Configuring public DNS (1.1.1.1 and 8.8.8.8)'
if [[ ( -e /etc/resolv.conf || -L /etc/resolv.conf ) &&
      ! -e /etc/resolv.conf.debian12-init.bak && ! -L /etc/resolv.conf.debian12-init.bak ]]; then
    cp -a /etc/resolv.conf /etc/resolv.conf.debian12-init.bak
fi
install -d -m 755 /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/60-public-dns.conf <<'DNS'
[Resolve]
DNS=1.1.1.1 8.8.8.8
Domains=~.
DNS
chmod 644 /etc/systemd/resolved.conf.d/60-public-dns.conf
# More specific per-link domains, such as Tailscale's, retain their DNS route.
DNS_BOOTSTRAPPED=0
if command -v resolvectl >/dev/null 2>&1; then
    activate_public_dns
else
    log 'Using bootstrap DNS until systemd-resolved is installed'
    rm -f -- /etc/resolv.conf
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
    DNS_BOOTSTRAPPED=1
fi
timeout 15 getent ahostsv4 deb.debian.org >/dev/null || die 'Public DNS cannot resolve deb.debian.org; check outbound DNS connectivity.'

# Repair permissions from an interrupted earlier run before apt reads the repo.
for apt_file in /usr/share/keyrings/google-chrome.gpg /etc/apt/sources.list.d/google-chrome.list; do
    [[ ! -e $apt_file ]] || chmod 644 "$apt_file"
done
if [[ -f /etc/apt/sources.list.d/google-chrome.list ]]; then
    ensure_chrome_key
fi
log 'Installing base utilities'
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl openssh-server expect tzdata procps tmux htop vim python3 python3-cryptography xz-utils systemd-resolved
if [[ $DNS_BOOTSTRAPPED == 1 ]]; then
    activate_public_dns
    timeout 15 getent ahostsv4 deb.debian.org >/dev/null || die 'systemd-resolved cannot resolve deb.debian.org after installation.'
fi

configure_ssh_port

log 'Setting vm.swappiness=60'
[[ -e /etc/sysctl.conf ]] || install -m 644 /dev/null /etc/sysctl.conf
[[ -e /etc/sysctl.conf.debian12-init.bak ]] || cp -a /etc/sysctl.conf /etc/sysctl.conf.debian12-init.bak
if grep -qE '^[[:space:]]*vm\.swappiness[[:space:]]*=' /etc/sysctl.conf; then
    sed -i -E 's/^[[:space:]]*vm\.swappiness[[:space:]]*=.*/vm.swappiness = 60/' /etc/sysctl.conf
else
    printf '\n# debian12-init: allow swapping under memory pressure\nvm.swappiness = 60\n' >> /etc/sysctl.conf
fi
sysctl -w vm.swappiness=60
[[ $(sysctl -n vm.swappiness) == 60 ]] || die 'vm.swappiness did not become 60.'

log 'Disabling Alibaba Cloud agents when installed'
CLOUD_AGENT_WARNINGS=()
for agent in cloudmonitor aliyun; do
    unit="$agent.service"
    if [[ $(systemctl show -p LoadState --value "$unit") == loaded ]]; then
        if ! systemctl disable --now "$unit"; then
            CLOUD_AGENT_WARNINGS+=("$unit")
            log "WARNING: $unit refused to disable; check the provider's agent protection settings"
        elif systemctl is-enabled --quiet "$unit" || systemctl is-active --quiet "$unit"; then
            CLOUD_AGENT_WARNINGS+=("$unit")
            log "WARNING: $unit is still enabled or active"
        else
            log "$unit disabled and stopped"
        fi
    fi
done

if ! grep -Fq '# debian12-init interactive aliases' /etc/bash.bashrc; then
    cat >> /etc/bash.bashrc <<'ALIASES'

# debian12-init interactive aliases
alias ll='ls $LS_OPTIONS -l'
alias cp='cp -i'
alias mv='mv -i'
ALIASES
fi
if ! grep -Fqx 'set mouse=' /etc/vim/vimrc.local 2>/dev/null; then
    printf '\n" debian12-init: disable mouse mode by default\nset mouse=\n' >> /etc/vim/vimrc.local
fi
chmod 644 /etc/vim/vimrc.local

install_node

# Use the server's public IPv4 address, not its private interface address.
PUBLIC_IP=$(curl -4fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)
valid_timezone() {
    [[ ( $1 == UTC || $1 =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$ ) && -f /usr/share/zoneinfo/$1 ]]
}
if [[ $SERVER_TIMEZONE == auto ]]; then
    DETECTED_TIMEZONE=
    if [[ $PUBLIC_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        for provider_url in "https://ipinfo.io/$PUBLIC_IP/timezone" "https://ipapi.co/$PUBLIC_IP/timezone/"; do
            candidate=$(curl -4fsSL --max-time 8 "$provider_url" 2>/dev/null || true)
            candidate=${candidate//$'\r'/}
            candidate=${candidate//$'\n'/}
            if valid_timezone "$candidate"; then
                DETECTED_TIMEZONE=$candidate
                break
            fi
        done
    fi
    if [[ -n $DETECTED_TIMEZONE ]]; then
        timedatectl set-timezone "$DETECTED_TIMEZONE"
        log "Time zone set from public IP $PUBLIC_IP: $DETECTED_TIMEZONE"
    else
        log "IP time zone lookup failed; keeping $(timedatectl show -p Timezone --value)"
    fi
elif [[ $SERVER_TIMEZONE == keep ]]; then
    log "Keeping current time zone: $(timedatectl show -p Timezone --value)"
else
    valid_timezone "$SERVER_TIMEZONE" || die "Invalid SERVER_TIMEZONE: $SERVER_TIMEZONE"
    timedatectl set-timezone "$SERVER_TIMEZONE"
    log "Time zone set to $SERVER_TIMEZONE"
fi

# A 1.6 GiB machine has little headroom for Docker, XFCE, and Chrome together.
if (( $(awk '/MemTotal:/ {print $2}' /proc/meminfo) < 2097152 )) &&
   [[ $(swapon --noheadings --show | wc -l) -eq 0 ]]; then
    log 'Adding 4 GiB swap for this low-memory server'
    if [[ ! -e /swapfile ]]; then
        fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
        chmod 600 /swapfile
        mkswap /swapfile
    fi
    swapon /swapfile
    grep -qE '^/swapfile[[:space:]]' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
fi

if [[ -e $CREDENTIALS_FILE ]]; then
    # This root-only file lets a rerun show the same credentials.
    [[ $(stat -c %a "$CREDENTIALS_FILE") == 600 ]] || die "$CREDENTIALS_FILE must have mode 600."
    # shellcheck source=/dev/null
    source "$CREDENTIALS_FILE"
else
    PANEL_USER=admin
    PANEL_PASSWORD=$(openssl rand -hex 12)
fi

log 'Installing the minimal XFCE session and TigerVNC'
apt-get install -y --no-install-recommends \
    xfce4-session xfce4-panel xfdesktop4 xfwm4 xfce4-terminal thunar \
    dbus-x11 tigervnc-standalone-server fonts-dejavu-core fonts-wqy-microhei locales

if ! locale -a | grep -qi '^zh_CN\.utf8$'; then
    sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
    grep -q '^zh_CN.UTF-8 UTF-8$' /etc/locale.gen || printf 'zh_CN.UTF-8 UTF-8\n' >> /etc/locale.gen
    locale-gen zh_CN.UTF-8
fi

# LC_TIME controls date formatting separately from the Chinese desktop UI.
date_locale_for_country() {
    local country=$1 language=en base
    [[ $country =~ ^[A-Z]{2}$ ]] || return 1
    case $country in
        CN|TW|HK|MO) language=zh ;;
        JP) language=ja ;;
        KR) language=ko ;;
        DE|AT|CH) language=de ;;
        FR) language=fr ;;
        ES|MX|AR|CL|CO|PE) language=es ;;
        BR|PT) language=pt ;;
        RU) language=ru ;;
        IT) language=it ;;
        NL|BE) language=nl ;;
        PL) language=pl ;;
        TR) language=tr ;;
        TH) language=th ;;
        VN) language=vi ;;
        ID) language=id ;;
    esac
    for base in "${language}_${country}" "en_${country}"; do
        if [[ -f /usr/share/i18n/locales/$base ]]; then
            printf '%s.UTF-8\n' "$base"
            return 0
        fi
    done
    base=$(find /usr/share/i18n/locales -maxdepth 1 -type f -name "*_${country}" -printf '%f\n' | sort | head -n 1)
    [[ -n $base ]] || return 1
    printf '%s.UTF-8\n' "$base"
}

SELECTED_DATE_LOCALE=$(sed -nE 's/^LC_TIME="?([^"[:space:]]+)"?$/\1/p' /etc/default/locale | tail -n 1)
SELECTED_DATE_LOCALE=${SELECTED_DATE_LOCALE:-zh_CN.UTF-8}
APPLY_DATE_LOCALE=0
if [[ $DATE_LOCALE == auto ]]; then
    COUNTRY_CODE=
    if [[ $PUBLIC_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        for provider_url in "https://ipinfo.io/$PUBLIC_IP/country" "https://ipapi.co/$PUBLIC_IP/country_code/"; do
            candidate=$(curl -4fsSL --max-time 8 "$provider_url" 2>/dev/null || true)
            candidate=${candidate//$'\r'/}
            candidate=${candidate//$'\n'/}
            if [[ $candidate =~ ^[A-Z]{2}$ ]]; then
                COUNTRY_CODE=$candidate
                break
            fi
        done
    fi
    if [[ -n $COUNTRY_CODE ]] && candidate=$(date_locale_for_country "$COUNTRY_CODE"); then
        SELECTED_DATE_LOCALE=$candidate
        APPLY_DATE_LOCALE=1
        log "Date locale selected from public IP $PUBLIC_IP ($COUNTRY_CODE): $SELECTED_DATE_LOCALE"
    else
        log "IP date locale lookup failed; keeping $SELECTED_DATE_LOCALE"
    fi
elif [[ $DATE_LOCALE != keep ]]; then
    SELECTED_DATE_LOCALE=$DATE_LOCALE
    APPLY_DATE_LOCALE=1
fi

locale_base=${SELECTED_DATE_LOCALE%.UTF-8}
[[ $SELECTED_DATE_LOCALE == "$locale_base.UTF-8" && $locale_base =~ ^[a-z]{2,3}_[A-Z]{2}$ && -f /usr/share/i18n/locales/$locale_base ]] || die "Invalid DATE_LOCALE: $SELECTED_DATE_LOCALE"
if ! locale -a | grep -qi "^${locale_base}\.utf8$"; then
    grep -Eq "^${locale_base}(\.UTF-8)? UTF-8$" /etc/locale.gen || printf '%s UTF-8\n' "$locale_base" >> /etc/locale.gen
    locale-gen
fi
if [[ $APPLY_DATE_LOCALE == 1 ]]; then
    update-locale "LC_TIME=$SELECTED_DATE_LOCALE"
fi

if ! id "$DESKTOP_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$DESKTOP_USER"
fi
DESKTOP_HOME=$(getent passwd "$DESKTOP_USER" | cut -d: -f6)
[[ -d $DESKTOP_HOME ]] || die "Home directory missing for $DESKTOP_USER."
install -d -m 700 -o "$DESKTOP_USER" -g "$DESKTOP_USER" "$DESKTOP_HOME/.vnc"
install -d -m 755 -o "$DESKTOP_USER" -g "$DESKTOP_USER" "$DESKTOP_HOME/Desktop"

cat > "$DESKTOP_HOME/.vnc/xstartup" <<'XSTARTUP'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session startxfce4
XSTARTUP
chown "$DESKTOP_USER:$DESKTOP_USER" "$DESKTOP_HOME/.vnc/xstartup"
chmod 700 "$DESKTOP_HOME/.vnc/xstartup"

rm -f -- "$DESKTOP_HOME/.vnc/passwd"

cat > /etc/systemd/system/tigervnc-desktop.service <<EOF
[Unit]
Description=TigerVNC XFCE desktop for $DESKTOP_USER
After=network.target

[Service]
Type=simple
User=$DESKTOP_USER
Group=$DESKTOP_USER
WorkingDirectory=$DESKTOP_HOME
Environment=HOME=$DESKTOP_HOME
Environment=LANG=zh_CN.UTF-8
Environment=LANGUAGE=zh_CN:zh
Environment=LC_TIME=$SELECTED_DATE_LOCALE
ExecStart=/usr/bin/tigervncserver $VNC_DISPLAY -fg -localhost yes -rfbport $VNC_PORT -geometry $VNC_GEOMETRY -depth 24 -SecurityTypes None
ExecStop=-/usr/bin/tigervncserver -kill $VNC_DISPLAY
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable tigervnc-desktop.service
systemctl restart tigervnc-desktop.service
systemctl is-active --quiet tigervnc-desktop.service || die 'TigerVNC service is not active.'
systemctl is-enabled --quiet tigervnc-desktop.service || die 'TigerVNC service is not enabled at boot.'

log 'Installing Google Chrome from the official apt repository'
ensure_chrome_key
printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main\n' > /etc/apt/sources.list.d/google-chrome.list
chmod 644 /usr/share/keyrings/google-chrome.gpg /etc/apt/sources.list.d/google-chrome.list
apt-get update
apt-get install -y --no-install-recommends google-chrome-stable

# Chrome's supported enterprise policy disables the local GenAI model and
# removes an already downloaded model. Keep this policy readable by all users.
install -d -m 755 /etc/opt/chrome/policies/managed
printf '{"GenAILocalFoundationalModelSettings":1}\n' > /etc/opt/chrome/policies/managed/10-on-device-ai.json
chmod 644 /etc/opt/chrome/policies/managed/10-on-device-ai.json

# Apply resource settings to every profile, including profiles created later.
# Graphics acceleration changes take effect after restarting Chrome.
log 'Configuring Chrome Memory Saver (maximum), disabling preloading and graphics acceleration'
cat > /etc/opt/chrome/policies/managed/20-low-resource.json <<'CHROME_POLICY'
{
    "HighEfficiencyModeEnabled": true,
    "MemorySaverModeSavings": 2,
    "NetworkPredictionOptions": 2,
    "HardwareAccelerationModeEnabled": false
}
CHROME_POLICY
chmod 644 /etc/opt/chrome/policies/managed/20-low-resource.json

cat > /usr/local/bin/chrome-low-resource <<'CHROME'
#!/bin/sh
# Keep background work and renderer fan-out small; preserve Chrome's sandbox.
# Chrome treats a lock from an old host name as another machine using the
# profile. Clear stale symlinks only when this user has no Chrome process.
profile_dir=${XDG_CONFIG_HOME:-$HOME/.config}/google-chrome
lock_file=$profile_dir/SingletonLock
if [ -L "$lock_file" ]; then
    lock_owner=$(readlink -- "$lock_file")
    lock_pid=${lock_owner##*-}
    case "$lock_pid" in
        ''|*[!0-9]*) ;;
        *)
            lock_host=${lock_owner%-$lock_pid}
            if [ "$lock_host" != "$(hostname)" ] &&
               ! pgrep -u "$(id -u)" -x chrome >/dev/null 2>&1; then
                for name in SingletonLock SingletonCookie SingletonSocket; do
                    [ ! -L "$profile_dir/$name" ] || rm -f -- "$profile_dir/$name"
                done
            fi
            ;;
    esac
fi
exec /usr/bin/google-chrome-stable \
    --no-first-run \
    --no-default-browser-check \
    --disable-background-mode \
    --disable-background-networking \
    --disable-component-update \
    --disable-default-apps \
    --disable-extensions \
    --disable-sync \
    --process-per-site \
    --renderer-process-limit=2 \
    --disk-cache-size=52428800 \
    "$@"
CHROME
chmod 755 /usr/local/bin/chrome-low-resource
cat > "$DESKTOP_HOME/Desktop/Google Chrome.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Google Chrome (low resource)
Comment=Start Chrome with reduced background work
Exec=/usr/local/bin/chrome-low-resource %U
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
DESKTOP
chown "$DESKTOP_USER:$DESKTOP_USER" "$DESKTOP_HOME/Desktop/Google Chrome.desktop"
chmod 755 "$DESKTOP_HOME/Desktop/Google Chrome.desktop"

# XFCE's clock has its own fixed date format by default. %x delegates to the
# session's LC_TIME so the panel follows the detected regional date format.
PANEL_BUS=
for attempt in {1..15}; do
    PANEL_PID=$(pgrep -u "$DESKTOP_USER" -x xfce4-panel | head -n 1 || true)
    if [[ -n $PANEL_PID ]]; then
        PANEL_BUS=$(tr '\0' '\n' < "/proc/$PANEL_PID/environ" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
        [[ -z $PANEL_BUS ]] || break
    fi
    sleep 1
done
[[ -n $PANEL_BUS ]] || die 'XFCE panel session bus is unavailable.'
XFCONF=(runuser -u "$DESKTOP_USER" -- env DISPLAY="$VNC_DISPLAY" DBUS_SESSION_BUS_ADDRESS="$PANEL_BUS" xfconf-query -c xfce4-panel)
CLOCK_PLUGINS=$("${XFCONF[@]}" -lv | awk '$2 == "clock" && $1 ~ /^\/plugins\/plugin-[0-9]+$/ {print $1}')
if [[ -n $CLOCK_PLUGINS ]]; then
    while IFS= read -r clock_plugin; do
        "${XFCONF[@]}" -p "$clock_plugin/digital-date-format" -n -t string -s '%x'
    done <<< "$CLOCK_PLUGINS"
    log "XFCE clock date format follows $SELECTED_DATE_LOCALE"
fi

for attempt in {1..15}; do
    ss -ltn | grep -qE '127\.0\.0\.1:5901[[:space:]]' && break
    sleep 1
done
ss -ltn | grep -qE '127\.0\.0\.1:5901[[:space:]]' || die 'TigerVNC is not listening on 127.0.0.1:5901.'

install_trojan

# Install the panel stack last so desktop access is ready before this stage.
if ! command -v 1pctl >/dev/null 2>&1; then
    if [[ -d $PANEL_DATA_DIR ]] && [[ -n $(find "$PANEL_DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
        die "$PANEL_DATA_DIR is not empty; the upstream installer would erase its contents."
    fi
    log "Installing 1Panel $PANEL_VERSION"
    [[ -n $WORK_DIR ]] || WORK_DIR=$(mktemp -d /tmp/debian12-init.XXXXXXXX)
    PACKAGE="1panel-${PANEL_VERSION}-linux-amd64.tar.gz"
    BASE_URL="https://resource.fit2cloud.com/1panel/package/stable/${PANEL_VERSION}/release"
    curl -fsSL --retry 3 -o "$WORK_DIR/checksums.txt" "$BASE_URL/checksums.txt"
    curl -fsSL --retry 3 -o "$WORK_DIR/$PACKAGE" "$BASE_URL/$PACKAGE"
    (cd "$WORK_DIR" && grep -F "  $PACKAGE" checksums.txt | sha256sum -c -) || die '1Panel SHA-256 verification failed.'
    tar -xzf "$WORK_DIR/$PACKAGE" -C "$WORK_DIR"
    PANEL_DIR="$WORK_DIR/1panel-${PANEL_VERSION}-linux-amd64"
    [[ -f $PANEL_DIR/install.sh ]] || die '1Panel installer missing from archive.'
    printf 'en\n' > "$PANEL_DIR/.selected_language"
    if [[ $INSTALL_DOCKER == 0 ]]; then
        # Upstream calls these unconditionally. The panel UI itself runs without
        # Docker; app-store container features can be enabled later if wanted.
        [[ $(grep -Ec '^    Install_(Docker|Compose)$' "$PANEL_DIR/install.sh") == 2 ]] || die 'Unexpected 1Panel installer layout.'
        sed -i -e '/^    Install_Docker$/d' -e '/^    Install_Compose$/d' "$PANEL_DIR/install.sh"
        log 'Skipping 1Panel Docker and Compose installation'
    fi

    # Expect supplies answers to the upstream installer, which reads its password
    # from /dev/tty. The password is generated locally and never passed as an arg.
    cat > "$WORK_DIR/install-1panel.exp" <<'EXPECT'
set timeout 1800
log_user 1
spawn bash ./install.sh
expect {
    -re {Set 1Panel installation directory.*: $} { send "$env(PANEL_BASE_DIR)\r"; exp_continue }
    -re {Do you want to configure image acceleration.*: $} { send "n\r"; exp_continue }
    -re {A lower version of Docker Compose was detected.*: $} { send "y\r"; exp_continue }
    -re {Set 1Panel port.*: $} { send "$env(PANEL_PORT)\r"; exp_continue }
    -re {Set 1Panel secure entrance.*: $} { send "admin\r"; exp_continue }
    -re {Set 1Panel panel user.*: $} { send "$env(PANEL_USER)\r"; exp_continue }
    -re {Set 1Panel panel password[^\n]*} { send "$env(PANEL_PASSWORD)\r"; exp_continue }
    timeout { puts stderr "1Panel installer timed out"; exit 1 }
    eof
}
set result [wait]
exit [lindex $result 3]
EXPECT
    (cd "$PANEL_DIR" && export PANEL_BASE_DIR PANEL_PORT PANEL_USER PANEL_PASSWORD && expect "$WORK_DIR/install-1panel.exp")
else
    log '1Panel already installed; keeping its current settings'
    [[ -e $CREDENTIALS_FILE ]] || die 'Existing 1Panel credentials are unknown; cannot print its password.'
    CURRENT_PANEL_BASE=$(sed -n 's/^BASE_DIR=//p' "$(command -v 1pctl)" | head -n 1)
    [[ $CURRENT_PANEL_BASE == "$PANEL_BASE_DIR" ]] || die "Existing 1Panel base is $CURRENT_PANEL_BASE; expected $PANEL_BASE_DIR. Migrate it before rerunning."
fi
systemctl enable --now 1panel.service
systemctl is-active --quiet 1panel.service || die '1Panel service is not active.'
systemctl is-enabled --quiet 1panel.service || die '1Panel service is not enabled at boot.'
# Save them as soon as the panel succeeds so an interrupted install can resume.
# Rewriting also removes any VNC password saved by an older script revision.
install -d -m 700 /root/.config/debian12-init
printf 'PANEL_PORT=%q\nPANEL_USER=%q\nPANEL_PASSWORD=%q\nDESKTOP_USER=%q\n' \
    "$PANEL_PORT" "$PANEL_USER" "$PANEL_PASSWORD" "$DESKTOP_USER" > "$CREDENTIALS_FILE"
chmod 600 "$CREDENTIALS_FILE"

if [[ $INSTALL_DOCKER == 1 ]]; then
    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        log 'Installing Docker Engine and Compose from the official apt repository'
        install -d -m 755 /etc/apt/keyrings
        curl -fsSL --retry 3 https://download.docker.com/linux/debian/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod 644 /etc/apt/keyrings/docker.gpg
        printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable\n' > /etc/apt/sources.list.d/docker.list
        apt-get update
        if command -v docker >/dev/null 2>&1; then
            apt-get install -y --no-install-recommends docker-compose-plugin
        else
            apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        fi
    fi
    systemctl enable --now docker.service
    systemctl is-active --quiet docker.service || die 'Docker service is not active.'
    systemctl is-enabled --quiet docker.service || die 'Docker service is not enabled at boot.'
    docker info >/dev/null || die 'Docker daemon is unavailable.'
    docker compose version >/dev/null || die 'Docker Compose plugin is unavailable.'
    # 1Panel v1 invokes the legacy command name even when Compose v2 is installed.
    if ! command -v docker-compose >/dev/null 2>&1; then
        cat > /usr/local/bin/docker-compose <<'COMPOSE'
#!/bin/sh
exec docker compose "$@"
COMPOSE
        chmod 755 /usr/local/bin/docker-compose
    fi
    docker-compose version >/dev/null || die 'The docker-compose compatibility command is unavailable.'
fi

if [[ $INSTALL_OPENRESTY == 1 ]]; then
    log 'Installing OpenResty through the 1Panel app store'
    [[ -n $WORK_DIR ]] || WORK_DIR=$(mktemp -d /tmp/debian12-init.XXXXXXXX)
    install -d -m 755 "$STREAM_CONFIG_DIR"
    STREAM_CONFIG_TARGET="$STREAM_CONFIG_DIR/tls-forward-443.conf"
    if [[ -f $STREAM_CONFIG_TARGET ]]; then
        # Keep custom SNI mappings on reruns while widening the old listener.
        sed -i -e 's/\r$//' \
            -e 's/listen 127\.0\.0\.1:443;/listen 0.0.0.0:443;/' \
            -e 's/# Local-only listener for frpc stcp on the overseas server\./# Accept TLS connections on every IPv4 interface./' \
            "$STREAM_CONFIG_TARGET"
    else
        STREAM_CONFIG_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tls-forward-443.conf"
        if [[ ! -f $STREAM_CONFIG_SOURCE ]]; then
            STREAM_CONFIG_SOURCE="$WORK_DIR/tls-forward-443.conf"
            curl -fsSL --retry 3 -o "$STREAM_CONFIG_SOURCE" \
                https://raw.githubusercontent.com/qdog2012/myscripts/main/tls-forward-443.conf
        fi
        install -m 644 "$STREAM_CONFIG_SOURCE" "$STREAM_CONFIG_TARGET"
        sed -i 's/\r$//' "$STREAM_CONFIG_TARGET"
    fi
    cat > "$WORK_DIR/install-openresty.py" <<'PYTHON'
import base64
import http.cookiejar
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.asymmetric import padding as rsa_padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.serialization import load_pem_public_key


port = os.environ['PANEL_PORT']
base = f'http://127.0.0.1:{port}'
https_port = int(os.environ['OPENRESTY_HTTPS_PORT'])
panel_data_dir = Path(os.environ['PANEL_DATA_DIR'])
stream_dir = Path(os.environ['STREAM_CONFIG_DIR'])
jar = http.cookiejar.CookieJar()
# This is a local management connection even when the shell has proxy variables.
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(jar))


def request(method, path, data=None, extra_headers=None):
    headers = {'Content-Type': 'application/json', 'Accept-Language': 'en'}
    headers.update(extra_headers or {})
    payload = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(base + path, payload, headers, method=method)
    with opener.open(req, timeout=45) as response:
        result = json.load(response)
    if result.get('code') != 200:
        raise RuntimeError(f'{path}: {result.get("message", result)}')
    return result.get('data')


def wait_for_panel():
    # systemd Type=simple becomes active before 1Panel opens its HTTP socket.
    deadline = time.monotonic() + 120
    last_error = 'not ready'
    announced = False
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SystemExit(
                f'1Panel did not become ready at {base}/admin within 120 seconds '
                f'({last_error}).\nCheck: systemctl status 1panel --no-pager -l\n'
                'Check: journalctl -u 1panel -n 80 --no-pager\n'
                f'Check: ss -lntp (expected panel port {port})')
        try:
            with opener.open(base + '/admin', timeout=min(5, remaining)):
                return
        except urllib.error.HTTPError as error:
            error.close()
            if error.code not in {502, 503, 504}:
                raise SystemExit(
                    f'1Panel returned HTTP {error.code} at {base}/admin; '
                    'check the panel protocol, port and secure entrance.') from None
            last_error = f'HTTP {error.code}'
        except (urllib.error.URLError, OSError, http.client.HTTPException) as error:
            last_error = str(getattr(error, 'reason', error))
        if not announced:
            print(f'Waiting up to 120 seconds for 1Panel at {base}/admin', flush=True)
            announced = True
        time.sleep(min(2, max(0, deadline - time.monotonic())))


wait_for_panel()
key_cookie = next((c.value for c in jar if c.name == 'panel_public_key'), None)
if not key_cookie:
    raise RuntimeError('1Panel public key cookie is unavailable')
public_key = load_pem_public_key(base64.b64decode(urllib.parse.unquote(key_cookie)))
aes_key = secrets.token_hex(16).encode()
iv = secrets.token_bytes(16)
padder = padding.PKCS7(128).padder()
plain = padder.update(os.environ['PANEL_PASSWORD'].encode()) + padder.finalize()
encryptor = Cipher(algorithms.AES(aes_key), modes.CBC(iv)).encryptor()
ciphertext = encryptor.update(plain) + encryptor.finalize()
encrypted_key = public_key.encrypt(aes_key, rsa_padding.PKCS1v15())
password = ':'.join(base64.b64encode(part).decode() for part in (encrypted_key, iv, ciphertext))
entrance = base64.b64encode(b'admin').decode()
language = request('GET', '/api/v1/auth/setting').get('language') or 'en'
login = request('POST', '/api/v1/auth/login', {
    'name': os.environ['PANEL_USER'], 'password': password,
    'authMethod': 'session', 'language': language,
}, {'EntranceCode': entrance})
if login.get('mfaStatus') == 'enable':
    raise RuntimeError('1Panel MFA is enabled; automatic OpenResty installation cannot log in')


def installed():
    return request('POST', '/api/v1/apps/installed/check', {'key': 'openresty', 'name': 'openresty'})


current = installed()
if not current.get('isExist'):
    try:
        app = request('GET', '/api/v1/apps/openresty')
    except RuntimeError:
        request('POST', '/api/v1/apps/sync', {})
        deadline = time.monotonic() + 900
        while True:
            time.sleep(10)
            try:
                app = request('GET', '/api/v1/apps/openresty')
                break
            except RuntimeError:
                if time.monotonic() > deadline:
                    raise RuntimeError('1Panel app store did not publish OpenResty within 15 minutes')
    version = app['versions'][0]
    detail = request('GET', f'/api/v1/apps/detail/{app["id"]}/{version}/app')
    if not detail.get('enable', True):
        raise RuntimeError('1Panel reports that OpenResty is unavailable on this server')
    params = {field['envKey']: field.get('default', '')
              for field in detail['params'].get('formFields', [])}
    params['PANEL_APP_PORT_HTTPS'] = https_port
    request('POST', '/api/v1/apps/install', {
        'appDetailId': detail['id'], 'name': 'openresty', 'params': params,
        'advanced': False, 'allowPort': True, 'pullImage': True,
    })
    print(f'1Panel OpenResty {version} installation started', flush=True)
elif current.get('status', '').lower() in {'uperr', 'downloaderr', 'error', 'stopped'}:
    operation = 'start' if current['status'].lower() == 'stopped' else 'rebuild'
    request('POST', '/api/v1/apps/installed/op', {
        'installId': current['appInstallId'], 'operate': operation,
    })
    print(f'1Panel OpenResty {operation} requested', flush=True)

deadline = time.monotonic() + 1200
while True:
    current = installed()
    status = current.get('status', '').lower()
    if status == 'running':
        break
    if 'error' in status or status in {'uperr', 'installerr'}:
        raise RuntimeError(f'OpenResty installation failed: {current}')
    if time.monotonic() > deadline:
        raise RuntimeError(f'OpenResty did not reach running state within 20 minutes: {current}')
    time.sleep(10)

install_path = Path(current['installPath'])
expected_path = panel_data_dir / 'apps/openresty/openresty'
if install_path != expected_path:
    raise RuntimeError(f'OpenResty is installed at {install_path}; expected {expected_path}')

config = request('GET', f'/api/v1/apps/installed/params/{current["appInstallId"]}')
params = {entry['key']: entry['value'] for entry in config['params']}
params['PANEL_APP_PORT_HTTPS'] = https_port
compose = config['dockerCompose']
mount = f'{stream_dir}:/usr/local/openresty/nginx/conf/stream.d:ro'
compose_changed = mount not in compose
if compose_changed:
    match = re.search(r'(?m)^([ \t]*- )\./www:/www[ \t]*$', compose)
    if not match:
        raise RuntimeError('OpenResty Compose file has no expected ./www:/www volume')
    compose = compose[:match.end()] + '\n' + match.group(1) + mount + compose[match.end():]

nginx_conf = install_path / 'conf/nginx.conf'
nginx_text = nginx_conf.read_text()
stream_include = 'include /usr/local/openresty/nginx/conf/stream.d/*.conf;'
nginx_changed = stream_include not in nginx_text
if nginx_changed:
    if re.search(r'(?m)^\s*stream\s*\{', nginx_text):
        raise RuntimeError('OpenResty already has a stream block; add the stream.d include there')
    nginx_text = nginx_text.rstrip() + f'\n\nstream {{\n    {stream_include}\n}}\n'

default_conf = install_path / 'conf/conf.d/00.default.conf'
default_text = default_conf.read_text()
default_new = re.sub(r'(?m)^([ \t]*listen[ \t]+)443([ \t]+ssl\b)',
                     lambda match: match.group(1) + str(https_port) + match.group(2),
                     default_text)
if not re.search(rf'(?m)^\s*listen\s+{https_port}\s+ssl\b', default_new):
    raise RuntimeError('OpenResty default HTTPS listener was not found')

if nginx_changed:
    nginx_conf.write_text(nginx_text)
if default_new != default_text:
    default_conf.write_text(default_new)

if compose_changed or current['httpsPort'] != https_port:
    update = {key: config[key] for key in (
        'cpuQuota', 'memoryLimit', 'memoryUnit', 'containerName',
        'allowPort', 'hostMode', 'gpuConfig') if key in config}
    update.update({'installId': current['appInstallId'], 'params': params,
                   'advanced': True, 'editCompose': True, 'dockerCompose': compose})
    request('POST', '/api/v1/apps/installed/params/update', update)

container_name = current['containerName']
deadline = time.monotonic() + 180
while True:
    inspect = subprocess.run(
        ['docker', 'inspect', '--format', '{{json .Mounts}}', container_name],
        text=True, capture_output=True)
    if inspect.returncode == 0:
        mounts = json.loads(inspect.stdout)
        if any(m.get('Source') == str(stream_dir) and
               m.get('Destination') == '/usr/local/openresty/nginx/conf/stream.d'
               for m in mounts):
            break
    if time.monotonic() > deadline:
        raise RuntimeError('OpenResty stream.d mount did not appear within 3 minutes')
    time.sleep(3)

deadline = time.monotonic() + 180
while True:
    check = subprocess.run(['docker', 'exec', container_name, 'nginx', '-t'],
                           text=True, capture_output=True)
    if check.returncode == 0:
        break
    if 'is not running' not in check.stderr or time.monotonic() > deadline:
        raise RuntimeError(f'OpenResty nginx -t failed: {check.stderr}')
    time.sleep(3)
subprocess.run(['docker', 'exec', container_name, 'nginx', '-s', 'reload'], check=True)


def public_443_listening():
    sockets = subprocess.run(['ss', '-ltnH'], text=True, capture_output=True,
                             check=True).stdout
    return any(re.search(r'\s0\.0\.0\.0:443\s', line)
               for line in sockets.splitlines())


time.sleep(2)
if not public_443_listening():
    # nginx cannot replace an existing 127.0.0.1:443 socket with the wider
    # 0.0.0.0:443 socket during a graceful reload.
    print('Restarting OpenResty to apply the public TLS listener', flush=True)
    subprocess.run(['docker', 'restart', container_name], check=True,
                   stdout=subprocess.DEVNULL)
    deadline = time.monotonic() + 180
    while not public_443_listening():
        if time.monotonic() > deadline:
            raise RuntimeError('OpenResty did not listen on public port 443 after restart')
        time.sleep(3)
    subprocess.run(['docker', 'exec', container_name, 'nginx', '-t'], check=True)

deadline = time.monotonic() + 180
while True:
    current = installed()
    if current.get('httpsPort') == https_port and current.get('status') == 'Running':
        break
    if time.monotonic() > deadline:
        raise RuntimeError(f'OpenResty did not reach HTTPS {https_port}: {current}')
    time.sleep(3)
with open(os.environ['OPENRESTY_CONTAINER_FILE'], 'w', encoding='utf-8') as container_file:
    container_file.write(container_name)
print(f'1Panel OpenResty is running on HTTP {current.get("httpPort")} / HTTPS {https_port}; stream config: {stream_dir / "tls-forward-443.conf"}', flush=True)
PYTHON
    OPENRESTY_CONTAINER_FILE="$WORK_DIR/openresty-container"
    export PANEL_PORT PANEL_USER PANEL_PASSWORD OPENRESTY_CONTAINER_FILE
    export PANEL_DATA_DIR OPENRESTY_HTTPS_PORT STREAM_CONFIG_DIR
    python3 "$WORK_DIR/install-openresty.py"
    docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$(cat "$OPENRESTY_CONTAINER_FILE")" | grep -Eq '^(always|unless-stopped)$' || die 'OpenResty container has no boot restart policy.'
    ss -ltn | grep -qE ':18443[[:space:]]' || die 'OpenResty HTTPS is not listening on port 18443.'
    ss -ltn | grep -qE '0\.0\.0\.0:443[[:space:]]' || die 'OpenResty TLS stream is not listening on public IPv4 port 443.'
fi

PANEL_PUBLIC_IP=${PUBLIC_IP:-$(curl -4fsSL --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')}
# A session established before SSH was reloaded can still report the old port.
# Only an explicit external NAT port should override the configured port here.
SSH_TUNNEL_PORT=${SSH_TUNNEL_PORT:-$SSH_PORT}
[[ $SSH_TUNNEL_PORT =~ ^[0-9]{1,5}$ ]] || SSH_TUNNEL_PORT=$SSH_PORT
printf '\n===== Setup complete =====\n'
printf 'SSH port: %s\nSSH connection: ssh -p %s root@%s\n' "$SSH_PORT" "$SSH_TUNNEL_PORT" "$PANEL_PUBLIC_IP"
printf 'Public DNS: 1.1.1.1, 8.8.8.8 (systemd-resolved; more specific per-link DNS routes preserved)\n'
printf 'Swap tendency: vm.swappiness=%s\n' "$(sysctl -n vm.swappiness)"
printf 'System time zone: %s\n' "$(timedatectl show -p Timezone --value)"
printf 'Date locale: %s\n' "$SELECTED_DATE_LOCALE"
printf 'Node.js: %s (%s)\n' "$(node --version)" "$NODE_INSTALL_DIR"
printf '1Panel directory: %s\n' "$PANEL_DATA_DIR"
printf '1Panel URL: http://%s:%s/%s\n' "$PANEL_PUBLIC_IP" "$PANEL_PORT" "$PANEL_ENTRANCE"
printf '1Panel tunnel: ssh -p %s -L %s:127.0.0.1:%s root@YOUR_SERVER\n' "$SSH_TUNNEL_PORT" "$PANEL_PORT" "$PANEL_PORT"
printf '1Panel URL via tunnel: http://127.0.0.1:%s/%s\n' "$PANEL_PORT" "$PANEL_ENTRANCE"
printf '1Panel account: %s\n1Panel password: %s\n' "$PANEL_USER" "$PANEL_PASSWORD"
if [[ $INSTALL_OPENRESTY == 1 ]]; then
    printf 'OpenResty HTTPS: %s\nTLS stream config: %s\n' "$OPENRESTY_HTTPS_PORT" "$STREAM_CONFIG_DIR/tls-forward-443.conf"
fi
if [[ $INSTALL_TROJAN == 1 ]]; then
    printf 'Trojan server/SNI: %s\nTrojan TCP port: %s\nTrojan password: %s\n' "$TROJAN_DOMAIN" "$TROJAN_PORT" "$TROJAN_PASSWORD"
    printf 'Spectre import: trojan://%s@%s:%s?security=tls&sni=%s#Trojan\n' \
        "$TROJAN_PASSWORD" "$TROJAN_DOMAIN" "$TROJAN_PORT" "$TROJAN_DOMAIN"
    printf 'Trojan certificate: %s/server.crt (self-signed; 3650 days)\n' "$TROJAN_TLS_DIR"
    openssl x509 -in "$TROJAN_TLS_DIR/server.crt" -noout -sha256 -fingerprint
    printf 'Spectre: TLS enabled; trust/pin the certificate if supported, otherwise enable skip certificate verification. Allow inbound TCP %s.\n' "$TROJAN_PORT"
    printf 'Trojan credentials: %s\n' "$TROJAN_CREDENTIALS_FILE"
fi
printf 'Desktop user: %s\nVNC authentication: none (loopback only)\n' "$DESKTOP_USER"
printf 'VNC tunnel: ssh -p %s -L 5901:127.0.0.1:5901 root@YOUR_SERVER\n' "$SSH_TUNNEL_PORT"
printf 'VNC viewer: 127.0.0.1:5901\n'
if ((${#CLOUD_AGENT_WARNINGS[@]})); then
    printf 'Cloud agents requiring manual disable: %s\n' "${CLOUD_AGENT_WARNINGS[*]}"
fi
printf 'Root-only credentials copy: %s\n' "$CREDENTIALS_FILE"
