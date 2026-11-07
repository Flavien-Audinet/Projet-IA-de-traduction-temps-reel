import AppKit
import SwiftUI

/// Un bloc prêt à afficher, en POINTS relatifs au coin haut-gauche de la zone capturée.
struct RenderBlock: Identifiable, Equatable {
    let id: String
    let rect: CGRect              // zone du texte d'origine (toujours recouverte)
    let translation: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let weight: Font.Weight
    let serif: Bool
    let underline: Bool
    let text: RGB
    let background: RGB
    let opaqueBackground: Bool
    let align: TextAlign
    let minScale: CGFloat         // réduction maximale autorisée si la traduction ne tient pas
    let bgOpacity: Double
    let singleLine: Bool
    let maxWidth: CGFloat         // place disponible si la traduction est plus longue
    let maxHeight: CGFloat
    let topShift: CGFloat         // décalage pour aligner la ligne de base sur l'original

    static func == (a: RenderBlock, b: RenderBlock) -> Bool {
        a.id == b.id && a.rect == b.rect && a.translation == b.translation && a.text == b.text && a.background == b.background
            && a.fontSize == b.fontSize && a.weight == b.weight && a.serif == b.serif && a.minScale == b.minScale
            && a.bgOpacity == b.bgOpacity && a.maxWidth == b.maxWidth && a.maxHeight == b.maxHeight
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var blocks: [RenderBlock] = []
}

/// Rendu d'un bloc : on recouvre le texte d'origine avec la couleur du fond,
/// puis on écrit la traduction dans le même style. Elle s'étend dans l'espace libre
/// si elle est plus longue, et ne rétrécit qu'en dernier recours.
/// La vue fait (maxWidth + 2·pad) × (maxHeight + 2·pad) : la marge contient le débord du fond.
struct BlockView: View {
    let b: RenderBlock

    static func pad(_ b: RenderBlock) -> CGFloat { max(1, b.fontSize * 0.15) }
    static func size(_ b: RenderBlock) -> CGSize {
        let p = pad(b)
        return CGSize(width: b.maxWidth + 2 * p, height: b.maxHeight + 2 * p)
    }
    /// Coin haut-gauche de la vue (points, repère de la zone capturée).
    static func origin(_ b: RenderBlock, offset d: CGPoint = .zero) -> CGPoint {
        let p = pad(b)
        let x = b.align == .center ? b.rect.midX - b.maxWidth / 2 : b.rect.minX
        return CGPoint(x: x + d.x - p, y: b.rect.minY + d.y - p)
    }

