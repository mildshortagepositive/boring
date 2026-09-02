#!/usr/bin/env bash
# Runs the Docker daemon in the foreground as a persistent terminal.
# OpenShell's docker compute driver talks to this daemon.
set -euo pipefail

# Nested-VM egress fix: Docker programs the nftables backend (FORWARD ACCEPT),
# but the legacy iptables backend ships a FORWARD DROP policy that also hooks
# the kernel FORWARD chain and silently drops container egress. Allow it so
# sandboxes can reach the network when their policy permits.
if command -v iptables-legacy >/dev/null 2>&1; then
  sudo iptables-legacy -P FORWARD ACCEPT || true
fi

# Once the socket appears, make it reachable by the (non-root) gateway process.
(
  for _ in $(seq 1 60); do
    if [ -S /var/run/docker.sock ]; then
      sudo chmod 666 /var/run/docker.sock || true
      break
    fi
    sleep 1
  done
) &

# Foreground: this process stays attached so the terminal (and daemon) persist.
exec sudo dockerd
