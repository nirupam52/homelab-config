#!/bin/sh
# Coding-agent VM: Claude Code, Codex, Docker, GitHub CLI. Run once as root by
# vms/create.sh, after base.sh.
set -eu
export DEBIAN_FRONTEND=noninteractive

apt-get install -y --no-install-recommends \
    build-essential python3 python3-venv python3-pip nodejs npm \
    ripgrep fd-find unzip gh docker.io docker-cli docker-compose docker-buildx \
    bubblewrap socat
systemctl enable --now docker
usermod -aG docker agent

npm install -g @openai/codex@latest

# Claude Code's native installer; it keeps itself up to date.
su - agent -c 'set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash'
