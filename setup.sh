#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SSD_MOUNT=/mnt/ssd
HOMELAB_ROOT=$SSD_MOUNT/homelab
BOOT_CONFIG=
SECRET_VALUE=

fail() {
    printf 'setup: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: sudo ./setup.sh

Guides a Raspberry Pi OS Lite host through the one-time host setup and can be
run again to reconcile the same configuration. It never formats a disk.
EOF
}

case "${1:-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

need() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

ask() {
    printf '%s [%s]: ' "$1" "$2" >&2
    IFS= read -r ANSWER
    ANSWER=${ANSWER:-$2}
}

ask_secret() {
    printf '%s: ' "$1" >&2
    stty -echo
    IFS= read -r SECRET_VALUE
    stty echo
    printf '\n' >&2
}

install_docker_repository() {
    DOCKER_KEYRING=${1:-/etc/apt/keyrings/docker.asc}
    DOCKER_SOURCES=${2:-/etc/apt/sources.list.d/docker.sources}
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
        debian:*|raspbian:*|*:debian*) DOCKER_REPO_OS=debian ;;
        ubuntu:*|*:ubuntu*) DOCKER_REPO_OS=ubuntu ;;
        *) fail "Docker Compose v2 is unavailable for ${ID:-unknown}" ;;
    esac

    DOCKER_SUITE=${VERSION_CODENAME:-}
    [ -n "$DOCKER_SUITE" ] || fail 'Docker repository codename was not found'
    need dpkg
    DOCKER_ARCH=$(dpkg --print-architecture)
    case "$DOCKER_ARCH" in
        amd64|arm64|armhf|ppc64el|s390x) ;;
        *) fail "Docker repository does not support architecture $DOCKER_ARCH" ;;
    esac

    DOCKER_KEYRING_DIR=${DOCKER_KEYRING%/*}
    DOCKER_SOURCES_DIR=${DOCKER_SOURCES%/*}
    install -m 0755 -d "$DOCKER_KEYRING_DIR" "$DOCKER_SOURCES_DIR"
    curl -fsSL "https://download.docker.com/linux/$DOCKER_REPO_OS/gpg" \
        -o "$DOCKER_KEYRING"
    chmod a+r "$DOCKER_KEYRING"
    cat > "$DOCKER_SOURCES" <<EOF
Types: deb
URIs: https://download.docker.com/linux/$DOCKER_REPO_OS
Suites: $DOCKER_SUITE
Components: stable
Architectures: $DOCKER_ARCH
Signed-By: $DOCKER_KEYRING
EOF
    apt-get update
}

install_packages() {
    printf '%s\n' '== Install host packages =='
    apt-get update
    apt-get install -y ca-certificates curl docker.io ufw unattended-upgrades

    if ! docker compose version >/dev/null 2>&1; then
        if ! apt-get install -y docker-compose-v2 >/dev/null 2>&1 || \
           ! docker compose version >/dev/null 2>&1; then
            install_docker_repository
            apt-get install -y docker-compose-plugin
        fi
    fi
    docker compose version >/dev/null 2>&1 || \
        fail 'Docker Compose v2 could not be installed'
}

sync_compose() {
    source=$1
    destination=$2
    if [ "$source" != "$destination" ]; then
        install -D -m 0644 "$source" "$destination"
    fi
}


mount_ssd() {
    printf '%s\n' '== Mount SSD =='
    need blkid
    need mountpoint
    mkdir -p "$SSD_MOUNT"

    if ! mountpoint -q "$SSD_MOUNT"; then
        if grep -Eq "^[[:space:]]*UUID=[^[:space:]]+[[:space:]]+$SSD_MOUNT[[:space:]]" /etc/fstab; then
            mount "$SSD_MOUNT" || fail "could not mount $SSD_MOUNT from /etc/fstab"
        else
            printf '%s\n' 'The SSD partition must already contain the data you want to keep.'
            printf '%s' 'SSD partition (for example /dev/sda1): ' >&2
            IFS= read -r SSD_DEVICE
            [ -b "$SSD_DEVICE" ] || fail "$SSD_DEVICE is not a block device"

            SSD_UUID=$(blkid -s UUID -o value "$SSD_DEVICE")
            SSD_TYPE=$(blkid -s TYPE -o value "$SSD_DEVICE")
            [ -n "$SSD_UUID" ] || fail "$SSD_DEVICE has no filesystem UUID"
            [ -n "$SSD_TYPE" ] || fail "$SSD_DEVICE has no filesystem type"

            if awk -v mount="$SSD_MOUNT" '$2 == mount { found = 1 } END { exit !found }' /etc/fstab; then
                fail "/etc/fstab already has a different entry for $SSD_MOUNT"
            fi
            printf 'UUID=%s %s %s defaults,noatime,nofail 0 2\n' \
                "$SSD_UUID" "$SSD_MOUNT" "$SSD_TYPE" >> /etc/fstab
            mount "$SSD_MOUNT" || fail "could not mount $SSD_MOUNT"
        fi
    fi

    mountpoint -q "$SSD_MOUNT" || fail "$SSD_MOUNT is not mounted"
    mkdir -p "$HOMELAB_ROOT/apps/pihole/data" \
        "$HOMELAB_ROOT/apps/pihole/dnsmasq.d" \
        "$HOMELAB_ROOT/infra/docktail"
    sync_compose "$REPO_ROOT/infra/docktail/compose.yaml" "$HOMELAB_ROOT/infra/docktail/compose.yaml"
    sync_compose "$REPO_ROOT/apps/pihole/compose.yaml" "$HOMELAB_ROOT/apps/pihole/compose.yaml"
    sync_compose "$REPO_ROOT/apps/dozzle/compose.yaml" "$HOMELAB_ROOT/apps/dozzle/compose.yaml"
}

configure_docker() {
    printf '%s\n' '== Configure Docker on the SSD =='
    mkdir -p "$SSD_MOUNT/docker"

    if [ -f /etc/docker/daemon.json ] && ! cmp -s "$REPO_ROOT/docker/daemon.json" /etc/docker/daemon.json; then
        printf '%s\n' '/etc/docker/daemon.json differs from this repository.'
        printf '%s' 'Replace it with the SSD data-root configuration? [y/N] ' >&2
        IFS= read -r ANSWER
        case "$ANSWER" in y|Y) ;; *) fail 'Docker configuration was not changed' ;; esac
    fi
    install -D -m 0644 "$REPO_ROOT/docker/daemon.json" /etc/docker/daemon.json

    systemctl enable --now docker
    if [ "$(docker info --format '{{.DockerRootDir}}')" != "$SSD_MOUNT/docker" ]; then
        systemctl restart docker
    fi
    [ "$(docker info --format '{{.DockerRootDir}}')" = "$SSD_MOUNT/docker" ] || \
        fail "Docker data root is not $SSD_MOUNT/docker"
}

configure_tailscale() {
    printf '%s\n' '== Connect Tailscale =='
    if ! command -v tailscale >/dev/null 2>&1; then
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
    systemctl enable --now tailscaled

    tailscale up --ssh --advertise-tags=tag:server
    tailscale ip -4 >/dev/null 2>&1 || fail 'Tailscale is not connected'
}

configure_boot() {
    printf '%s\n' '== Disable Wi-Fi and Bluetooth at boot =='
    if [ -f /boot/firmware/config.txt ]; then
        BOOT_CONFIG=/boot/firmware/config.txt
    elif [ -f /boot/config.txt ]; then
        BOOT_CONFIG=/boot/config.txt
    else
        fail 'Raspberry Pi boot config was not found'
    fi

    if ! grep -Eq '^[[:space:]]*dtoverlay=disable-wifi([,[:space:]].*)?[[:space:]]*$' "$BOOT_CONFIG" || \
       ! grep -Eq '^[[:space:]]*dtoverlay=disable-bt([,[:space:]].*)?[[:space:]]*$' "$BOOT_CONFIG"; then
        [ -e "$BOOT_CONFIG.homelab.bak" ] || cp -p "$BOOT_CONFIG" "$BOOT_CONFIG.homelab.bak"
        {
            printf '\n[all]\n'
            printf '%s\n' 'dtoverlay=disable-wifi'
            printf '%s\n' 'dtoverlay=disable-bt'
        } >> "$BOOT_CONFIG"
    fi
}

configure_firewall() {
    printf '%s\n' '== Configure Tailscale-only firewall =='
    if ufw show added | grep '^ufw allow ' | grep -v ' on tailscale0 ' | grep -q .; then
        fail 'UFW has an existing non-Tailscale allow rule; remove it manually before continuing'
    fi

    if grep -Eq '^[[:space:]]*IPV6[[:space:]]*=' /etc/default/ufw; then
        sed -i 's/^[[:space:]]*IPV6[[:space:]]*=.*/IPV6=yes/' /etc/default/ufw
    else
        printf '%s\n' 'IPV6=yes' >> /etc/default/ufw
    fi
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow in on tailscale0
    ufw --force enable
}

