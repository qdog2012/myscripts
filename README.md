# Debian 12 server setup

`debian12-init.sh` installs 1Panel, a small XFCE desktop, Google Chrome, and
TigerVNC on a fresh Debian 12 amd64 server. Run it as root:

```bash
curl -fsSLO https://raw.githubusercontent.com/qdog2012/myscripts/main/debian12-init.sh
bash debian12-init.sh
```

The script prints the 1Panel URL (`/admin`), 1Panel account/password, and desktop
user when installation completes. It saves the generated panel password in
`/root/.config/debian12-init/credentials` with mode `0600` for a rerun. The
default 1Panel port is `8080` and its account is `admin`; set `PANEL_PORT` to
choose another port. The default desktop user is `desktop`; set `DESKTOP_USER`
to change it. Docker is skipped by default. Set `INSTALL_DOCKER=1` if you want
the upstream 1Panel installer to add Docker and Compose for container apps.

TigerVNC has no password and listens only on `127.0.0.1:5901`. From your own
computer, create an SSH tunnel and then connect a VNC viewer to
`127.0.0.1:5901`:

```bash
ssh -L 5901:127.0.0.1:5901 root@YOUR_SERVER
```

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
SHA-256 checksum. It installs Chrome from Google's signed apt repository. For
machines with less than 2 GiB RAM and no active swap, it adds a 2 GiB swap file.

The system time zone is detected from the server's public IPv4 address using
IP geolocation. An unsuccessful lookup leaves the existing time zone unchanged.
Set `SERVER_TIMEZONE=Asia/Shanghai` to choose an IANA time zone explicitly, or
`SERVER_TIMEZONE=keep` to preserve the current setting.
