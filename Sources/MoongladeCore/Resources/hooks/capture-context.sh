#!/bin/sh

cwd=${1:-"$PWD"}
tool=${2:-agent}
process_id=${3:-"$PPID"}
term_program=${TERM_PROGRAM:-}
orca_terminal_handle=${ORCA_TERMINAL_HANDLE:-}
case "$term_program" in
    [Oo][Rr][Cc][Aa]) ;;
    *) orca_terminal_handle="" ;;
esac
iterm_session_id=${ITERM_SESSION_ID:-}
tmux_pane=${TMUX_PANE:-}
# cmux reports TERM_PROGRAM=ghostty; its surface ID is the only way to tell the
# two apart, and it matches the scripting `id` of the terminal exactly.
cmux_surface_id=${CMUX_SURFACE_ID:-}
herdr_pane_id=${HERDR_PANE_ID:-}
herdr_socket_path=${HERDR_SOCKET_PATH:-}
tty_name=$(/bin/ps -o tty= -p "$process_id" 2>/dev/null | /usr/bin/tr -d ' ')
case "$tty_name" in
    ""|"??") tty_path="" ;;
    /dev/*) tty_path=$tty_name ;;
    *) tty_path="/dev/$tty_name" ;;
esac
project_name=${cwd##*/}

/usr/bin/osascript -l JavaScript - \
    "$term_program" \
    "$orca_terminal_handle" \
    "$iterm_session_id" \
    "$tmux_pane" \
    "$tty_path" \
    "$project_name — $tool" \
    "$cmux_surface_id" \
    "$herdr_pane_id" \
    "$herdr_socket_path" <<'JAVASCRIPT' 2>/dev/null || true
function optional(value) {
    return value === "" ? null : value;
}

function run(arguments) {
    return JSON.stringify({
        term_program: optional(arguments[0]),
        orca_terminal_handle: optional(arguments[1]),
        iterm_session_id: optional(arguments[2]),
        tmux_pane: optional(arguments[3]),
        tty: optional(arguments[4]),
        window_title_hint: optional(arguments[5]),
        cmux_surface_id: optional(arguments[6]),
        herdr_pane_id: optional(arguments[7]),
        herdr_socket_path: optional(arguments[8])
    });
}
JAVASCRIPT

exit 0
