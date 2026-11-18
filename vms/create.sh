#!/bin/sh
# Create an agent VM once: launch it, run vms/base.sh, join it to the tailnet
# as tag:agent, then run vms/<vm>/provision.sh. Rebuild by deleting the VM
# (`sudo incus delete --force <vm>`) and running this again.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

fail() {
    printf 'create: %s\n' "$1" >&2
    exit 1
}

[ $# -eq 1 ] || { printf 'Usage: sudo ./vms/create.sh coder|hermes\n' >&2; exit 2; }
NAME=$1
case "$NAME" in
    coder) CPUS=3 MEMORY=6GiB DISK=60GiB ;;
    hermes) CPUS=2 MEMORY=3GiB DISK=30GiB ;;
    *) fail "unknown VM '$NAME' (expected coder or hermes)" ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

incus profile show agent-vm >/dev/null 2>&1 || \
    fail "the agent-vm profile is missing; run 'sudo ./setup.sh bootstrap' first"
! incus info "$NAME" >/dev/null 2>&1 || \
    fail "$NAME already exists; to rebuild it: sudo incus delete --force $NAME"

incus launch images:debian/13/cloud "$NAME" --vm --profile agent-vm \
    --config limits.cpu="$CPUS" --config limits.memory="$MEMORY" \
    --device root,size="$DISK"

tries=0
until incus exec "$NAME" -- true >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -le 90 ] || fail "$NAME did not come up within 3 minutes"
    sleep 2
done
# Let cloud-init finish before apt runs. A degraded result is not fatal;
# base.sh fails loudly if the VM is unusable.
incus exec "$NAME" -- cloud-init status --wait >/dev/null 2>&1 || true

incus exec "$NAME" -- mkdir -p /opt/homelab
incus file push "$HERE/base.sh" "$NAME/opt/homelab/base.sh"
incus file push -r "$HERE/$NAME" "$NAME/opt/homelab/"
incus exec "$NAME" -- sh /opt/homelab/base.sh

# Prints a login link; open it as a tailnet admin to add the VM as tag:agent.
# DNS stays on Incus's resolver: tag:agent cannot reach Pi-hole.
incus exec "$NAME" -- tailscale up --advertise-tags=tag:agent --hostname="$NAME" \
    --ssh --accept-dns=false
incus exec "$NAME" -- tailscale set --auto-update

incus exec "$NAME" -- sh "/opt/homelab/$NAME/provision.sh"
printf '\n%s is ready: ssh agent@%s\n' "$NAME" "$NAME"
