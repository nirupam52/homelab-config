# Sourced by login shells; Hermes snapshots this environment once per SSH
# session. The only route out of the sandbox is the egress-dev proxy.
export HTTP_PROXY=http://egress-dev:3128
export HTTPS_PROXY=http://egress-dev:3128
export http_proxy=$HTTP_PROXY
export https_proxy=$HTTPS_PROXY
export NO_PROXY=localhost,127.0.0.1
export no_proxy=$NO_PROXY
export PIP_BREAK_SYSTEM_PACKAGES=1
export PATH="$HOME/.local/bin:$PATH"
