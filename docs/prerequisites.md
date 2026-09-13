# Prerequisites

Complete these before running `setup.sh`.

## 1. Tailscale admin console

1. Enable **MagicDNS** and **HTTPS certificates**.
2. Create the `tag:server` and `tag:container` tags. Allow `autogroup:admin`
   to own `tag:server`, and allow `tag:server` to own `tag:container`.
3. Create a DockTail OAuth client with **General → Services → Write**
   permission, and attach `tag:container` to it. Keep the client ID and
   secret ready for the setup prompts.
4. Add an ACL equivalent to:

```json
{
  "tagOwners": {
    "tag:server": ["autogroup:admin"],
    "tag:container": ["tag:server"]
  },
  "autoApprovers": {
    "services": {
      "tag:container": ["tag:server"]
    }
  },
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["svc:dozzle", "svc:pihole", "svc:llama", "svc:hermes"],
      "ip": ["443"]
    }
  ],
  "acls": [
    {"action": "accept", "src": ["autogroup:member"], "dst": ["tag:server:*"]}
  ],
  "ssh": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:server"],
      "users": ["autogroup:nonroot", "root"]
    }
  ]
}
```

## 2. SSD

Prepare an already-formatted partition with a filesystem UUID — `setup.sh`
will never format a disk. Keep a local keyboard/monitor available for the
first run: system SSH is disabled after Tailscale SSH is confirmed.

## 3. llama.cpp models

Stage one or more verified GGUF models after the SSD is mounted. Single-file
models go directly in the directory; multimodal or multi-shard models go in
their own subdirectory (see the [llama.cpp
docs](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md#model-sources)):

```sh
sudo install -d -m 0750 /mnt/ssd/homelab/apps/llama-cpp/models
sudo install -m 0644 /path/to/model.gguf \
  /mnt/ssd/homelab/apps/llama-cpp/models/
sha256sum /mnt/ssd/homelab/apps/llama-cpp/models/model.gguf
```

Use the exact filename and checksum from the model publisher.

> The first setup pass may create the SSD directory and stop with a
> no-models error before Dozzle starts. Stage at least one model, then run
> `sudo ./setup.sh reconcile` to resume reconciling every application, not
> just llama.cpp.

## 4. GitHub deploy key

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
