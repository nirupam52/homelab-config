#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SSD_MOUNT=/mnt/ssd
HOMELAB_ROOT=$SSD_MOUNT/homelab
DOCKTAIL_ENV=$HOMELAB_ROOT/infra/docktail/.env
PIHOLE_ENV=$HOMELAB_ROOT/apps/pihole/.env
BOOT_CONFIG=
SECRET_VALUE=
TAILSCALE_IPV4=
MODE=full
PROJECT=
LLAMA_ENV=$HOMELAB_ROOT/apps/llama-cpp/.env
LLAMA_MODELS=$HOMELAB_ROOT/apps/llama-cpp/models
HERMES_ENV=$HOMELAB_ROOT/apps/hermes-agent/.env
HERMES_DATA=$HOMELAB_ROOT/apps/hermes-agent/data
HERMES_CONFIG=$HERMES_DATA/config.yaml

fail() {
    printf 'setup: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: sudo ./setup.sh [bootstrap|reconcile [project]]

No argument: runs bootstrap then reconcile. Use for the first run, after a
reboot, or when unsure which mode a change needs.

bootstrap: applies host-level state only (packages, SSD mount, Docker data
root, Tailscale connection, boot overlays, firewall, disabled services). It
never formats a disk. Idempotent but rarely needed once a host is set up.

reconcile [project]: syncs Compose files and secrets, then starts or updates
containers. project is one of: docktail, pihole, llama-cpp, dozzle,
hermes-agent. Omit it to reconcile all five. Fails fast if bootstrap has
never completed.
EOF
}

case "${1:-}" in
    "") [ $# -eq 0 ] || { usage >&2; exit 2; } ;;
    -h|--help) [ $# -eq 1 ] || { usage >&2; exit 2; }; usage; exit 0 ;;
    bootstrap) [ $# -eq 1 ] || { usage >&2; exit 2; }; MODE=bootstrap ;;
    reconcile) [ $# -le 2 ] || { usage >&2; exit 2; }; MODE=reconcile; PROJECT=${2:-} ;;
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

install_packages() {
    printf '%s\n' '== Install host packages =='
    need dpkg
    REQUIRED_PACKAGES='ca-certificates curl docker.io ufw unattended-upgrades locales'
    NEED_INSTALL=0
    for pkg in $REQUIRED_PACKAGES; do
        dpkg -s "$pkg" >/dev/null 2>&1 || NEED_INSTALL=1
    done
    docker compose version >/dev/null 2>&1 || NEED_INSTALL=1

    if [ "$NEED_INSTALL" -eq 0 ]; then
        printf '%s\n' 'Required packages already installed; skipping apt-get.'
        return 0
    fi

    apt-get update
    apt-get install -y $REQUIRED_PACKAGES

    if ! docker compose version >/dev/null 2>&1; then
        if ! apt-get install -y docker-compose-v2 >/dev/null 2>&1 || \
           ! docker compose version >/dev/null 2>&1; then
            apt-get install -y --no-install-recommends docker-compose-plugin
        fi
    fi
    docker compose version >/dev/null 2>&1 || \
        fail 'Docker Compose v2 could not be installed'
}

configure_locale() {
    printf '%s\n' '== Configure system locale =='
    if LANG=C LC_ALL=C locale -a | grep -Eiq '^en_US\.(utf8|UTF-8)$'; then
        printf '%s\n' 'en_US.UTF-8 already generated; skipping locale-gen.'
    else
        locale-gen en_US.UTF-8
        LANG=C LC_ALL=C locale -a | grep -Eiq '^en_US\.(utf8|UTF-8)$' || \
            fail 'en_US.UTF-8 locale was not generated'
    fi
    LANG=C LC_ALL=C update-locale LANG=en_US.UTF-8
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
        "$HOMELAB_ROOT/apps/llama-cpp/models" \
        "$HOMELAB_ROOT/apps/hermes-agent/data" \
        "$HOMELAB_ROOT/infra/docktail"
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

    tailscale up --accept-dns=false --advertise-tags=tag:server --ssh --accept-routes
    tailscale_ipv4
}

tailscale_ipv4() {
    TAILSCALE_IPV4=$(tailscale ip -4) || fail 'Tailscale is not connected'
    [ -n "$TAILSCALE_IPV4" ] || fail 'Tailscale IPv4 address is empty'
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
            if ! grep -Eq '^[[:space:]]*dtoverlay=disable-wifi([,[:space:]].*)?[[:space:]]*$' "$BOOT_CONFIG"; then
                printf '%s\n' 'dtoverlay=disable-wifi'
            fi
            if ! grep -Eq '^[[:space:]]*dtoverlay=disable-bt([,[:space:]].*)?[[:space:]]*$' "$BOOT_CONFIG"; then
                printf '%s\n' 'dtoverlay=disable-bt'
            fi
        } >> "$BOOT_CONFIG"
    fi
}

