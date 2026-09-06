# Raspberry Pi homelab

This repository configures one Raspberry Pi 5 running Raspberry Pi OS Lite
64-bit. The OS stays on the SD card. Docker's data root and application data
stay on an SSD. The Pi and every application are reachable only through
Tailscale.

## Design

- `setup.sh` is the only host setup and deployment entrypoint. It has three
  modes: no argument runs bootstrap then reconcile; `bootstrap` applies
  host-level state only; `reconcile [project]` syncs Compose files and
  secrets and starts or updates one application or all of them.
- The SSD is mounted at `/mnt/ssd` by UUID.
- Docker stores images and containers in `/mnt/ssd/docker`.
- Application data and runtime secrets live under `/mnt/ssd/homelab/`.
- `infra/docktail/compose.yaml` runs one DockTail controller.
- `apps/*/compose.yaml` contains one application per Compose project.
- Application Compose files publish no host ports except Pi-hole DNS.
- Pi-hole binds UDP and TCP port 53 only to the host's Tailscale IPv4 address;
  DockTail publishes the remaining private application services.
- `apps/llama-cpp/compose.yaml` runs one CPU-only llama.cpp server.
- llama.cpp model files live on the SSD and are never stored in Git.
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
      "dst": ["svc:dozzle", "svc:pihole", "svc:llama"],
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

For llama.cpp, stage one verified GGUF model after the SSD is mounted:

```sh
sudo install -d -m 0750 /mnt/ssd/homelab/apps/llama-cpp/models
sudo install -m 0644 /path/to/model.gguf \
  /mnt/ssd/homelab/apps/llama-cpp/models/
sha256sum /mnt/ssd/homelab/apps/llama-cpp/models/model.gguf
```

Use the exact filename and checksum from the model publisher. The first setup
pass may create the SSD directory and stop with a missing-model error before
Dozzle starts; stage the model, then run `sudo ./setup.sh reconcile` to
resume reconciling every application, not just llama.cpp.

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

The guided prompts request, in order:

1. The SSD partition, such as `/dev/sda1`.
2. Confirmation that Tailscale SSH works from another tailnet device, asked
   before system SSH is disabled.
3. The Tailscale OAuth client ID and secret.
4. A Pi-hole web password.
5. The llama.cpp model filename and API key.

Prompts 3, 4, and 5 only appear the first time, or after their runtime `.env`
file is removed; reruns keep the existing values. The model filename must match
a file in `/mnt/ssd/homelab/apps/llama-cpp/models/`; runtime `.env` files are
created on the SSD with mode `600`.

The script then installs Docker, Compose, UFW, the `en_US.UTF-8` locale, and
unattended upgrades; mounts the SSD; moves Docker's data root; connects
Tailscale with:

```sh
tailscale up --accept-dns=false --advertise-tags=tag:server --ssh --accept-routes
```

It then applies the Wi-Fi and Bluetooth boot overlays, configures the
firewall, and disables system SSH, Avahi, triggerhappy, and Bluetooth. That
is the `bootstrap` phase.

Finally it reconciles applications (the `reconcile` phase): it mirrors each
Compose file onto the SSD, collects any missing secret, refreshes the
Pi-hole `.env`'s Tailscale address, and starts or updates DockTail, Pi-hole,
llama.cpp, and Dozzle. It never formats the SSD or removes application data,
models, and Compose volumes. It does overwrite the mirrored Compose files
(mode `0644`); existing `.env` secret values are preserved and those files
stay mode `600`.

After the first run, prefer the narrower modes for routine changes:
`reconcile` for changes under `apps/` or `infra/`, `reconcile <project>`
(`docktail`, `pihole`, `llama-cpp`, or `dozzle`) for a single application, and
`bootstrap` for changes to `docker/daemon.json`, the firewall, or the Tailscale
flags. `llama-cpp` is included when `reconcile` runs without a project. See
**Verify and update** below for the exact commands. `reconcile` fails fast if
bootstrap has never completed: it requires the SSD mounted at `/mnt/ssd`,
Docker's data root on the SSD, and a connected Tailscale daemon.

Reboot once after the first run so the device-tree radio overlays take effect:

```sh
sudo reboot
```

## Services