disable_service() {
    unit=$1
    if systemctl list-unit-files --no-legend "$unit" 2>/dev/null | grep -q "^$unit[[:space:]]"; then
        systemctl disable --now "$unit"
    fi
}

configure_services() {
    printf '%s\n' '== Disable unused services =='
    if systemctl is-enabled --quiet ssh.service 2>/dev/null || systemctl is-active --quiet ssh.service 2>/dev/null; then
        printf '%s\n' 'Tailscale SSH must be tested from another tailnet device before system SSH is disabled.'
        printf '%s' 'Have you tested Tailscale SSH and want to disable system SSH? [y/N] ' >&2
        IFS= read -r ANSWER
        case "$ANSWER" in y|Y) ;; *) fail 'system SSH remains enabled' ;; esac
    fi

    disable_service ssh.service
    disable_service ssh.socket
    disable_service sshd.service
    disable_service sshd.socket
    disable_service avahi-daemon.service
    disable_service triggerhappy.service
    disable_service bluetooth.service
    systemctl enable --now apt-daily-upgrade.timer
}

configure_secrets() {
    printf '%s\n' '== Configure DockTail and Pi-hole secrets =='
    DOCKTAIL_ENV=$HOMELAB_ROOT/infra/docktail/.env
    PIHOLE_ENV=$HOMELAB_ROOT/apps/pihole/.env

    if [ ! -f "$DOCKTAIL_ENV" ]; then
        ask 'Tailscale OAuth client ID' ''
        [ -n "$ANSWER" ] || fail 'OAuth client ID cannot be empty'
        DOCKTAIL_CLIENT_ID=$ANSWER
        ask_secret 'Tailscale OAuth client secret'
        [ -n "$SECRET_VALUE" ] || fail 'OAuth client secret cannot be empty'
        DOCKTAIL_CLIENT_SECRET=$SECRET_VALUE
        printf 'TAILSCALE_OAUTH_CLIENT_ID=%s\nTAILSCALE_OAUTH_CLIENT_SECRET=%s\n' \
            "$DOCKTAIL_CLIENT_ID" "$DOCKTAIL_CLIENT_SECRET" > "$DOCKTAIL_ENV"
    fi
    chmod 600 "$DOCKTAIL_ENV"

    if [ ! -f "$PIHOLE_ENV" ]; then
        ask_secret 'Pi-hole web password'
        [ -n "$SECRET_VALUE" ] || fail 'Pi-hole web password cannot be empty'
        printf 'PIHOLE_WEBPASSWORD=%s\n' "$SECRET_VALUE" > "$PIHOLE_ENV"
    fi
    chmod 600 "$PIHOLE_ENV"
}