configure_firewall() {
    printf '%s\n' '== Configure Tailscale-only firewall =='
    if ufw show added | grep '^ufw allow ' | grep -vE ' on tailscale0([[:space:]]|$)' | grep -q .; then
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

ensure_docktail_secret() {
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
}

ensure_pihole_secret() {
    tailscale_ipv4
    if [ ! -f "$PIHOLE_ENV" ]; then
        ask_secret 'Pi-hole web password'
        [ -n "$SECRET_VALUE" ] || fail 'Pi-hole web password cannot be empty'
        printf 'PIHOLE_WEBPASSWORD=%s\n' "$SECRET_VALUE" > "$PIHOLE_ENV"
    fi
    if grep -Eq '^TAILSCALE_IPV4=' "$PIHOLE_ENV"; then
        sed -i "s/^TAILSCALE_IPV4=.*/TAILSCALE_IPV4=$TAILSCALE_IPV4/" "$PIHOLE_ENV"
    else
        printf 'TAILSCALE_IPV4=%s\n' "$TAILSCALE_IPV4" >> "$PIHOLE_ENV"
    fi
    chmod 600 "$PIHOLE_ENV"
}

ensure_llama_secret() {
    if [ ! -f "$LLAMA_ENV" ]; then
        ask_secret 'llama.cpp API key'
        [ -n "$SECRET_VALUE" ] || fail 'llama.cpp API key cannot be empty'
        printf 'LLAMA_API_KEY=%s\n' "$SECRET_VALUE" > "$LLAMA_ENV"
    fi
    grep -Eq '^LLAMA_API_KEY=.+$' "$LLAMA_ENV" || \
        fail 'LLAMA_API_KEY is missing from the llama.cpp .env'
    [ -n "$(find "$LLAMA_MODELS" -name '*.gguf' -print -quit)" ] || \
        fail "no .gguf models found in $LLAMA_MODELS; stage at least one before reconciling llama-cpp"
    chmod 600 "$LLAMA_ENV"
}

ensure_hermes_secret() {
    grep -Eq '^LLAMA_API_KEY=.+$' "$LLAMA_ENV" 2>/dev/null || \
        fail "LLAMA_API_KEY is missing from $LLAMA_ENV; run 'sudo ./setup.sh reconcile llama-cpp' first"
    docker network inspect llama-cpp >/dev/null 2>&1 || \
        fail "the llama-cpp Docker network does not exist yet; run 'sudo ./setup.sh reconcile llama-cpp' first"
    LLAMA_KEY=$(sed -n 's/^LLAMA_API_KEY=//p' "$LLAMA_ENV")

    if [ ! -f "$HERMES_ENV" ]; then
        ask 'Hermes dashboard username' 'admin'
        HERMES_USERNAME=$ANSWER
        ask_secret 'Hermes dashboard password'
        [ -n "$SECRET_VALUE" ] || fail 'Hermes dashboard password cannot be empty'
        HERMES_SECRET=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
        printf 'HERMES_DASHBOARD_USERNAME=%s\nHERMES_DASHBOARD_PASSWORD=%s\nHERMES_DASHBOARD_SECRET=%s\n' \
            "$HERMES_USERNAME" "$SECRET_VALUE" "$HERMES_SECRET" > "$HERMES_ENV"
    fi
    grep -Eq '^HERMES_DASHBOARD_USERNAME=.+$' "$HERMES_ENV" || fail "HERMES_DASHBOARD_USERNAME is missing from $HERMES_ENV"
    grep -Eq '^HERMES_DASHBOARD_PASSWORD=.+$' "$HERMES_ENV" || fail "HERMES_DASHBOARD_PASSWORD is missing from $HERMES_ENV"
    grep -Eq '^HERMES_DASHBOARD_SECRET=.+$' "$HERMES_ENV" || fail "HERMES_DASHBOARD_SECRET is missing from $HERMES_ENV"
    chmod 600 "$HERMES_ENV"

    mkdir -p "$HERMES_DATA"
    if [ ! -f "$HERMES_CONFIG" ]; then
        MODEL_COUNT=$(find "$LLAMA_MODELS" -maxdepth 1 -name '*.gguf' | wc -l | tr -d ' ')
        LLAMA_CTX=$(sed -n 's/^LLAMA_CTX_SIZE=//p' "$LLAMA_ENV")
        LLAMA_CTX=${LLAMA_CTX:-4096}
        {
            printf 'model:\n'
            printf '  provider: "llamacpp"\n'
            printf '  base_url: "http://llama:8080/v1"\n'
            printf '  api_key: "%s"\n' "$LLAMA_KEY"
            printf '  context_length: %s\n' "$LLAMA_CTX"
            if [ "$MODEL_COUNT" -eq 1 ]; then
                MODEL_DEFAULT=$(basename "$(find "$LLAMA_MODELS" -maxdepth 1 -name '*.gguf')" .gguf)
                printf '  default: "%s"\n' "$MODEL_DEFAULT"
            fi
            printf 'approvals:\n'
            printf '  mode: "manual"\n'
        } > "$HERMES_CONFIG"
    fi
    chmod 600 "$HERMES_CONFIG"
}

compose_up() {
    name=$1
    compose_file=$2
    env_file=$3
    if [ -n "$env_file" ]; then
        set -- --project-name "$name" --env-file "$env_file" -f "$compose_file"
    else
        set -- --project-name "$name" -f "$compose_file"
    fi
    docker compose "$@" config --quiet
    docker compose "$@" up -d
}

reconcile_project() {
    printf '== Reconcile %s ==\n' "$1"
    case "$1" in
        docktail)
            sync_compose "$REPO_ROOT/infra/docktail/compose.yaml" "$HOMELAB_ROOT/infra/docktail/compose.yaml"
            ensure_docktail_secret
            compose_up docktail "$HOMELAB_ROOT/infra/docktail/compose.yaml" "$DOCKTAIL_ENV"
            ;;
        pihole)
            sync_compose "$REPO_ROOT/apps/pihole/compose.yaml" "$HOMELAB_ROOT/apps/pihole/compose.yaml"
            ensure_pihole_secret
            compose_up pihole "$HOMELAB_ROOT/apps/pihole/compose.yaml" "$PIHOLE_ENV"
            ;;
        llama-cpp)
            sync_compose "$REPO_ROOT/apps/llama-cpp/compose.yaml" "$HOMELAB_ROOT/apps/llama-cpp/compose.yaml"
            ensure_llama_secret
            compose_up llama-cpp "$HOMELAB_ROOT/apps/llama-cpp/compose.yaml" "$LLAMA_ENV"
            ;;
        dozzle)
            sync_compose "$REPO_ROOT/apps/dozzle/compose.yaml" "$HOMELAB_ROOT/apps/dozzle/compose.yaml"
            compose_up dozzle "$HOMELAB_ROOT/apps/dozzle/compose.yaml" ''
            ;;
        hermes-agent)
            sync_compose "$REPO_ROOT/apps/hermes-agent/compose.yaml" "$HOMELAB_ROOT/apps/hermes-agent/compose.yaml"
            ensure_hermes_secret
            compose_up hermes-agent "$HOMELAB_ROOT/apps/hermes-agent/compose.yaml" "$HERMES_ENV"
            ;;
        *)
            fail "unknown project '$1' (expected docktail, pihole, llama-cpp, dozzle, or hermes-agent)"
            ;;
    esac
}

