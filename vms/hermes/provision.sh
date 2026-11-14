#!/bin/sh
# Hermes VM: a pinned Hermes Agent install, its gateway and dashboard as
# system services, and the dashboard published on the tailnet with
# `tailscale serve`. Runs as root inside the VM on every
# `sudo ./setup.sh reconcile hermes`, after base.sh and the tailnet join.
# Hermes restarts only when its code, config or units changed, so a reconcile
# does not interrupt a running task for nothing.
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Hermes v0.22.5. To upgrade, change the commit to a newer release tag's
# commit on main, then reconcile.
HERMES_COMMIT=bf0203a794a07aac3ff764972ab9087baa4e4f4e
HERMES_HOME=/home/agent/.hermes
INSTALLED_MARKER=/var/lib/homelab/hermes-commit
RESTART=0

install_file() {
    if ! cmp -s "$1" "$2"; then
        install -D -m "$3" -o "$4" -g "$4" "$1" "$2"
        RESTART=1
    fi
}

# The installer pins only fresh clones, so any version change, or an
# install that never finished, replaces the code checkout. Sessions, memory,
# skills and the ChatGPT login live elsewhere in $HERMES_HOME and are kept.
# The marker is written only after the whole installer succeeded.
if [ "$(cat "$INSTALLED_MARKER" 2>/dev/null || true)" != "$HERMES_COMMIT" ]; then
    systemctl stop hermes-dashboard.service hermes-gateway.service 2>/dev/null || true
    rm -f "$INSTALLED_MARKER"
    rm -rf "$HERMES_HOME/hermes-agent"
    su - agent -c "set -o pipefail; curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/$HERMES_COMMIT/scripts/install.sh \
        | bash -s -- --commit $HERMES_COMMIT --non-interactive --skip-computer-use"
    install -d -m 0755 "$(dirname "$INSTALLED_MARKER")"
    printf '%s\n' "$HERMES_COMMIT" > "$INSTALLED_MARKER"
    RESTART=1
fi

# config.yaml is desired state: the repo copy replaces the live one, so
# settings changed on the dashboard's Config page last until the next
# reconcile.
install_file "$HERE/config.yaml" "$HERMES_HOME/config.yaml" 0600 agent

# Dashboard login. Generated once and kept in the VM; read it with
# `ssh agent@hermes sudo cat /etc/hermes/dashboard.env`.
install -d -m 0700 /etc/hermes
if [ ! -f /etc/hermes/dashboard.env ]; then
    (
        umask 077
        printf 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=hermes\n'
        printf 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=%s\n' "$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
        printf 'HERMES_DASHBOARD_BASIC_AUTH_SECRET=%s\n' "$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"
    ) > /etc/hermes/dashboard.env.tmp
    mv /etc/hermes/dashboard.env.tmp /etc/hermes/dashboard.env
    RESTART=1
fi

# The dashboard binds to loopback and rejects any other Host header unless
# its public URL is declared. Declaring a non-loopback URL also turns on the
# login above.
dns_name=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
[ -n "$dns_name" ] || { echo 'provision: tailscale has no DNS name' >&2; exit 1; }
printf 'HERMES_DASHBOARD_PUBLIC_URL=https://%s\n' "$dns_name" > /etc/hermes/public-url.env.tmp
install_file /etc/hermes/public-url.env.tmp /etc/hermes/public-url.env 0600 root
rm -f /etc/hermes/public-url.env.tmp

su - agent -c 'mkdir -p ~/work'
install_file "$HERE/hermes-gateway.service" /etc/systemd/system/hermes-gateway.service 0644 root
install_file "$HERE/hermes-dashboard.service" /etc/systemd/system/hermes-dashboard.service 0644 root
systemctl daemon-reload
systemctl enable hermes-gateway.service hermes-dashboard.service
if [ "$RESTART" -eq 1 ]; then
    systemctl restart hermes-gateway.service hermes-dashboard.service
else
    systemctl start hermes-gateway.service hermes-dashboard.service
fi

# https://<this VM's tailnet name>/ -> dashboard. Only tailnet members the
# policy grants tag:agent can reach it.
tailscale serve --bg --https=443 http://127.0.0.1:9119
