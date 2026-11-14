# Raspberry Pi homelab

Config for one Raspberry Pi 5 (Raspberry Pi OS Lite 64-bit). The OS stays on
the SD card; Docker and application data live on an SSD. Everything is
reachable only through Tailscale — no exposed ports except Pi-hole DNS.

## How it works

- `setup.sh` is the only host setup and deployment entrypoint (bootstrap +
  reconcile — see [Operations](docs/operations.md)).
- The SSD mounts at `/mnt/ssd`. Docker's data root and every app's data and
  secrets live under `/mnt/ssd/homelab/`, never on the SD card or in Git.
- [DockTail](infra/docktail) publishes each app as a private Tailscale
  Service over HTTPS — no host ports, no Tailscale sidecars, nothing public.
  It needs read-only access to the Docker and Tailscale sockets; see
  [Services](docs/services.md#about-docktail) for that trade-off.
- Pi-hole is the one exception: it binds DNS (UDP/TCP 53) directly to the
  Pi's Tailscale IP.
- AI agents run in [Incus](https://linuxcontainers.org/incus/) VMs, not
  containers: `coder` (Claude Code, Codex) and `hermes` (Hermes Agent). Each
  has root inside its VM, reaches only the web, and joins the tailnet as
  `tag:agent`. See [Agent VMs](docs/agent-vms.md).

## Apps

| App | Purpose | URL after setup |
|---|---|---|
| [dozzle](apps/dozzle) | Container log viewer | `https://dozzle.<tailnet>.ts.net` |
| [pihole](apps/pihole) | Tailnet-wide DNS + ad blocking | `https://pihole.<tailnet>.ts.net/admin/` |
| [docktail](infra/docktail) | Publishes the apps above as Tailscale Services | — |
| [coder](vms/coder) (VM) | Claude Code, Codex, Docker | `ssh agent@coder` |
| [hermes](vms/hermes) (VM) | Hermes Agent dashboard, signed in with ChatGPT | `https://hermes.<tailnet>.ts.net` |

## Getting started

1. [Prerequisites](docs/prerequisites.md) — Tailscale ACLs, SSD partition,
   GitHub deploy key.
2. [First setup](docs/first-setup.md) — clone, run `setup.sh`, answer the
   prompts, reboot.
3. [Services](docs/services.md) — confirm everything is reachable.

## Documentation

| Doc | Covers |
|---|---|
| [docs/prerequisites.md](docs/prerequisites.md) | Tailscale admin console setup, SSD prep, deploy key |
| [docs/first-setup.md](docs/first-setup.md) | Cloning, running `setup.sh`, what bootstrap/reconcile do |
| [docs/services.md](docs/services.md) | Service URLs, DockTail troubleshooting, adding new apps |
| [docs/agent-vms.md](docs/agent-vms.md) | Agent VMs: isolation, access, sign-ins, updates, backups |
| [docs/migrate-to-agent-vms.md](docs/migrate-to-agent-vms.md) | One-time move from the Hermes containers to agent VMs |
| [docs/dns.md](docs/dns.md) | Tailnet-wide DNS via Pi-hole |
| [docs/operations.md](docs/operations.md) | Verify/update commands, directory layout, recovery |

## Layout

```
setup.sh                host bootstrap + deploy entrypoint
docker/daemon.json       Docker daemon config
infra/docktail/          Tailscale Service publisher
apps/dozzle/             container log viewer
apps/pihole/             DNS + ad blocking
infra/incus/             agent VM network ACL and profile
vms/                     agent VMs: sizes and provisioning scripts
```

Runtime data, secrets, and mirrored Compose files live on the SSD, not in
this repo — see [docs/operations.md](docs/operations.md#runtime-layout) for
that layout.
