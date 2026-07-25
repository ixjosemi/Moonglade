#!/bin/sh
# One-command install (and reinstall) for Moonglade.
#
#   ./scripts/install.sh
#
# Builds the app, replaces any previous copy in /Applications, wires the
# agent hooks, relaunches the app, and verifies the result with
# `moonglade doctor`. Safe to re-run at any time.
set -eu

cd "$(dirname "$0")/.."

step() { /usr/bin/printf '\n==> %s\n' "$1"; }

step "Building Moonglade (release)"
./scripts/build-app.sh

app_destination="/Applications/Moonglade.app"
if [ ! -w "/Applications" ]; then
    app_destination="$HOME/Applications/Moonglade.app"
    /bin/mkdir -p "$HOME/Applications"
fi

step "Stopping the running instance (if any)"
if /usr/bin/pgrep -x Moonglade >/dev/null 2>&1; then
    /usr/bin/pkill -x Moonglade
    attempts=0
    while /usr/bin/pgrep -x Moonglade >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 20 ]; then
            /usr/bin/printf 'error: Moonglade did not exit; close it and re-run.\n' >&2
            exit 1
        fi
        /bin/sleep 0.25
    done
    /usr/bin/printf 'stopped.\n'
else
    /usr/bin/printf 'not running.\n'
fi

step "Installing app to $app_destination"
/bin/rm -rf "$app_destination"
/usr/bin/ditto .build/Moonglade.app "$app_destination"

step "Wiring agent hooks (Claude Code / OpenCode / Codex / Pi)"
"$app_destination/Contents/Resources/bin/moonglade" install

step "Launching Moonglade"
/usr/bin/open "$app_destination"
attempts=0
until /usr/bin/pgrep -x Moonglade >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 20 ]; then
        /usr/bin/printf 'error: Moonglade did not appear after launch.\n' >&2
        exit 1
    fi
    /bin/sleep 0.25
done
/usr/bin/printf '✓ app running (pid %s)\n' "$(/usr/bin/pgrep -x Moonglade)"

step "Verifying installation (moonglade doctor)"
"$app_destination/Contents/Resources/bin/moonglade" doctor

/usr/bin/printf '\nAll good. Agents already running must be restarted to pick up the hooks.\n'
/usr/bin/printf 'OpenCode loads plugins in its background service: also run\n'
/usr/bin/printf '  pkill -f "opencode2 serve" (a fresh one starts with the next opencode)\n'
