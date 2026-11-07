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
