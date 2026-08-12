#!/bin/sh
# Render the social card from the README banner.
#
#   ./scripts/make-og.sh
#
# assets/header.svg is the one piece of marketing art this project has, so the
# card a pasted link unfurls into is that same image rather than a second one
# drawn to match it. Two things have to change on the way out:
#
#   - The frame comes off. The banner is a rounded card with a hairline border,
#     which is right in a README and wrong as a full-bleed image.
#   - The aspect goes from the banner's 1040x600 to the 1.91:1 every scraper
#     crops a large card to. There is nothing to crop: the banner uses its full
#     height, the panel starting at the top edge and the collapsed bar ending
#     near the bottom, so a centre crop would take the camera band off one and
#     the shoulders off the other. Instead the render is fitted to 630 tall and
#     its outermost pixel column is stretched across the 54px left over on each
#     side. That column is smooth night gradient, so the join cannot be seen.
#
# JPEG, not PNG: the banner carries its own grain, which leaves q92 nothing to
# smear on the gradients, and it comes out eight times smaller. Alpha would buy
# nothing on an image that is composited onto a card by someone else.
set -eu

cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null 2>&1 || {
    printf 'needs rsvg-convert — brew install librsvg\n' >&2
    exit 1
}
command -v magick >/dev/null 2>&1 || {
    printf 'needs magick — brew install imagemagick\n' >&2
    exit 1
}

# Both of these are lifted verbatim out of the banner. If either stops matching,
# the card silently keeps the frame it is supposed to lose — so fail here
# instead, and say which line moved.
frame='<rect x="0.5" y="0.5" width="1039" height="599" rx="22" fill="none" stroke="#ffffff" stroke-opacity="0.07"/>'
clip='<clipPath id="mg-screenClip"><rect x="0" y="0" width="1040" height="600" rx="22"/></clipPath>'
for needle in "$frame" "$clip"; do
    grep -qF "$needle" assets/header.svg || {
        printf 'assets/header.svg no longer contains:\n  %s\nUpdate this script before the card is regenerated.\n' "$needle" >&2
        exit 1
    }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# `,` as the delimiter: the two needles carry slashes and hashes, and no commas.
sed -e "s,$frame,," \
    -e "s,$clip,<clipPath id=\"mg-screenClip\"><rect x=\"0\" y=\"0\" width=\"1040\" height=\"600\"/></clipPath>," \
    assets/header.svg > "$work/unframed.svg"

rsvg-convert -h 630 "$work/unframed.svg" -o "$work/core.png"

magick "$work/core.png" \
    -virtual-pixel edge \
    -set option:distort:viewport 1200x630-54-0 -distort SRT 0 +repage \
    -strip -sampling-factor 4:4:4 -quality 92 \
    assets/og.jpg

/usr/bin/printf 'Wrote assets/og.jpg (%s)\n' "$(/usr/bin/wc -c < assets/og.jpg | tr -d ' ') bytes"
