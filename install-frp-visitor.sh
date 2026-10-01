#!/usr/bin/env bash
# Run on the other Linux server, not on the browser's computer.
set -Eeuo pipefail
umask 027

FRP_VERSION=0.71.0
FRP_SHA256=84f27e39f11169f7adcef8e8b70c9329de17747b1f14dad9fb95eef5682ea716
BASE=/serverdata/frp-visitor
BIND_ADDR=${FRP_VISITOR_BIND_ADDR:-127.0.0.1}
BIND_PORT=${FRP_VISITOR_BIND_PORT:-443}
BUNDLE=${1:?Usage: install-frp-visitor.sh /path/to/visitor-client.tar.gz}
[[ $EUID -eq 0 ]] || { echo 'Run this script as root.' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'This installer supports amd64 only.' >&2; exit 1; }
[[ -f $BUNDLE ]] || { echo 'Visitor bundle was not found.' >&2; exit 1; }
for command in curl tar sha256sum python3 ss; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
python3 - "$BIND_ADDR" "$BIND_PORT" <<'PY'
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
if not 1 <= int(sys.argv[2]) <= 65535:
    raise SystemExit('Invalid listen port.')
PY
if [[ -e $BASE && ! -f $BASE/managed-by-myscripts ]]; then
    echo "$BASE is not managed by this installer." >&2; exit 1
fi
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT
tar -tzf "$BUNDLE" > "$temp_dir/entries"
[[ $(wc -l < "$temp_dir/entries") -eq 4 ]] &&
    ! grep -Ev '^(visitor.toml|ca.crt|visitor.crt|visitor.key)$' "$temp_dir/entries" || {
    echo 'Unexpected visitor bundle contents.' >&2; exit 1;
}
tar -xzf "$BUNDLE" -C "$temp_dir"
if [[ ! -x /usr/local/bin/frpc || $(/usr/local/bin/frpc --version) != "$FRP_VERSION" ]]; then
    curl -fSL --retry 3 --connect-timeout 15 --max-time 180 \
        "https://github.com/fatedier/frp/releases/download/v$FRP_VERSION/frp_${FRP_VERSION}_linux_amd64.tar.gz" \
        -o "$temp_dir/frp.tar.gz"
    printf '%s  %s\n' "$FRP_SHA256" "$temp_dir/frp.tar.gz" | sha256sum --check --status
    tar -xzf "$temp_dir/frp.tar.gz" -C "$temp_dir"
    install -m 0755 "$temp_dir/frp_${FRP_VERSION}_linux_amd64/frpc" /usr/local/bin/frpc
fi
getent group frp >/dev/null || groupadd --system frp
id frp >/dev/null 2>&1 || useradd --system --gid frp --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin frp
install -d -m 0750 -o root -g frp "$BASE"
touch "$BASE/managed-by-myscripts"
for file in ca.crt visitor.crt visitor.key; do install -m 0640 -o root -g frp "$temp_dir/$file" "$BASE/$file"; done
python3 - "$temp_dir/visitor.toml" "$BASE/visitor.toml" "$BASE" "$BIND_ADDR" "$BIND_PORT" <<'PY'
import sys
source, destination, base, address, port = sys.argv[1:]
text = open(source).read()
for name in ('ca.crt', 'visitor.crt', 'visitor.key'):
    text = text.replace('"' + name + '"', '"' + base + '/' + name + '"')
text = text.replace('bindAddr = "127.0.0.1"', 'bindAddr = "' + address + '"')
text = text.replace('bindPort = 443', 'bindPort = ' + port)
with open(destination, 'w') as output:
    output.write(text)
PY
chown root:frp "$BASE/visitor.toml"
chmod 0640 "$BASE/visitor.toml"
/usr/local/bin/frpc verify -c "$BASE/visitor.toml"
cat > /etc/systemd/system/frpc-visitor.service <<EOF
[Unit]
Description=MyScripts FRP STCP visitor
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
User=frp
Group=frp
ExecStart=/usr/local/bin/frpc -c $BASE/visitor.toml
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable frpc-visitor
systemctl restart frpc-visitor
visitor_ready() {
    local pid
    pid=$(systemctl show frpc-visitor --property=MainPID --value)
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
    ss -lntpH "sport = :$BIND_PORT" | awk -v endpoint="$BIND_ADDR:$BIND_PORT" -v pid="$pid" \
        '$4 == endpoint && index($0, "pid=" pid ",") {found=1} END {exit !found}'
}
for attempt in {1..20}; do
    if visitor_ready; then break; fi
    sleep 1
done
systemctl is-active --quiet frpc-visitor && visitor_ready || {
    echo 'Visitor listener is not ready; check journalctl -u frpc-visitor.' >&2; exit 1;
}
echo "Visitor configured on $BIND_ADDR:$BIND_PORT. Check registration: journalctl -u frpc-visitor -n 30 --no-pager"
echo 'Only configured SNI destinations can pass through the upstream OpenResty listener.'
