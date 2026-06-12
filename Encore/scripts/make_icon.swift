// Renders the Encore app icon to assets/icon_1024.png.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let inset = rect.insetBy(dx: size * 0.09, dy: size * 0.09)
let path = NSBezierPath(roundedRect: inset, xRadius: size * 0.2, yRadius: size * 0.2)

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.38, alpha: 1),
    NSColor(calibratedRed: 0.55, green: 0.10, blue: 0.45, alpha: 1),
    NSColor(calibratedRed: 0.08, green: 0.06, blue: 0.18, alpha: 1),
])!
gradient.draw(in: path, angle: -65)

let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let symbolSize = symbol.size
    let scale = (size * 0.5) / max(symbolSize.width, symbolSize.height)
    let w = symbolSize.width * scale, h = symbolSize.height * scale
    symbol.draw(in: NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h),
                from: .zero, operation: .sourceOver, fraction: 0.96)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
let out = URL(fileURLWithPath: "assets/icon_1024.png")
try? FileManager.default.createDirectory(atPath: "assets", withIntermediateDirectories: true)
try png.write(to: out)
print("wrote \(out.path)")
