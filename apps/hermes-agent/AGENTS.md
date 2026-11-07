# Where to put your work

Your working directory is `/outputs`. The owner browses and downloads it from
the dashboard's Files tab, so everything you create here is visible to them.
This file is installed by `setup.sh` from the repo; edits to it are overwritten.

- Put deliverables (HTML, Markdown, images, programs, archives, notes) in
  `/outputs/<short-task-name>/`. Use relative links inside HTML and Markdown so
  files still work after being downloaded.
- The Files tab cannot list a folder that contains a symlink pointing outside
  `/outputs`, so never create one. This includes Python virtualenvs, which
  symlink to the system interpreter: keep environments under `~/.venvs/` (or
  use `python3 -m venv --copies`). Relative symlinks inside a project are fine.
- Keep caches, `node_modules` you do not need to hand over, and other bulky
  build state in `~` rather than `/outputs`.
- Do not `chmod` files in `/outputs` to `600` or `700`; the dashboard could not
  read them. Never put credentials or private data in `/outputs`.
- When you finish, tell the owner the folder name and what to open.

# The environment you run in

Your shell and file tools run in a locked-down container on the owner's
Raspberry Pi 5 (64-bit ARM Linux, Debian). Plan around these limits instead of
working around them:

- **No root.** You are an ordinary user with no `sudo`, no `apt`, and no Docker.
  The root filesystem is read-only. Writable: `~` and `/outputs` (both persist
  across restarts) and `/tmp` (1 GiB, memory-backed, wiped on restart).
- **Installed:** Python 3 with pip and venv, Node.js and npm, git, gcc and
  make (build-essential), ripgrep, jq, curl. `pip install --user`, virtualenvs
  and project-local `npm install` work. Binaries you download must be Linux
  arm64.
- **Resources:** about 4 GiB of memory, 3 CPUs and 1024 processes, on a Pi that
  also runs other services. Avoid huge builds and downloads; a command killed
  for memory means you hit the cap.
- **Network:** no direct internet. Outbound HTTPS goes through a proxy
  (`HTTPS_PROXY` is already set) that allows package registries (PyPI, npm,
  crates.io, Go) and GitHub, and nothing else. Plain HTTP, raw IP addresses and
  the local network are blocked. A `403` or "denied" from the proxy means the
  host is not on the list, not that the network is flaky. Do not retry it or
  try to get around the proxy. Tell the owner the hostname and that it would
  need adding to `apps/hermes-agent/egress/dev.conf` in their homelab repo.
- **Nothing here is reachable from outside the container.** A dev server you
  start on a port cannot be opened by the owner. Build a static version into
  `/outputs/<task>/` instead. The Files tab downloads files and does not render
  them, so say that the owner should open the HTML locally.
- **Extra system packages or tools** have to be added by the owner to
  `apps/hermes-agent/sandbox/Dockerfile`. Your own settings and limits are
  also changed by the owner in that repo. When you need one changed, explain
  what and why, ideally as a short diff, and carry on with what you can do.
