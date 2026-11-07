import AppKit

/// Sélection d'une zone à la souris sur l'écran sous le curseur. Échap annule.
@MainActor
final class RegionSelector {
    private var window: NSWindow?
    private var completion: ((CGRect?) -> Void)?

    /// Renvoie la zone choisie en coordonnées CG (points), ou nil si annulé.
    func pick(_ completion: @escaping (CGRect?) -> Void) {
        guard let screen = Geo.screenUnderMouse else { completion(nil); return }
        self.completion = completion
        let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        v.onDone = { [weak self] local in
            guard let self else { return }
            let result = local.map { r -> CGRect in
                // local (AppKit, relatif à l'écran) → global AppKit → global CG
                Geo.flip(r.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
            }
            self.window?.orderOut(nil)
            self.window = nil
            NSCursor.arrow.set()
            let c = self.completion
            self.completion = nil
            c?(result)
        }
        w.contentView = v
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        NSCursor.crosshair.set()
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class SelectionView: NSView {
        var onDone: ((CGRect?) -> Void)?
        private var start: CGPoint?
        private var current: CGPoint?

        override var acceptsFirstResponder: Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

        private var selection: CGRect? {
            guard let s = start, let c = current else { return nil }
            return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            if let r = selection {
                NSColor.clear.setFill()
                r.fill(using: .copy)
                NSColor.systemBlue.setStroke()
                let p = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
                p.lineWidth = 2
                p.stroke()
                let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
                label.draw(at: CGPoint(x: r.minX, y: r.maxY + 4),
                           withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            } else {
                let hint = "Dessine la zone à traduire — Échap pour annuler" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white,
                                                            .font: NSFont.systemFont(ofSize: 18, weight: .medium)]
                let size = hint.size(withAttributes: attrs)
                hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attrs)
            }
        }

        override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil); current = start; needsDisplay = true }
        override func mouseDragged(with e: NSEvent) { current = convert(e.locationInWindow, from: nil); needsDisplay = true }
        override func mouseUp(with e: NSEvent) {
            current = convert(e.locationInWindow, from: nil)
            if let r = selection, r.width > 12, r.height > 8 { onDone?(r) } else { start = nil; current = nil; needsDisplay = true }
        }
        override func keyDown(with e: NSEvent) { if e.keyCode == 53 { onDone?(nil) } }   // Échap
    }
}
