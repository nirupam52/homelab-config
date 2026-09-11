# Tailnet-wide DNS

The setup script records the Pi's Tailscale IPv4 address in
`/mnt/ssd/homelab/apps/pihole/.env` and publishes Pi-hole on UDP and TCP port
53 at that address.

## Enable it

1. Open the Tailscale admin console's **DNS** page.
2. Under **Nameservers**, choose **Add nameserver → Custom** and enter the
   Pi's Tailscale IPv4 address from `tailscale ip -4`.
3. Enable **Override DNS servers**.
4. Keep Tailscale DNS enabled on each client. On Linux clients:
   ```sh
   sudo tailscale set --accept-dns=true
   ```
5. In Pi-hole's **Lists** settings, verify or add ad/tracker blocklists, then
   update gravity.

The existing `tag:server:*` ACL permits tailnet members to reach direct DNS
on the Pi. No `svc:pihole-dns` service is needed because Tailscale Services
currently support TCP only, while clients normally send DNS over UDP.

## Verify

```sh
PIHOLE_IP=100.x.y.z
dig @"$PIHOLE_IP" example.com
dig +tcp @"$PIHOLE_IP" example.com
```

Confirm the queries appear in Pi-hole's **Query Log**. If they do not, the
client is not using Tailscale DNS or is bypassing it with DoH, DoT, a VPN,
or a private relay.
