#!/bin/sh

payload=${1:-}
if [ -z "$payload" ]; then
    exit 0
fi
script_directory=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && /bin/pwd)
/usr/bin/printf '%s' "$payload" | \
    "$script_directory/moonglade" hook codex-notify --pid "$PPID" >/dev/null 2>&1 || true
exit 0
