#!/bin/bash
# Entrypoint for the Claude Code + Tailscale container.
#
# Brings up tailscaled, joins the tailnet, and enables Tailscale SSH.
# Tailscale state is persisted at /var/lib/tailscale (mount a volume there),
# so after the first authenticated start no auth key is needed on restart.
#
# Optionally also starts a Claude Code Remote Control server (RC_ENABLE=1) so
# this container shows up as a live session at claude.ai/code and in the Claude
# mobile app, drivable from your phone or a browser (outbound HTTPS only).
#
# Optional environment variables:
#   TS_HOSTNAME    tailnet hostname to advertise       (default: claude-code)
#   TS_AUTHKEY     auth key for UNATTENDED first login  (default: interactive URL)
#   TS_EXTRA_ARGS  extra flags appended to `tailscale up`
#   RC_ENABLE      1/true/yes/on to start Remote Control (default: off)
#   RC_DIR         directory Remote Control serves       (default: /workspace)
#   RC_NAME        session title shown in the app        (default: $TS_HOSTNAME)
#   RC_EXTRA_ARGS  extra flags appended to `claude remote-control`
set -e

TS_HOSTNAME="${TS_HOSTNAME:-claude-code}"

# --- Optional: Claude Code Remote Control -------------------------------------
# Runs a persistent `claude remote-control` server as the `node` user so the
# container is drivable from claude.ai/code and the Claude mobile app (Code tab).
# The connection is outbound HTTPS only, so no inbound ports are opened.
#
# One-time requirement: sign in to Claude Code as `node` with a claude.ai
# (Pro/Max/Team/Enterprise) account — SSH in, run `claude`, then `/login`. The
# credentials live in /home/node and persist via that volume, so this survives
# restarts without re-authenticating.
start_remote_control() {
  local dir="${RC_DIR:-/workspace}"
  local name="${RC_NAME:-$TS_HOSTNAME}"
  local cfg="/home/node/.claude.json"
  local log="/home/node/remote-control.log"

  mkdir -p "$dir"
  chown node:node "$dir" 2>/dev/null || true

  # Remote Control refuses an untrusted directory, and there is no CLI flag to
  # accept the trust dialog non-interactively, so pre-mark RC_DIR as trusted in
  # the node user's config. This runs at boot before any `claude` process
  # exists, so there is no write race on .claude.json. We write a sibling temp,
  # chown it back to node, then atomically rename so the file stays node-owned.
  if [ -f "$cfg" ]; then
    local tmp="${cfg}.rc-tmp"
    if jq --arg d "$dir" '.projects[$d].hasTrustDialogAccepted = true' \
         "$cfg" > "$tmp" 2>>"$log"; then
      chown node:node "$tmp" 2>/dev/null || true
      mv "$tmp" "$cfg" 2>>"$log" || rm -f "$tmp"
    else
      rm -f "$tmp"
      echo "[entrypoint] warning: could not pre-trust $dir — run \`claude\` there once as node" >&2
    fi
  else
    echo "[entrypoint] no Claude login yet — SSH in, run \`claude\` and /login, then restart with RC_ENABLE=1" >&2
  fi

  # Supervisor: keep the server alive. Remote Control exits after ~10 minutes
  # without network; relaunch it shortly after. Runs via a `node` login shell so
  # HOME/USER/PATH are correct and the claude.ai credentials are found.
  (
    while true; do
      runuser -l node -c "cd '$dir' && exec claude remote-control --name '$name' ${RC_EXTRA_ARGS:-}" \
        </dev/null >>"$log" 2>&1 || true
      echo "[$(date -Is)] remote-control exited; restarting in 15s" >>"$log"
      sleep 15
    done
  ) &
  echo "[entrypoint] Claude Code Remote Control enabled (dir=$dir, name=$name, log=$log)"
}

mkdir -p /var/lib/tailscale /var/run/tailscale

tailscaled \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket=/var/run/tailscale/tailscaled.sock &
TS_PID=$!

# Wait for the daemon's control socket.
until [ -S /var/run/tailscale/tailscaled.sock ]; do
  sleep 1
done

# Build `tailscale up` args. --authkey is only added when TS_AUTHKEY is set;
# on a persisted state dir it's harmless/ignored once already logged in.
UP_ARGS=(--ssh --hostname="${TS_HOSTNAME}" --accept-dns=false)
if [ -n "${TS_AUTHKEY:-}" ]; then
  UP_ARGS+=(--authkey="${TS_AUTHKEY}")
fi
if [ -n "${TS_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  UP_ARGS+=(${TS_EXTRA_ARGS})
fi

tailscale --socket=/var/run/tailscale/tailscaled.sock up "${UP_ARGS[@]}"

# Start Remote Control if requested (independent of Tailscale; it only needs
# outbound internet, not the tailnet).
case "${RC_ENABLE:-}" in
  1 | true | TRUE | yes | on) start_remote_control ;;
esac

# Hand control to tailscaled; if it exits, the container exits (restart policy
# in compose brings it back).
wait "$TS_PID"
