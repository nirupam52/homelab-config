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
- Application Compose files publish no host ports except Pi-hole DNS.
- Pi-hole binds UDP and TCP port 53 only to the host's Tailscale IPv4 address;
  DockTail publishes the remaining private application services.
- No Tailscale sidecars or Tailscale Serve files are used.

DockTail needs read-only access to the Docker socket and the host Tailscale
socket. This is a deliberate trade-off: Docker metadata and environment values
are visible to the controller, but it cannot create or exec into containers
through the read-only socket. DockTail is community-maintained AGPL software,
and Tailscale Services is a public beta feature.

## Before running setup

In the Tailscale admin console:

1. Enable MagicDNS and HTTPS certificates.
2. Create the `tag:server` and `tag:container` tags. Allow `autogroup:admin` to own `tag:server`, and allow `tag:server` to own `tag:container`.
3. Create a DockTail OAuth client with General → Services → Write permission. Attach the `tag:container` to this.
   Keep the client ID and secret ready for the setup prompts.
4. Add an ACL equivalent to:

```json
{
  "tagOwners": {
    "tag:server": ["autogroup:admin"],
    "tag:container": ["tag:server"]
  },
  "autoApprovers": {
    "services": {
      "tag:container": ["tag:server"]
    }
  },
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["svc:dozzle", "svc:pihole"],
      "ip": ["443"]
    }
  ],
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

The script records the Pi's Tailscale IPv4 address in the runtime Pi-hole
`.env` file for the DNS port binding.

The script then installs Docker, Compose, UFW, Tailscale, and unattended
upgrades; mounts the SSD; moves Docker's data root; applies the Wi-Fi and
Bluetooth boot overlays; configures the firewall; disables system SSH,
Avahi, triggerhappy, and Bluetooth; connects Tailscale with:

```sh
tailscale up --ssh --accept-dns=false --advertise-tags=tag:server
```

Finally it starts DockTail, Pi-hole, and Dozzle. Run it again after a reboot or
repository update to reconcile the same configuration. It never formats the
SSD or removes application data and Compose volumes. It does reapply host
settings and overwrite the mirrored Compose files; existing runtime secret
values are preserved and files remain mode `600`.

Reboot once after the first run so the device-tree radio overlays take effect:

```sh
sudo reboot
```

## Services

After DockTail creates the Service definitions and Tailscale approves the
advertised hosts, the usual URLs are:

- `https://dozzle.<tailnet>.ts.net`
- `https://pihole.<tailnet>.ts.net/admin/`

`tailscale serve status` only reports the host's local advertisement. It does
not prove that the Service definition exists in the tailnet control plane.

If a Service exists but shows `Hosts: 0`, its host advertisement is not
approved yet. Open the Service in the Tailscale admin console, approve the
pending `homelabpi` host under Service hosts, and wait for the host count to
become `1`. A browser connection will time out until that approval completes.
If no pending host is listed, recheck the `autoApprovers.services` rule and
recreate DockTail to advertise the host again.

If the URLs appear locally but the Services page is empty, inspect DockTail's
control-plane errors:

```sh
docker compose --project-name docktail \
  --env-file /mnt/ssd/homelab/infra/docktail/.env \
  -f /mnt/ssd/homelab/infra/docktail/compose.yaml logs --tail=100 docktail
```

An error such as `requested tags [tag:container] are invalid or not
permitted` means the `tag:container` and `autoApprovers.services` policy above
has not been applied.

After fixing the OAuth credentials or tailnet policy, recreate DockTail so it
reloads the `.env` file and re-advertises the services. `docker compose
restart` does not reload changed environment values:

```sh
docker compose --project-name docktail \
  --env-file /mnt/ssd/homelab/infra/docktail/.env \
  -f /mnt/ssd/homelab/infra/docktail/compose.yaml up -d --force-recreate docktail
```

Pi-hole DNS is published directly on the server's Tailscale IPv4 address over
UDP and TCP port 53. The binding is restricted to that address. DockTail
publishes only the Pi-hole web service. Pi-hole is the intentional exception
to the no-host-port rule; other applications still use DockTail labels and do
not publish host ports.

DockTail watches the labels in the application Compose files. Adding an app
means adding another labeled Compose project; do not add a Tailscale sidecar or
host port publication. Do not add `docktail.funnel.*` labels: nothing is public.

## Tailnet-wide DNS

The setup script records the Pi's Tailscale IPv4 address in
`/mnt/ssd/homelab/apps/pihole/.env` and publishes Pi-hole on UDP and TCP port
53 at that address.

After setup:

1. Open the Tailscale admin console's **DNS** page.
2. Under **Nameservers**, choose **Add nameserver → Custom** and enter the
   Pi's Tailscale IPv4 address from `tailscale ip -4`.
3. Enable **Override DNS servers**.
4. Keep Tailscale DNS enabled on each client. On Linux clients:

   ```sh
   sudo tailscale set --accept-dns=true
   ```

5. In Pi-hole's **Lists** settings, verify or add ad/tracker blocklists, then
   update gravity.

The existing `tag:server:*` ACL permits tailnet members to reach direct DNS on
the Pi. No `svc:pihole-dns` service is needed because Tailscale Services
currently support TCP only, while clients normally send DNS over UDP.

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
    ├── apps/pihole/.env     Pi-hole password and Tailscale address
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
allow only on `tailscale0`. Pi-hole is expected to be the only container with
published host ports, and its `docker ps` entry should show the configured
Tailscale IPv4 address mapped to both UDP and TCP port 53. Check the Tailscale
admin console if a DockTail service is pending approval.

From a Tailscale client, test both DNS transports:

```sh
PIHOLE_IP=100.x.y.z
dig @"$PIHOLE_IP" example.com
dig +tcp @"$PIHOLE_IP" example.com
```

Then confirm the queries appear in Pi-hole's **Query Log**. If they do not,
the client is not using Tailscale DNS or is bypassing it with DoH, DoT, a VPN,
or a private relay.

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
