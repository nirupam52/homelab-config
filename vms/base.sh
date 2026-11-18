#!/bin/sh
# Shared setup for every agent VM, run once as root by vms/create.sh before
# the VM's own provision.sh.
#
# The agent runs as `agent` with passwordless sudo: the VM is the sandbox.
# Debian's unattended-upgrades package turns on daily security updates.
set -eu
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git jq sudo tmux unattended-upgrades

useradd --create-home --shell /bin/bash agent
printf '%s\n' 'agent ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent
chmod 0440 /etc/sudoers.d/agent
su - agent -c 'mkdir -p ~/work'

# Tailscale SSH is the only way in; create.sh joins the tailnet next.
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
