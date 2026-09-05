#!/bin/sh
set -eu

tailscale serve --bg --service=svc:dozzle --https=443 http://127.0.0.1:8080
tailscale serve --bg --service=svc:pihole --https=443 http://127.0.0.1:8081/admin
tailscale serve status
