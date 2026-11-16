# claude-code-tailscale — roadmap

The Docker image for a headless Claude Code CLI reached over Tailscale SSH. It is the image
the `claude-code` container on Sapphire runs (`ghcr.io/msfrox/claude-code-tailscale:latest`),
rebuilt daily by `.github/workflows/docker-publish.yml`. This repo is small, so the tracker,
the cards and the resume block all live in this one file.

**Triage, sprint S16 (2026-11-16): keep.** It is in daily use; the away-runner depends on it.

## Shipped

- [x] Image, entrypoint, GHCR publish workflow (2026-08)
- [x] `TS_EXTRA_ARGS` and `RC_EXTRA_ARGS` documented and wired (2026-09-21)

## Phase H — housekeeping (planned 2026-11-16, sprint S16)

| ID | Card | Model | Status |
|---|---|---|---|
| T1 | `.gitattributes`: LF everywhere, and above all for `entrypoint.sh` | Sonnet | todo |
| T2 | README and comments say Unraid; the host is Debian with Compose | Sonnet | todo |

## Resume

**Model: Sonnet 5.5. Effort: medium.** First card: T1. Nothing is in flight.
Nothing here waits on Shehan.

## Cards

### T1 — Force LF line endings                     [Sonnet] · effort medium · ~10 min
Why: a shell script saved with CRLF endings fails inside the container with `bad interpreter` or `$'\r': command not found`, and the image is rebuilt and pulled every day. The CRLF rewrite of 2026-11-15/16 hit other repos; if it had hit `entrypoint.sh` and been committed, the next daily build would have shipped a container that does not start, and the Claude login lives in that container.
Do: add `.gitattributes` with `* text=auto eol=lf` and an explicit `*.sh text eol=lf` and `Dockerfile text eol=lf`. Run `git add --renormalize .` and commit.
Done when: `git ls-files --eol | grep -cE 'i/crlf|w/crlf'` prints 0; the publish workflow run for the commit is green.
Don't: change the Dockerfile or the entrypoint's contents. Pushing to `main` triggers a build that Sapphire may pull, so keep this commit to the one file.

### T2 — Bring the docs up to the Debian host        [Sonnet] · effort medium · ~40 min
Why: README (9 mentions), Dockerfile header (5) and `docker-compose.yml` still describe Unraid. Sapphire moved to Debian 13 in October 2026, where this runs as a Compose stack kept in the private `star-sapphire` repo. The repo is public, so the README is also what a stranger reads.
Context to read: `README.md`, `docker-compose.yml`, `.github/workflows/docker-publish.yml`; `/workspace/CLAUDE.md` §1 and §6h for what is true on the host today.
Do: make Docker Compose the first, recommended path and move the Unraid template to a short "Unraid" section marked as no longer tested by the author. Point `docker-compose.yml`'s `image:` at `ghcr.io/msfrox/claude-code-tailscale:latest` (it says `claude-code-tailscale:latest`, which only exists after a local build). Fix the workflow comment that says 05:00 UTC above a `0 6 * * *` cron. Update the repo description: `gh repo edit msfrox/claude-code-tailscale --description "Headless Claude Code CLI reachable over Tailscale SSH — Docker image"`.
Done when: `grep -ci unraid README.md` counts only the Unraid section; `docker compose config` parses the file; the comment and the cron agree.
Don't: write anything about Shehan's own host (names, tailnet, paths) into this public README. Don't change runtime behaviour.
