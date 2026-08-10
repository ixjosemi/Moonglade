#!/bin/sh
# One-command install (and reinstall) for Moonglade, from source.
#
#   ./scripts/install.sh
#
# Builds the app and installs it. Everything after the build is shared with the
# download installer and lives in scripts/install-app.sh, which build-app.sh
# ships inside the bundle.
#
# To install without a Swift toolchain, use the published build instead:
#   curl -fsSL https://github.com/ixjosemi/Moonglade/releases/latest/download/install.sh | sh
set -eu

cd "$(dirname "$0")/.."

/usr/bin/printf '\n==> Building Moonglade (release)\n'
./scripts/build-app.sh

exec .build/Moonglade.app/Contents/Resources/install-app.sh .build/Moonglade.app
