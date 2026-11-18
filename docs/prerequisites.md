# Prerequisites

Complete these before running `setup.sh`.

## 1. Tailscale admin console

1. Enable **MagicDNS** and **HTTPS certificates**.
2. Create the `tag:server`, `tag:container` and `tag:agent` tags.
3. Create a DockTail OAuth client with **General → Services → Write**
   permission, and attach `tag:container` to it. Keep the client ID and
   secret ready for the setup prompts.
4. Set the policy file. Access is per device: list your devices' Tailscale
   IPs under `hosts`.

```jsonc
{
   "hosts": {
      "admin-phone":   "100.x.y.z",
      "admin-mac":     "100.x.y.z",
      "admin-windows": "100.x.y.z",
   },

   "grants": [
      // Apps published by DockTail.
      {
         "src": ["admin-phone", "admin-mac", "admin-windows"],
         "dst": ["svc:dozzle", "svc:pihole", "svc:llama"],
         "ip":  ["443"],
      },
      // Pi-hole DNS for the whole tailnet.
      {
         "src": ["autogroup:member"],
         "dst": ["tag:server"],
         "ip":  ["53"],
      },
      // SSH to the Pi.
      {
         "src": ["admin-mac", "admin-windows"],
         "dst": ["tag:server"],
         "ip":  ["22"],
      },
      // Agent VMs. Phone: the Hermes dashboard only.
      {
         "src": ["admin-phone"],
         "dst": ["tag:agent"],
         "ip":  ["443"],
      },
      // Agent VMs. Computers: SSH, dashboard, dev-server previews.
      {
         "src": ["admin-mac", "admin-windows"],
         "dst": ["tag:agent"],
         "ip":  ["*"],
      },
      // Nothing has tag:agent as a source: agent VMs reach nothing on the tailnet.
   ],

   "tagOwners": {
      "tag:server":    ["autogroup:admin"],
      "tag:container": ["tag:server"],
      "tag:agent":     ["autogroup:admin"],
   },

   // Never list tag:agent here: no Services, routes or exit nodes.
   "autoApprovers": {
      "services": {
         "svc:dozzle": ["tag:server"],
         "svc:pihole": ["tag:server"],
         "svc:llama":  ["tag:server"],
      },
   },

   // Grants above decide which devices reach port 22.
   "ssh": [
      {
         "action": "accept",
         "src":    ["autogroup:owner"],
         "dst":    ["tag:server"],
         "users":  ["autogroup:nonroot", "root"],
      },
      {
         "action": "accept",
         "src":    ["autogroup:owner"],
         "dst":    ["tag:agent"],
         "users":  ["agent"],
      },
   ],
}
```

`svc:llama` is not part of this repository; drop it if you don't run it.

`tag:agent` is for the [agent VMs](agent-vms.md). `vms/create.sh` joins
each VM through a login link, so the admin who opens it must own the tag.
Keep `tag:agent` out of every `src`, out of `autoApprovers` and out of
Funnel. Tagged devices are not `autogroup:member`, so the VMs cannot use
Pi-hole either; they resolve names through Incus.

Inside a VM you are root with its logins. For a fresh sign-in before each
agent SSH session (every 12 hours by default), set that rule's `action` to
`"check"`.

## 2. SSD

Prepare an already-formatted partition with a filesystem UUID — `setup.sh`
will never format a disk. Keep a local keyboard/monitor available for the
first run: system SSH is disabled after Tailscale SSH is confirmed.

## 3. GitHub deploy key

The Pi clones this repository over SSH with a repository-specific, read-only
deploy key. Generate it as the normal Pi user:

```sh
install -d -m 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/homelab-config-deploy \
  -C "rpi5 homelab deploy key"
```

Add the public key in the repository's GitHub settings:

1. Open **Settings → Deploy keys → Add deploy key**.
2. Give it a name such as `rpi5-homelab`.
3. Paste the output of:
   ```sh
   cat ~/.ssh/homelab-config-deploy.pub
   ```
4. Leave **Allow write access** disabled. Pull access is sufficient.

Scope the key to this repo only, so it isn't offered to unrelated GitHub
repositories:

```sh
cat >> ~/.ssh/config <<'EOF'
Host github-homelab
    HostName github.com
    User git
    IdentityFile ~/.ssh/homelab-config-deploy
    IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
```

If the key has a passphrase, load it before cloning or pulling:

```sh
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/homelab-config-deploy
```

Test the connection. On the first connection, verify GitHub's published SSH
host fingerprint before accepting it:

```sh
ssh -T github-homelab
```

Next: [First setup](first-setup.md).
