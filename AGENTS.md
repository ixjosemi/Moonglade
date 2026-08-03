# Agent Guide

## Scope

Moonglade is a native macOS 14+ Swift package with three targets: the notch app, the `moonglade` integration CLI, and a dependency-free behavioral test runner.

## Commands

```bash
swift build
swift run moonglade-tests
./scripts/build-app.sh
```

Run all three before proposing a pull request. The app bundle is written to `.build/Moonglade.app` and must never be committed.

SwiftPM cannot compile Metal sources, so `Sources/MoongladeApp/Ripple.metal` is excluded from the target and its shaders ship as a prebuilt `Sources/MoongladeApp/Resources/default.metallib`. `swift build` will not tell you the shader is stale — after editing the `.metal` source, regenerate and commit the library:

```bash
./scripts/compile-shaders.sh
```

It needs the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`). The script also rewrites `Resources/default.metallib.source-sha256`, which records the source the committed library was built from; commit it alongside the library. CI compares that hash against `Ripple.metal` and fails when they disagree, so an edited shader with a stale library is caught instead of shipping silently.

## Engineering rules

- Add a failing behavioral test before changing runtime behavior.
- Keep integrations local-only; do not add telemetry or network access without explicit product approval and privacy documentation.
- Treat process metadata, hook payloads, rollout files, state files, filesystem paths, and terminal identifiers as untrusted input.
- Use absolute executable paths or a fixed allowlist. Never execute strings through a shell.
- Preserve user-owned configuration. Installation must fail rather than overwrite an unknown integration file.
- State belongs in `~/.moonglade/state`, with directory mode `0700` and file mode `0600`.
- Never commit credentials, signing certificates, provisioning profiles, notarization passwords, `.env` files, generated apps, or local session data.
- Keep source under `Sources/` and behavioral tests under `Tests/MoongladeCoreTests/`.

## Public interfaces

`MoongladeCore` is an internal module shared by the app and CLI, not a supported library product. Changes to the state schema or installed integration format require explicit documentation and tests.

### `session_title`

State documents carry an optional `session_title`: the name the agent gave the session, written by its own integration. It stays absent for tools that never name a session, and until the agent picks a name. The OpenCode plugin fills it from `session.created` and `session.updated`; a retitle never moves the session status, and never creates a document for a session the plugin is not already tracking.

It exists because a terminal pane cannot be tied to a process. Ghostty's scripting bridge reports only a surface id, name, and working directory — no PID, no TTY — so several agents running in one project directory offer nothing to tell their panes apart. `session_title` outranks the scraped `terminal.window_title_hint` for the row name, identifies the hosting pane in `GhosttySessionMatcher`, and targets `FocusService` when no surface id was resolved.

The matcher separates identity from inference: only assignments founded on evidence (PID, TTY, session title, a title that singles the tool out) enter `GhosttyAssignmentMemory`. A pane picked by enumeration order is a guess, is never remembered, and is re-evaluated on the next scan; a pane whose title reads as another command is never claimed at all.
