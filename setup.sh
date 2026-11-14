#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SSD_MOUNT=/mnt/ssd
HOMELAB_ROOT=$SSD_MOUNT/homelab
DOCKTAIL_ENV=$HOMELAB_ROOT/infra/docktail/.env
PIHOLE_ENV=$HOMELAB_ROOT/apps/pihole/.env
BOOT_CONFIG=
SECRET_VALUE=
TAILSCALE_IPV4=
INCUS_POOL_DIR=$SSD_MOUNT/incus
MODE=full
PROJECT=

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
root, Tailscale connection, boot overlays, firewall, disabled services,
Incus for agent VMs). It never formats a disk. Idempotent but rarely needed
once a host is set up.

reconcile [project]: syncs Compose files and secrets, then starts or updates
containers. project is one of: docktail, pihole, dozzle. Omit it to
reconcile all three. Fails fast if bootstrap has never completed.

reconcile <vm>: creates the agent VM vms/<vm>/ describes if it is missing,
applies its CPU/memory/disk limits, joins it to the tailnet once, and re-runs
its provisioning script. vm is one of: coder, hermes. VMs are never part of a
plain `reconcile`, so routine container updates never touch running agents.
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
    REQUIRED_PACKAGES='ca-certificates curl docker.io openssh-client ufw unattended-upgrades locales'
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
        if grep -Eq "^[[:space:]]*UUID=[^[:space:]]+[[:space:]]+${SSD_MOUNT}[[:space:]]" /etc/fstab; then
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
    # The only non-Tailscale inbound rules allowed are the DHCP/DNS ones
    # configure_incus adds for the agent VM bridge.
    if ufw show added | grep '^ufw allow ' | grep -vE ' on (tailscale0|incusbr0)([[:space:]]|$)' | grep -q .; then
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

configure_incus() {
    printf '%s\n' '== Configure Incus for agent VMs =='
    [ -c /dev/kvm ] || fail '/dev/kvm is missing; this kernel cannot run virtual machines'
    INCUS_PACKAGES='incus qemu-system-arm qemu-efi-aarch64'
    NEED_INSTALL=0
    for pkg in $INCUS_PACKAGES; do
        dpkg -s "$pkg" >/dev/null 2>&1 || NEED_INSTALL=1
    done
    if [ "$NEED_INSTALL" -eq 1 ]; then
        apt-get update
        # shellcheck disable=SC2086
        apt-get install -y $INCUS_PACKAGES || \
            fail 'could not install Incus (Debian 12 needs bookworm-backports enabled first)'
    fi
    systemctl enable --now incus.service
    incus admin waitready --timeout=60
    # ACLs on bridge networks need the nftables firewall driver.
    incus info | grep -Eq '^[[:space:]]+firewall:[[:space:]]+nftables$' || \
        fail 'Incus is not using the nftables firewall driver; network ACLs would not apply'

    # VM disks, the image cache and backups all live on the SSD.
    incus storage show default >/dev/null 2>&1 || \
        incus storage create default dir source="$INCUS_POOL_DIR"
    incus storage show default | grep -q '^driver: dir$' && \
        [ "$(incus storage get default source)" = "$INCUS_POOL_DIR" ] || \
        fail "Incus pool 'default' is not a dir pool at $INCUS_POOL_DIR; move or delete it first"
    for volume in images backups; do
        incus storage volume show default "$volume" >/dev/null 2>&1 || \
            incus storage volume create default "$volume"
        [ "$(incus config get "storage.${volume}_volume")" = "default/$volume" ] || \
            incus config set "storage.${volume}_volume=default/$volume"
    done

    # The ACL's carve-outs assume exactly this address; IPv6 stays off so
    # the IPv4-only ACL covers everything.
    incus network show incusbr0 >/dev/null 2>&1 || incus network create incusbr0
    incus network set incusbr0 ipv4.address=10.250.0.1/24 ipv4.nat=true ipv6.address=none
    incus network acl show agent-egress >/dev/null 2>&1 || incus network acl create agent-egress
    incus network acl edit agent-egress < "$REPO_ROOT/infra/incus/agent-egress.yaml"
    incus profile show agent-vm >/dev/null 2>&1 || incus profile create agent-vm
    incus profile edit agent-vm < "$REPO_ROOT/infra/incus/agent-vm.yaml"

    # VMs get DHCP and DNS from Incus on the bridge. UFW's forward policy
    # (and Docker's) is DROP, so VM traffic must be routed explicitly;
    # replies come back through UFW's conntrack rule. Which destinations a VM
    # may reach is decided by the agent-egress ACL, not here.
    ufw allow in on incusbr0 to any port 67 proto udp
    ufw allow in on incusbr0 to any port 53
    ufw route allow in on incusbr0
}

