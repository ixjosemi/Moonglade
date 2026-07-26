#!/bin/sh

cwd=${1:-"$PWD"}
tool=${2:-agent}
process_id=${3:-"$PPID"}
term_program=${TERM_PROGRAM:-}
iterm_session_id=${ITERM_SESSION_ID:-}
tmux_pane=${TMUX_PANE:-}
# cmux reports TERM_PROGRAM=ghostty; its surface ID is the only way to tell the
# two apart, and it matches the scripting `id` of the terminal exactly.
cmux_surface_id=${CMUX_SURFACE_ID:-}
tty_name=$(/bin/ps -o tty= -p "$process_id" 2>/dev/null | /usr/bin/tr -d ' ')
case "$tty_name" in
    ""|"??") tty_path="" ;;
    /dev/*) tty_path=$tty_name ;;
    *) tty_path="/dev/$tty_name" ;;
esac
project_name=${cwd##*/}

/usr/bin/osascript -l JavaScript - \
    "$term_program" \
    "$iterm_session_id" \
    "$tmux_pane" \
    "$tty_path" \
    "$project_name — $tool" \
    "$cmux_surface_id" <<'JAVASCRIPT' 2>/dev/null || true
function optional(value) {
    return value === "" ? null : value;
}

function run(arguments) {
    return JSON.stringify({
        term_program: optional(arguments[0]),
        iterm_session_id: optional(arguments[1]),
        tmux_pane: optional(arguments[2]),
        tty: optional(arguments[3]),
        window_title_hint: optional(arguments[4]),
        cmux_surface_id: optional(arguments[5])
    });
}
JAVASCRIPT

exit 0
