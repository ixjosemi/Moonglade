#!/bin/sh
set -eu

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
/bin/chmod 755 "$bundle/Contents/MacOS/Moonglade" "$bundle/Contents/Resources/bin/moonglade"
/usr/bin/codesign --force --deep --sign - "$bundle"
/usr/bin/printf 'Built %s\n' "$bundle"