disable_service() {
    unit=$1
    if systemctl list-unit-files --no-legend "$unit" 2>/dev/null | grep -q "^${unit}[[:space:]]"; then
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

compose_up() {
    name=$1
    compose_file=$2
    env_file=$3
    up_flags=${4:-}
    if [ -n "$env_file" ]; then
        set -- --project-name "$name" --env-file "$env_file" -f "$compose_file"
    else
        set -- --project-name "$name" -f "$compose_file"
    fi
    docker compose "$@" config --quiet
    # shellcheck disable=SC2086
    docker compose "$@" up -d $up_flags
}

vm_config_set() {
    [ "$(incus config get "$1" "$2")" = "$3" ] || incus config set "$1" "$2=$3"
}

join_tailnet() {
    name=$1
    if ! incus exec "$name" -- tailscale status >/dev/null 2>&1; then
        printf 'Join %s to the tailnet with a pre-approved, single-use tag:agent auth key.\n' "$name"
        ask_secret "Tailscale auth key for $name"
        [ -n "$SECRET_VALUE" ] || fail 'Tailscale auth key cannot be empty'
        printf '%s' "$SECRET_VALUE" | \
            incus exec "$name" -- sh -c 'umask 077 && cat > /run/tailscale-authkey'
        joined=0
        incus exec "$name" -- tailscale up --auth-key=file:/run/tailscale-authkey \
            --advertise-tags=tag:agent --hostname="$name" --ssh --accept-dns=false || joined=$?
        incus exec "$name" -- rm -f /run/tailscale-authkey
        [ "$joined" -eq 0 ] || fail "$name could not join the tailnet"
    fi
    # VMs resolve names through Incus on the bridge: Pi-hole is on the
    # tailnet, which tag:agent cannot reach.
    incus exec "$name" -- tailscale set --ssh --accept-dns=false --auto-update
}

reconcile_vm() {
    name=$1
    command -v incus >/dev/null 2>&1 || fail "Incus is not installed; run 'sudo ./setup.sh bootstrap' first"
    # shellcheck disable=SC1090
    . "$REPO_ROOT/vms/$name/vm.conf"

    if incus info "$name" >/dev/null 2>&1; then
        # Memory and CPU changes may only apply after the VM restarts; disks
        # can grow but never shrink.
        vm_config_set "$name" limits.cpu "$VM_CPUS"
        vm_config_set "$name" limits.memory "$VM_MEMORY"
        [ "$(incus config device get "$name" root size)" = "$VM_DISK" ] || \
            incus config device set "$name" root size="$VM_DISK"
        incus info "$name" | grep -q '^Status: RUNNING$' || incus start "$name"
    else
        incus launch "$VM_IMAGE" "$name" --vm --profile agent-vm \
            --config limits.cpu="$VM_CPUS" --config limits.memory="$VM_MEMORY" \
            --device root,size="$VM_DISK"
    fi

    tries=0
    until incus exec "$name" -- true >/dev/null 2>&1; do
        tries=$((tries + 1))
        [ "$tries" -le 90 ] || fail "$name did not come up within 3 minutes"
        sleep 2
    done
    # First boot: let cloud-init finish before apt runs. A degraded result
    # is not fatal; base.sh below fails loudly if the VM is unusable.
    incus exec "$name" -- cloud-init status --wait >/dev/null 2>&1 || true

    # Provisioning scripts are desired state: replace the VM's copy wholesale.
    incus exec "$name" -- rm -rf /opt/homelab
    incus exec "$name" -- mkdir -p /opt/homelab
    incus file push "$REPO_ROOT/vms/base.sh" "$name/opt/homelab/base.sh"
    incus file push -r "$REPO_ROOT/vms/$name" "$name/opt/homelab/"
    incus exec "$name" -- sh /opt/homelab/base.sh
    join_tailnet "$name"
    incus exec "$name" -- sh "/opt/homelab/$name/provision.sh"
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
        dozzle)
            sync_compose "$REPO_ROOT/apps/dozzle/compose.yaml" "$HOMELAB_ROOT/apps/dozzle/compose.yaml"
            compose_up dozzle "$HOMELAB_ROOT/apps/dozzle/compose.yaml" ''
            ;;
        *)
            [ -f "$REPO_ROOT/vms/$1/vm.conf" ] || \
                fail "unknown project '$1' (expected docktail, pihole, dozzle, or a VM under vms/)"
            reconcile_vm "$1"
            ;;
    esac
}

reconcile_all() {
    reconcile_project docktail
    reconcile_project pihole
    reconcile_project dozzle
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
    configure_incus
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
