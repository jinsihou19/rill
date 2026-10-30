import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let box = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 195, yRadius: 195)
        NSShadow().set()
        NSGradient(starting: NSColor(srgbRed: 0.97, green: 0.43, blue: 0.31, alpha: 1), ending: NSColor(srgbRed: 0.77, green: 0.17, blue: 0.19, alpha: 1))!.draw(in: box, angle: -70)
        let symbol = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 500, weight: .medium))!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white]))!
        symbol.draw(in: NSRect(x: 242, y: 223, width: 540, height: 570))
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
