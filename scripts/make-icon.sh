#!/bin/sh
# Regenerates config/AppIcon.icns from assets/icon.svg.
#
# Uses AppKit's native SVG rendering so no third-party rasterizer is required.
# Run after editing assets/icon.svg and commit the resulting .icns; the app
# build copies it verbatim.
#
# The icon's glows, ripples and halos are all feGaussianBlur, so this script
# probes the rasterizer for filter support first and refuses to write an
# iconset when the primitives are dropped — a silently flattened icon looks
# plausible enough to ship by accident.
set -eu

cd "$(dirname "$0")/.."

iconset="$(/usr/bin/mktemp -d)/AppIcon.iconset"
/bin/mkdir -p "$iconset"

/usr/bin/swift - "$PWD/assets/icon.svg" "$iconset" <<'SWIFT'
import AppKit

let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func rasterize(_ image: NSImage, pixels: Int) -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fail("cannot allocate a \(pixels)x\(pixels) bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

/// Renders a blurred disc and samples a pixel the blur alone can reach.
func verifyGaussianBlurSupport() {
    let probe = """
    <svg width="64" height="64" viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <filter id="b" x="-100%" y="-100%" width="300%" height="300%">
          <feGaussianBlur stdDeviation="6"/>
        </filter>
      </defs>
      <circle cx="32" cy="32" r="12" fill="#ffffff" filter="url(#b)"/>
    </svg>
    """
    let probeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("moonglade-blur-probe.svg")
    defer { try? FileManager.default.removeItem(at: probeURL) }
    do {
        try probe.write(to: probeURL, atomically: true, encoding: .utf8)
    } catch {
        fail("cannot write the blur probe: \(error.localizedDescription)")
    }
    guard let image = NSImage(contentsOf: probeURL) else {
        fail("cannot read the blur probe back")
    }
    // 18px from the centre is 6px clear of the unblurred disc, so any alpha
    // here can only have come from feGaussianBlur.
    guard let sample = rasterize(image, pixels: 64).colorAt(x: 32, y: 50) else {
        fail("cannot sample the blur probe")
    }
    guard sample.alphaComponent > 0.02 else {
        fail("""
            this rasterizer drops SVG filter primitives, so assets/icon.svg \
            would render without any of its glows. Regenerate the icon on a \
            macOS version whose AppKit renders feGaussianBlur.
            """)
    }
}

verifyGaussianBlurSupport()

guard let source = NSImage(contentsOf: svgURL) else {
    fail("cannot read \(svgURL.path)")
}
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    let bitmap = rasterize(source, pixels: variant.pixels)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fail("cannot encode \(variant.name) as PNG")
    }
    do {
        try png.write(to: iconsetURL.appendingPathComponent("\(variant.name).png"))
    } catch {
        fail("cannot write \(variant.name): \(error.localizedDescription)")
    }
}
SWIFT

/usr/bin/iconutil -c icns "$iconset" -o config/AppIcon.icns
/bin/rm -rf "$(dirname "$iconset")"
/usr/bin/printf 'Wrote config/AppIcon.icns\n'
