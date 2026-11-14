# Migrating from the Hermes containers to agent VMs

One-time steps for a Pi that runs the previous `hermes-agent` Compose stack.
The old Hermes keeps running until the `coder` VM has proven that VMs work
here, and its state is archived, not deleted, until the new Hermes works.
Pi-hole, Dozzle and DockTail keep running throughout. Pi-hole restarts once
in step 4, which means a few seconds without DNS.

## 1. Check that the Pi can run VMs (read-only)

```sh
ls -l /dev/kvm                     # must exist
. /etc/os-release && echo "$VERSION_CODENAME"
apt-cache policy incus | head -3   # trixie: a candidate version
free -h; df -h /mnt/ssd            # ~10 GiB RAM and ~100 GiB SSD free
```

On bookworm, enable `bookworm-backports` first, because bookworm itself has
no `incus` package. If `/dev/kvm` is missing, stop here.

## 2. Tailscale admin console: add `tag:agent`

1. Save a copy of the current policy file for rollback.
2. **Access controls:** add the `tag:agent` parts from
   [prerequisites](prerequisites.md#1-tailscale-admin-console): the
   `tagOwners` entry, the `tag:agent` grant and the `agent` SSH rule. Leave
   `svc:hermes` alone for now.
3. **Keys:** generate two auth keys, one per VM, each with tag `tag:agent`,
   pre-approved, not reusable, not ephemeral, and a 1-day expiry.

## 3. Pull and bootstrap

```sh
cd ~/homelab-config
git pull --ff-only
sudo ./setup.sh bootstrap
```

Bootstrap installs Incus and QEMU, creates the storage pool on
`/mnt/ssd/incus`, the `incusbr0` bridge, the `agent-egress` ACL and the
`agent-vm` profile, and adds three UFW rules for the bridge. It does not
restart Docker or any container, and the old Hermes keeps running.

Verify:

```sh
sudo incus info | grep firewall      # firewall: nftables
sudo incus network list              # incusbr0, 10.250.0.1/24
sudo ufw status | grep incusbr0
docker ps                            # all existing containers still up
```

## 4. Restart Pi-hole with its new OOM score

```sh
sudo ./setup.sh reconcile pihole
```

## 5. Create the coder VM

```sh
sudo ./setup.sh reconcile coder      # paste the first auth key when asked
```

The first run downloads the Debian image and takes several minutes. When it
finishes, check the network boundary. Most routers answer HTTP, so the LAN
gateway makes a good test target:

```sh
GW=$(ip -4 route | awk '/default/ {print $3; exit}')
sudo incus exec coder -- curl -sI https://github.com | head -1    # HTTP/2 200
curl -m 5 -s -o /dev/null -w 'from the Pi: %{http_code}\n' "http://$GW"
sudo incus exec coder -- curl -m 5 -s -o /dev/null -w 'from coder: %{http_code}\n' "http://$GW"
```

The Pi gets a status code, and `coder` must get `000`. Then sign in as
described in [Agent VMs → Sign-ins](agent-vms.md#sign-ins-once-per-vm).

If this step fails, stop. The old Hermes is untouched; see Rolling back.

## 6. Retire the old Hermes stack

Stop the old stack and keep its state:

```sh
cd /mnt/ssd/homelab/apps/hermes-agent
sudo docker compose --project-name hermes-agent --env-file .env -f compose.yaml down
cd / && sudo mv /mnt/ssd/homelab/apps/hermes-agent /mnt/ssd/homelab/hermes-agent.old
```

Then, in the Tailscale admin console:

1. **Services:** delete `svc:hermes`. DockTail does not remove it, and the
   new `hermes` VM needs that name.
2. **Access controls:** remove `svc:hermes` from the Services grant.

## 7. Create the hermes VM

```sh
sudo ./setup.sh reconcile hermes     # paste the second auth key
```

Sign in with `ssh agent@hermes` and run `hermes auth add openai-codex`. Read
the dashboard password with `sudo cat /etc/hermes/dashboard.env`, then open
`https://hermes.<tailnet>.ts.net` and send a chat message.

## 8. Clean up (optional, once the new Hermes works)

```sh
sudo rm -rf /mnt/ssd/homelab/hermes-agent.old
docker image rm hermes-sandbox:local
```

The archive holds the old ChatGPT login. In ChatGPT → Settings → Security,
log out that session too.

## Rolling back

- **One VM:** `sudo incus delete --force <vm>`, then remove its device in
  the Tailscale admin console.
- **Back to the old Hermes:**
  1. Delete the `hermes` VM.
  2. Restore the saved Tailscale policy, which brings back `svc:hermes`.
  3. Move the stack back:
     `sudo mv /mnt/ssd/homelab/hermes-agent.old /mnt/ssd/homelab/apps/hermes-agent`
  4. Check out the previous commit and run
     `sudo ./setup.sh reconcile hermes-agent`.
  5. Approve the `homelabpi` host for `svc:hermes` again (see
     [Services → Troubleshooting](services.md#troubleshooting)).
  The old login, sessions and dashboard password are all in the archive.
- **Remove Incus entirely:**
  1. Delete both VMs.
  2. `sudo apt purge incus`, then `sudo rm -rf /mnt/ssd/incus`.
  3. Remove the three `incusbr0` UFW rules: find them with
     `sudo ufw status numbered`, then `sudo ufw delete <n>`.
