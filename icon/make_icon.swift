// Draws the 1024×1024 app icon: a screen with a picture-in-picture video tile.
// Usage: swift make_icon.swift <out.png>

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(deviceRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Background squircle on Apple's icon grid (824pt body, centred).
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35).cgColor)
rgb(20, 150, 100).setFill()
bg.fill()
ctx.restoreGState()
bg.addClip()
NSGradient(starting: rgb(46, 204, 128), ending: rgb(10, 105, 80))!.draw(in: body, angle: -90)

// The "screen": a white outline filling most of the body.
let screen = NSRect(x: 196, y: 262, width: 632, height: 500)
let screenPath = NSBezierPath(roundedRect: screen, xRadius: 54, yRadius: 54)
rgb(255, 255, 255, 0.14).setFill()
screenPath.fill()
screenPath.lineWidth = 34
rgb(255, 255, 255).setStroke()
screenPath.stroke()

// The PiP tile, overlapping the screen's bottom-right corner.
let tile = NSRect(x: 486, y: 196, width: 392, height: 262)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 40, yRadius: 40)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0, 40, 25, 0.55).cgColor)
rgb(255, 255, 255).setFill()
tilePath.fill()
ctx.restoreGState()

// Video-camera glyph inside the tile.
let green = rgb(16, 128, 88)
let camBody = NSRect(x: tile.midX - 118, y: tile.midY - 62, width: 160, height: 124)
green.setFill()
NSBezierPath(roundedRect: camBody, xRadius: 28, yRadius: 28).fill()
let lens = NSBezierPath()
lens.move(to: NSPoint(x: camBody.maxX + 14, y: tile.midY))
lens.line(to: NSPoint(x: camBody.maxX + 82, y: tile.midY + 54))
lens.line(to: NSPoint(x: camBody.maxX + 82, y: tile.midY - 54))
lens.close()
lens.lineJoinStyle = .round
lens.lineWidth = 18
green.setStroke()
lens.fill()
lens.stroke()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
