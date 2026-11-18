# Migrating from the Hermes containers to agent VMs

One-time steps for a Pi that runs the previous `hermes-agent` Compose stack.
The old Hermes keeps running until `coder` proves VMs work here, and its
state is archived, not deleted, until the new Hermes works. Pi-hole restarts
once (step 4): a few seconds without DNS.

## 1. Check that the Pi can run VMs

```sh
ls -l /dev/kvm                     # must exist; if not, stop here
. /etc/os-release && echo "$VERSION_CODENAME"
apt-cache policy incus | head -3   # needs a candidate version
free -h; df -h /mnt/ssd            # ~10 GiB RAM and ~100 GiB SSD free
```

On bookworm, enable `bookworm-backports` first; bootstrap installs Incus
and its QEMU from there.

## 2. Tailscale: add `tag:agent`

Save a copy of the current policy file, then add the `tag:agent` parts from
[prerequisites](prerequisites.md#1-tailscale-admin-console): the
`tagOwners` entry, the two agent grants and the `agent` SSH rule. Leave
`svc:hermes` for now.

## 3. Bootstrap

```sh
cd ~/homelab-config && git pull --ff-only
sudo ./setup.sh bootstrap
sudo incus info | grep firewall                  # firewall: nftables
sudo incus network get incusbr0 security.acls    # agent-egress
docker ps                                        # existing containers still up
```

Bootstrap adds Incus, its storage pool on `/mnt/ssd/incus`, the `incusbr0`
bridge with the ACL, the `agent-vm` profile, and three UFW rules for the
bridge. It restarts no container.

## 4. Restart Pi-hole with its new OOM score

```sh
sudo ./setup.sh reconcile pihole
```

## 5. Create coder

```sh
sudo ./vms/create.sh coder
```

Open the login link it prints. Then run
[Check the boundary](agent-vms.md#check-the-boundary) (the `hermes` line
comes after step 7). If anything that must be blocked is open, stop and
delete the VM; the old Hermes is untouched.

## 6. Retire the old Hermes stack

```sh
cd /mnt/ssd/homelab/apps/hermes-agent
sudo docker compose --project-name hermes-agent --env-file .env -f compose.yaml down
cd ~/homelab-config && sudo mv /mnt/ssd/homelab/apps/hermes-agent /mnt/ssd/homelab/hermes-agent.old
```

In the Tailscale admin console, delete the `svc:hermes` Service (DockTail
leaves it, and the new VM needs the name). In the policy file, remove
`svc:hermes` from the Services grant and from `autoApprovers`.

## 7. Create hermes

```sh
sudo ./vms/create.sh hermes
```

The new Hermes starts empty; the old memory, sessions and skills stay in
`hermes-agent.old`. Run the last line of the boundary check, then
[sign in](agent-vms.md#sign-in-once-per-vm) and send a chat message on
`https://hermes.<tailnet>.ts.net`.

## 8. Clean up

Once the new Hermes works:

```sh
sudo rm -rf /mnt/ssd/homelab/hermes-agent.old
docker image rm hermes-sandbox:local
```

The archive held the old ChatGPT login: in ChatGPT → Settings → Security,
log out that session too.

## Rolling back

- **One VM:** `sudo incus delete --force <vm>`, then remove its device in
  the Tailscale admin console.
- **Back to the old Hermes:** delete the `hermes` VM, restore the saved
  Tailscale policy, `sudo mv /mnt/ssd/homelab/hermes-agent.old /mnt/ssd/homelab/apps/hermes-agent`,
  check out the previous commit, run `sudo ./setup.sh reconcile hermes-agent`,
  and approve `svc:hermes` again ([Services → Troubleshooting](services.md#troubleshooting)).
- **Remove Incus:** delete both VMs, `sudo apt purge incus`,
  `sudo rm -rf /mnt/ssd/incus`, and delete the three `incusbr0` rules
  (`sudo ufw status numbered`, then `sudo ufw delete <n>`).
