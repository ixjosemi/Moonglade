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
echo "Wrote Sources/MoongladeApp/Resources/default.metallib"
