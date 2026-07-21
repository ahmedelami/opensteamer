#!/bin/zsh
# Starts the legacy relay diagnostic stack in detached `screen` sessions.
#
# Prerequisites: SwiftPM, GNU screen, installed RelayBridge npm dependencies, and optionally
# `cloudflared`. Set MCAP_TOKEN (preferred) or RELAY_TOKEN before running. The launcher embeds the
# value in short-lived detached shell commands before exporting it, so privileged local process
# inspection may observe it during startup even though the scripts do not deliberately log it.
#
# The script replaces any existing sessions named `audiostreamer-capture`,
# `audiostreamer-bridge`, and `audiostreamer-tunnel`, truncates their logs under
# `/tmp/audiostreamer`, then starts CaptureServer and the localhost WebSocket bridge. When available,
# cloudflared exposes the bridge through a temporary public tunnel. Detached sessions continue after
# this launcher exits and must be stopped separately. Missing authentication is fatal; missing
# cloudflared emits a warning but does not make the attempt to start the local two-process stack fail.
set -eu

TOKEN="${MCAP_TOKEN:-${RELAY_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
  echo "Set MCAP_TOKEN before running this script." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_DIR="/tmp/audiostreamer"
mkdir -p "$LOG_DIR"

cd "$ROOT"

screen -S audiostreamer-capture -X quit >/dev/null 2>&1 || true
screen -S audiostreamer-bridge -X quit >/dev/null 2>&1 || true
screen -S audiostreamer-tunnel -X quit >/dev/null 2>&1 || true

# Logs are per-machine diagnostics, not durable validation artifacts; each launch starts them empty.
: > "$LOG_DIR/capture-server.log"
: > "$LOG_DIR/relay-bridge.log"
: > "$LOG_DIR/cloudflared.log"

screen -dmS audiostreamer-capture /bin/zsh -lc "cd '$ROOT' && export MCAP_TOKEN='$TOKEN' && exec /usr/bin/swift run CaptureServer --port 9000 --duration 0 --no-bonjour --verbose >> '$LOG_DIR/capture-server.log' 2>&1"
sleep 3

screen -dmS audiostreamer-bridge /bin/zsh -lc "cd '$ROOT/macOS/RelayBridge' && export MCAP_TOKEN='$TOKEN' RELAY_TOKEN='$TOKEN' && exec /opt/homebrew/bin/npm start >> '$LOG_DIR/relay-bridge.log' 2>&1"
sleep 2

if command -v cloudflared >/dev/null 2>&1; then
  # Quick Tunnel assignment and its public URL are emitted asynchronously into cloudflared.log.
  screen -dmS audiostreamer-tunnel /bin/zsh -lc "exec cloudflared tunnel --url http://127.0.0.1:8787 >> '$LOG_DIR/cloudflared.log' 2>&1"
else
  echo "cloudflared is not installed. Install it with: brew install cloudflared" >&2
fi

echo "Capture log: $LOG_DIR/capture-server.log"
echo "Bridge log:  $LOG_DIR/relay-bridge.log"
echo "Tunnel log:  $LOG_DIR/cloudflared.log"
