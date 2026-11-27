#!/bin/sh
# Fails unless the resource bundle at <bundle> resolves <name>.<extension>
# through NSBundle, the same lookup the app makes at runtime
# (BundledResources.containsResource), so CI checks what the app will load.
#
# SwiftPM writes a resource bundle in one of two layouts, and both are
# legitimate: the native build system's flat directory, with the file at the
# bundle root, and Swift Build's real macOS bundle, Contents/Info.plist plus
# Contents/Resources/, which is the default from Swift 6.4. Which one a build
# gets depends on the toolchain, so this asks Foundation where the file is
# instead of joining either layout's path by hand.
#
# Usage: verify-bundle-resource.sh <bundle> <name> <extension>
set -eu

if [ "$#" -ne 3 ]; then
    /usr/bin/printf 'usage: %s <bundle> <name> <extension>\n' "$0" >&2
    exit 64
fi

resolved="$(/usr/bin/osascript -l JavaScript - "$1" "$2" "$3" <<'EOF'
ObjC.import('Foundation');
function run(argv) {
    const bundle = $.NSBundle.bundleWithPath(argv[0]);
    if (bundle.isNil()) throw new Error(argv[0] + ' is not a bundle.');
    const url = bundle.URLForResourceWithExtension(argv[1], argv[2]);
    if (url.isNil()) throw new Error(argv[0] + ' has no ' + argv[1] + '.' + argv[2] + '.');
    return url.path.js;
}
EOF
)"

# A regular file, not a link out of the bundle, as the runtime check requires.
if [ ! -f "$resolved" ] || [ -L "$resolved" ]; then
    /usr/bin/printf '%s is not a regular file.\n' "$resolved" >&2
    exit 1
fi
/usr/bin/printf 'Found %s\n' "$resolved"
