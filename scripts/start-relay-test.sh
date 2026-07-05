#!/bin/zsh
set -eu

TOKEN="${MCAP_TOKEN:-${RELAY_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
  echo "Set MCAP_TOKEN before running this script." >&2
  exit 1
fi

ROOT="/path/to/AudioStreamer"
LOG_DIR="/tmp/audiostreamer"
mkdir -p "$LOG_DIR"

cd "$ROOT"

screen -S audiostreamer-capture -X quit >/dev/null 2>&1 || true
screen -S audiostreamer-bridge -X quit >/dev/null 2>&1 || true
screen -S audiostreamer-tunnel -X quit >/dev/null 2>&1 || true

: > "$LOG_DIR/capture-server.log"
: > "$LOG_DIR/relay-bridge.log"
: > "$LOG_DIR/cloudflared.log"

screen -dmS audiostreamer-capture /bin/zsh -lc "cd '$ROOT' && export MCAP_TOKEN='$TOKEN' && exec /usr/bin/swift run CaptureServer --port 9000 --duration 0 --no-bonjour --verbose >> '$LOG_DIR/capture-server.log' 2>&1"
sleep 3

screen -dmS audiostreamer-bridge /bin/zsh -lc "cd '$ROOT/RelayBridge' && export MCAP_TOKEN='$TOKEN' RELAY_TOKEN='$TOKEN' && exec /opt/homebrew/bin/npm start >> '$LOG_DIR/relay-bridge.log' 2>&1"
sleep 2

if command -v cloudflared >/dev/null 2>&1; then
  screen -dmS audiostreamer-tunnel /bin/zsh -lc "exec cloudflared tunnel --url http://127.0.0.1:8787 >> '$LOG_DIR/cloudflared.log' 2>&1"
else
  echo "cloudflared is not installed. Install it with: brew install cloudflared" >&2
fi

echo "Capture log: $LOG_DIR/capture-server.log"
echo "Bridge log:  $LOG_DIR/relay-bridge.log"
echo "Tunnel log:  $LOG_DIR/cloudflared.log"
