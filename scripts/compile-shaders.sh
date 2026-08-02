#!/bin/sh
# Recompiles the SwiftUI layer-effect shaders into the prebuilt metallib the
# package ships as a resource. swift build cannot compile Metal sources, so
# run this after editing Sources/MoongladeApp/Ripple.metal and commit the
# regenerated default.metallib alongside it.
#
# Requires the Metal toolchain: xcodebuild -downloadComponent MetalToolchain
set -eu

cd "$(dirname "$0")/.."
mkdir -p Sources/MoongladeApp/Resources
xcrun -sdk macosx metal \
    -mmacos-version-min=14.0 \
    Sources/MoongladeApp/Ripple.metal \
    -o Sources/MoongladeApp/Resources/default.metallib
echo "Wrote Sources/MoongladeApp/Resources/default.metallib"
