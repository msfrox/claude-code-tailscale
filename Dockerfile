# Claude Code + Tailscale headless container for Unraid
#
# Reproduces the running "claude-code" container, but with everything baked in:
#   - Node 24 LTS (was Node 20 in the old ad-hoc image)
#   - npm / yarn / corepack
#   - Tailscale (tailscaled + tailscale) for SSH access over the tailnet
#   - GitHub CLI (gh)
#   - Claude Code CLI installed globally, with /usr/local made writable by the
#     `node` user so `claude` can self-update at runtime (this was the original
#     "no write permission to npm prefix" bug).
#
# The container runs as root so tailscaled can create the TUN interface.
# Tailscale SSH then logs interactive users in as `node` (passwordless sudo).

FROM node:24-bookworm

LABEL org.opencontainers.image.title="claude-code-tailscale" \
      org.opencontainers.image.description="Headless Claude Code CLI reachable over Tailscale SSH" \
      org.opencontainers.image.source="https://github.com/anthropics/claude-code"

ENV DEBIAN_FRONTEND=noninteractive

# ---- Base packages + third-party apt repos (Tailscale, GitHub CLI) ----------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        sudo \
        xz-utils \
        iproute2 \
        iptables \
        openssh-client \
        less \
        jq \
        ripgrep \
        procps; \
    install -m 0755 -d /etc/apt/keyrings; \
    \
    # Tailscale repo (Debian bookworm) \
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg; \
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
        -o /etc/apt/sources.list.d/tailscale.list; \
    \
    # GitHub CLI repo \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends tailscale gh; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ---- Passwordless sudo for the node user ------------------------------------
RUN echo 'node ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/node \
    && chmod 0440 /etc/sudoers.d/node \
    && visudo -c

# ---- Console user consolidation ---------------------------------------------
# Unraid's WebUI "Console" runs `docker exec` as root, but Tailscale SSH logs in
# as node. Drop interactive root shells into node so both entry points share one
# user, one ~/.claude, and one login (avoids a stray /root/.claude identity).
# Only fires for an interactive root shell; scripts and non-interactive
# `docker exec <cmd>` are unaffected. Maintenance escape hatch:
#   docker exec -e STAY_ROOT=1 -it <container> bash
RUN printf '%s\n' \
    '' \
    '# Drop interactive root shells to the node user (Unraid console = docker exec' \
    '# as root; Tailscale SSH = node). Keeps one user/~/.claude/login.' \
    'if [ -z "${STAY_ROOT:-}" ] && [ "$(id -u)" = 0 ] && [ -t 0 ] && command -v su >/dev/null 2>&1; then' \
    '  exec su - node' \
    'fi' \
    >> /root/.bashrc

# ---- Claude Code CLI --------------------------------------------------------
# Install globally, then hand /usr/local to the node user so runtime
# self-update (npm -g) works without root.
RUN npm install -g @anthropic-ai/claude-code@latest \
    && chown -R node:node /usr/local/lib/node_modules /usr/local/bin /usr/local/share

# ---- Tailscale state dir (also a mount point for persistence) ---------------
RUN mkdir -p /var/lib/tailscale /var/run/tailscale

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# tailscaled needs root; interactive logins arrive via Tailscale SSH as `node`.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
