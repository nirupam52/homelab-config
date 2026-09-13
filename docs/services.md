# Services

After DockTail creates the Service definitions and Tailscale approves the
advertised host, the usual URLs are:

| Service | URL |
|---|---|
| Dozzle | `https://dozzle.<tailnet>.ts.net` |
| llama.cpp | `https://llama.<tailnet>.ts.net` |
| hermes-agent | `https://hermes.<tailnet>.ts.net` |
| Pi-hole | `https://pihole.<tailnet>.ts.net/admin/` |

## About DockTail

DockTail needs read-only access to the Docker socket and the host Tailscale
socket. This is a deliberate trade-off: Docker metadata and environment
values are visible to the controller, but it cannot create or exec into
containers through the read-only socket. DockTail is community-maintained
AGPL software, and Tailscale Services is a public beta feature.

## Troubleshooting

`tailscale serve status` only reports the host's local advertisement. It
does not prove that the Service definition exists in the tailnet control
plane.

**A Service shows `Hosts: 0`:** its host advertisement is not approved yet.
Open the Service in the Tailscale admin console, approve the pending
`homelabpi` host under Service hosts, and wait for the host count to become
`1`. A browser connection will time out until that approval completes. If no
pending host is listed, recheck the `autoApprovers.services` rule and
recreate DockTail to advertise the host again.

**URLs work locally but the Services page is empty:** inspect DockTail's
control-plane errors:

```sh
docker compose --project-name docktail \
  --env-file /mnt/ssd/homelab/infra/docktail/.env \
  -f /mnt/ssd/homelab/infra/docktail/compose.yaml logs --tail=100 docktail
```

An error such as `requested tags [tag:container] are invalid or not
permitted` means the `tag:container` and `autoApprovers.services` policy
from [prerequisites](prerequisites.md#1-tailscale-admin-console) has not
been applied.

After fixing the OAuth credentials or tailnet policy, recreate DockTail so
it reloads the `.env` file and re-advertises the services. `docker compose
restart` does not reload changed environment values:

```sh
docker compose --project-name docktail \
  --env-file /mnt/ssd/homelab/infra/docktail/.env \
  -f /mnt/ssd/homelab/infra/docktail/compose.yaml up -d --force-recreate docktail
```

## Pi-hole is the exception

Pi-hole DNS is published directly on the server's Tailscale IPv4 address
over UDP and TCP port 53, restricted to that address. DockTail publishes
only the Pi-hole web service. This is the intentional exception to the
no-host-port rule; every other application still uses DockTail labels and
publishes no host ports.

## Adding an app

DockTail watches the labels in the application Compose files. Adding an app
means adding another labeled Compose project under `apps/`. Do not add a
Tailscale sidecar or host port publication, and do not add
`docktail.funnel.*` labels — nothing here is meant to be public.
