#!/usr/bin/env bash
# Debian 12: 1Panel, a small XFCE desktop, Chrome, and loopback-only TigerVNC.
set -Eeuo pipefail
umask 077

PANEL_VERSION=v1.10.34-lts
PANEL_PORT=${PANEL_PORT:-8080}
PANEL_ENTRANCE=admin
INSTALL_DOCKER=${INSTALL_DOCKER:-0}
SERVER_TIMEZONE=${SERVER_TIMEZONE:-auto}
DATE_LOCALE=${DATE_LOCALE:-auto}
DESKTOP_USER=${DESKTOP_USER:-desktop}
VNC_DISPLAY=:1
VNC_PORT=5901
VNC_GEOMETRY=${VNC_GEOMETRY:-1680x1050}
CREDENTIALS_FILE=/root/.config/debian12-init/credentials
WORK_DIR=

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die 'Run this script as root.'
[[ $(. /etc/os-release; printf '%s' "$ID:$VERSION_ID") == debian:12 ]] || die 'Debian 12 is required.'
[[ $(uname -m) == x86_64 ]] || die 'This script currently supports x86_64 only (Chrome amd64 package).'
[[ $DESKTOP_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ && $DESKTOP_USER != root ]] || die 'Invalid DESKTOP_USER.'
[[ $PANEL_PORT =~ ^[0-9]{2,5}$ ]] && (( PANEL_PORT >= 1024 && PANEL_PORT <= 65535 )) || die 'Invalid PANEL_PORT.'
[[ $PANEL_PORT -ne $VNC_PORT ]] || die 'PANEL_PORT conflicts with VNC.'
[[ $INSTALL_DOCKER == 0 || $INSTALL_DOCKER == 1 ]] || die 'INSTALL_DOCKER must be 0 or 1.'
[[ $VNC_GEOMETRY =~ ^[0-9]{3,4}x[0-9]{3,4}$ ]] || die 'Invalid VNC_GEOMETRY (expected WIDTHxHEIGHT).'

export DEBIAN_FRONTEND=noninteractive
# Repair permissions from an interrupted earlier run before apt reads the repo.
for apt_file in /usr/share/keyrings/google-chrome.gpg /etc/apt/sources.list.d/google-chrome.list; do
    [[ ! -e $apt_file ]] || chmod 644 "$apt_file"
done
log 'Installing base utilities'
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl expect tzdata procps tmux htop vim

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
    log 'Adding 2 GiB swap for this low-memory server'
    if [[ ! -e /swapfile ]]; then
        fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
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

if ! command -v 1pctl >/dev/null 2>&1; then
    log "Installing 1Panel $PANEL_VERSION"
    WORK_DIR=$(mktemp -d /tmp/debian12-init.XXXXXXXX)
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
    -re {Set 1Panel installation directory.*: $} { send "\r"; exp_continue }
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
    (cd "$PANEL_DIR" && export PANEL_PORT PANEL_USER PANEL_PASSWORD && expect "$WORK_DIR/install-1panel.exp")
else
    log '1Panel already installed; keeping its current settings'
    [[ -e $CREDENTIALS_FILE ]] || die 'Existing 1Panel credentials are unknown; cannot print its password.'
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
curl -fsSL --retry 3 https://dl.google.com/linux/linux_signing_key.pub | gpg --batch --yes --dearmor -o /usr/share/keyrings/google-chrome.gpg
printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main\n' > /etc/apt/sources.list.d/google-chrome.list
chmod 644 /usr/share/keyrings/google-chrome.gpg /etc/apt/sources.list.d/google-chrome.list
apt-get update
apt-get install -y --no-install-recommends google-chrome-stable

cat > /usr/local/bin/chrome-low-resource <<'CHROME'
#!/bin/sh
# Keep background work and renderer fan-out small; preserve Chrome's sandbox.
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
PANEL_PUBLIC_IP=${PUBLIC_IP:-$(curl -4fsSL --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')}
printf '\n===== Setup complete =====\n'
printf 'System time zone: %s\n' "$(timedatectl show -p Timezone --value)"
printf 'Date locale: %s\n' "$SELECTED_DATE_LOCALE"
printf '1Panel URL: http://%s:%s/%s\n' "$PANEL_PUBLIC_IP" "$PANEL_PORT" "$PANEL_ENTRANCE"
printf '1Panel tunnel: ssh -L %s:127.0.0.1:%s root@YOUR_SERVER\n' "$PANEL_PORT" "$PANEL_PORT"
printf '1Panel URL via tunnel: http://127.0.0.1:%s/%s\n' "$PANEL_PORT" "$PANEL_ENTRANCE"
printf '1Panel account: %s\n1Panel password: %s\n' "$PANEL_USER" "$PANEL_PASSWORD"
printf 'Desktop user: %s\nVNC authentication: none (loopback only)\n' "$DESKTOP_USER"
printf 'VNC tunnel: ssh -L 5901:127.0.0.1:5901 root@YOUR_SERVER\n'
printf 'VNC viewer: 127.0.0.1:5901\n'
printf 'Root-only credentials copy: %s\n' "$CREDENTIALS_FILE"
