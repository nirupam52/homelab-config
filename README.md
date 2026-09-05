# Homelab setup

This directory contains the homelab deployment:

- Raspberry Pi
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
Assuming the partition we want to mount is `sda2`

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

The repository checkout should be owned by the account that performs updates. Run these commands as the normal Pi login user:

```bash
PI_USER="$(id -un)"
PI_GROUP="$(id -gn)"
sudo install -d -o "$PI_USER" -g "$PI_GROUP" -m 0755 /srv/homelab/repo
```

If the checkout already exists and was created with `sudo`, repair its ownership once:

```bash
sudo chown -R "$(id -un):$(id -gn)" /srv/homelab/repo
```

Clone, copy, and update the checkout without `sudo`:

```bash
cd /srv/homelab/repo
git pull
```

Only the repository is user-owned; keep `/srv/homelab/docker` root-managed for Docker.

## 4. Install Docker

Apply the Docker data-root configuration before starting containers:

```bash
sudo install -d -m 0755 /srv/homelab/docker

sudo install -D -m 0644 \
  /srv/homelab/repo/docker/daemon.json \
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
sudo tailscale up
sudo tailscale set --ssh
sudo tailscale set --accept-dns=false
sudo tailscale ip -4
```

Complete the authentication link shown by `tailscale up`. Save the IPv4
address for the Compose environment file.


## Host hardening

Keep the Pi on wired access, or keep a console/recovery path open.
Before stopping normal SSH, connect to this Pi over Tailscale SSH from a second
tailnet device and confirm that it works. The apply script will not continue
without its explicit confirmation flag.

Install UFW, then apply and check the hardening:

```bash
sudo apt-get update
sudo apt-get install -y ufw
sudo sh /srv/homelab/repo/hardening/apply.sh --tailscale-ssh-tested
sudo sh /srv/homelab/repo/hardening/verify.sh
```

The apply script does not reboot the Pi. It configures UFW, stops normal SSH
and Avahi, disables Wi-Fi and Bluetooth services, and adds persistent radio
overlays. It does not reset UFW or remove packages. If it finds unexpected
firewall rules, stop and review them instead of resetting UFW.

Reboot after the first local check, then run the check again:

```bash
sudo reboot
sudo sh /srv/homelab/repo/hardening/verify.sh
```

The scripts check local state only. After the services below are running,
complete the LAN, tailnet, and external checks in section 9.

Keep the Compose bindings narrow. Do not publish a new Docker port on
`0.0.0.0` or `[::]`; Docker can route published ports before UFW sees them.
Do not add a Docker `iptables=false` setting.

If recovery is needed, use the console or the current Tailscale path:

```bash
sudo ufw disable
```

To undo the radio change, remove only the `dtoverlay=disable-wifi` and
`dtoverlay=disable-bt` lines added by the script. Remove their `[all]` section
only if it was created solely for those lines, then reboot. The script keeps
one backup beside the boot config; do not overwrite a newer boot config with
the whole backup without checking it first.

Re-enable normal SSH only deliberately and only for recovery:

```bash
sudo systemctl enable --now ssh.service
```

Do not blindly re-enable Avahi, Wi-Fi, or Bluetooth.

## 6. Configure the services

```bash
cd /srv/homelab/repo
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
sh /srv/homelab/repo/tailscale/serve.sh
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
sudo ss -lntup
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
They should show only tailnet access.

From a LAN device that is not using Tailscale:

- SSH to the Pi's LAN IP should fail.
- DNS queries to the Pi's LAN IP should fail.
- The Pi's LAN IP and LAN IP on port `8443` should not open.

From outside the home network, confirm that no service is reachable. Also
confirm that the router has no port forwarding to the Pi.

## Updating and stopping

Images are pinned to explicit release tags in `compose.yaml`.

```bash
cd /srv/homelab/repo
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
