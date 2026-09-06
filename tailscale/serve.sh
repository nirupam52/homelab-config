#!/bin/sh
set -eu

tailscale serve --service=svc:dozzle   --https=443   http://127.0.0.1:8080
tailscale serve --service=svc:pihole --https=443  http://127.0.0.1:8081
tailscale serve status
