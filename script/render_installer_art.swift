import AppKit

// Render the Finder background only. Real application/folder icons are placed
// by dmg_layout.py, so drag-to-install remains standard Finder behavior.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let width = 1440, height = 960
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.scaleBy(x: 2, y: 2)
NSColor(srgbRed: 0.863, green: 0.902, blue: 0.906, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 720, height: 480).fill()
let pine = NSColor(srgbRed: 0.09, green: 0.22, blue: 0.21, alpha: 1)
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, alpha: CGFloat = 1) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: pine.withAlphaComponent(alpha)
    ])
}
if let logo = NSImage(contentsOf: root.appendingPathComponent("Assets/git-island-logo.png")) {
    logo.draw(in: NSRect(x: 42, y: 417, width: 30, height: 30))
}
text("git island.", x: 82, y: 421, size: 19, weight: .bold)
text("Your island is one drag away.", x: 42, y: 352, size: 31, weight: .semibold)
text("Drag Git Island into Applications. Then open it from there.", x: 43, y: 323, size: 13, alpha: 0.72)
// A quiet directional cue between the actual Finder icons.
pine.withAlphaComponent(0.35).setStroke()
let arrow = NSBezierPath(); arrow.lineWidth = 1.5
arrow.move(to: NSPoint(x: 302, y: 226)); arrow.line(to: NSPoint(x: 418, y: 226))
arrow.move(to: NSPoint(x: 410, y: 234)); arrow.line(to: NSPoint(x: 418, y: 226)); arrow.line(to: NSPoint(x: 410, y: 218)); arrow.stroke()
text("Less checking. More making.", x: 43, y: 49, size: 13, weight: .medium, alpha: 0.7)
text("macOS 26 or later · A MacBook with a notch", x: 43, y: 28, size: 10, alpha: 0.6)
if let art = NSImage(contentsOf: root.appendingPathComponent("Assets/onboarding-island.png")) {
    art.draw(in: NSRect(x: 473, y: 4, width: 223, height: 165), from: .zero, operation: .sourceOver, fraction: 0.8)
}
let sea = NSColor(srgbRed: 0.863, green: 0.902, blue: 0.906, alpha: 1)
let feather = NSGradient(starting: sea.withAlphaComponent(0), ending: sea)!
feather.draw(in: NSRect(x:473,y:4,width:35,height:165), angle:180)
feather.draw(in: NSRect(x:661,y:4,width:35,height:165), angle:0)
feather.draw(in: NSRect(x:473,y:134,width:223,height:35), angle:90)
feather.draw(in: NSRect(x:473,y:4,width:223,height:25), angle:270)
NSGraphicsContext.restoreGraphicsState()
bitmap.size = NSSize(width: 720, height: 480)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
