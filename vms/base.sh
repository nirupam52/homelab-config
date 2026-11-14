#!/bin/sh
# Shared provisioning for every agent VM. `sudo ./setup.sh reconcile <vm>`
# pushes this into the VM and runs it as root on every reconcile, before the
# VM's own provision.sh. Safe to re-run; it never restarts agent work.
#
# The agent runs as `agent` with passwordless sudo: the VM is the sandbox.
set -eu
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git jq sudo tmux unattended-upgrades

# Daily Debian security updates inside the guest.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

id agent >/dev/null 2>&1 || useradd --create-home --shell /bin/bash agent
printf '%s\n' 'agent ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent
chmod 0440 /etc/sudoers.d/agent

# Tailscale SSH is the only way in; reconcile joins the tailnet after this.
command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
