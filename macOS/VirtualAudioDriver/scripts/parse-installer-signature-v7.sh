#!/bin/zsh
set -euo pipefail

export LC_ALL=C

if (( $# != 2 )); then
    print -u2 "usage: $0 pkgutil-check-signature-output expected-team-id"
    exit 64
fi
input="$1"
expected_team="$2"
[[ -f "$input" ]] && [[ ! -L "$input" ]] && \
    (( $(/usr/bin/stat -f '%z' "$input") <= 65536 )) || {
    print -u2 "installer signature input is unavailable or oversized"
    exit 65
}
[[ "$expected_team" =~ '^[A-Z0-9]{10}$' ]] || {
    print -u2 "installer Team ID is malformed"
    exit 64
}

/usr/bin/python3 - "$input" "$expected_team" <<'PY'
import re
import sys

text = open(sys.argv[1], "r", encoding="utf-8").read()
team = sys.argv[2]
lines = text.splitlines()
status = [line.strip() for line in lines if line.strip().startswith("Status:")]
expected_status = "Status: signed by a developer certificate issued by Apple for distribution"
if status != [expected_status]:
    raise SystemExit("installer signature status is not the exact Developer ID distribution status")

leaf_indices = [
    index for index, line in enumerate(lines)
    if re.match(r"^\s*1\.\s+Developer ID Installer:", line)
]
if len(leaf_indices) != 1:
    raise SystemExit("installer signature does not contain exactly one leaf identity")
leaf_index = leaf_indices[0]
if f"({team})" not in lines[leaf_index]:
    raise SystemExit("installer leaf Team ID is not exact")

fingerprint_label = None
for index in range(leaf_index + 1, min(len(lines), leaf_index + 12)):
    if re.match(r"^\s*\d+\.\s+", lines[index]):
        break
    if lines[index].strip() == "SHA256 Fingerprint:":
        if fingerprint_label is not None:
            raise SystemExit("installer leaf has duplicate SHA256 fingerprint labels")
        fingerprint_label = index
if fingerprint_label is None:
    raise SystemExit("installer leaf SHA256 fingerprint label is missing")

hex_text = ""
for index in range(fingerprint_label + 1, min(len(lines), fingerprint_label + 6)):
    if re.match(r"^\s*\d+\.\s+", lines[index]) or "Fingerprint:" in lines[index]:
        break
    candidate = re.sub(r"[^0-9A-Fa-f]", "", lines[index])
    if candidate:
        hex_text += candidate
    if len(hex_text) >= 64:
        break
if not re.fullmatch(r"[0-9A-Fa-f]{64}", hex_text):
    raise SystemExit("installer leaf SHA256 fingerprint is malformed")
print(hex_text.upper())
PY
