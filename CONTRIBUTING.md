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

Use Conventional Commits, for example `fix(installer): reject symlinked config paths`. Keep pull requests focused and explain security/privacy implications.

## Pull requests

Pull requests must not contain credentials, personal session data, generated `.app` bundles, signing material, or unrelated formatting churn. By contributing, you agree that your contribution is licensed under the MIT License.