reconcile_all() {
    reconcile_project docktail
    reconcile_project pihole
    reconcile_project llama-cpp
    reconcile_project dozzle
    reconcile_project hermes-agent
}

require_bootstrapped() {
    mountpoint -q "$SSD_MOUNT" || \
        fail "$SSD_MOUNT is not mounted; run 'sudo ./setup.sh bootstrap' first"
    DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null) || DOCKER_ROOT=
    [ "$DOCKER_ROOT" = "$SSD_MOUNT/docker" ] || \
        fail "Docker data root is not $SSD_MOUNT/docker; run 'sudo ./setup.sh bootstrap' first"
    systemctl is-active --quiet tailscaled || \
        fail "Tailscale is not running; run 'sudo ./setup.sh bootstrap' first"
    tailscale_ipv4
}

run_bootstrap() {
    install_packages
    configure_locale
    mount_ssd
    configure_docker
    configure_tailscale
    configure_boot
    configure_firewall
    configure_services
}

case "$MODE" in
    full)
        run_bootstrap
        reconcile_all
        ;;
    bootstrap)
        run_bootstrap
        ;;
    reconcile)
        require_bootstrapped
        if [ -n "$PROJECT" ]; then
            reconcile_project "$PROJECT"
        else
            reconcile_all
        fi
        ;;
esac

printf '%s\n' '' 'Setup complete.'
case "$MODE" in
    full|bootstrap)
        printf '%s\n' 'Reboot once to apply the radio overlays, then verify the services in the README.'
        ;;
esac
