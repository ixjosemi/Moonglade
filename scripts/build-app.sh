#!/bin/sh
set -eu

swift build -c release
bundle=".build/AgentGlance.app"
/bin/rm -rf "$bundle"
/bin/mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/bin"
/bin/cp config/Info.plist "$bundle/Contents/Info.plist"
/bin/cp config/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
/bin/cp .build/release/AgentGlanceApp "$bundle/Contents/MacOS/AgentGlance"
/bin/cp .build/release/agentglance "$bundle/Contents/Resources/bin/agentglance"
/bin/cp -R .build/release/AgentGlance_AgentGlanceCore.bundle "$bundle/Contents/Resources/"
/bin/cp -R .build/release/AgentGlance_AgentGlanceApp.bundle "$bundle/Contents/Resources/"
/bin/chmod 755 "$bundle/Contents/MacOS/AgentGlance" "$bundle/Contents/Resources/bin/agentglance"
/usr/bin/codesign --force --deep --sign - "$bundle"
/usr/bin/printf 'Built %s\n' "$bundle"
