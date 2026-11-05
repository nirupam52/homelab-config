#!/bin/sh
set -eu

key_dir=$HOME/.sshd
mkdir -p "$key_dir"
chmod 700 "$key_dir"
[ -f "$key_dir/ssh_host_ed25519_key" ] || \
    ssh-keygen -q -t ed25519 -N '' -f "$key_dir/ssh_host_ed25519_key"

exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_hermes_config
