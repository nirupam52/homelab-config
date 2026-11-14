#!/bin/sh
# Coding-agent VM: Claude Code, Codex, Docker, GitHub CLI. Runs as root inside
# the VM on every `sudo ./setup.sh reconcile coder`, after base.sh. Never
# touches logins (~/.claude, ~/.codex, gh) or running tmux sessions.
set -eu
export DEBIAN_FRONTEND=noninteractive

apt-get install -y --no-install-recommends \
    build-essential python3 python3-venv python3-pip nodejs npm \
    ripgrep fd-find unzip gh docker.io docker-compose docker-buildx \
    bubblewrap socat
systemctl enable --now docker
usermod -aG docker agent

# Codex follows its latest release; each reconcile updates it.
npm install -g @openai/codex@latest

# Claude Code's native installer; it keeps itself up to date afterwards.
[ -x /home/agent/.local/bin/claude ] || \
    su - agent -c 'set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash'

su - agent -c 'mkdir -p ~/work'