start_stack() {
    printf '%s\n' '== Start DockTail and applications =='
    docker compose --project-name docktail --env-file "$DOCKTAIL_ENV" \
        -f "$HOMELAB_ROOT/infra/docktail/compose.yaml" config --quiet
    docker compose --project-name docktail --env-file "$DOCKTAIL_ENV" \
        -f "$HOMELAB_ROOT/infra/docktail/compose.yaml" up -d

    docker compose --project-name pihole --env-file "$PIHOLE_ENV" \
        -f "$HOMELAB_ROOT/apps/pihole/compose.yaml" config --quiet
    docker compose --project-name pihole --env-file "$PIHOLE_ENV" \
        -f "$HOMELAB_ROOT/apps/pihole/compose.yaml" up -d

    docker compose --project-name dozzle \
        -f "$HOMELAB_ROOT/apps/dozzle/compose.yaml" config --quiet
    docker compose --project-name dozzle \
        -f "$HOMELAB_ROOT/apps/dozzle/compose.yaml" up -d
}

install_packages
mount_ssd
configure_docker
configure_tailscale
configure_boot
configure_firewall
configure_services
configure_secrets
start_stack

printf '%s\n' '' 'Setup complete.'
printf '%s\n' 'Reboot once to apply the radio overlays, then verify the services in the README.'
