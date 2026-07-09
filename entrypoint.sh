#!/bin/bash
# Entrypoint for the Claude Code + Tailscale container.
#
# Brings up tailscaled, joins the tailnet, and enables Tailscale SSH.
# Tailscale state is persisted at /var/lib/tailscale (mount a volume there),
# so after the first authenticated start no auth key is needed on restart.
#
# Optional environment variables:
#   TS_HOSTNAME   tailnet hostname to advertise      (default: claude-code)
#   TS_AUTHKEY    auth key for UNATTENDED first login (default: interactive URL)
#   TS_EXTRA_ARGS extra flags appended to `tailscale up`
set -e

TS_HOSTNAME="${TS_HOSTNAME:-claude-code}"

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

# Hand control to tailscaled; if it exits, the container exits (restart policy
# in compose brings it back).
wait "$TS_PID"
