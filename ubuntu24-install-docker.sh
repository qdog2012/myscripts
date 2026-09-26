#!/usr/bin/env bash
# Install Docker Engine, Buildx, and Compose from Docker's official Ubuntu repo.
set -Eeuo pipefail

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || die 'Run as root: sudo bash ubuntu24-install-docker.sh'
[[ $(. /etc/os-release; printf '%s:%s' "$ID" "$VERSION_ID") == ubuntu:24.04 ]] || die 'Ubuntu 24.04 is required.'
arch=$(dpkg --print-architecture)
[[ $arch == amd64 || $arch == arm64 ]] || die "Unsupported architecture: $arch"

# Do not silently replace a distro-managed container runtime on an existing host.
for package in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) == 'install ok installed' ]]; then
        die "Conflicting package $package is installed. Review its workloads before replacing it with Docker CE."
    fi
done

list_file=/etc/apt/sources.list.d/docker.list
sources_file=/etc/apt/sources.list.d/docker.sources
if [[ -e $list_file && -e $sources_file ]]; then
    die "Both $list_file and $sources_file exist; keep one Docker apt source."
elif [[ -e $list_file ]]; then
    grep -Fq 'https://download.docker.com/linux/ubuntu noble stable' "$list_file" || die "Unexpected Docker apt source in $list_file"
elif [[ -e $sources_file ]]; then
    grep -Fq 'https://download.docker.com/linux/ubuntu' "$sources_file" || die "Unexpected Docker apt source in $sources_file"
    grep -Eq '^Suites:[[:space:]]+noble([[:space:]]|$)' "$sources_file" || die "Docker apt source is not for Ubuntu 24.04: $sources_file"
fi

export DEBIAN_FRONTEND=noninteractive
log 'Installing apt prerequisites'
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl

if [[ -e $list_file ]]; then
    log "Using existing Docker apt source: $list_file"
elif [[ -e $sources_file ]]; then
    log "Using existing Docker apt source: $sources_file"
else
    log 'Adding Docker official signed apt source'
    install -d -m 0755 /etc/apt/keyrings
    key_tmp=$(mktemp /tmp/docker-key.XXXXXXXX)
    trap 'rm -f -- "$key_tmp"' EXIT
    curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o "$key_tmp"
    install -m 0644 "$key_tmp" /etc/apt/keyrings/docker.asc
    cat > "$sources_file" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    chmod 0644 "$sources_file"
fi

log 'Installing Docker Engine, Buildx, and Compose'
apt-get update
apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now containerd.service docker.service
systemctl is-active --quiet docker.service || die 'Docker service is not active.'
systemctl is-enabled --quiet docker.service || die 'Docker service is not enabled at boot.'
docker info >/dev/null || die 'Docker daemon is unavailable.'
docker compose version >/dev/null || die 'Docker Compose plugin is unavailable.'
docker buildx version >/dev/null || die 'Docker Buildx plugin is unavailable.'

log 'Docker installation complete'
docker --version
docker compose version
docker buildx version
