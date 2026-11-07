// Génère les icônes de l'extension (bulle de traduction sur fond bleu).
import AppKit
let out = CommandLine.arguments[1]
for px in [16, 32, 48, 96, 128] {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(px), r = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.04, dy: s * 0.04)
  NSColor(srgbRed: 0.165, green: 0.47, blue: 0.84, alpha: 1).setFill()
  NSBezierPath(roundedRect: r, xRadius: s * 0.22, yRadius: s * 0.22).fill()
  let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.56, weight: .semibold).applying(.init(paletteColors: [.white]))
  if let img = NSImage(systemSymbolName: "character.bubble.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let z = img.size
    img.draw(in: NSRect(x: (s - z.width) / 2, y: (s - z.height) / 2, width: z.width, height: z.height))
  }
  NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon-\(px).png"))
}
