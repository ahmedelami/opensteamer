#!/bin/zsh
# Starts the legacy relay diagnostic stack in detached `screen` sessions.
#
# Prerequisites: SwiftPM, GNU screen, and installed RelayBridge npm dependencies. Set MCAP_TOKEN
# (preferred) or RELAY_TOKEN before running. The launcher embeds the
# value in short-lived detached shell commands before exporting it, so privileged local process
# inspection may observe it during startup even though the scripts do not deliberately log it.
#
# The script replaces existing `audiostreamer-capture` and `audiostreamer-bridge` sessions,
# truncates their logs under `/tmp/audiostreamer`, then starts CaptureServer and the loopback-only
# WebSocket bridge. Detached sessions continue after this launcher exits and must be stopped
# separately. This legacy plaintext diagnostic must stay on a trusted local machine; the script
# deliberately does not create a tunnel or public listener.
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

# Logs are per-machine diagnostics, not durable validation artifacts; each launch starts them empty.
: > "$LOG_DIR/capture-server.log"
: > "$LOG_DIR/relay-bridge.log"

screen -dmS audiostreamer-capture /bin/zsh -lc "cd '$ROOT' && export MCAP_TOKEN='$TOKEN' && exec /usr/bin/swift run CaptureServer --port 9000 --duration 0 --no-bonjour --verbose >> '$LOG_DIR/capture-server.log' 2>&1"
sleep 3

screen -dmS audiostreamer-bridge /bin/zsh -lc "cd '$ROOT/macOS/RelayBridge' && export MCAP_TOKEN='$TOKEN' RELAY_TOKEN='$TOKEN' && exec /opt/homebrew/bin/npm start >> '$LOG_DIR/relay-bridge.log' 2>&1"
sleep 2

echo "Capture log: $LOG_DIR/capture-server.log"
echo "Bridge log:  $LOG_DIR/relay-bridge.log"
