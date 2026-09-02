#!/usr/bin/env bash
# Per-boot bring-up for the OpenShell development environment.
#
# Idempotent: safe to run repeatedly. Starts the Docker daemon and the
# OpenShell gateway as background daemons, applies the nested-VM network fix,
# registers the local gateway, and then returns.
set -euo pipefail

export OPENSHELL_LOCAL_TLS_DIR="$HOME/.local/state/openshell/tls"
DOCKERD_LOG='/tmp/dockerd.log'
GATEWAY_LOG='/tmp/openshell-gateway.log'
GATEWAY_ENDPOINT='https://127.0.0.1:17670'

log() { printf 'start: %s\n' "$*"; }

# --- 1. Nested-VM network fix -----------------------------------------------
# Docker programs the nftables backend (FORWARD ACCEPT), but the legacy
# iptables backend ships a FORWARD DROP policy that also hooks the kernel
# FORWARD chain, silently dropping container egress. Allow forwarding so
# sandboxes can reach the network when their policy permits it.
if command -v iptables-legacy >/dev/null 2>&1; then
  sudo iptables-legacy -P FORWARD ACCEPT || true
fi

# --- 2. Docker daemon --------------------------------------------------------
if ! sudo docker info >/dev/null 2>&1; then
  log "starting dockerd"
  sudo bash -c "nohup dockerd >>'$DOCKERD_LOG' 2>&1 &"
  for _ in $(seq 1 30); do
    if sudo docker info >/dev/null 2>&1; then break; fi
    sleep 1
  done
  if ! sudo docker info >/dev/null 2>&1; then
    log "ERROR: dockerd did not become ready; see $DOCKERD_LOG"
    exit 1
  fi
else
  log "dockerd already running"
fi

# Make the socket reachable by the gateway (runs as the current user).
sudo chmod 666 /var/run/docker.sock || true

# --- 3. Gateway mTLS certificates (in case install.sh has not run) ----------
if [ ! -f "$OPENSHELL_LOCAL_TLS_DIR/ca.crt" ]; then
  log "generating gateway mTLS certificates"
  mkdir -p "$OPENSHELL_LOCAL_TLS_DIR"
  openshell-gateway generate-certs --output-dir "$OPENSHELL_LOCAL_TLS_DIR" --server-san host.openshell.internal
fi

# --- 4. OpenShell gateway ----------------------------------------------------
if ! pgrep -f '/usr/bin/openshell-gateway' >/dev/null 2>&1; then
  log "starting openshell-gateway"
  nohup env OPENSHELL_LOCAL_TLS_DIR="$OPENSHELL_LOCAL_TLS_DIR" \
    /usr/bin/openshell-gateway >>"$GATEWAY_LOG" 2>&1 &
  for _ in $(seq 1 30); do
    if (exec 3<>/dev/tcp/127.0.0.1/17670) 2>/dev/null; then exec 3>&- 3<&-; break; fi
    sleep 1
  done
else
  log "openshell-gateway already running"
fi

# --- 5. Register the local gateway with the CLI ------------------------------
if ! openshell status >/dev/null 2>&1; then
  log "registering local gateway"
  openshell gateway add "$GATEWAY_ENDPOINT" --local --name openshell || true
fi

log "ready. Try: openshell sandbox create --detach -- sleep infinity && openshell sandbox exec -- uname -a"
