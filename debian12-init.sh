#!/usr/bin/env bash
# Debian 12: 1Panel, a small XFCE desktop, Chrome, and loopback-only TigerVNC.
set -Eeuo pipefail
umask 077

PANEL_VERSION=v1.10.34-lts
PANEL_PORT=${PANEL_PORT:-10086}
PANEL_ENTRANCE=admin
INSTALL_DOCKER=${INSTALL_DOCKER:-0}
DESKTOP_USER=${DESKTOP_USER:-desktop}
VNC_DISPLAY=:1
VNC_PORT=5901
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

export DEBIAN_FRONTEND=noninteractive
# Repair permissions from an interrupted earlier run before apt reads the repo.
for apt_file in /usr/share/keyrings/google-chrome.gpg /etc/apt/sources.list.d/google-chrome.list; do
    [[ ! -e $apt_file ]] || chmod 644 "$apt_file"
done
log 'Installing base utilities'
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl expect

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
    PANEL_USER="admin$(openssl rand -hex 3)"
    PANEL_PASSWORD=$(openssl rand -hex 12)
    # Classic VNC authentication uses only the first eight password characters.
    VNC_PASSWORD=$(openssl rand -hex 4)
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
systemctl is-active --quiet 1panel || die '1Panel service is not active.'
if [[ ! -e $CREDENTIALS_FILE ]]; then
    # Save them as soon as the panel succeeds so an interrupted install can resume.
    install -d -m 700 /root/.config/debian12-init
    printf 'PANEL_PORT=%q\nPANEL_USER=%q\nPANEL_PASSWORD=%q\nVNC_PASSWORD=%q\nDESKTOP_USER=%q\n' \
        "$PANEL_PORT" "$PANEL_USER" "$PANEL_PASSWORD" "$VNC_PASSWORD" "$DESKTOP_USER" > "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
fi

log 'Installing the minimal XFCE session and TigerVNC'
apt-get install -y --no-install-recommends \
    xfce4-session xfce4-panel xfdesktop4 xfwm4 xfce4-terminal thunar \
    dbus-x11 tigervnc-standalone-server tigervnc-tools fonts-dejavu-core

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

VNC_PASSWD_CMD=$(command -v tigervncpasswd || command -v vncpasswd) || die 'TigerVNC password tool is missing.'
printf '%s\n' "$VNC_PASSWORD" | "$VNC_PASSWD_CMD" -f > "$DESKTOP_HOME/.vnc/passwd"
chown "$DESKTOP_USER:$DESKTOP_USER" "$DESKTOP_HOME/.vnc/passwd"
chmod 600 "$DESKTOP_HOME/.vnc/passwd"

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
ExecStart=/usr/bin/tigervncserver $VNC_DISPLAY -fg -localhost yes -rfbport $VNC_PORT -geometry 1280x720 -depth 24 -SecurityTypes VncAuth
ExecStop=-/usr/bin/tigervncserver -kill $VNC_DISPLAY
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now tigervnc-desktop.service
systemctl is-active --quiet tigervnc-desktop.service || die 'TigerVNC service is not active.'

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

for attempt in {1..15}; do
    ss -ltn | grep -qE '127\.0\.0\.1:5901[[:space:]]' && break
    sleep 1
done
ss -ltn | grep -qE '127\.0\.0\.1:5901[[:space:]]' || die 'TigerVNC is not listening on 127.0.0.1:5901.'
PANEL_PUBLIC_IP=$(curl -4fsSL --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')
printf '\n===== Setup complete =====\n'
printf '1Panel URL: http://%s:%s/%s\n' "$PANEL_PUBLIC_IP" "$PANEL_PORT" "$PANEL_ENTRANCE"
printf '1Panel tunnel: ssh -L %s:127.0.0.1:%s root@YOUR_SERVER\n' "$PANEL_PORT" "$PANEL_PORT"
printf '1Panel URL via tunnel: http://127.0.0.1:%s/%s\n' "$PANEL_PORT" "$PANEL_ENTRANCE"
printf '1Panel account: %s\n1Panel password: %s\n' "$PANEL_USER" "$PANEL_PASSWORD"
printf 'Desktop user: %s\nVNC password: %s\n' "$DESKTOP_USER" "$VNC_PASSWORD"
printf 'VNC tunnel: ssh -L 5901:127.0.0.1:5901 root@YOUR_SERVER\n'
printf 'VNC viewer: 127.0.0.1:5901\n'
printf 'Root-only credentials copy: %s\n' "$CREDENTIALS_FILE"
