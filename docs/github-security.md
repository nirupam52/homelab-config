# GitHub security and updates

The repo is public on a free GitHub plan. Everything below is free for public
repositories.

## Updates: Dependabot

`.github/dependabot.yml` opens weekly PRs (Mondays, 06:00 America/Chicago):

| Ecosystem | Covers |
|---|---|
| `docker-compose` | Every `image: tag@sha256` in `apps/*/compose.yaml` and `infra/docktail/compose.yaml`. Tag and digest are bumped together. One PR per service. |
| `docker` | Digest of the base image in `apps/hermes-agent/sandbox/Dockerfile`. |
| `github-actions` | Workflow action pins, grouped into one PR. |

Releases younger than 5 days (14 for major versions) are skipped by
`cooldown`, so a bad release can be pulled upstream before it reaches a PR.
Security updates ignore the cooldown.

Merging a PR changes the repo only. Deploy it on the Pi:

```sh
git pull && sudo ./setup.sh reconcile <project>
```

Review notes:

- **hermes-agent** is a `0.x` release; any bump can be breaking. Read the
  upstream release notes before merging.
- **ubuntu/squid** uses a non-semver tag (`7.2-26.04_edge`). If Dependabot
  proposes an odd tag, close the PR and bump it by hand.
- **Pi-hole** uses date-based versions (`2026.10.0`). Dependabot treats them as
  semver-like, so check that the PR moves forward.
- Packages installed with `apt` in the sandbox Dockerfile are not tracked by
  Dependabot. Rebuild picks up current Debian packages: `sudo ./setup.sh
  reconcile hermes-agent`.

## CI

| Workflow | Runs | Checks |
|---|---|---|
| `ci.yml` | PRs, pushes to `main` | `shellcheck setup.sh`; `docker compose config` on every compose file, with dummy secrets. |
| `image-scan.yml` | Mondays, PRs touching `apps/` or `infra/`, manual | Trivy scan (CRITICAL/HIGH with a fix available) of every image in the compose files, plus the sandbox image built from source. Results go to Security → Code scanning, one category per image. Never fails the build. |

Dependabot alerts do not cover container images or `apt` packages. The image
scan is the only thing that does.

All actions are pinned to a commit SHA with the version in a trailing
comment; Dependabot updates both. Workflows default to `contents: read`.

## Repository settings

These live in GitHub, not in the repo. Settings → Advanced Security unless
noted.

| Setting | State |
|---|---|
| Dependency graph, Dependabot alerts | On |
| Dependabot security updates | On |
| Secret scanning, push protection | On |
| Private vulnerability reporting | On (`SECURITY.md` points to it) |
| Settings → General → Automatically delete head branches | On |
| Settings → Actions → Workflow permissions | Read repository contents; Actions cannot approve PRs |
| Ruleset on `main` | See below |

Set or reapply them with the GitHub CLI:

```sh
R=repos/nirupam52/homelab-config
gh api -X PUT $R/vulnerability-alerts
gh api -X PUT $R/automated-security-fixes
gh api -X PUT $R/private-vulnerability-reporting
gh api -X PATCH $R -F delete_branch_on_merge=true
```

### Ruleset on `main`

Require a PR and the CI checks, and block force pushes and deletion. This
matters here because you run `main` on the Pi as root through `setup.sh`, so
whatever lands on `main` gets deployed with root privileges. No required
approvals: this is a one-person repo and you cannot approve your own PR.

```sh
gh api -X POST repos/nirupam52/homelab-config/rulesets --input - <<'EOF'
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "shellcheck" },
          { "context": "compose" } ] } }
  ]
}
EOF
```

Create it after `ci.yml` has run once on `main`, so the check names exist.
Without a bypass actor it applies to you too.