After DockTail creates the Service definitions and Tailscale approves the
advertised hosts, the usual URLs are:

- `https://dozzle.<tailnet>.ts.net`
- `https://llama.<tailnet>.ts.net`
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

## llama.cpp

llama.cpp is a CPU-only, OpenAI-compatible inference server for this Pi. Its
container listens on port `8080` internally; DockTail publishes it as the
private Tailscale Service `llama` on HTTPS port `443`. No host port is
published.

The server requires:

- One explicitly selected `.gguf` model in
  `/mnt/ssd/homelab/apps/llama-cpp/models/`.
- The model filename and API key in
  `/mnt/ssd/homelab/apps/llama-cpp/.env`.
- A client using `Authorization: Bearer <LLAMA_API_KEY>`.

The initial defaults are a 4096-token context, four CPU threads, and one
parallel request slot. Benchmark the selected model before increasing these
values. Edit the runtime `.env` and run `sudo ./setup.sh reconcile llama-cpp` to
change them.

Test the service from a Tailscale client:

```sh
LLAMA_URL=https://llama.<tailnet>.ts.net
LLAMA_API_KEY='value from /mnt/ssd/homelab/apps/llama-cpp/.env'
curl --fail "$LLAMA_URL/health"
curl --fail \
  -H "Authorization: Bearer $LLAMA_API_KEY" \
  -H "Content-Type: application/json" \
  "$LLAMA_URL/v1/chat/completions" \
  -d '{"model":"local-model","messages":[{"role":"user","content":"Reply with one word: ready"}],"max_tokens":8}'
```

The API is reachable only through Tailscale. Do not add a host port, Funnel
label, or llama.cpp tools/MCP configuration.

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
    ├── apps/llama-cpp/compose.yaml
    ├── apps/llama-cpp/.env     Model filename, API key, and tuning
    ├── apps/llama-cpp/models/  GGUF model files
    ├── apps/pihole/compose.yaml
    ├── apps/pihole/.env        Pi-hole password and Tailscale address
    ├── apps/pihole/data/       Pi-hole data
    ├── apps/pihole/dnsmasq.d/
    ├── infra/docktail/compose.yaml
    └── infra/docktail/.env     DockTail OAuth secret
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
docker compose --env-file /mnt/ssd/homelab/apps/llama-cpp/.env \
  -f /mnt/ssd/homelab/apps/llama-cpp/compose.yaml ps
docker compose -f /mnt/ssd/homelab/apps/dozzle/compose.yaml ps
```

The firewall defaults to deny incoming and allow outgoing, with an inbound
allow only on `tailscale0`. Pi-hole is expected to be the only container with
published host ports. llama.cpp should show no published ports. Check the
Tailscale admin console if a DockTail Service is pending approval.

From a Tailscale client, test both DNS transports:

```sh
PIHOLE_IP=100.x.y.z
dig @"$PIHOLE_IP" example.com
dig +tcp @"$PIHOLE_IP" example.com
```

Then confirm the queries appear in Pi-hole's **Query Log**. If they do not,
the client is not using Tailscale DNS or is bypassing it with DoH, DoT, a VPN,
or a private relay.

For an update, review the repository change, pull it, then run the mode that
matches the change:

```sh
cd ~/homelab-config
git pull --ff-only
sudo ./setup.sh reconcile   # apps/ or infra/ changed (Compose files, secrets)
sudo ./setup.sh bootstrap   # docker/, firewall, or Tailscale flags changed
sudo ./setup.sh             # unsure, or both kinds of change
```

`docker compose up -d` reconciles changed images and configuration without
removing application data. Do not run `docker compose down -v`.

To replace a model, copy the new verified `.gguf` file into the models
directory, update `LLAMA_MODEL` in the runtime `.env`, and run
`sudo ./setup.sh reconcile llama-cpp`.
Keep the old model until the new service passes `/health` and an inference
smoke test.

## Recovery trade-off

System `sshd` is disabled. If Tailscale is unavailable, remote recovery is not
possible; use the local console or re-flash the SD card. The SSD data remains
untouched. To re-enable system SSH deliberately from the console:

```sh
sudo systemctl enable --now ssh.service
```

Do not disable the firewall or re-enable wireless services as a routine fix.

