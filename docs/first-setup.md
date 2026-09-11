# First setup

Prerequisites: [docs/prerequisites.md](prerequisites.md).

## Clone and run

```sh
git clone git@github-homelab:nirupam52/homelab-config.git ~/homelab-config
cd ~/homelab-config
sudo ./setup.sh
```

For an existing HTTPS checkout, point it at the deploy key once:

```sh
cd ~/homelab-config
git remote set-url origin git@github-homelab:nirupam52/homelab-config.git
```

## Prompts

The guided prompts request, in order:

1. The SSD partition, such as `/dev/sda1`.
2. Confirmation that Tailscale SSH works from another tailnet device, asked
   before system SSH is disabled.
3. The Tailscale OAuth client ID and secret.
4. A Pi-hole web password.
5. The llama.cpp API key.

Prompts 3, 4, and 5 only appear the first time, or after their runtime
`.env` file is removed; reruns keep the existing values. Runtime `.env`
files are created on the SSD with mode `600`. `reconcile llama-cpp`
separately requires at least one `.gguf` file already staged (see
[prerequisites](prerequisites.md#3-llamacpp-models)).

## What it does

Running with no argument does **bootstrap** then **reconcile** — use this
for the first run.

**bootstrap** (host-level, idempotent):

- Installs Docker, Compose, UFW, the `en_US.UTF-8` locale, and unattended
  upgrades.
- Mounts the SSD and moves Docker's data root there.
- Connects Tailscale:
  ```sh
  tailscale up --accept-dns=false --advertise-tags=tag:server --ssh --accept-routes
  ```
- Applies the Wi-Fi and Bluetooth boot overlays and configures the firewall.
- Disables system SSH, Avahi, triggerhappy, and Bluetooth.

**reconcile** (application-level):

- Mirrors each Compose file onto the SSD (overwrites, mode `0644`).
- Collects any missing secret; preserves existing `.env` values (stays mode
  `600`).
- Refreshes Pi-hole's `.env` with the current Tailscale address.
- Starts or updates DockTail, Pi-hole, llama.cpp, and Dozzle.
- Never formats the SSD or removes application data, models, or Compose
  volumes.
- Fails fast if bootstrap has never completed: it requires the SSD mounted
  at `/mnt/ssd`, Docker's data root on the SSD, and a connected Tailscale
  daemon.

After the first run, prefer the narrower `bootstrap` / `reconcile [project]`
modes for routine changes — see the [command
reference](operations.md#update).

## Reboot

Once, after the first run, so the device-tree radio overlays take effect:

```sh
sudo reboot
```

Next: [Services](services.md) to confirm everything is reachable.
