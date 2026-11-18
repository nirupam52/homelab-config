#!/bin/sh
# Hermes VM: Hermes Agent (stable channel), its gateway and dashboard as
# system services, and the dashboard published on the tailnet with
# `tailscale serve`. Run once as root by vms/create.sh, after base.sh and the
# tailnet join. Update later with `hermes update`.
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
HERMES_HOME=/home/agent/.hermes

# Starting settings. The installer keeps an existing config.yaml; after this,
# the dashboard's Config page owns it.
install -d -m 0700 -o agent -g agent "$HERMES_HOME"
install -m 0600 -o agent -g agent "$HERE/config.yaml" "$HERMES_HOME/config.yaml"
su - agent -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
    | bash -s -- --non-interactive --skip-computer-use'

# The dashboard rejects any Host header but its declared public URL, and
# declaring a non-loopback URL turns on its login. Read the password with
# `sudo cat /etc/hermes/dashboard.env`.
dns_name=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
[ -n "$dns_name" ] || { echo 'provision: tailscale has no DNS name' >&2; exit 1; }
install -d -m 0700 /etc/hermes
umask 077
{
    printf 'HERMES_DASHBOARD_PUBLIC_URL=https://%s\n' "$dns_name"
    printf 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=hermes\n'
    printf 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=%s\n' "$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
    printf 'HERMES_DASHBOARD_BASIC_AUTH_SECRET=%s\n' "$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"
} > /etc/hermes/dashboard.env

install -m 0644 "$HERE/hermes-gateway.service" "$HERE/hermes-dashboard.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now hermes-gateway.service hermes-dashboard.service

# https://<this VM's tailnet name>/ -> dashboard on loopback. Only tailnet
# members the policy grants tag:agent can reach it.
tailscale serve --bg --https=443 http://127.0.0.1:9119
