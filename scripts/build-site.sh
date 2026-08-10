#!/bin/sh
# Assemble the published site into _site/.
#
#   ./scripts/build-site.sh
#   python3 -m http.server -d _site 8000    # preview at localhost:8000
#
# The site is four things that live elsewhere in the repo, gathered rather than
# copied by hand: the page, the app icon it uses as its favicon, the agent brand
# marks the app itself renders in a session row, and the remote installer served
# at /install so the curl command can name this domain instead of a release
# asset URL. The installer has exactly one source of truth,
# scripts/install-remote.sh, and this is where it is published from.
set -eu

cd "$(dirname "$0")/.."

output="_site"
/bin/rm -rf "$output"
/bin/mkdir -p "$output"

/bin/cp docs/index.html "$output/index.html"
/bin/cp assets/icon.svg "$output/icon.svg"
/bin/cp assets/hero-moonglade.webp "$output/hero-moonglade.webp"

# Straight out of the app's own bundle, never a second copy: the page shows an
# agent with the same mark the panel draws next to a live session. The whole
# directory, so a newly supported agent's icon is publishable without touching
# this script.
/bin/cp -R Sources/MoongladeCore/Resources/icons "$output/icons"
/bin/cp scripts/install-remote.sh "$output/install"

# GitHub Pages reads the custom domain from a CNAME file at the site root.
if [ -f docs/CNAME ]; then
    /bin/cp docs/CNAME "$output/CNAME"
fi

# Jekyll would otherwise try to process the tree and drop anything it does not
# recognise as a page.
/usr/bin/touch "$output/.nojekyll"

/usr/bin/printf 'Built %s\n' "$output"
