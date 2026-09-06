#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

fail() {
    printf 'deploy: %s\n' "$1" >&2
    exit 1
}

if [ "$#" -ne 0 ]; then
    fail "this script applies the checked-out revision and takes no arguments; fetch, review, and check out the approved revision first (see README)"
fi

[ -f .env ] || fail '.env is missing; copy .env.example and configure it first'

if [ "$(stat -c '%a' .env 2>/dev/null || printf 000)" != 600 ]; then
    fail '.env must have mode 600; run chmod 600 .env'
fi

command -v python3 >/dev/null 2>&1 || fail 'python3 is required for host hardening checks'
if ! python3 -B -c \
    'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)'
then
    fail 'Python 3.8 or newer is required for host hardening checks'
fi

command -v docker >/dev/null 2>&1 || fail 'docker is required'
command -v sudo >/dev/null 2>&1 || fail 'sudo is required'
command -v tailscale >/dev/null 2>&1 || fail 'tailscale is required'

# Keep the repository user-owned. sudo is used only for the Docker and audit
# operations that require root on the host.
sudo -v

TAILSCALE_IPV4=$(sudo tailscale ip -4) \
    || fail 'unable to determine the current Tailscale IPv4 address'
[ -n "$TAILSCALE_IPV4" ] \
    || fail 'tailscale ip -4 returned no IPv4 address'

[ "$(sudo docker info --format '{{.DockerRootDir}}')" = /srv/homelab/docker ] \
    || fail 'DockerRootDir is not /srv/homelab/docker; refusing to deploy'

sudo docker compose version >/dev/null 2>&1 \
    || fail 'Docker Compose is unavailable'

COMPOSE_CONFIG=$(mktemp) || fail 'unable to create a temporary Compose configuration file'
COMPOSE_PS=$(mktemp) || {
    rm -f "$COMPOSE_CONFIG"
    fail 'unable to create a temporary Compose status file'
}
trap 'rm -f "$COMPOSE_CONFIG" "$COMPOSE_PS"' EXIT HUP INT TERM

printf '%s\n' '== Validate effective Compose configuration =='
if ! sudo docker compose config --format json >"$COMPOSE_CONFIG"; then
    fail 'unable to render the effective Compose configuration'
fi

if ! python3 -B - "$COMPOSE_CONFIG" "$TAILSCALE_IPV4" <<'PY'
import json
import sys

config_path, tailscale_text = sys.argv[1:]
try:
    with open(config_path, encoding="utf-8") as config_file:
        config = json.load(config_file)
except (OSError, ValueError) as error:
    print("deploy: rendered Compose configuration is not valid JSON: %s" % error,
          file=sys.stderr)
    raise SystemExit(1)

services = config.get("services")
if not isinstance(services, dict) or not services:
    print("deploy: rendered Compose configuration has no services", file=sys.stderr)
    raise SystemExit(1)

for service_name, service in services.items():
    for published in service.get("ports", []):
        if not isinstance(published, dict):
            print("deploy: service %s has an uninspectable published port" % service_name,
                  file=sys.stderr)
            raise SystemExit(1)
        host_ip = published.get("host_ip")
        if host_ip not in ("127.0.0.1", "::1", tailscale_text):
            print(
                "deploy: service %s publishes a port on unsafe host address %r; "
                "expected 127.0.0.1, ::1, or %s"
                % (service_name, host_ip, tailscale_text),
                file=sys.stderr,
            )
            raise SystemExit(1)
PY
then
    fail 'effective Compose configuration publishes an unsafe host address'
fi

printf '%s\n' '== Host hardening verification (read-only preflight) =='
sudo sh "$SCRIPT_DIR/hardening/verify.sh"

printf '%s\n' '== Pull pinned images =='
sudo docker compose pull

printf '%s\n' '== Apply Compose configuration =='
sudo docker compose up -d --wait --remove-orphans

printf '%s\n' '== Container status =='
sudo docker compose ps
if ! sudo docker compose ps --format json >"$COMPOSE_PS"; then
    fail 'unable to inspect deployed container status'
fi

if ! python3 -B - "$COMPOSE_CONFIG" "$COMPOSE_PS" <<'PY'
import json
import sys

config_path, status_path = sys.argv[1:]
try:
    with open(config_path, encoding="utf-8") as config_file:
        expected_services = set(json.load(config_file)["services"])
    with open(status_path, encoding="utf-8") as status_file:
        status = []
        for line_number, line in enumerate(status_file, 1):
            line = line.strip()
            if not line:
                continue
            try:
                container = json.loads(line)
            except ValueError as error:
                raise ValueError("line %d: %s" % (line_number, error)) from error
            if not isinstance(container, dict):
                raise ValueError("line %d is not a JSON object" % line_number)
            status.append(container)
        if not status:
            raise ValueError("status output is empty")
except (KeyError, OSError, ValueError) as error:
    print("deploy: unable to parse Compose service status: %s" % error, file=sys.stderr)
    raise SystemExit(1)

by_service = {}
for container in status:
    if not isinstance(container, dict):
        continue
    service = container.get("Service")
    if service is None:
        service = container.get("service")
    by_service.setdefault(service, []).append(container)

for service in sorted(expected_services):
    containers = by_service.get(service, [])
    if not containers:
        print("deploy: expected service %s has no running container" % service,
              file=sys.stderr)
        raise SystemExit(1)
    for container in containers:
        state = container.get("State")
        if state is None:
            state = container.get("state")
        health = container.get("Health")
        if health is None:
            health = container.get("health")
        if str(state).lower() != "running" or (
            health and str(health).lower() != "healthy"
        ):
            print(
                "deploy: service %s is not ready (state=%s, health=%s)"
                % (service, state, health or "none"),
                file=sys.stderr,
            )
            raise SystemExit(1)
PY
then
    fail 'expected Compose services are not all running and healthy'
fi

printf '%s\n' 'deploy: complete'
