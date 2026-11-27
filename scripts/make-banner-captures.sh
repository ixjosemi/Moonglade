#!/bin/sh
# Embed screenshots of the real app in the README banner.
#
#   ./scripts/build-app.sh
#   MOONGLADE_DEMO=1 open -n .build/Moonglade.app   # quit any other Moonglade first
#   # panel: click the notch, then press Cmd-Shift-3 without moving the pointer
#   ./scripts/make-banner-captures.sh panel ~/Desktop/Screenshot.png
#   # bar: with the panel closed, capture the notch with Cmd-Shift-3 or Cmd-Shift-4
#   ./scripts/make-banner-captures.sh bar ~/Desktop/Screenshot.png
#
# Neither the banner nor the landing page draws the open panel or the
# collapsed bar: both show what the app renders. Each capture is cut along its
# own silhouette so none of the wallpaper it was taken over comes along, saved
# at 2x as WebP to assets/captures/ (q92 keeps the text crisp at a fifth of the
# lossless size; alpha stays lossless), where build-site.sh publishes it for
# the page, embedded in assets/header.svg from the same bytes, and og.jpg is
# regenerated after.
#
# The open panel is 800x270pt with its shoulders, centred on the display and
# hanging from its top edge, so it is the 1600x540 pixels centred along the
# top of a full-screen capture, cut along HangingNotchGeometry's outline. The
# collapsed bar is pure black, so its outline is read off the capture itself:
# for every row from the top, the span between its first and last black pixel.
set -eu

cd "$(dirname "$0")/.."

usage() {
    printf 'usage: %s panel|bar <screenshot.png>\n' "$0" >&2
    exit 64
}
[ $# -eq 2 ] && [ -f "$2" ] || usage
kind=$1
shot=$2
case "$kind" in panel | bar) ;; *) usage ;; esac

for tool in magick rsvg-convert cwebp python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'needs %s — brew install imagemagick librsvg webp\n' "$tool" >&2
        exit 1
    }
done

width=$(magick identify -format '%w' "$shot" 2>/dev/null)
density=$(magick identify -format '%x' "$shot" 2>/dev/null)
[ "$density" = 144 ] || {
    printf '%s is not a 2x screenshot (%s ppi); take it on a Retina display\n' "$shot" "$density" >&2
    exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ "$kind" = panel ]; then
    [ "$width" -ge 1600 ] || {
        printf '%s is %spx wide; the panel needs a full-screen capture\n' "$shot" "$width" >&2
        exit 1
    }
    left=$(( (width - 1600) / 2 ))
    # The camera band at the top of an open panel is pure black.
    band=$(magick "$shot" -alpha off -crop "8x8+$(( width / 2 - 4 ))+2" +repage -colorspace gray \
        -format '%[fx:int(255*mean)]' info: 2>/dev/null)
    [ "$band" -le 12 ] || {
        printf 'no open panel at the top centre of %s (camera band reads %s/255)\n' "$shot" "$band" >&2
        exit 1
    }
    cat > "$work/mask.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="540" viewBox="0 0 800 270"><rect width="800" height="270" fill="black"/><path fill="white" d="M0 0 C7.73 0 14 6.27 14 14 L14 250 C14 261.05 22.95 270 34 270 L766 270 C777.05 270 786 261.05 786 250 L786 14 C786 6.27 792.27 0 800 0 Z"/></svg>
SVG
    rsvg-convert "$work/mask.svg" -o "$work/mask.png"
    magick "$work/mask.png" -colorspace gray -morphology Erode Disk:1 "$work/edge.png"
    magick "$shot" -alpha off -crop "1600x540+$left+0" +repage "$work/rgb.png" 2>/dev/null
else
    # A full-screen capture is narrowed to the top centre; a capture of just
    # the notch is used as it is.
    if [ "$width" -gt 1000 ]; then
        magick "$shot" -alpha off -crop "1000x120+$(( (width - 1000) / 2 ))+0" +repage "$work/area.png" 2>/dev/null
    else
        magick "$shot" -alpha off "$work/area.png" 2>/dev/null
    fi
    magick "$work/area.png" -colorspace gray -depth 8 txt:- > "$work/area.txt"
    geometry=$(python3 -I - "$work/area.txt" "$work/mask.pgm" <<'PY'
import collections, re, sys
rows = collections.defaultdict(dict)
for line in open(sys.argv[1]):
    match = re.match(r"(\d+),(\d+): \((\d+)", line)
    if match:
        rows[int(match.group(2))][int(match.group(1))] = int(match.group(3))
width = max(max(row) for row in rows.values()) + 1
spans = []
for y in range(max(rows) + 1):
    dark = [x for x in range(width) if rows[y].get(x, 255) <= 6]
    if not dark:
        break
    spans.append((dark[0], dark[-1]))
if len(spans) < 20:
    sys.exit("no collapsed bar along the top of the capture")
left = min(span[0] for span in spans)
right = max(span[1] for span in spans)
with open(sys.argv[2], "w") as mask:
    mask.write(f"P2\n{right - left + 1} {len(spans)}\n255\n")
    for first, last in spans:
        mask.write(" ".join("255" if first <= x <= last else "0" for x in range(left, right + 1)) + "\n")
print(f"{right - left + 1}x{len(spans)}+{left}+0")
PY
)
    magick "$work/mask.pgm" -blur 0x0.5 "$work/edge.png"
    magick "$work/area.png" -crop "$geometry" +repage "$work/rgb.png"
fi

magick "$work/rgb.png" "$work/edge.png" -alpha off -compose copy_opacity -composite "$work/cut.png"
cwebp -quiet -m 6 -q 92 -alpha_q 100 "$work/cut.png" -o "$work/cut.webp"
pixels=$(magick identify -format '%w %h' "$work/cut.png")
/bin/mkdir -p assets/captures
/bin/cp "$work/cut.webp" "assets/captures/$kind.webp"

python3 -I - "$kind" "assets/captures/$kind.webp" $pixels assets/header.svg <<'PY'
import base64, re, sys
kind, image, width, height, path = sys.argv[1:6]
data = base64.b64encode(open(image, "rb").read()).decode()
with open(path) as handle:
    svg = handle.read()
element = "mg-panelShot" if kind == "panel" else "mg-barShot"
match = re.search(r'<image id="%s" href="data:image/webp;base64,[^"]*"[^>]*/>' % element, svg)
if not match or svg.count('id="%s"' % element) != 1:
    sys.exit('assets/header.svg has no single <image id="%s">' % element)
tag = re.sub(r'(href="data:image/webp;base64,)[^"]*"', lambda m: m.group(1) + data + '"', match.group(0))
if kind == "bar":
    # The bar keeps its own size: half its pixels, centred on the notch axis.
    w, h = int(width) / 2, int(height) / 2
    for name, value in (("x", 520 - w / 2), ("width", w), ("height", h)):
        tag = re.sub(r' %s="[^"]*"' % name, ' %s="%g"' % (name, value), tag)
svg = svg[:match.start()] + tag + svg[match.end():]
with open(path, "w") as handle:
    handle.write(svg)
PY

printf 'Saved assets/captures/%s.webp and embedded it in assets/header.svg\n' "$kind"
./scripts/make-og.sh
