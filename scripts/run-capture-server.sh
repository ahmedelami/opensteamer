#!/bin/zsh
set -eu

cd /path/to/AudioStreamer
exec /usr/bin/swift run CaptureServer --port 9000 --duration 0 --no-bonjour --verbose
