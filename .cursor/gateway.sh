#!/usr/bin/env bash
# Runs the OpenShell gateway in the foreground as a persistent terminal.
# Waits for Docker, ensures mTLS certs exist, then launches the gateway and
# registers it with the local CLI.
set -euo pipefail

export OPENSHELL_LOCAL_TLS_DIR="$HOME/.local/state/openshell/tls"
GATEWAY_ENDPOINT='https://127.0.0.1:17670'

# Wait for the Docker daemon (started by the dockerd terminal).
for _ in $(seq 1 90); do
  if sudo docker info >/dev/null 2>&1; then break; fi
  sleep 1
done
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

# Ensure gateway mTLS certificates exist (install.sh normally creates them).
if [ ! -f "$OPENSHELL_LOCAL_TLS_DIR/ca.crt" ]; then
  mkdir -p "$OPENSHELL_LOCAL_TLS_DIR"
  openshell-gateway generate-certs --output-dir "$OPENSHELL_LOCAL_TLS_DIR" \
    --server-san host.openshell.internal
fi

# Register the local gateway with the CLI once the port is accepting (async).
(
  for _ in $(seq 1 90); do
    if (exec 3<>/dev/tcp/127.0.0.1/17670) 2>/dev/null; then
      exec 3>&- 3<&-
      openshell status >/dev/null 2>&1 || \
        openshell gateway add "$GATEWAY_ENDPOINT" --local --name openshell || true
      break
    fi
    sleep 1
  done
) &

# Foreground: this process stays attached so the terminal (and gateway) persist.
exec env OPENSHELL_LOCAL_TLS_DIR="$OPENSHELL_LOCAL_TLS_DIR" /usr/bin/openshell-gateway
