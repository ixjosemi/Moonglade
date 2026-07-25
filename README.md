<p align="center">
  <img src="assets/header.svg" alt="The Moonglade panel hanging from the MacBook notch: three agent sessions with their provider, status, project, branch, and elapsed time" width="880"/>
</p>

**Know when your coding agents need you—without leaving the notch.**

Moonglade is a quiet, native macOS indicator for Claude Code, OpenCode, Codex CLI, [Pi](https://github.com/badlogic/pi-mono), and [Convoy](https://github.com/Inakitajes/convoy) pipeline sessions. It lives around the MacBook notch (or as a pill on displays without one) and returns you to the exact terminal tab or tmux pane with one click.

## Why Moonglade?

- See global counts for running, waiting, and blocked sessions without having to infer them from provider icons.
- Click the status summary and its wide session menu grows out of the notch itself: provider, status light, session title taken from the live terminal tab, project directory, git branch (worktrees included) or Convoy pipeline step, and elapsed time.
- Focus the recorded Ghostty, iTerm2, Terminal, or tmux session with one click.
- Expand any row (chevron or right click) for inline actions: rename the session, copy the project path, reveal it in Finder, or kill the process — SIGTERM with SIGKILL escalation — and close its exact tmux pane or Ghostty tab.
- Watch Convoy pipeline runs as first-class sessions: the current step in the row, red light on human gates, and no duplicate rows for the OpenCode sessions a pipeline owns.
- Closed terminals disappear immediately through kernel exit notifications, with a five-second scanner/reaper backstop for missed hooks and stale state.
- Follow the screen with the pointer by default, or choose the screen with the focused window — or a panel on every connected display — in Settings.
- Read a panel that belongs on the hardware: it hangs from the notch as a liquid-glass drop, stays pure black across the camera band, and answers the click with a Metal ripple. Frost and tint are tunable per display kind, and optional sounds can announce a session that needs you or one that just finished its turn.
- Keep all observation and state on your Mac.
- Run without telemetry, accounts, servers, or third-party Swift dependencies, at ~1% CPU and ~16 MB of memory.

## Session states

<p align="center">
  <img src="assets/status-bar.svg" alt="The compact bar: a braille spinner and count for running sessions, a green dot and count for sessions waiting at the prompt, and a count and red dot for sessions that need you" width="760"/>
</p>

| State | In the bar | Meaning |
| --- | --- | --- |
| Running | Braille dot-matrix spinner | The agent is processing. |
| Waiting | Green dot | The session waits at the prompt for your next input. |
| Blocked | Red dot | A question, permission ask, or failed pipeline step needs you. |

Running and waiting sit on the left of the camera and blocked on its right, and each pair puts its round glyph on the outer screen edge so both wings meet the notch shoulders symmetrically. The bar shows a count for each state that actually exists right now — zero-count states leave no slot behind — and collapses to a single dimmed moon when no agent is running at all.

The menu always shows the real status and provider per session, using the same three glyphs plus a grey dot for a session whose process has exited and is about to be reaped.

## Requirements

- macOS 14 Sonoma or newer — macOS 26 for the real Liquid Glass backdrop, which degrades to a system blur below it;
- a MacBook with a notch for the intended UI placement;
- Swift 6.0 or newer to build from source;
- Node.js 20+ to run the OpenCode and Pi behavioral tests;
- Ghostty 1.3+ with AppleScript enabled, cmux, iTerm2, or Terminal.

Apple Silicon is the tested development platform. Intel builds have not yet been validated.

## Install

One command builds the app, installs it into `/Applications`, wires the agent hooks, launches it, and verifies everything:

```bash
git clone https://github.com/ixjosemi/Moonglade.git
cd Moonglade
./scripts/install.sh
```

The same command reinstalls: it stops the running instance, replaces the app, relaunches, and re-verifies. The bundle is ad-hoc signed for local use — do not redistribute it as an official release.

Verify an existing installation at any time:

```bash
/Applications/Moonglade.app/Contents/Resources/bin/moonglade doctor
```

```
✓ hook binaries: all executables present in ~/.moonglade/bin
✓ state directory: ~/.moonglade/state exists
✓ Claude Code hooks: all lifecycle hooks registered in ~/.claude/settings.json
✓ OpenCode plugin: ~/.config/opencode/plugins/moonglade.js matches the bundled file
✓ Codex notify: notify hook registered in ~/.codex/config.toml
✓ Pi extension: ~/.pi/agent/extensions/moonglade.ts matches the bundled file
```

`doctor` is read-only and exits non-zero when something is broken, so it is also usable from scripts.

### Manual build

For development without touching `/Applications`:

```bash
swift build
swift run moonglade-tests
./scripts/build-app.sh
open .build/Moonglade.app
```

SwiftPM cannot compile Metal sources, so the expansion ripple ships as a prebuilt `Sources/MoongladeApp/Resources/default.metallib`. After editing `Ripple.metal`, regenerate it with `./scripts/compile-shaders.sh` and commit the result.

### What the hook installer does

Without integrations the app still detects running agents (via a fast libproc process scan), but every session shows as permanently working — the hooks are what feed real status changes. `install.sh` runs `moonglade install`, which:

- installs the CLI and hook scripts under `~/.moonglade/bin`;
- merges Moonglade-owned Claude Code hooks into `~/.claude/settings.json`, preserving every existing setting and hook (the merge is idempotent);
- installs `~/.config/opencode/plugins/moonglade.js` only when it can do so safely;
- adds a Codex `notify` entry only when no notification command exists;
- installs the Pi extension `~/.pi/agent/extensions/moonglade.ts` only when it can do so safely.

Installation fails instead of replacing an unknown Moonglade-named plugin. Integration directories may be symlinks — common in dotfile setups — as long as they resolve to a directory you own inside your home; `~/.moonglade` itself must be symlink-free because hooks execute binaries from it. Agents started before installing need a restart to pick up the hooks. OpenCode additionally loads plugins in its detached background service, which survives TUI restarts — after installing, run `pkill -f "opencode2 serve"` once; the next `opencode` starts a fresh service with the plugin loaded.

To remove integrations and local state:

```bash
/Applications/Moonglade.app/Contents/Resources/bin/moonglade uninstall
```

Then quit Moonglade and delete the app bundle. Review your Claude or Codex configuration if you manually modified Moonglade entries after installation.

## Terminal focus

| Host | Focus strategy | Notes |
| --- | --- | --- |
| Ghostty | exact surface ID, foreground PID, or TTY; unique project/title fallback | Requires Ghostty 1.3+ |
| cmux | exact panel ID, no fallback | Resolved before Ghostty: cmux ships Ghostty's engine and reports the same `TERM_PROGRAM` |
| iTerm2 | exact normalized session ID, then TTY | Selects the split, tab, and window |
| Terminal | exact TTY | Selects the tab and raises its containing window |
| tmux | validated pane ID, then host activation | `tmux` must be in a trusted standard install location |

macOS asks for Automation access the first time Moonglade controls a terminal. If denied, enable it under **System Settings → Privacy & Security → Automation**.

## How it works

Claude hooks, an OpenCode plugin, a Pi extension, the Codex rollout watcher, the Convoy runs watcher, and a process fallback produce versioned session documents under `~/.moonglade/state`. The app observes that directory and renders active sessions. State is written atomically with user-only permissions. Convoy needs no hook at all: its run metadata under `~/.convoy/runs` is read directly, and a run is only shown while its recorded server process is verifiably alive. OpenCode phase IDs named by Convoy are retained in a private ownership index and filtered at repository load time, so internal phases stay hidden even after a plugin rewrite or app restart.

Everything is event-driven and off the main thread: a libproc-based scanner (no subprocesses, ~2 ms per full sweep) runs on a 5-second heartbeat, kernel `EVFILT_PROC` exit watchers reap closed sessions instantly, and directory observation with debounce delivers state changes to the UI. A native session that has been quiet for a full scan interval is also checked against the detected agent set; removal requires two consecutive misses, so one transient metadata-read failure cannot hide a live session. Terminal identity disambiguates agents sharing a project directory. Claude and OpenCode status changes land in well under a second; Codex and Convoy ride the heartbeat. Session titles follow the live Ghostty tab title — cleaned of status decorations, then truncated by the row's width rather than a fixed character count — and a manual rename (persisted in `~/.moonglade/session-names.json`) always wins. Agent matching accepts either the kernel-resolved executable path or `argv[0]`, so versioned symlink installs like `~/.local/bin/claude → …/versions/x.y.z` are detected correctly.

See [Architecture](docs/ARCHITECTURE.md) for the full data flow and trust boundaries.

## Privacy and security

Moonglade has no networking or telemetry. It stores local session metadata—including project paths, process IDs, timestamps, and terminal identifiers—but not prompts or model responses. Read [PRIVACY.md](PRIVACY.md) before installing integrations and [SECURITY.md](SECURITY.md) before reporting a vulnerability.

Treat `moonglade debug` output as private because it includes session and project metadata:

```bash
/Applications/Moonglade.app/Contents/Resources/bin/moonglade debug
```

## Known limitations

- Codex rollout formats are not a stable public contract; unknown lines are ignored and the notify hook is the reliable turn-complete signal.
- Same-directory Codex sessions can be ambiguous when upstream events provide no PID or terminal identifier.
- The app currently has no signed/notarized binary release, automatic updater, or Homebrew cask.
- The behavioral runner is an executable because the minimal Command Line Tools environment used during early development did not ship XCTest or Swift Testing. Run it with `swift run moonglade-tests`.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md). New runtime behavior requires a failing behavioral test first. All pull requests must pass:

```bash
swift build
swift run moonglade-tests
./scripts/build-app.sh
```

## Trademark notice

Moonglade is independent and is not affiliated with Anthropic, OpenAI, SST, Ghostty, Apple, or tmux. Product names and marks identify compatible tools only. See [NOTICE](NOTICE).

## License

[MIT](LICENSE) © 2026 Josemi Hernandez
