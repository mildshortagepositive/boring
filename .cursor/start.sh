#!/usr/bin/env bash
# Per-boot bring-up for the OpenShell development environment.
#
# Launches the Docker daemon and the OpenShell gateway, then STAYS IN THE
# FOREGROUND (tailing their logs). Keeping this process attached is what keeps
# the two background daemons alive for the life of the agent — backgrounding
# them and returning does not survive the boot session being torn down.
#
# Idempotent: if a daemon is already running it is not started again.
set -uo pipefail

export OPENSHELL_LOCAL_TLS_DIR="$HOME/.local/state/openshell/tls"
DOCKERD_LOG='/tmp/dockerd.log'
GATEWAY_LOG='/tmp/openshell-gateway.log'
GATEWAY_ENDPOINT='https://127.0.0.1:17670'

log() { printf 'start: %s\n' "$*"; }

# --- Nested-VM egress fix ---------------------------------------------------
# Docker programs the nftables backend (FORWARD ACCEPT), but the legacy
# iptables backend ships a FORWARD DROP policy that also hooks the kernel
# FORWARD chain and silently drops container egress. Allow forwarding so
# sandboxes can reach the network when their policy permits it.
if command -v iptables-legacy >/dev/null 2>&1; then
  sudo iptables-legacy -P FORWARD ACCEPT || true
fi

# --- Gateway mTLS certificates (install.sh normally creates them) -----------
if [ ! -f "$OPENSHELL_LOCAL_TLS_DIR/ca.crt" ]; then
  log "generating gateway mTLS certificates"
  mkdir -p "$OPENSHELL_LOCAL_TLS_DIR"
  openshell-gateway generate-certs --output-dir "$OPENSHELL_LOCAL_TLS_DIR" \
    --server-san host.openshell.internal
fi

# --- Docker daemon -----------------------------------------------------------
# Launch daemons with `setsid ... < /dev/null` so they run in their own session,
# detached from this terminal. Otherwise a terminal hangup (when this script is
# re-parented or the boot session is torn down) reaches the daemon: dockerd and
# the gateway install their own signal handlers and shut down cleanly on it.
if ! sudo docker info >/dev/null 2>&1; then
  log "starting dockerd"
  sudo bash -c "setsid dockerd >>'$DOCKERD_LOG' 2>&1 < /dev/null &"
  for _ in $(seq 1 60); do
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
# Make the socket reachable by the (non-root) gateway process.
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

# --- OpenShell gateway -------------------------------------------------------
if ! pgrep -f '/usr/bin/openshell-gateway' >/dev/null 2>&1; then
  log "starting openshell-gateway"
  # Sub-shell backgrounds the setsid'd daemon and exits, orphaning it to init
  # (ppid 1) so it is fully detached from this script's session.
  bash -c "setsid env OPENSHELL_LOCAL_TLS_DIR='$OPENSHELL_LOCAL_TLS_DIR' /usr/bin/openshell-gateway >>'$GATEWAY_LOG' 2>&1 < /dev/null &"
  for _ in $(seq 1 60); do
    if (exec 3<>/dev/tcp/127.0.0.1/17670) 2>/dev/null; then exec 3>&- 3<&-; break; fi
    sleep 1
  done
else
  log "openshell-gateway already running"
fi

# --- Register the local gateway with the CLI --------------------------------
if ! openshell status >/dev/null 2>&1; then
  log "registering local gateway"
  openshell gateway add "$GATEWAY_ENDPOINT" --local --name openshell || true
fi

log "OpenShell runtime ready (dockerd + gateway on ${GATEWAY_ENDPOINT})."
log "Use: openshell sandbox create --detach -- sleep infinity && openshell sandbox exec -- uname -a"

# Ensure the log files exist, then stay attached so the daemons keep running.
: >>"$DOCKERD_LOG"; : >>"$GATEWAY_LOG" 2>/dev/null || true
exec tail -n +1 -F "$DOCKERD_LOG" "$GATEWAY_LOG"
