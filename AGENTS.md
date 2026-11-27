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

## Review before merge

Every pull request, agent-written ones included, passes the review and score described in [CONTRIBUTING.md](CONTRIBUTING.md#review-before-merge) before it merges; that section holds the rubric and the severities. An agent that wrote a change does not review it in the same context: the review runs in a fresh one. The maintainer runs both with a personal `/review-pipeline <pr> --score` command; it is not part of this repository, and nothing here depends on it.

## Distribution

There are two install paths and they converge: `scripts/install.sh` builds from source, the published build is downloaded by `scripts/install-remote.sh`, and both hand the finished bundle to `scripts/install-app.sh`. That last script ships inside the bundle at `Contents/Resources/install-app.sh` because the remote installer is fetched standalone through `curl` and cannot read this repository — one implementation, distributed with the artifact it installs. Change the install sequence there, never in two places.

`curl` is the delivery channel on purpose. Gatekeeper's quarantine attribute is set by the downloading application, not by the file, so an app fetched with `curl` never meets the "unidentified developer" wall an unsigned `.dmg` from a browser would. Nothing here asks a user to disable a security control.

### Releasing

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `config/Info.plist`. That plist is the only record of the version; the settings pane reads it through `Bundle.main`.
2. Tag and publish a GitHub release as `v<version>`. `.github/workflows/release.yml` then runs the tests, builds a signed app, verifies the tag matches the bundle version, and attaches `Moonglade-arm64.zip`, `SHA256SUMS`, and `install.sh` to the release.

The published build is signed with a **self-signed certificate that must stay the same across releases**. TCC keys the automation grant to the signer, and `build-app.sh`'s default ad-hoc signature has no stable identity — its identity is the binary's own hash — so every update would look like a new app and silently lose permission to focus the user's terminal. This is not notarization and does not pretend to be; it exists so permissions survive updates.

Create the identity once in Keychain Access (Certificate Assistant → Create a Certificate → Code Signing, self-signed), export it as a `.p12`, and store three repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_SIGN_CERTIFICATE_P12` | `base64 -i identity.p12` |
| `MACOS_SIGN_CERTIFICATE_PASSWORD` | the password used on export |
| `MACOS_SIGN_IDENTITY` | the certificate's common name |

The release job fails when they are absent rather than falling back to an ad-hoc signature, because that fallback would publish a build that breaks focus on every update.

### The landing page

`docs/index.html` is deployed to GitHub Pages by `.github/workflows/pages.yml`, which runs `scripts/build-site.sh` to assemble `_site/` from the page, `assets/icon.svg`, and `scripts/install-remote.sh` served at `/install`. The installer therefore has one source of truth and is published, never duplicated. Preview locally with:

```bash
./scripts/build-site.sh && python3 -m http.server -d _site 8000
```

The page's palette is taken from `assets/icon.svg` — the same night gradient, violet and blue blooms, and frost. `assets/header.svg`, the README banner, is built from the same sources: the hero photograph itself as its wallpaper, the icon's moon, the page's palette and type, and the app itself, whose open panel is a screenshot rather than a drawing, with the brand marks copied out of `Sources/MoongladeCore/Resources/icons`. Three surfaces have to agree, so none of them invents a colour, a silhouette, or a mark of its own.

The page shows the app twice — the open panel inside a MacBook lid under `#how`, and the collapsed bar beneath it — and neither is drawn: both are the captures in `assets/captures/`, the same bytes the banner embeds, written by `scripts/make-banner-captures.sh` and published by `build-site.sh`. They sit at the app's own scale, 800×270pt of panel and 369×38pt of bar, the panel welded over the lid's menu bar strip the way the app draws over it. Where the lid is narrower than the panel both shrink together rather than reflow, because a screenshot that reflowed would no longer be one. The lid keeps a 14-inch MacBook Pro's two visible ratios and nothing else, and the interface inside it stays at the app's own scale rather than the display's — scaled honestly to 1512pt the row titles would land at 10px.

The banner is rendered by GitHub in a browser but is worth checking through a second rasterizer before committing, because the failures are silent ones — a dropped `feGaussianBlur` flattens every glow, and AppKit resolves a `<use>` of a path but not a `<use>` of a group that itself contains one, which quietly costs the Codex mark five of its six blades:

```bash
rsvg-convert -w 880 assets/header.svg -o /tmp/header.png
```

`assets/og.jpg`, the card a pasted link unfurls into, is that same banner unframed and fitted to 1200×630. It is committed rather than rendered at deploy time, because the Pages runner has neither librsvg nor ImageMagick — so after any change to the banner, regenerate and commit it alongside:

```bash
./scripts/make-og.sh
```

### The moon

The moon in `assets/header.svg` and in `assets/icon.svg` is not drawn. It is one photograph — the hero's own moon, cut out of `assets/hero-moonglade.webp` — embedded in both as the same base64 `data:` URI, so the tile, the page and the banner show a single moon between them. Embedded rather than referenced because all three are rendered where a relative path resolves to nothing: AppKit rasterizing the iconset, and every browser loading the icon as a favicon or the banner through `<img>`.

The alpha is the crop's own luminance times a radial falloff, baked into the file. The night it was cut from then contributes nothing, the crop has no edge of its own, and no rasterizer is asked for a blend mode it might not have — WebP with alpha in a `data:` URI is decoded by AppKit, librsvg and browsers alike, and is four times smaller than the equivalent PNG, which matters because this file is also served as the site's favicon. Regenerate it with:

```bash
magick assets/hero-moonglade.webp -crop 480x430+517+0 +repage -modulate 106,104 rgb.png
magick rgb.png -colorspace gray -level 11%,66% lum.png
magick -size 480x430 radial-gradient:white-black -level 16%,74% fade.png
magick lum.png fade.png -compose multiply -composite alpha.png
magick rgb.png alpha.png -alpha off -compose copy_opacity -composite -strip \
    -quality 82 moon.webp
```

Then base64 it into the `href` of the `<image>` in both files, and run `./scripts/make-icon.sh`.

The crop holds the moon at (240, 213) with a radius of 118. The banner wants it at (520, 310) with a radius of 58 and the tile at (512, 344) with a radius of 106, which is where each `<image>`'s `x`, `y`, `width` and `height` come from; move the moon and all four change with it. Two values are worth re-checking by eye rather than trusting: the `-level` on the luminance, because too high leaves the disc translucent and greying against the sky behind it while too low brings the photograph's clouds along, and the `-modulate` saturation, because the moon is violet and a boost that reads as rich at 512pt reads as pink at the 16pt the icon is also drawn at.

The drawn halo behind each stays drawn. The cut-out fades to nothing well inside the photograph's own glow, and without that halo the moon lands on the sky rather than lighting the water under it. The banner also masks the cut-out with a soft circle: the crop's lower edge carries a band of the hero's horizon glow, which vanishes into the icon's drawn sky but shows as a lighter box over a photographed one.

### The banner's sea

The banner's wallpaper is `assets/hero-moonglade.webp` itself — its clouds, horizon and glittering glade — embedded once as `#mg-wall` and used twice, as the desktop and, frosted, as what the panel's glass shows. It is the photograph's top 869 rows scaled to the banner's 1040 width, which lands its horizon (row 589) on the banner's y=407. That leaves the photograph's own moon behind the panel, where the frost turns it into the light the glass is lit by, and the cut-out moon below as the only one in open sky. Regenerate it after any change to the hero, re-measuring the horizon row if the hero's framing moved:

```bash
magick assets/hero-moonglade.webp -crop 1506x869+0+0 +repage -strip -quality 78 \
    -define webp:method=6 sea.webp
```

Then base64 it into the `href` of `#mg-wall` and run `./scripts/make-og.sh`. The edges of the banner fall to night under `#mg-vignette`; keep them there, because `make-og.sh` stretches the outermost pixel column and a textured one would streak.

### The banner's captures

The banner draws neither the open panel nor the collapsed bar. Both are screenshots of the running app, cut along their own silhouette, saved to `assets/captures/` for the landing page and embedded at 2x as `#mg-panelShot` and `#mg-barShot`, so every row, tile, glyph and the glass itself are what the app renders. Retake them whenever either changes:

```bash
./scripts/build-app.sh
MOONGLADE_DEMO=1 open -n .build/Moonglade.app
# click the notch, then Cmd-Shift-3 without moving the pointer
./scripts/make-banner-captures.sh panel ~/Desktop/Screenshot.png
# close the panel, then capture the notch again
./scripts/make-banner-captures.sh bar ~/Desktop/Screenshot.png
```

`MOONGLADE_DEMO=1` runs the app against a throwaway directory seeded by `DemoWorkspace` — two running sessions, one waiting, one blocked, each with a named project and branch — and skips process observation, so nothing reaps them. It never opens `~/.moonglade`; quit any running Moonglade first, or the two panels stack. The panel is cut along `HangingNotchGeometry`'s outline; the bar, being pure black, along the outline read off the capture itself. The glass shows whatever wallpaper is behind it, so the panel carries the wallpaper of the Mac it was taken on. The script refuses a capture that is not at 2x or has no open panel, re-embeds it, and regenerates `og.jpg`.

### `session_title`

State documents carry an optional `session_title`: the name the agent gave the session, written by its own integration. It stays absent for tools that never name a session, and until the agent picks a name. The OpenCode plugin fills it from `session.created` and `session.renamed`; a retitle never moves the session status, and never creates a document for a session the plugin is not already tracking.

It exists because a terminal pane cannot be tied to a process. Ghostty's scripting bridge reports only a surface id, name, and working directory — no PID, no TTY — so several agents running in one project directory offer nothing to tell their panes apart. `session_title` outranks the scraped `terminal.window_title_hint` for the row name, identifies the hosting pane in `GhosttySessionMatcher`, and targets `FocusService` when no surface id was resolved.

The matcher separates identity from inference: only assignments founded on evidence (PID, TTY, session title, a title that singles the tool out) enter `GhosttyAssignmentMemory`. A pane picked by enumeration order is a guess, is never remembered, and is re-evaluated on the next scan; a pane whose title reads as another command is never claimed at all.
