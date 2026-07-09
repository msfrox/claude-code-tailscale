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
- `.github/workflows/docker-publish.yml` — builds + pushes the image to GHCR

## The image (GHCR)

A GitHub Actions workflow builds this image and publishes it to the GitHub
Container Registry on every push to `main`:

```
ghcr.io/<owner>/claude-code-tailscale:latest
```

> **One-time:** after the first workflow run, open the repo's **Packages →
> package settings** and set the package visibility to **Public** so hosts
> (Unraid, etc.) can `docker pull` it without credentials.

You can either pull that prebuilt image (Options A/B below) or build locally
(Options C/D).

## Deploy

### Option A — Unraid native Docker manager (recommended on Unraid)

Unraid's Docker manager pulls a prebuilt image from a registry, so use the GHCR
image above.

1. **Docker** tab → **Add Container**.
2. **Name:** `claude-code`
3. **Repository:** `ghcr.io/<owner>/claude-code-tailscale:latest`
4. Switch the template to **Advanced view** (toggle, top-right) and set
   **Extra Parameters:** `--cap-add NET_ADMIN`
5. **Add** a **Device:** value `/dev/net/tun`
6. **Add** these **Path** mappings (Container path → host path):
   | Container path        | Host path (example)                              |
   |-----------------------|--------------------------------------------------|
   | `/var/lib/tailscale`  | `/mnt/user/appdata/claude-code/tailscale`        |
   | `/home/node`          | `/mnt/user/appdata/claude-code/home`             |
   | `/workspace`          | your projects path, e.g. `/mnt/user/Projects`    |
7. **Add** these **Variables**:
   | Name         | Value                                              |
   |--------------|----------------------------------------------------|
   | `TS_HOSTNAME`| `claude-code`                                      |
   | `TS_AUTHKEY` | a Tailscale auth key (first join only — see below) |
8. **Apply.** Watch the container log for the tailnet join; if you left
   `TS_AUTHKEY` blank the log prints a login URL to authorize once. After the
   first join the identity lives in the `/var/lib/tailscale` mapping and the key
   is no longer needed.

> No published ports are needed — access is over Tailscale SSH. Network type can
> stay **bridge**; Tailscale runs inside the container via `/dev/net/tun`.
>
> **Updating:** click the container → **Force update** to pull a newer image.
> Because Node/system packages live in the image, that's how you move versions.

### Option B — Portainer **Git stack**

Portainer clones the repo, builds from the `Dockerfile`, and runs the stack.

1. **Stacks → Add stack →** name it `claude-code`.
2. Build method: **Repository**.
3. **Repository URL:** `https://github.com/<owner>/claude-code-tailscale`
4. **Repository reference:** `refs/heads/main`
5. **Compose path:** `docker-compose.yml`
6. **Public repo → leave Authentication OFF.** (Only a **private** fork needs a
   token: toggle Authentication ON, username = your GitHub user, password = a
   fine-grained PAT with *Contents: Read-only* on that repo.)
7. **Environment variables:**
   | Name            | Value                                            | Required |
   |-----------------|--------------------------------------------------|----------|
   | `TS_AUTHKEY`    | a Tailscale auth key (see below)                 | first join only |
   | `TS_HOSTNAME`   | `claude-code`                                    | optional |
   | `WORKSPACE_PATH`| host path for projects, e.g. `/mnt/.../Projects` | optional |
8. **Deploy the stack.**

Generate `TS_AUTHKEY` at the Tailscale admin console → **Settings → Keys →
Generate auth key**. It's only needed for the **first** authenticated start.

### Option C — host shell (docker compose)

```bash
cd /path/to/docker/claude-code        # where these files live
cp .env.example .env                  # then edit .env (optional TS_AUTHKEY)
docker compose build
docker compose up -d
docker compose logs -f                # watch it join the tailnet
```

### Option D — plain docker build & run

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

## Access methods

By default you reach the container **directly over Tailscale SSH**: the
container is its own tailnet node (via its bundled `tailscaled`), and
`tailscale up --ssh` lets you `ssh claude-code` from any device on your tailnet
with no SSH keys to manage — the tailnet identity authenticates you. This is the
slickest option, especially from a phone, and is what this image ships with.

If you'd rather **not** run Tailscale inside the container (e.g. your host
already runs Tailscale and you don't want a second tailnet node), here are the
main alternatives and their trade-offs.

### A) Reuse the host's Tailscale — SSH to host, then `docker exec`

No Tailscale and no SSH server inside the container at all. Reach the host over
its existing tailnet, then step in:

```bash
ssh your-unraid-host          # over the host's Tailscale
docker exec -it claude-code bash
claude
```

- **Pros:** simplest image (drop `tailscaled`, the `NET_ADMIN` cap, and
  `/dev/net/tun`); one tailnet identity; nothing to authenticate per-container.
- **Cons:** two hops (less slick from a phone); needs host SSH reachable over the
  tailnet.

To use this, you can base the container on a plain `node:24-bookworm` without the
Tailscale bits — or keep this image and just ignore its Tailscale layer.

### B) Real SSH server on a published port (bound to the tailnet)

Add `openssh-server` to the image, run `sshd`, and publish it **bound to the
host's Tailscale IP** so it isn't exposed on your LAN:

```yaml
# docker-compose.yml
ports:
  - "100.x.y.z:2222:22"     # host's tailnet IP ONLY — not 0.0.0.0
```

Then `ssh -p 2222 node@100.x.y.z`. You manage `authorized_keys` yourself.

- **Pros:** direct-ish access without the container being its own tailnet node;
  works as the entry point for a Cloudflare Tunnel (option C).
- **Cons:** you run and secure `sshd` (host keys, `authorized_keys`); **binding
  to `0.0.0.0` by mistake exposes SSH to your whole LAN** — always pin the
  tailnet IP.

### C) Cloudflare Tunnel — a Tailscale-independent backup path

Because Tailscale SSH does not expose a normal TCP port, `cloudflared` cannot
tunnel to it. Give it a real `sshd` port (option B) first, then run `cloudflared`
**on the host** (Unraid has a plugin/container for it) pointing at that port,
behind **Cloudflare Access**:

- Create a Zero Trust **Access application** for the SSH hostname and an Access
  policy (who may connect).
- Cloudflare's browser-based terminal lets you reach it **from a phone with no
  client installed** — a genuinely separate path that still works if Tailscale
  is down.
- **Cons:** more setup (Cloudflare Zero Trust + Access); keep it behind Access so
  you're not publishing SSH to the internet.

> **Recommendation:** keep Tailscale SSH (the default) as your primary — it's the
> most convenient. If you want redundancy, add option C **alongside** it (run
> `cloudflared` on the host) rather than removing Tailscale, so you have two
> independent ways in.

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
