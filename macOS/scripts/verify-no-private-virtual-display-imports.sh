#!/bin/zsh
# Rejects loader-time dependencies on Apple's optional private virtual-display classes.
set -euo pipefail

fail() {
    print -u2 -- "verify-no-private-virtual-display-imports: $*"
    exit 1
}

[[ $# == 1 ]] || fail "usage: $0 <Mach-O>"
readonly TARGET="$1"
[[ "$TARGET" == /* ]] || fail "target path must be absolute"
[[ -f "$TARGET" && ! -L "$TARGET" ]] || fail "target is not a real file: $TARGET"

/usr/bin/nm -m "$TARGET" >/dev/null || fail "could not inspect target symbols"
if /usr/bin/nm -m "$TARGET" \
    | /usr/bin/grep -E '_OBJC_CLASS_\$_CGVirtualDisplay' >/dev/null; then
    fail "target has a loader-time dependency on private CGVirtualDisplay classes"
fi

print -- "verify-no-private-virtual-display-imports: passed"
