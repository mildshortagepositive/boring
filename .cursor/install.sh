#!/usr/bin/env bash
# Idempotent, one-time setup for an OpenShell development environment.
#
# This repository ("boring") has no first-party application code; its README
# documents using the NVIDIA OpenShell runtime (https://github.com/NVIDIA/OpenShell)
# to run sandboxed AI agents (e.g. NemoClaw/OpenClaw). This script installs the
# OpenShell CLI + gateway and the Docker compute driver it requires.
#
# Per-boot bring-up of dockerd and the gateway runs as terminals
# (see .cursor/environment.json -> dockerd.sh and gateway.sh).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() { printf 'install: %s\n' "$*"; }

# --- 1. System packages: Docker + FUSE (compute driver) ---------------------
# fuse-overlayfs/uidmap support rootless-style overlays; iptables is needed for
# Docker's NAT rules inside the nested Cloud Agent VM.
if ! command -v dockerd >/dev/null 2>&1; then
  log "installing docker.io and container/fuse dependencies"
  sudo apt-get update -qq
  sudo apt-get install -y -qq -o Dpkg::Options::=--force-confold \
    docker.io fuse3 fuse-overlayfs iptables uidmap ca-certificates curl
else
  log "docker already installed ($(dockerd --version 2>/dev/null | head -1))"
fi

# --- 2. Docker daemon config -------------------------------------------------
# The nested VM cannot mount overlay filesystems (overlay mount => EINVAL), so
# use the vfs storage driver, which works everywhere. Disable the containerd
# snapshotter so the classic vfs driver is honored.
DAEMON_JSON='/etc/docker/daemon.json'
DESIRED_DAEMON_JSON='{
  "storage-driver": "vfs",
  "features": { "containerd-snapshotter": false }
}'
if [ ! -f "$DAEMON_JSON" ] || [ "$(cat "$DAEMON_JSON" 2>/dev/null)" != "$DESIRED_DAEMON_JSON" ]; then
  log "writing $DAEMON_JSON (vfs storage driver)"
  sudo mkdir -p /etc/docker
  printf '%s\n' "$DESIRED_DAEMON_JSON" | sudo tee "$DAEMON_JSON" >/dev/null
fi

# Allow the (non-root) gateway process to reach the Docker socket.
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  log "adding $USER to docker group"
  sudo usermod -aG docker "$USER" || true
fi

# --- 3. OpenShell CLI + gateway ---------------------------------------------
if ! command -v openshell >/dev/null 2>&1; then
  log "installing OpenShell CLI"
  curl -fsSL https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh -o /tmp/openshell-install.sh
  # The installer tries to (re)start a systemd user service; there is no user
  # systemd bus in this container, so that step is expected to warn. start.sh
  # launches the gateway directly instead.
  sh /tmp/openshell-install.sh || true
else
  log "openshell already installed ($(openshell --version 2>/dev/null))"
fi

# --- 4. Gateway mTLS certificates (durable) ---------------------------------
TLS_DIR="$HOME/.local/state/openshell/tls"
if [ ! -f "$TLS_DIR/ca.crt" ]; then
  log "generating gateway mTLS certificates"
  mkdir -p "$TLS_DIR"
  openshell-gateway generate-certs --output-dir "$TLS_DIR" --server-san host.openshell.internal
else
  log "gateway certificates already present"
fi

log "done. The dockerd + openshell-gateway terminals launch the runtime per boot."
