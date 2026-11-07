import AppKit

/// Deux systèmes de coordonnées écran coexistent sur macOS :
///  - « CG » (ScreenCaptureKit, CGWindowList) : origine en HAUT à gauche de l'écran principal, y vers le bas ;
///  - « AppKit » (NSWindow, NSScreen) : origine en BAS à gauche de l'écran principal, y vers le haut.
enum Geo {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? NSScreen.screens.first?.frame.height ?? 0
    }

    /// Conversion CG ↔ AppKit (la formule est la même dans les deux sens).
    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Écran (NSScreen) contenant un rectangle CG, ou celui sous la souris.
    static func screen(containing cgRect: CGRect) -> NSScreen? {
        let ak = flip(cgRect)
        return NSScreen.screens.max { a, b in
            a.frame.intersection(ak).area < b.frame.intersection(ak).area
        }
    }

    static var screenUnderMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
