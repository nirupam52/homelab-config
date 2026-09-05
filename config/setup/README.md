# Homelab setup

This directory contains the homelab deployment:

- Raspberry Pi 5
- SD Card for OS, Everything else on SSD
- Tailscale-only access

## Storage layout

The SSD is mounted at `/srv/homelab`.

```text
SD card
└── OS

SSD: /srv/homelab
├── repo/              repository checkout
└── docker/            Docker images, containers, and volumes
```

The Docker data directory is configured in `docker/daemon.json`. The Pi-hole
volume is therefore stored on the SSD.

## 1. Verify the disks

Run this on the Raspberry Pi:

```bash
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL,TRAN
```

Confirm that the dedicated SSD partition is `/dev/sda2` and that the SD card
is `/dev/mmcblk0`. Never format `/dev/mmcblk0`.

## 2. Format the SSD partition

Only run this if `/dev/sda2` is not already the intended empty ext4 partition.
This erases `/dev/sda2`:

```bash
sudo mkfs.ext4 -m 1 -L homelab /dev/sda2
```

## 3. Mount the SSD

```bash
sudo mkdir -p /srv/homelab

SSD_UUID="$(sudo blkid -s UUID -o value /dev/sda2)"
test -n "$SSD_UUID"

if ! grep -q "UUID=$SSD_UUID /srv/homelab " /etc/fstab; then
  printf 'UUID=%s /srv/homelab ext4 defaults,noatime,nofail 0 2\n' \
    "$SSD_UUID" | sudo tee -a /etc/fstab >/dev/null
fi

sudo mount /srv/homelab
df -h /srv/homelab
```

Place this repository checkout at `/srv/homelab/repo` using the preferred
transfer method.

## 4. Install Docker

Apply the Docker data-root configuration before starting containers:

```bash
sudo install -d -m 0755 /srv/homelab/docker

sudo install -D -m 0644 \
  /srv/homelab/repo/config/setup/docker/daemon.json \
  /etc/docker/daemon.json

sudo apt-get update
sudo apt-get install -y docker.io docker-compose
sudo systemctl enable --now docker
```

Verify that Docker uses the SSD:

```bash
sudo docker info --format 'DockerRootDir={{.DockerRootDir}}'
```

Expected output:

```text
DockerRootDir=/srv/homelab/docker
```

## 5. Install and connect Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
sudo tailscale set --accept-dns=false
sudo tailscale ip -4
```

Complete the authentication link shown by `tailscale up`. Save the IPv4
address for the Compose environment file.

## 6. Configure the services

```bash
cd /srv/homelab/repo/config/setup
cp .env.example .env
chmod 600 .env
nano .env
```

Set these values:

```dotenv
TZ=UTC
TAILSCALE_IPV4=<Pi IPv4 address from tailscale ip -4>
PIHOLE_WEBPASSWORD=<strong Pi-hole web password>
```

Start Docker Services:

```bash
sudo docker compose config --quiet
sudo docker compose up -d
sudo docker compose ps
```

## 7. Enable private web access

```bash
sh /srv/homelab/repo/config/setup/tailscale/serve.sh
tailscale serve status
```

Tailscale Serve provides:

- Dozzle at the node HTTPS URL on port `443`.
- Pi-hole at the same URL on port `8443`, under `/admin/`.

If Tailscale asks to enable HTTPS certificates for the tailnet, approve it.

## 8. Configure tailnet DNS

In the Tailscale admin console:

1. Open **DNS**.
2. Add the Pi's Tailscale IPv4 address as a nameserver.
3. Keep MagicDNS enabled.
4. Enable local-DNS override if every tailnet device should use Pi-hole.

The LAN is not changed. Pi-hole DNS is bound only to the Pi's Tailscale IPv4
address.

## 9. Verify

On the Pi:

```bash
sudo docker compose ps
sudo ss -lntup | grep -E '(:53|:8080|:8081)'
tailscale serve status
```

Expected bindings:

```text
<Tailscale IPv4>:53   Pi-hole DNS
127.0.0.1:8080        Dozzle backend
127.0.0.1:8081        Pi-hole web backend
```

From another Tailscale device:

```bash
nslookup example.com <Pi Tailscale IPv4>
```

Then open the URLs shown by `tailscale serve status`.

## Updating and stopping

Images are pinned to explicit release tags in `compose.yaml`.

```bash
cd /srv/homelab/repo/config/setup
sudo docker compose pull
sudo docker compose up -d
```

Stop the services without deleting Pi-hole data:

```bash
sudo docker compose down
```

Do not use `docker compose down -v` unless the Pi-hole volume should be
removed.


## References

- [Debian Docker package](https://packages.debian.org/trixie/docker.io)
- [Debian Docker Compose package](https://packages.debian.org/trixie/docker-compose)
- [Pi-hole Docker configuration](https://docs.pi-hole.net/docker/configuration/)
- [Tailscale Linux installation](https://tailscale.com/docs/install/linux)
- [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve)
