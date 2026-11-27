# Contributing

Thanks for helping improve Moonglade.

## Development setup

Requirements:

- macOS 14 or newer;
- Swift 6.0 or newer;
- Node.js 20 or newer for OpenCode integration tests;
- Ghostty 1.3+, cmux, iTerm2, or Terminal for manual focus testing. Ghostty and
  cmux both need AppleScript enabled.

```bash
git clone https://github.com/ixjosemi/Moonglade.git
cd Moonglade
swift build
swift run moonglade-tests
./scripts/build-app.sh
open .build/Moonglade.app
```

`swift build` does not compile Metal. If you edit `Sources/MoongladeApp/Ripple.metal`, regenerate the prebuilt shader library with `./scripts/compile-shaders.sh` and commit it with your change.

## Workflow

1. Open an issue for significant behavioral or architectural changes.
2. Add a failing behavioral test.
3. Implement the smallest complete change.
4. Run the full build and test commands.
5. Update documentation when behavior, permissions, privacy, or integrations change.
6. Get the change reviewed and scored as described in [Review before merge](#review-before-merge).

Use Conventional Commits, for example `fix(installer): reject symlinked config paths`. Keep pull requests focused and explain security/privacy implications.

## Review before merge

Every pull request gets an adversarial review and a score before it merges, the maintainer's own and agent-written ones included. Both are written by a reviewer who did not write the change, and both are recorded in the pull request.

The review tries to break the change rather than read it. Run `swift build`, `swift run moonglade-tests` and `./scripts/build-app.sh` on the pull request's head; when the change adds tests, revert the change and confirm they fail; probe the edge cases the change claims to handle.

The score grades the change against its contract: the linked issue, or the pull request description when there is none. Each dimension is scored from 0 to 100 with the evidence behind it, where 100 means nothing a maintainer would ask to change and 90 means ready to merge as it is.

| Dimension | Weight | Graded on |
| --- | ---: | --- |
| Acceptance | 30% | Every promise in the contract is implemented, edge cases included. |
| Tests | 20% | Each promise has a test that fails if the change is reverted, and the suite is green. |
| Security | 15% | Nothing exploitable, no data exposure, untrusted input validated. |
| Maintainability | 15% | Follows the closest existing code; no unneeded abstraction. |
| Operational | 10% | Builds, checks and failure paths are sound. |
| Scope | 10% | Only the agreed change. |

Findings carry a severity:

- **critical**: fails the contract, is exploitable, loses data, or breaks the build or the main tests;
- **major**: breaks an edge case or a secondary path, leaves a central promise without a protecting test, or breaks a pattern the repository already follows;
- **minor**: style, consistency or an optional improvement.

Critical and major findings are important: each one is fixed, or answered in the pull request with a reason, before merging.

## Pull requests

Pull requests must not contain credentials, personal session data, generated `.app` bundles, signing material, or unrelated formatting churn. By contributing, you agree that your contribution is licensed under the MIT License.
