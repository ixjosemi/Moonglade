#!/bin/sh
# Install the published Moonglade build.
#
#   curl -fsSL https://github.com/ixjosemi/Moonglade/releases/latest/download/install.sh | sh
#
# Downloads the latest release, verifies it against the release checksums,
# and hands the verified bundle to its own Contents/Resources/install-app.sh,
# which is the same code `./scripts/install.sh` runs after a source build.
#
# This script is fetched on its own and cannot read the repository, so it stays
# self-contained down to the point where a verified bundle exists on disk.
#
# It never prompts, so it is safe to run with its stdin attached to the pipe
# curl writes into.
set -eu

repository="ixjosemi/Moonglade"
archive_name="Moonglade-arm64.zip"
checksums_name="SHA256SUMS"
download_base="https://github.com/$repository/releases/latest/download"
source_install_url="https://github.com/$repository#install"

fail() {
    /usr/bin/printf 'error: %s\n' "$1" >&2
    exit 1
}

step() { /usr/bin/printf '\n==> %s\n' "$1"; }

if [ "$(/usr/bin/uname -s)" != "Darwin" ]; then
    fail "Moonglade is a macOS app."
fi

# Apple Silicon is the only architecture the project validates, so an Intel Mac
# is sent to the source build rather than handed an untested binary.
if [ "$(/usr/bin/uname -m)" != "arm64" ]; then
    fail "the published build is Apple Silicon only. Build from source: $source_install_url"
fi

macos_major="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
if [ "$macos_major" -lt 14 ]; then
    fail "Moonglade needs macOS 14 Sonoma or newer (found $(/usr/bin/sw_vers -productVersion))."
fi

work_directory="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$work_directory"' EXIT INT TERM

step "Downloading the latest release"
/usr/bin/curl -fsSL --proto '=https' --tlsv1.2 \
    -o "$work_directory/$archive_name" "$download_base/$archive_name" \
    || fail "could not download $archive_name from $download_base"
/usr/bin/curl -fsSL --proto '=https' --tlsv1.2 \
    -o "$work_directory/$checksums_name" "$download_base/$checksums_name" \
    || fail "could not download $checksums_name from $download_base"

# The archive arrives over the network, so nothing in it is trusted until its
# digest matches the one published beside it.
step "Verifying checksum"
expected_digest="$(/usr/bin/grep "  $archive_name\$" "$work_directory/$checksums_name" \
    | /usr/bin/awk '{ print $1 }')"
actual_digest="$(/usr/bin/shasum -a 256 "$work_directory/$archive_name" | /usr/bin/awk '{ print $1 }')"
if [ -z "$expected_digest" ]; then
    fail "$checksums_name does not list $archive_name."
fi
if [ "$expected_digest" != "$actual_digest" ]; then
    /usr/bin/printf 'error: checksum mismatch for %s.\n' "$archive_name" >&2
    /usr/bin/printf '  expected: %s\n' "$expected_digest" >&2
    /usr/bin/printf '  actual:   %s\n' "$actual_digest" >&2
    exit 1
fi
/usr/bin/printf 'ok (%s)\n' "$expected_digest"

# ditto is the extractor that restores a signed bundle intact; unzip drops the
# resource forks and permissions the signature is sealed over.
step "Unpacking"
/usr/bin/ditto -x -k "$work_directory/$archive_name" "$work_directory/unpacked" \
    || fail "could not unpack $archive_name."
bundle="$work_directory/unpacked/Moonglade.app"
installer="$bundle/Contents/Resources/install-app.sh"
if [ ! -x "$installer" ]; then
    fail "the downloaded archive is not a Moonglade bundle."
fi

# The signature is what carries the app's identity to TCC, so a bundle that
# does not verify would install an app that cannot hold its automation grant.
/usr/bin/codesign --verify --deep --strict "$bundle" \
    || fail "the downloaded bundle failed signature verification."

version="$(/usr/bin/defaults read "$bundle/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"
/usr/bin/printf 'Moonglade %s\n' "$version"

exec "$installer" "$bundle"