    var body: some View {
        let pad = Self.pad(b)
        let alignment: Alignment = b.align == .center ? .top : .topLeading
        Text(b.translation)
            .font(.system(size: b.fontSize, weight: b.weight, design: b.serif ? .serif : .default))
            .foregroundStyle(b.text.color)
            .underline(b.underline, color: b.text.color)
            .lineSpacing(b.lineSpacing)
            .multilineTextAlignment(b.align == .center ? .center : .leading)
            .lineLimit(b.singleLine ? 1 : nil)
            .minimumScaleFactor(b.minScale)
            .offset(y: b.topShift)
            // Seulement des minimums : le fond épouse le texte (au moins la zone d'origine), sans s'étaler.
            .frame(minWidth: b.rect.width, minHeight: b.rect.height, alignment: alignment)
            .background {
                // Fond uni : couleur exacte. Photo / vidéo : couleur dominante légèrement transparente.
                // (Pas de flou « derrière la fenêtre » : macOS le recalcule à chaque image, très coûteux.)
                RoundedRectangle(cornerRadius: b.fontSize * 0.2)
                    .fill(b.background.color.opacity(b.bgOpacity))
                    .padding(-pad)
            }
            .frame(width: b.maxWidth, height: b.maxHeight, alignment: alignment)
            .padding(pad)
    }
}

/// Version SwiftUI de la surimpression (utilisée par le mode test pour produire une image).
struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(model.blocks) { b in
                let o = BlockView.origin(b)
                BlockView(b: b).offset(x: o.x, y: o.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Compteur en direct (Réglages avancés › Débogage).
struct HUDView: View {
    @ObservedObject var st = LiveStats.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("MyTranslate · débogage").font(.caption.bold())
            Text(String(format: "Capture %.0f img/s · suivi %.2f ms", st.captureFPS, st.trackMs))
            Text(String(format: "OCR %d ms · %.1f OCR/s", st.ocrMs, st.ocrPerSec))
            Text("Blocs \(st.blocks) · suivis \(st.tracked) · perdus \(st.hidden)")
            Text("Traduction \(st.translateMs) ms")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(8)
        .frame(width: 250, alignment: .leading)
        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Conteneur à l'origine en haut à gauche, comme les coordonnées de l'OCR.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Fenêtre transparente, au-dessus de tout, qui laisse passer la souris et le clavier.
/// Chaque bloc est une vue (un calque) : suivre le défilement revient à déplacer des calques,
/// sans redessiner le texte — c'est ce qui rend le mouvement fluide.
@MainActor
final class OverlayController {
    private let container = FlippedView()
    private var views: [String: NSHostingView<BlockView>] = [:]
    private var blocks: [String: RenderBlock] = [:]
    private var offsets: [String: CGPoint?] = [:]

    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        container.wantsLayer = true
        p.contentView = container
        return p
    }()

    /// `cgFrame` : zone capturée en coordonnées CG (points, origine en haut à gauche).
    func show(cgFrame: CGRect, blocks list: [RenderBlock], offsets offs: [String: CGPoint?] = [:]) {
        let f = Geo.flip(cgFrame)
        if panel.frame != f { panel.setFrame(f, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setBlocks(list)
        offsets = offs
        layout()
        CATransaction.commit()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Nouvelles traductions arrivées pour la même OCR (les décalages restent valables).
    func update(blocks list: [RenderBlock]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setBlocks(list)
        layout()
        CATransaction.commit()
    }

    /// Appelé à chaque image capturée : ne fait que déplacer / masquer des calques.
    func apply(offsets offs: [String: CGPoint?]) {
        offsets = offs
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layout()
        CATransaction.commit()
    }

    private func setBlocks(_ list: [RenderBlock]) {
        let ids = Set(list.map(\.id))
        for (id, v) in views where !ids.contains(id) { v.removeFromSuperview(); views[id] = nil }
        var next: [String: RenderBlock] = [:]
        for b in list {
            next[b.id] = b
            if let v = views[b.id] {
                if blocks[b.id] != b { v.rootView = BlockView(b: b) }
            } else {
                let v = NSHostingView(rootView: BlockView(b: b))
                v.wantsLayer = true
                container.addSubview(v)
                views[b.id] = v
            }
        }
        blocks = next
    }

    private func layout() {
        let debug = Tuning.current.debugBoxes
        for (id, v) in views {
            guard let b = blocks[id] else { continue }
            let d = offsets[id] ?? .zero       // pas d'info de suivi : position de l'OCR
            if let d {
                v.isHidden = false
                v.alphaValue = 1
                let r = CGRect(origin: BlockView.origin(b, offset: d), size: BlockView.size(b))
                if v.frame != r { v.frame = r }
            } else if debug {
                v.isHidden = false
                v.alphaValue = 0.35            // débogage : bloc perdu, montré en transparence
            } else {
                v.isHidden = true              // contenu changé : on laisse voir l'original jusqu'à la prochaine OCR
            }
            // Débogage : vert = suivi, rouge = perdu, gris = pas d'information de suivi.
            if debug {
                v.layer?.borderWidth = 1.5
                v.layer?.borderColor = (offsets[id] == nil ? NSColor.systemGray
                                        : d == nil ? NSColor.systemRed : NSColor.systemGreen).cgColor
            } else if v.layer?.borderWidth != 0 {
                v.layer?.borderWidth = 0
            }
        }
    }

    // MARK: Compteur de débogage (coin haut-droit de la zone traduite)

    private var hud: NSHostingView<HUDView>?

    func updateHUD() {
        let on = Tuning.current.hud
        if on && hud == nil {
            let h = NSHostingView(rootView: HUDView())
            h.wantsLayer = true
            container.addSubview(h)
            hud = h
        } else if !on, let h = hud {
            h.removeFromSuperview()
            hud = nil
        }
        if let h = hud {
            let size = CGSize(width: 250, height: 118)
            let r = CGRect(x: max(0, container.bounds.width - size.width - 10), y: 10, width: size.width, height: size.height)
            if h.frame != r { h.frame = r }
        }
    }

    func move(cgFrame: CGRect) {
        let f = Geo.flip(cgFrame)
        if panel.frame != f { panel.setFrame(f, display: true) }
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setBlocks([])
        CATransaction.commit()
        offsets = [:]
    }

    func hide() {
        clear()
        panel.orderOut(nil)
    }
}
