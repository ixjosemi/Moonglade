#!/bin/sh
# Install an already-built Moonglade.app.
#
#   install-app.sh <path-to-Moonglade.app>
#
# Stops the running instance, replaces any previous copy in /Applications,
# wires the agent hooks, relaunches the app, and verifies the result with
# `moonglade doctor`. Safe to re-run at any time.
#
# This script ships inside the bundle at Contents/Resources/install-app.sh.
# The remote installer is fetched standalone through curl and cannot read this
# repository, so it runs this copy out of the archive it just verified — the
# source install and the download install then share one implementation
# instead of two that drift.
set -eu

if [ "$#" -ne 1 ]; then
    /usr/bin/printf 'usage: install-app.sh <path-to-Moonglade.app>\n' >&2
    exit 2
fi

bundle="$1"
executable="$bundle/Contents/MacOS/Moonglade"
command_line_tool="$bundle/Contents/Resources/bin/moonglade"

if [ ! -x "$executable" ] || [ ! -x "$command_line_tool" ]; then
    /usr/bin/printf 'error: %s is not a complete Moonglade bundle.\n' "$bundle" >&2
    exit 1
fi

step() { /usr/bin/printf '\n==> %s\n' "$1"; }

app_destination="/Applications/Moonglade.app"
if [ ! -w "/Applications" ]; then
    app_destination="$HOME/Applications/Moonglade.app"
    /bin/mkdir -p "$HOME/Applications"
fi

# Installing over a running app leaves the old process attached to a bundle
# that no longer exists, so it has to exit before the copy.
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
/usr/bin/ditto "$bundle" "$app_destination"

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
