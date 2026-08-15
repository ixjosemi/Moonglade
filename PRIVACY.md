# Privacy

Moonglade is local-only. It does not contain networking code, telemetry, analytics, advertising, or crash reporting.

## Data read

- running Claude Code, OpenCode, and Codex process metadata;
- process identifiers, working directories, terminal names, TTYs, and terminal session identifiers;
- Herdr pane and local socket identifiers exported by the hosting terminal;
- when focused-window display selection is enabled, the frontmost application's PID and normal on-screen window bounds, but never window names, images, or content;
- Moonglade hook events from Claude Code and OpenCode;
- Codex JSONL rollout files under `~/.codex/sessions`, which may contain conversation content;
- Convoy run metadata under `~/.convoy/runs`, from which Moonglade retains run lifecycle and exact phase session identifiers;
- the configuration files modified when the user explicitly runs `moonglade install`.

Moonglade scans Codex rollout lines locally but extracts and retains only session and lifecycle metadata. Prompt and response fields are discarded. It does not inspect project source files, environment secrets, or API credentials.

Focused-window geometry is sampled locally, reused for up to half a second, and never stored. Moonglade does not request Accessibility or Screen Recording access; if macOS withholds the geometry, display selection falls back to the pointer, then the last selected display, then the first connected display.

## Data stored

Transient session metadata is stored as JSON in `~/.moonglade/state`. The directory is mode `0700` and files are mode `0600`. State may include project paths, process IDs, status, timestamps, terminal identifiers, Herdr pane/socket identity, and a window-title hint. Moonglade also stores a private, bounded ownership index containing only OpenCode session IDs already named by Convoy metadata; it uses those IDs to keep internal pipeline phases out of the global session list.

No Moonglade data leaves the Mac. Uninstall integrations with `moonglade uninstall`; this removes Moonglade-owned hooks, plugin files, binaries, and state.
