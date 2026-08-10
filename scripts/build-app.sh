#!/bin/sh
# Package Sources/ into .build/Moonglade.app.
#
# MOONGLADE_SIGN_IDENTITY selects the codesign identity. It defaults to "-",
# an ad-hoc signature, which is right for a build that never leaves the machine
# that made it. The release workflow overrides it with a self-signed identity
# that stays the same across releases, because TCC keys the automation grant to
# the signer: under an ad-hoc signature, whose identity is the binary's own
# hash, every update would look like a different app and lose the permission to
# focus your terminal.
set -eu

sign_identity="${MOONGLADE_SIGN_IDENTITY:--}"

swift build -c release
bundle=".build/Moonglade.app"
/bin/rm -rf "$bundle"
/bin/mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/bin"
/bin/cp config/Info.plist "$bundle/Contents/Info.plist"
/bin/cp config/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
/bin/cp .build/release/MoongladeApp "$bundle/Contents/MacOS/Moonglade"
/bin/cp .build/release/moonglade "$bundle/Contents/Resources/bin/moonglade"
/bin/cp -R .build/release/Moonglade_MoongladeCore.bundle "$bundle/Contents/Resources/"
/bin/cp -R .build/release/Moonglade_MoongladeApp.bundle "$bundle/Contents/Resources/"
/bin/cp scripts/install-app.sh "$bundle/Contents/Resources/install-app.sh"
/bin/chmod 755 "$bundle/Contents/MacOS/Moonglade" "$bundle/Contents/Resources/bin/moonglade" \
    "$bundle/Contents/Resources/install-app.sh"
/usr/bin/codesign --force --deep --sign "$sign_identity" "$bundle"
/usr/bin/printf 'Built %s\n' "$bundle"
