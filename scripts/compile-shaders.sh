#!/bin/sh
# Recompiles the SwiftUI layer-effect shaders into the prebuilt metallib the
# package ships as a resource. swift build cannot compile Metal sources, so
# run this after editing Sources/MoongladeApp/Ripple.metal and commit the
# regenerated default.metallib alongside it.
#
# Requires the full Xcode Metal toolchain; Command Line Tools do not include
# the `metal` compiler.
set -eu

cd "$(dirname "$0")/.."
mkdir -p Sources/MoongladeApp/Resources
xcrun -sdk macosx metal \
    Sources/MoongladeApp/Ripple.metal \
    -o Sources/MoongladeApp/Resources/default.metallib

# The metallib is a build product of a toolchain CI cannot reproduce byte for
# byte, so drift is detected against the source instead: this records which
# Ripple.metal the committed library was built from. Editing the shader
# without rerunning this script leaves the two disagreeing, and CI fails.
shasum -a 256 Sources/MoongladeApp/Ripple.metal | cut -d' ' -f1 \
    > Sources/MoongladeApp/Resources/default.metallib.source-sha256

echo "Wrote Sources/MoongladeApp/Resources/default.metallib"
echo "Wrote Sources/MoongladeApp/Resources/default.metallib.source-sha256"
