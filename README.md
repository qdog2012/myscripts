# Debian 12 server setup

`debian12-init.sh` installs 1Panel, Docker with Compose, OpenResty through the
1Panel app store, a small XFCE desktop, Google Chrome, and TigerVNC on a fresh
Debian 12 amd64 server. It also installs `tmux`, `htop`,
and `vim`, disables Vim mouse mode by default, and adds interactive Bash aliases
for `ll`, `cp -i`, and `mv -i`. Run it as root:

```bash
curl -fsSLO https://raw.githubusercontent.com/qdog2012/myscripts/main/debian12-init.sh
bash debian12-init.sh
```

If present, the script stops and disables the Alibaba Cloud `cloudmonitor` and
`aliyun` services. This also disables their cloud monitoring and remote-assistance
features. Aegis is left to manual management through the Alibaba Cloud console.
If an agent refuses to disable, the script reports it for manual action and
continues the rest of the setup.

The script prints the 1Panel URL (`/admin`), 1Panel account/password, and desktop
user when installation completes. It saves the generated panel password in
`/root/.config/debian12-init/credentials` with mode `0600` for a rerun. The
default 1Panel port is `8080` and its account is `admin`; set `PANEL_PORT` to
choose another port. The default desktop user is `desktop`; set `DESKTOP_USER`
to change it. Docker and OpenResty are installed by default. Set
`INSTALL_DOCKER=0` to skip both, or `INSTALL_OPENRESTY=0` to keep Docker without
OpenResty. On a rerun of a matching 1Panel installation, the script also
installs Docker and OpenResty if they are missing. New 1Panel installations live in
`/serverdata/1panel`. OpenResty appears under 1Panel's installed apps, with
HTTP on `80` and HTTPS on `18443`. The script places
`tls-forward-443.conf` in `/serverdata/1panel/www/stream.d`, mounts that
directory into OpenResty, and loads it in a `stream` block. Its TLS stream
listener binds to every IPv4 interface on port `443`; allow inbound TCP `443`
in the cloud security group for public access. Unknown SNI names forward to
`127.0.0.1:18443`. Docker and the OpenResty container start automatically
after a reboot.
Rerunning the script preserves custom SNI mappings in the installed stream
configuration while upgrading an old loopback-only 443 listener to public IPv4.
The default OpenResty HTTPS site has no certificate; configure a site and
certificate in 1Panel before expecting direct HTTPS requests to succeed.

An existing 1Panel installation at another base directory must be migrated
before rerunning this script; the script does not move its application data.

TigerVNC has no password and listens only on `127.0.0.1:5901`. From your own
computer, create an SSH tunnel and then connect a VNC viewer to
`127.0.0.1:5901`:

```bash
ssh -L 5901:127.0.0.1:5901 root@YOUR_SERVER
```

If SSH uses a custom port, add `-p PORT` to the tunnel command. The setup
script detects the port of its SSH session when printing tunnel examples;
set `SSH_TUNNEL_PORT` when running from a local console.

The XFCE session uses `zh_CN.UTF-8` and the lightweight WenQuanYi Micro Hei
font for Chinese text. Its default resolution is `1680x1050`; set
`VNC_GEOMETRY=WIDTHxHEIGHT` before running to change it. The 1Panel and VNC
systemd services are enabled at boot.

If the cloud firewall blocks direct access to the 1Panel port, use a tunnel:

```bash
ssh -L 8080:127.0.0.1:8080 root@YOUR_SERVER
```

Then open `http://127.0.0.1:8080/admin`. To use the public 1Panel URL,
allow inbound TCP `8080` in the cloud firewall or security group.

The script uses the official 1Panel `v1.10.34-lts` package and verifies its
SHA-256 checksum. It installs Chrome from Google's signed apt repository and
disables Chrome's on-device AI model through the managed
`GenAILocalFoundationalModelSettings` policy. This keeps the setting off for all
Chrome profiles and shows it as managed in Chrome settings. For
machines with less than 2 GiB RAM and no active swap, it adds a 2 GiB swap file.
The desktop Chrome launcher clears stale profile locks left by a server host-name
change when no Chrome process is running.

The system time zone is detected from the server's public IPv4 address using
IP geolocation. An unsuccessful lookup leaves the existing time zone unchanged.
Set `SERVER_TIMEZONE=Asia/Shanghai` to choose an IANA time zone explicitly, or
`SERVER_TIMEZONE=keep` to preserve the current setting.

The script also selects a date-format locale from the public IP's country. It
sets `LC_TIME` for the system and XFCE session while keeping the desktop UI in
Chinese. It also sets the XFCE panel clock to `%x`, so its visible date follows
`LC_TIME`. If geolocation fails, it keeps the prior date locale. Set
`DATE_LOCALE=zh_CN.UTF-8` to override the automatic selection, or
`DATE_LOCALE=keep` to preserve the current date locale.

## Ubuntu 24.04 Docker installation

For a standalone Docker installation on Ubuntu 24.04 (amd64 or arm64), run:

```bash
sudo bash ubuntu24-install-docker.sh
```

`ubuntu24-install-docker.sh` installs Docker Engine, containerd, Buildx, and
the Compose plugin from Docker's signed apt repository. It enables Docker at
boot and verifies the daemon and plugins. It can be rerun. It stops with an
error if conflicting distro Docker/containerd packages are installed, so an
existing deployment is not replaced implicitly.
