# Security policy

This repository is configuration for a personal homelab, not a distributed
product. Secrets, runtime data, and Tailscale state are never committed; they
live on the Pi (see `.gitignore`).

## Reporting a vulnerability

Report privately through GitHub: **Security tab → Report a vulnerability**.
Please do not open a public issue for anything that exposes credentials, a
network path into the tailnet, or a way out of the Hermes sandbox.

Findings that apply to this repo's configuration are in scope, for example an
egress allowlist that is too broad or a container that holds a secret it should
not. Vulnerabilities in upstream projects (Pi-hole, Dozzle, DockTail, Hermes,
Tailscale) should go to those projects.
