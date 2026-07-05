#!/bin/zsh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

cd "$ROOT_DIR"
exec /usr/bin/swift run CaptureServer --port 9000 --duration 0 --no-bonjour --verbose
