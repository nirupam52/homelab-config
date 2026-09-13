# hermes-agent

[Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous Research)
running as a **dashboard-only** deployment: the container runs `hermes
dashboard`, never `hermes gateway run`, so no Telegram/Discord/Slack/etc.
messaging integration ever starts and no OpenAI-compatible API server is
exposed. The only way in is the web dashboard's Chat tab, which embeds the
full Hermes terminal UI in the browser. DockTail publishes it as the private
Tailscale Service `hermes` on HTTPS port `443`. No host port is published.

## Model provider: the existing llama.cpp server

hermes-agent does not bring its own model. It is wired to the already-deployed
[llama.cpp](llama-cpp.md) router as a `custom` (llama.cpp-compatible)
provider:

```yaml
model:
  provider: "llamacpp"     # alias for "custom"
  base_url: "http://llama:8080/v1"
  api_key: "<the llama.cpp .env LLAMA_API_KEY value>"
```

This reaches llama.cpp directly over a private Docker network named
`llama-cpp`, shared between the two Compose projects — not through Tailscale.
`apps/llama-cpp/compose.yaml` declares that network as `internal: true` and
attaches the `llama` service to it; `apps/hermes-agent/compose.yaml` joins
the same network as `external`. `internal: true` means neither container has
a route to the internet at all — see [Security](#security) for why. This
keeps inference traffic off the tailnet entirely (lower latency, no extra
ACL surface) while still requiring the bearer API key as defense in depth.
The `llama-cpp` Docker network must exist before hermes-agent can start,
which means llama-cpp must be reconciled first (see
[Requirements](#requirements)).

`sudo ./setup.sh reconcile hermes-agent` seeds
`/mnt/ssd/homelab/apps/hermes-agent/data/config.yaml` with the block above
once, on first run only — it never overwrites the file afterward, so any
changes made later from the dashboard's Config page persist across
reconciles. If exactly one `.gguf` model is staged in llama.cpp's models
directory, its filename (minus `.gguf`) is also written as `model.default`;
otherwise pick a model from the Chat tab's model picker (`/model llamacpp`)
on first login.

## Requirements

- llama-cpp already reconciled (`sudo ./setup.sh reconcile llama-cpp`) —
  the shared `llama-cpp` Docker network and `LLAMA_API_KEY` come from that
  run.
- A dashboard username and password in
  `/mnt/ssd/homelab/apps/hermes-agent/.env`, prompted for on first
  reconcile.

## Security

Running an autonomous, tool-using agent is a materially different risk than
the other apps in this repo: llama.cpp, Pi-hole, and Dozzle only do what a
request tells them to; hermes-agent can read/write files, run shell commands,
and (if it has network access) browse the web — on its own initiative,
including in response to content it reads rather than only what the
operator typed. Upstream's own security page documents a real incident along
these lines: an internet-reachable, unauthenticated dashboard was used by
scanners to drive an agent into planting an SSH-key backdoor. The controls
below are sized for that threat model, not just "add a password."

**Exposure**
- No messaging integrations are configured. The container's command is
  `dashboard --host 0.0.0.0 --no-open`, not `gateway run` — no bot token, no
  paired chat account, no OpenAI-compatible API server
  (`API_SERVER_ENABLED` is never set). This is a *current-configuration*
  fact, not a structural guarantee: the dashboard's own Channels/MCP/Cron
  pages let an authenticated session configure and start those things later.
  The dashboard credential is therefore the actual control, not the absence
  of a gateway container — treat `HERMES_DASHBOARD_PASSWORD` with the same
  care as the Tailscale OAuth secret.
- Dashboard auth is mandatory, not optional: Hermes refuses to bind to a
  non-loopback address at all without an auth provider configured — there is
  no unauthenticated-public-bind escape hatch. This deployment uses the
  bundled username/password provider (`HERMES_DASHBOARD_BASIC_AUTH_*`),
  which is upstream's documented choice for a trusted-network/homelab
  dashboard; the OAuth provider is the one meant for internet-facing use.
- Reachable only through Tailscale, like every other app here — no host
  port, no Funnel label. Only tailnet members granted `svc:hermes` in the
  ACL (see [prerequisites](prerequisites.md)) can even reach the login page.
- No Docker socket is mounted. Unlike Dozzle and DockTail, hermes-agent
  cannot see or touch other containers. Its terminal tool uses the default
  `local` backend: shell commands run inside this one unprivileged container
  (s6 drops the process to a non-root `hermes` UID before `hermes dashboard`
  starts), not on the Pi's host and not in a second nested container.

**Network egress is blocked — the main containment control.** The shared
`llama-cpp` network is `internal: true`, so hermes-agent (and llama.cpp) have
no default route to the internet: DNS resolution beyond the two containers'
own names fails, and outbound HTTP/HTTPS from any tool (browser, lazy-package
install, update check, a prompt-injected "fetch this URL and POST the
results elsewhere") has nowhere to go. This is the single highest-value
control for an agent whose tool access includes a shell and a bundled
Chromium: even a fully compromised or successfully-prompt-injected session
cannot exfiltrate data, phone home, or pull down a second-stage payload. The
trade-off is that web search/browsing tools, the dashboard's skill-hub
installs, and update checks won't work — none of which this deployment uses.
To lift it deliberately, attach a second, non-internal network to the
`hermes` service in `apps/hermes-agent/compose.yaml`.

**Verify after deploying:** confirm DockTail can still reach both containers
despite `internal: true` (it should — DockTail runs on `network_mode: host`
and connects to container IPs directly, which is host-local routing, not
the inter-network forwarding that `internal` blocks):

```sh
curl --fail https://hermes.<tailnet>.ts.net/api/status
curl --fail https://llama.<tailnet>.ts.net/health
```

If either fails after `sudo ./setup.sh reconcile`, check `docker compose
--project-name docktail --env-file /mnt/ssd/homelab/infra/docktail/.env -f
/mnt/ssd/homelab/infra/docktail/compose.yaml logs docktail` before reverting
the `internal: true` line — do not drop it silently, since that re-opens the
egress path above.

**Command approval is forced to `manual`, not the `smart` default.** Smart
mode uses an auxiliary LLM call to judge whether a command is safe to
auto-approve, and by default that auxiliary call routes to the same model
configured for chat — here, a locally-hosted, likely quantized model whose
judgment on a safety-classification task is unproven. `config.yaml` seeds
`approvals.mode: "manual"` so a human always confirms anything the pattern
matcher flags as dangerous, rather than trusting a small local model's
risk assessment. `approvals.mode: off` and `HERMES_YOLO_MODE` are never set.

**Blast radius if the agent session is compromised or manipulated** (e.g. via
prompt injection from fetched content, or a malicious skill): it can read or
corrupt anything under `/opt/data` on the SSD (sessions, memories, its own
`config.yaml` — which contains the llama.cpp API key in plaintext, scoped
only to running inference), and it can reach `llama:8080` on the internal
network. It cannot reach Pi-hole, Dozzle, DockTail, the Docker socket, the
Tailscale socket, or the internet. Prompt injection itself is not something
config can eliminate — it's inherent to any agent that reads content it
didn't fully control — the egress block and forced manual approval are what
bound the damage a successful injection can actually do here.

**Accepted residual risks:**
- The dashboard's session cookie doesn't get the `Secure` flag set, because
  DockTail's TLS-terminating proxy connects from a non-loopback peer and
  `dashboard.trusted_proxies` isn't configured (guessing the Docker bridge
  gateway IP up front risks colliding with another auto-allocated Docker
  network later). The actual exposure is low: the only plaintext hop is
  DockTail-to-container over the local Docker bridge, unreachable from
  outside the Pi. To close it, find the real gateway IP after deployment
  (`docker network inspect llama-cpp`) and add it to `dashboard.trusted_proxies`
  in `config.yaml`.
- Secrets (the dashboard password, the copied llama.cpp API key) sit in
  plaintext, `chmod 600`, on the SSD — the same posture as every other secret
  in this repo (`PIHOLE_WEBPASSWORD`, the DockTail OAuth secret). SSD theft
  or root compromise exposes all of them; nothing here is at greater risk
  than what already existed.
- The image (`nousresearch/hermes-agent`) is pinned by digest, but it's a
  fast-moving project with a large bundled dependency surface (messaging
  adapters, Matrix/olm, cloud-provider SDKs, Playwright/Chromium) that ships
  whether or not this deployment uses it. Only the official
  `github.com/NousResearch/hermes-agent` repo and `nousresearch/*` Docker Hub
  images were used to write this doc — several look-alike documentation
  mirrors exist under other domains; don't copy install commands from those.

## Test

```sh
HERMES_URL=https://hermes.<tailnet>.ts.net
curl --fail "$HERMES_URL/api/status"
```

Open `$HERMES_URL` in a browser, sign in with the username and password from
`/mnt/ssd/homelab/apps/hermes-agent/.env`, open the **Chat** tab, and confirm
the model picker shows the llama.cpp-backed model (`/model llamacpp` if none
is auto-selected).

## Rotating the llama.cpp API key

hermes-agent's `config.yaml` copies the key at first reconcile and does not
track later rotations automatically:

```sh
sudo vi /mnt/ssd/homelab/apps/llama-cpp/.env        # rotate LLAMA_API_KEY
sudo ./setup.sh reconcile llama-cpp
sudo vi /mnt/ssd/homelab/apps/hermes-agent/data/config.yaml  # update model.api_key to match
sudo ./setup.sh reconcile hermes-agent
```
