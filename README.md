# Raspberry Pi homelab

This repository configures one Raspberry Pi 5 running Raspberry Pi OS Lite
64-bit. The OS stays on the SD card. Docker's data root and application data
stay on an SSD. The Pi and every application are reachable only through
Tailscale.

## Design

- `setup.sh` is the only host setup and deployment entrypoint.
- The SSD is mounted at `/mnt/ssd` by UUID.
- Docker stores images and containers in `/mnt/ssd/docker`.
- Application data and runtime secrets live under `/mnt/ssd/homelab/`.
- `infra/docktail/compose.yaml` runs one DockTail controller.
- `apps/*/compose.yaml` contains one application per Compose project.
- Compose files contain no `ports:` entries. DockTail reaches container IPs
  directly and publishes private Tailscale Services from Docker labels.
- No Tailscale sidecars, Tailscale Serve files, or host port bindings are used.

DockTail needs read-only access to the Docker socket and the host Tailscale
socket. This is a deliberate trade-off: Docker metadata and environment values
are visible to the controller, but it cannot create or exec into containers
through the read-only socket. DockTail is community-maintained AGPL software,
and Tailscale Services is a public beta feature.

## Before running setup

In the Tailscale admin console:

1. Enable MagicDNS and HTTPS certificates.
2. Create the `tag:server` tag and allow `autogroup:admin` to own it.
3. Create a DockTail OAuth client scoped to `tag:server` with Services write
   permission. Keep the client ID and secret ready for the setup prompts.
4. Add an ACL equivalent to:

```json
{
  "tagOwners": {
    "tag:server": ["autogroup:admin"]
  },
  "acls": [
    {"action": "accept", "src": ["autogroup:member"], "dst": ["tag:server:*"]}
  ],
  "ssh": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:server"],
      "users": ["autogroup:nonroot", "root"]
    }
  ]
}
```

Prepare an already-formatted SSD partition with a filesystem UUID. The script
will never format a disk. Keep a local keyboard/monitor available for the
first run because system SSH is disabled after Tailscale SSH is confirmed.

## GitHub deploy key

The Pi clones this repository over SSH with a repository-specific, read-only
deploy key. Generate the key as the normal Pi user:

```sh
install -d -m 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/homelab-config-deploy \
  -C "rpi5 homelab deploy key"
```

Add the public key in the repository's GitHub settings:

1. Open **Settings -> Deploy keys -> Add deploy key**.
2. Give it a name such as `rpi5-homelab`.
3. Paste the output of:
   ```sh
   cat ~/.ssh/homelab-config-deploy.pub
   ```
4. Leave **Allow write access** disabled. Pull access is sufficient.

Use a host alias so this deploy key is not offered to unrelated GitHub
repositories:

```sh
cat >> ~/.ssh/config <<'EOF'
Host github-homelab
    HostName github.com
    User git
    IdentityFile ~/.ssh/homelab-config-deploy
    IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
```

If the key has a passphrase, load it before cloning or pulling:

```sh
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/homelab-config-deploy
```

Test the connection. On the first connection, verify GitHub's published SSH
host fingerprint before accepting it:

```sh
ssh -T github-homelab
```

## First setup

Clone this repository on the Pi and run the script as root:

```sh
git clone git@github-homelab:nirupam52/homelab-config.git ~/homelab-config
cd ~/homelab-config
sudo ./setup.sh
```

For an existing HTTPS checkout, change its remote once:

```sh
cd ~/homelab-config
git remote set-url origin git@github-homelab:nirupam52/homelab-config.git
```

The guided prompts request:

1. The SSD partition, such as `/dev/sda1`.
2. The Tailscale OAuth client ID and secret.
3. A Pi-hole web password.
4. Confirmation that Tailscale SSH works from another tailnet device.

The script then installs Docker, Compose, UFW, Tailscale, and unattended
upgrades; mounts the SSD; moves Docker's data root; applies the Wi-Fi and
Bluetooth boot overlays; configures the firewall; disables system SSH,
Avahi, triggerhappy, and Bluetooth; connects Tailscale with:

```sh
tailscale up --ssh --advertise-tags=tag:server
```

Finally it starts DockTail, Pi-hole, and Dozzle. Run it again after a reboot or
repository update to reconcile the same configuration. Existing runtime
secret files are preserved and kept mode `600`.

Reboot once after the first run so the device-tree radio overlays take effect:

```sh
sudo reboot
```

## Services

After Tailscale approves the advertised services, the usual URLs are:

- `https://dozzle.<tailnet>.ts.net`
- `https://pihole.<tailnet>.ts.net/admin/`

Pi-hole also advertises `pihole-dns` through DockTail as TCP port 53. Tailscale
Services currently supports TCP only, so normal UDP DNS is intentionally not
published. Use the Pi-hole web service for administration; do not add a Docker
`ports:` entry to work around this limitation.

DockTail watches the labels in the application Compose files. Adding an app
means adding another labeled Compose project; do not add a Tailscale sidecar or
host port publication. Do not add `docktail.funnel.*` labels: nothing is public.

Runtime state is separate from the checkout. Setup mirrors the Compose files
onto the SSD before starting them:

```text
SD card
└── ~/homelab-config        repository

SSD: /mnt/ssd
├── docker/                  Docker data root
└── homelab/
    ├── apps/dozzle/compose.yaml
    ├── apps/pihole/compose.yaml
    ├── apps/pihole/.env     Pi-hole secret
    ├── apps/pihole/data/    Pi-hole data
    ├── apps/pihole/dnsmasq.d/
    ├── infra/docktail/compose.yaml
    └── infra/docktail/.env DockTail OAuth secret
```

## Verify and update

On the Pi:

```sh
findmnt /mnt/ssd
docker info --format 'DockerRootDir={{.DockerRootDir}}'
sudo ufw status verbose
tailscale status
docker compose --env-file /mnt/ssd/homelab/infra/docktail/.env \
  -f /mnt/ssd/homelab/infra/docktail/compose.yaml ps
docker compose --env-file /mnt/ssd/homelab/apps/pihole/.env \
  -f /mnt/ssd/homelab/apps/pihole/compose.yaml ps
docker compose -f /mnt/ssd/homelab/apps/dozzle/compose.yaml ps
```

The firewall defaults to deny incoming and allow outgoing, with an inbound
allow only on `tailscale0`. No service should appear in `docker ps` with a
published host port. Check the Tailscale admin console if a DockTail service is
pending approval.

For an update, review the repository change and run the same setup command:

```sh
cd ~/homelab-config
git pull --ff-only
sudo ./setup.sh
```

`docker compose up -d` reconciles changed images and configuration without
removing application data. Do not run `docker compose down -v`.

## Recovery trade-off

System `sshd` is disabled. If Tailscale is unavailable, remote recovery is not
possible; use the local console or re-flash the SD card. The SSD data remains
untouched. To re-enable system SSH deliberately from the console:

```sh
sudo systemctl enable --now ssh.service
```

Do not disable the firewall or re-enable wireless services as a routine fix.
