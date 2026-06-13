// Renders the iOS app icon (full-bleed gradient, no transparent corners) to
// the path given as argv[1]. Uses the same lockFocus + tiffRepresentation path
// as the macOS generator (drawing into a separate bitmap context renders black
// when run headless). The art is fully opaque, so Xcode's asset compiler
// flattening any alpha is a no-op.
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size: CGFloat = 1024
let rect = NSRect(x: 0, y: 0, width: size, height: size)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Full-bleed gradient (iOS applies its own rounded-corner mask).
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.38, alpha: 1),
    NSColor(calibratedRed: 0.55, green: 0.10, blue: 0.45, alpha: 1),
    NSColor(calibratedRed: 0.08, green: 0.06, blue: 0.18, alpha: 1),
])!
gradient.draw(in: rect, angle: -65)

let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let scale = (size * 0.5) / max(s.width, s.height)
    let w = s.width * scale, h = s.height * scale
    symbol.draw(in: NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h),
                from: .zero, operation: .sourceOver, fraction: 0.96)
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("encode failed")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
