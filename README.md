# Claude Code + Tailscale container

A headless [Claude Code](https://claude.com/claude-code) CLI you reach over your
tailnet via Tailscale SSH. This is the "baked image" version of the container
that was previously hand-patched at runtime — building it means Node, npm,
system packages, and the `/usr/local` write-permission fix all survive container
recreation, host reboots, and image re-pulls.

## What's inside

| Component     | Version / notes                                        |
|---------------|--------------------------------------------------------|
| Base image    | `node:24-bookworm` (Node 24 LTS, npm, yarn, corepack)  |
| Tailscale     | latest stable from pkgs.tailscale.com                  |
| GitHub CLI    | latest stable from cli.github.com                      |
| Claude Code   | `@anthropic-ai/claude-code@latest`, self-update works  |
| User          | runs as `root` (for tailscaled); SSH logs you in `node`|

## Why this exists

The original container ran Node 20 and had `/usr/local` owned by root, so
`claude` couldn't self-update ("no write permission to npm prefix"). Those fixes
were applied live, inside the running container's throwaway overlay layer, and
would be lost on any recreate. This image bakes them in permanently.

## Files

- `Dockerfile` — the image definition
- `entrypoint.sh` — starts tailscaled + joins the tailnet with SSH enabled
- `docker-compose.yml` — build + run with the right caps, device, and volumes
- `.env.example` — copy to `.env` and fill in for an unattended first join

## Build & run

### Option A — Unraid / host shell (docker compose)

```bash
cd /path/to/docker/claude-code        # where these files live
cp .env.example .env                  # then edit .env (optional TS_AUTHKEY)
docker compose build
docker compose up -d
docker compose logs -f                # watch it join the tailnet
```

If you did **not** set `TS_AUTHKEY`, the logs print a Tailscale login URL —
open it once to authorize the node. After that the auth is stored in the
`tailscale-state` volume and never needed again.

### Option B — Portainer **Git stack** (recommended)

This is the clean way: Portainer pulls the repo, builds the image from the
`Dockerfile`, and runs the stack — no copying files onto the host. If your fork
is **private**, you first tell Portainer how to authenticate to GitHub (skip the
token step for a public repo).

#### 1. (Private repo only) Make a GitHub access token

- GitHub → **Settings → Developer settings → Personal access tokens → Fine-grained
  tokens → Generate new token**.
- **Repository access:** Only select repositories → your fork of this repo.
- **Permissions:** Repository → **Contents: Read-only** (that's all Portainer
  needs to clone).
- Set an expiry you're comfortable with and generate it. Copy the
  `github_pat_…` value.

  > A classic token with the `repo` scope also works if you prefer.

#### 2. Create the stack in Portainer

1. **Stacks → Add stack →** name it e.g. `claude-code`.
2. Build method: **Repository**.
3. **Repository URL:** `https://github.com/<your-user>/<your-fork>`
4. **Repository reference:** `refs/heads/main`
5. **Compose path:** `docker-compose.yml`
6. (Private repo only) Toggle **Authentication ON**:
   - **Username:** your GitHub username
   - **Password / token:** the `github_pat_…` token from step 1.
7. (Optional) Enable **Automatic updates → polling** so Portainer re-pulls and
   redeploys when you push changes to `main`.

#### 3. Set the environment variables

In the stack's **Environment variables** section add:

| Name            | Value                                          | Required |
|-----------------|------------------------------------------------|----------|
| `TS_AUTHKEY`    | a Tailscale auth key (see below)               | first join only |
| `TS_HOSTNAME`   | `claude-code` (or your preferred tailnet name) | optional |
| `WORKSPACE_PATH`| host path for projects, e.g. `/mnt/.../Projects` | optional |

Generate `TS_AUTHKEY` at the Tailscale admin console → **Settings → Keys →
Generate auth key** (reusable/ephemeral as you prefer). It's only needed for the
**first** authenticated start; afterwards the identity lives in the
`tailscale-state` volume and the key can be removed.

#### 4. Deploy

Click **Deploy the stack**. Portainer clones the repo, builds
`claude-code-tailscale:latest` from the `Dockerfile`, and starts the container
with the `NET_ADMIN` cap, `/dev/net/tun`, and the volumes from
`docker-compose.yml`. Watch the container logs for the Tailscale join; if you
didn't set `TS_AUTHKEY`, the log prints a login URL to authorize once.

> **Updating later:** push a commit to `main`, then in Portainer either wait for
> polling (if enabled) or hit **Pull and redeploy** on the stack. To rebuild on a
> newer Node base image, use **Re-pull image and redeploy** / enable
> `--pull` behavior so the `FROM node:24-bookworm` layer refreshes.

### Option C — plain docker build

```bash
docker build -t claude-code-tailscale:latest .
docker run -d --name claude-code --hostname claude-code \
  --restart unless-stopped \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -e TS_HOSTNAME=claude-code \
  -e TS_AUTHKEY=tskey-auth-xxxxx \
  -v tailscale-state:/var/lib/tailscale \
  -v node-home:/home/node \
  -v /path/on/host/projects:/workspace \
  claude-code-tailscale:latest
```

## Using host bind mounts instead of named volumes

By default `/home/node` and `/var/lib/tailscale` use named volumes, and
`/workspace` follows `WORKSPACE_PATH`. To pin any of them to specific host paths
(e.g. an array/cache path, or to migrate an existing container's data), bind
mount them, e.g.:

```yaml
volumes:
  - /path/on/host/tailscale:/var/lib/tailscale
  - /path/on/host/home:/home/node
  - /path/on/host/projects:/workspace
```

**Migrating an existing `/var/lib/tailscale` keeps that node's identity**, so it
stays the same tailnet machine with the same IP and no re-auth. Migrating
`/home/node` keeps your Claude Code login and config.

## Required container settings (don't drop these)

- **Capability `NET_ADMIN`** and **device `/dev/net/tun`** — without them
  tailscaled can't create the `tailscale0` interface and Tailscale (your only
  way in) won't work.
- **Persistent `/var/lib/tailscale`** — without it you re-authenticate on every
  restart.

## Updating

- **Claude Code** self-updates at runtime now (the `/usr/local` fix). No rebuild
  needed for CLI updates.
- **Node / system packages** — rebuild the image periodically:
  `docker compose build --pull && docker compose up -d`. Because Node lives in
  the image (not a volume), a rebuild is how you move Node versions going
  forward — no more hand-patching.
