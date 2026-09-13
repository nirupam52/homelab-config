# Operations

## Runtime layout

Runtime state is separate from the checkout. Setup mirrors the Compose files
onto the SSD before starting them:

```text
SD card
└── ~/homelab-config        repository

SSD: /mnt/ssd
├── docker/                  Docker data root
└── homelab/
    ├── apps/dozzle/compose.yaml
    ├── apps/hermes-agent/compose.yaml
    ├── apps/hermes-agent/.env         Dashboard username/password/secret
    ├── apps/hermes-agent/data/        Hermes state (config.yaml, sessions, skills)
    ├── apps/llama-cpp/compose.yaml
    ├── apps/llama-cpp/.env     API key and tuning
    ├── apps/llama-cpp/models/  GGUF model files (one or more)
    ├── apps/pihole/compose.yaml
    ├── apps/pihole/.env        Pi-hole password and Tailscale address
    ├── apps/pihole/data/       Pi-hole data
    ├── apps/pihole/dnsmasq.d/
    ├── infra/docktail/compose.yaml
    └── infra/docktail/.env     DockTail OAuth secret
```

## Verify

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
docker compose --env-file /mnt/ssd/homelab/apps/hermes-agent/.env \
  -f /mnt/ssd/homelab/apps/hermes-agent/compose.yaml ps
docker compose -f /mnt/ssd/homelab/apps/dozzle/compose.yaml ps
```

The firewall defaults to deny incoming and allow outgoing, with an inbound
allow only on `tailscale0`. Pi-hole is expected to be the only container
with published host ports. llama.cpp should show no published ports. Check
the Tailscale admin console if a DockTail Service is pending approval — see
[Services](services.md#troubleshooting).

For DNS-specific verification, see [docs/dns.md](dns.md#verify).

## Update

For an update, review the repository change, pull it, then run the mode
that matches the change:

```sh
cd ~/homelab-config
git pull --ff-only
sudo ./setup.sh reconcile   # apps/ or infra/ changed (Compose files, secrets)
sudo ./setup.sh bootstrap   # docker/, firewall, or Tailscale flags changed
sudo ./setup.sh             # unsure, or both kinds of change
```

For a single application: `sudo ./setup.sh reconcile <project>` where
`<project>` is one of `docktail`, `pihole`, `llama-cpp`, `dozzle`, or
`hermes-agent`. `llama-cpp` is included whenever `reconcile` runs without a
project, and must be reconciled before `hermes-agent` (hermes-agent joins
llama-cpp's Docker network).

`docker compose up -d` reconciles changed images and configuration without
removing application data. Do not run `docker compose down -v`.

## Recovery trade-off

System `sshd` is disabled. If Tailscale is unavailable, remote recovery is
not possible; use the local console or re-flash the SD card. The SSD data
remains untouched. To re-enable system SSH deliberately from the console:

```sh
sudo systemctl enable --now ssh.service
```

Do not disable the firewall or re-enable wireless services as a routine
fix.
