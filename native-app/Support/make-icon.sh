#!/bin/bash
# Regenerates AppIcon.icns: two floating windows with a play button, on a dark rounded square.
# Needs the Xcode Command Line Tools (swift, sips, iconutil). Usage: ./make-icon.sh
set -e
cd "$(dirname "$0")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/draw.swift" <<'SWIFT'
import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
let accent = color(0xFF3B5C)

// macOS icon grid: an 824 pt rounded square centred on the 1024 canvas.
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0x000000, 0.35); shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.shadowBlurRadius = 28
shadow.set()
color(0x1C1C24).setFill(); tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(0x303044), ending: color(0x14141A))!.draw(in: tile, angle: -90)
color(0xFFFFFF, 0.10).setStroke(); tile.lineWidth = 4; tile.stroke()

// The window behind: an accent outline, up and to the right.
let back = NSBezierPath(roundedRect: NSRect(x: 350, y: 440, width: 380, height: 250), xRadius: 46, yRadius: 46)
back.lineWidth = 24; accent.setStroke(); back.stroke()

// The window in front, floating (soft shadow), with the play button.
NSGraphicsContext.saveGraphicsState()
let float = NSShadow()
float.shadowColor = color(0x000000, 0.5); float.shadowOffset = NSSize(width: 0, height: -18); float.shadowBlurRadius = 44
float.set()
let front = NSBezierPath(roundedRect: NSRect(x: 250, y: 320, width: 440, height: 290), xRadius: 52, yRadius: 52)
color(0xF5F5F7).setFill(); front.fill()
NSGraphicsContext.restoreGraphicsState()

let play = NSBezierPath()
play.move(to: NSPoint(x: 438, y: 410)); play.line(to: NSPoint(x: 438, y: 520)); play.line(to: NSPoint(x: 538, y: 465)); play.close()
play.lineJoinStyle = .round; play.lineWidth = 22
accent.setFill(); play.fill(); accent.setStroke(); play.stroke()

NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swiftc -O "$WORK/draw.swift" -o "$WORK/draw"
"$WORK/draw" "$WORK/icon-1024.png"

SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for base in 16 32 128 256 512; do
    sips -z $base $base "$WORK/icon-1024.png" --out "$SET/icon_${base}x${base}.png" >/dev/null
    sips -z $((base * 2)) $((base * 2)) "$WORK/icon-1024.png" --out "$SET/icon_${base}x${base}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
echo "Wrote $(pwd)/AppIcon.icns"
