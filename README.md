# Debian 12 server setup

`debian12-init.sh` installs 1Panel, a small XFCE desktop, Google Chrome, and
TigerVNC on a fresh Debian 12 amd64 server. Run it as root:

```bash
curl -fsSLO https://raw.githubusercontent.com/qdog2012/myscripts/main/debian12-init.sh
bash debian12-init.sh
```

The script prints the 1Panel URL (`/admin`), 1Panel account/password, desktop
user, and VNC password when installation completes. It also saves the generated
passwords in `/root/.config/debian12-init/credentials` with mode `0600` for a
rerun. The default 1Panel port is `10086`; set `PANEL_PORT` before running to
choose another port. The default desktop user is `desktop`; set `DESKTOP_USER`
to change it. Docker is skipped by default. Set `INSTALL_DOCKER=1` if you want
the upstream 1Panel installer to add Docker and Compose for container apps.

TigerVNC listens only on `127.0.0.1:5901`. From your own computer, create an
SSH tunnel and then connect a VNC viewer to `127.0.0.1:5901`:

```bash
ssh -L 5901:127.0.0.1:5901 root@YOUR_SERVER
```

If the cloud firewall blocks direct access to the 1Panel port, use a tunnel:

```bash
ssh -L 10086:127.0.0.1:10086 root@YOUR_SERVER
```

Then open `http://127.0.0.1:10086/admin`. To use the public 1Panel URL,
allow inbound TCP `10086` in the cloud firewall or security group.

The script uses the official 1Panel `v1.10.34-lts` package and verifies its
SHA-256 checksum. It installs Chrome from Google's signed apt repository. For
machines with less than 2 GiB RAM and no active swap, it adds a 2 GiB swap file.
