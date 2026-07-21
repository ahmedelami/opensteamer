#!/bin/zsh
# Runs the development CaptureServer in the foreground on port 9000.
#
# Usage: configure any CaptureServer-required environment (`MCAP_TOKEN` supplies authentication)
# and execute this script from any directory. It requires SwiftPM and disables Bonjour while keeping
# the server alive indefinitely with verbose logging. `exec` replaces the shell, so signals and the
# server's final exit status are delivered directly to the caller. No detached process or cleanup
# artifact remains.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

cd "$ROOT_DIR"
exec /usr/bin/swift run CaptureServer --port 9000 --duration 0 --no-bonjour --verbose
