import AppKit
import ScreenCaptureKit
import CoreVideo

enum ScreenMode: String, CaseIterable, Identifiable {
    case window, region, fullscreen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .window: return "Fenêtre active"
        case .region: return "Zone choisie"
        case .fullscreen: return "Écran entier"
        }
    }
    var symbol: String {
        switch self {
        case .window: return "macwindow"
        case .region: return "rectangle.dashed"
        case .fullscreen: return "display"
        }
    }
    var hotkey: HotKeys.Combo {
        switch self {
        case .window: return .window
        case .region: return .region
        case .fullscreen: return .fullscreen
        }
    }
}

/// Bloc analysé (OCR + style), avant traduction.
struct AnalyzedBlock {
    let block: TextBlock
    let style: TextStyle
    let metrics: [LineMetrics]
    var id = ""     // stable d'une OCR à l'autre : texte + rang d'apparition
}

/// Étapes pures du traitement d'une image, partagées avec le mode test.
enum ScreenPipeline {
    static func analyze(_ pb: CVPixelBuffer, direction: Direction, fast: Bool) -> [AnalyzedBlock] {
        let lines = OCR.recognize(pb, languages: direction.ocrLanguages, fast: fast)
        let groups = OCR.group(lines)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let px = PixelReader(pb) else { return [] }

        var out: [AnalyzedBlock] = []
        for g in groups {
            let (bg, _) = StyleEstimator.background(around: g.lines, px)
            let ms = g.lines.map { StyleEstimator.measure($0, bg: bg, px) }
            // On coupe le bloc là où le style change (titre gras puis paragraphe, etc.).
            var parts: [[Int]] = [[0]]
            for i in 1..<max(1, g.lines.count) where i < g.lines.count {
                if styleBreak(ms[i - 1], ms[i]) { parts.append([i]) } else { parts[parts.count - 1].append(i) }
            }
            for idx in parts {
                let b = OCR.makeBlock(idx.map { g.lines[$0] })
                guard LanguageGuess.isSource(b.text, source: direction.nlSource, target: direction.nlTarget) else { continue }
                let m = idx.compactMap { ms[$0] }
                out.append(AnalyzedBlock(block: b, style: StyleEstimator.estimate(b, metrics: m, pixels: px), metrics: m))
            }
        }
        return out
    }

    private static func styleBreak(_ a: LineMetrics?, _ b: LineMetrics?) -> Bool {
        guard let a, let b else { return false }
        let dStep = abs(StyleEstimator.step(a.weightRatio) - StyleEstimator.step(b.weightRatio))
        let size = max(a.xHeight, b.xHeight) / max(1, min(a.xHeight, b.xHeight))
        return dStep >= 2 || size > 1.2 || a.ink.distance(b.ink) > 60
    }

    /// `scale` = pixels par point de la capture.
    /// `canvas` = taille de la zone capturée en points.
    static func render(_ analyzed: [AnalyzedBlock], translations: [String: String], scale: CGFloat,
                       canvas: CGSize) -> [RenderBlock] {
        analyzed.compactMap { a in
            guard let t = translations[a.block.text], t != a.block.text else { return nil }
            let s = a.style, r = a.block.rect
            let tune = Tuning.current
            let rect = CGRect(x: r.minX / scale, y: r.minY / scale, width: r.width / scale, height: r.height / scale)
            let fs = s.fontSize / scale * tune.fontScale
            let font = NSFont.systemFont(ofSize: fs)
            let fontLine = font.ascender - font.descender + font.leading
            let single = a.block.lines.count == 1
            // Ligne seule centrée dans son cadre (bouton, sous-titre, onglet) : autant de place libre des deux côtés.
            var align = a.block.align
            if single, s.freeLeft > r.height * 0.5, s.freeRight > r.height * 0.5,
               max(s.freeLeft, s.freeRight) / min(s.freeLeft, s.freeRight) < 1.6 {
                align = .center
            }
            // Sous-titre sur une vidéo / photo : ligne seule au centre horizontal de la zone.
            let subtitle = single && !s.uniformBackground && abs(rect.midX - canvas.width / 2) < canvas.width * 0.04
            if subtitle { align = .center }
            // Une traduction plus longue peut déborder dans l'espace libre (même fond) au lieu de rétrécir.
            var maxW = rect.width, maxH = rect.height
            if subtitle {
                maxW = min(2 * min(rect.midX, canvas.width - rect.midX) - 8, rect.width * 1.8)
            } else if single {
                maxW += align == .center ? 2 * min(s.freeLeft, s.freeRight) / scale : s.freeRight / scale
            } else {
                maxH += s.freeBelow / scale
            }
            // Réglage « traduction plus longue » : déborder plutôt que rétrécir.
            if tune.overflow != .shrink {
                if single && !subtitle {
                    maxW = max(maxW, min(rect.width * 1.8, canvas.width - rect.minX - 4))
                } else if !single {
                    maxH = max(maxH, rect.height * 2.5)
                }
            }
            // Jamais moins haut qu'une ligne de la police choisie (sinon le texte rétrécit à tort).
            maxH = max(maxH, fontLine * 1.05 + max(0, s.baseline / scale - font.ascender))
            let serif = tune.font == .auto ? s.serif : tune.font == .serif
            let wStep = min(3, max(0, s.weightStep + tune.weightShift))
            return RenderBlock(id: a.id.isEmpty ? "\(Int(r.minX)),\(Int(r.minY))|\(a.block.text)" : a.id, rect: rect, translation: t,
                               fontSize: fs, lineSpacing: max(0, a.block.linePitch / scale - fontLine),
                               weight: StyleEstimator.weight(wStep), serif: serif, underline: s.underline,
                               text: s.text, background: s.background,
                               opaqueBackground: s.uniformBackground, align: align,
                               minScale: tune.overflow == .overflow ? 1 : tune.minShrink,
                               bgOpacity: s.uniformBackground ? 1 : tune.photoOpacity,
                               singleLine: single, maxWidth: max(rect.width, maxW), maxHeight: max(rect.height, maxH),
                               topShift: s.baseline / scale - font.ascender)
        }
    }
}

@MainActor
final class ScreenTranslator: ObservableObject {
    static let shared = ScreenTranslator()

    @Published private(set) var mode: ScreenMode?
    @Published var status = "Inactif"
    @Published var stats = ""
    @Published var needsPermission = false
    /// Raccourci du menu : « OCR rapide » = mode toujours rapide (le réglage fin est dans Réglages avancés).
    var fastOCR: Bool {
        get { Tuning.current.ocrMode == .fast }
        set { TuningStore.shared.t.ocrMode = newValue ? .fast : .auto; objectWillChange.send() }
    }

    private let capture = FrameCapture()
    private let overlay = OverlayController()
    private let selector = RegionSelector()
    private let work = DispatchQueue(label: "mytranslate.ocr", qos: .userInitiated)

    /// Zone capturée (CG, points) et facteur pixels/points.
    private var captureFrame: CGRect = .zero
    private var scale: CGFloat = 2
    private var targetWindow: CGWindowID?
    private var windowTimer: Timer?
    private var session = 0

    // Suivi de mouvement — accédé UNIQUEMENT sur la file de capture.
    nonisolated(unsafe) private let motion = MotionTracker()
    nonisolated(unsafe) private var motionGen = 0
    nonisolated(unsafe) private var latestCQ: (gray: GrayFrame, pb: CVPixelBuffer)?
    nonisolated(unsafe) private var trackStep = 2

    // État de l'OCR (fil principal).
    private var frameNo = 0
    private var latest: (pb: CVPixelBuffer, gray: GrayFrame, n: Int)?
    private var ocrBusy = false
    private var lastOCRFrame = -1
    private var analyzed: [AnalyzedBlock] = []
    private var gen = 0            // génération des blocs affichés (une par OCR)
    private var shownGen = -1
    private var ocrMs = 0
    private var ocrPB: CVPixelBuffer?      // image de la dernière OCR (référence du suivi)
    // Cadence de l'OCR : on attend que l'image se stabilise (120 ms) ou au plus 0,7 s pendant un
    // mouvement continu, et on ignore les changements minuscules (curseur qui clignote, petite animation).
    // Entre deux OCR, c'est le suivi de mouvement qui déplace les traductions.
    private var lastChange = Date.distantPast, lastOCRTime = Date.distantPast
    private var dirtySinceOCR: CGFloat = 0
    private var ocrTimer: Timer?
    private var settleDelay: Double { Tuning.current.settleMs / 1000 }
    private var maxOCRInterval: Double { Tuning.current.maxOCRIntervalMs / 1000 }
    private var minDirty: CGFloat { CGFloat(Tuning.current.minDirtyPercent / 100) }
    // Vitesse de chaque bloc (points/s) pour l'anticipation, et statistiques en direct.
    private var motionState: [String: (p: CGPoint, t: CFAbsoluteTime, v: CGPoint)] = [:]
    private var lastShown: [String: CGPoint] = [:]
    private var fpsCount = 0, fpsStart = CFAbsoluteTimeGetCurrent(), ocrCount = 0
    nonisolated(unsafe) private var trackMsCQ = 0.0

    private init() {
        TuningStore.shared.observe { [weak self] old, new in
            guard let self, self.mode != nil else { return }
            if old.fps != new.fps || old.trackStep != new.trackStep {
                self.prepareTracking()
                let c = self.config(size: self.captureFrame.size, source: nil)
                if self.mode == .window { Task { await self.capture.update(config: c) } } else { self.start(self.mode!) }
            }
            if old.fontScale != new.fontScale || old.overflow != new.overflow || old.minShrink != new.minShrink
                || old.font != new.font || old.weightShift != new.weightShift || old.photoOpacity != new.photoOpacity
                || old.debugBoxes != new.debugBoxes {
                self.overlay.update(blocks: self.renderNow())
            }
            if old.hud != new.hud { self.overlay.updateHUD() }
        }
        capture.onFrame = { [weak self] pb, dirty in self?.onCaptureFrame(pb, dirty) }
        capture.onStop = { [weak self] err in
            Task { @MainActor in
                guard let self, self.mode != nil else { return }
                self.status = "Capture interrompue" + (err.map { " : \($0.localizedDescription)" } ?? "")
                self.stop()
            }
        }
    }

    func toggle(_ m: ScreenMode) {
        if mode == m { stop() } else { start(m) }
    }

    func start(_ m: ScreenMode) {
        stop()
        session += 1
        let s = session
        if m == .region {
            selector.pick { [weak self] rect in
                guard let self, let rect, s == self.session else { return }
                Task { await self.begin(.region, region: rect, session: s) }
            }
        } else {
            Task { await begin(m, region: nil, session: s) }
        }
    }

    func stop() {
        session += 1
        mode = nil
        windowTimer?.invalidate(); windowTimer = nil
        targetWindow = nil
        latest = nil
        analyzed = []
        ocrBusy = false
        ocrTimer?.invalidate(); ocrTimer = nil
        dirtySinceOCR = 1
        overlay.hide()
        capture.queue.async { [motion] in motion.clear() }
        Task { await capture.stop() }
        status = "Inactif"
        stats = ""
    }

    // MARK: Démarrage d'un mode

    private func begin(_ m: ScreenMode, region: CGRect?, session s: Int) async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            needsPermission = false
        } catch {
            needsPermission = true
            status = "Autorisation « Enregistrement de l'écran » requise"
            CGRequestScreenCaptureAccess()
            return
        }
        guard s == session else { return }
        let me = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }

        do {
            switch m {
            case .window:
                guard let (win, scr) = frontWindow(content) else {
                    status = "Aucune fenêtre au premier plan"
                    return
                }
                targetWindow = win.windowID
                captureFrame = win.frame
                scale = scr.backingScaleFactor
                prepareTracking()
                try await capture.start(filter: SCContentFilter(desktopIndependentWindow: win),
                                        config: config(size: win.frame.size, source: nil))
                startWindowTracking()

            case .region, .fullscreen:
                let area = region ?? Geo.screenUnderMouse.map { Geo.flip($0.frame) } ?? .zero
                guard let nsScreen = Geo.screen(containing: area),
                      let display = content.displays.first(where: { $0.displayID == nsScreen.displayID }) else {
                    status = "Écran introuvable"
                    return
                }
                scale = nsScreen.backingScaleFactor
                captureFrame = area.intersection(display.frame)
                prepareTracking()
                // sourceRect est relatif au coin haut-gauche de l'écran capturé
                let local = captureFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                let filter = SCContentFilter(display: display, excludingApplications: me.map { [$0] } ?? [],
                                             exceptingWindows: [])
                try await capture.start(filter: filter,
                                        config: config(size: captureFrame.size, source: m == .region ? local : nil))
            }
        } catch {
            status = "Impossible de capturer : \(error.localizedDescription)"
            return
        }
        guard s == session else { await capture.stop(); return }
        mode = m
        overlay.show(cgFrame: captureFrame, blocks: [])
        status = "\(m.label) : traduction en cours"
    }

    /// Pas de l'image réduite du suivi (l'estimation grossière ; l'affinage est en pleine résolution).
    private func prepareTracking() {
        let px = captureFrame.width * scale * captureFrame.height * scale
        let t = Tuning.current.trackStep
        let step = t > 0 ? t : (px > 6_000_000 ? 6 : 4)
        capture.queue.async { [weak self] in self?.trackStep = step }
    }

    /// 60 images/s : la capture sert au suivi du mouvement, l'OCR ne prend que les images utiles.
    private func config(size: CGSize, source: CGRect?) -> SCStreamConfiguration {
        FrameCapture.configuration(pixelSize: CGSize(width: size.width * scale, height: size.height * scale),
                                   sourceRect: source, fps: Tuning.current.fps)
    }

    /// Fenêtre principale de l'app au premier plan (hors MyTranslate).
    private func frontWindow(_ content: SCShareableContent) -> (SCWindow, NSScreen)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = app.processIdentifier
        // CGWindowList est trié du premier plan vers l'arrière : on prend la première fenêtre « normale » de l'app.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let sc = content.windows.first(where: { $0.windowID == id }),
                  sc.frame.width > 80, sc.frame.height > 60,
                  let scr = Geo.screen(containing: sc.frame) else { continue }
            return (sc, scr)
        }
        return nil
    }

    // MARK: Suivi de la fenêtre à 60 Hz (déplacement, redimensionnement, changement d'app)

    private func startWindowTracking() {
        windowTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackWindow() }
        }
        RunLoop.main.add(t, forMode: .common)     // continue pendant les glisser-déposer et menus
        windowTimer = t
    }

    private var lastFrontPID: pid_t?

    private func trackWindow() {
        guard mode == .window, let id = targetWindow else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let me = ProcessInfo.processInfo.processIdentifier
        if let front, front != me, let last = lastFrontPID, front != last {
            lastFrontPID = front
            start(.window)        // une autre app passe au premier plan : on la suit
            return
        }
        lastFrontPID = front
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
        guard let w = info?.first,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: b) else {
            overlay.hide()
            return
        }
        let onScreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
        if !onScreen { overlay.clear(); return }
        if rect.size != captureFrame.size {
            // Redimensionnement : la mise en page change, on repart d'une OCR propre.
            captureFrame = rect
            overlay.clear()
            overlay.move(cgFrame: rect)
            analyzed = []
            prepareTracking()
            capture.queue.async { [motion] in motion.clear() }
            let c = config(size: rect.size, source: nil)
            Task { await capture.update(config: c) }
        } else if rect.origin != captureFrame.origin {
            captureFrame = rect
            overlay.move(cgFrame: rect)
        }
    }

    // MARK: Images capturées (file de capture, 30/s)

    nonisolated private func onCaptureFrame(_ pb: CVPixelBuffer, _ dirty: [CGRect]) {
        guard let gray = GrayFrame(pb, step: trackStep) else { return }
        latestCQ = (gray, pb)
        let g = motionGen
        let t0 = CFAbsoluteTimeGetCurrent()
        let offsets = motion.hasReference && Tuning.current.tracking ? motion.track(gray, pb) : [:]
        trackMsCQ = trackMsCQ * 0.9 + (CFAbsoluteTimeGetCurrent() - t0) * 1000 * 0.1
        let total = CGFloat(CVPixelBufferGetWidth(pb) * CVPixelBufferGetHeight(pb))
        let frac = dirty.isEmpty ? 1 : dirty.reduce(0) { $0 + $1.width * $1.height } / max(1, total)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.frameArrived(pb, gray, gen: g, offsets: offsets, dirty: frac) }
        }
    }

    private func frameArrived(_ pb: CVPixelBuffer, _ gray: GrayFrame, gen g: Int, offsets: [String: CGPoint?], dirty: CGFloat) {
        guard mode != nil else { return }
        frameNo += 1
        latest = (pb, gray, frameNo)
        lastChange = Date()
        dirtySinceOCR += dirty
        // La surimpression suit le contenu immédiatement, sans attendre l'OCR.
        if g == shownGen, !offsets.isEmpty { overlay.apply(offsets: anticipate(offsets)) }
        updateStats(offsets)
        scheduleOCR()
    }

    /// Décalages en points + projection en avant selon la vitesse de chaque bloc (compense le délai
    /// capture → affichage), et option « garder la dernière position » quand un bloc n'est pas retrouvé.
    private func anticipate(_ offsets: [String: CGPoint?]) -> [String: CGPoint?] {
        let tune = Tuning.current
        let now = CFAbsoluteTimeGetCurrent()
        var out: [String: CGPoint?] = [:]
        for (id, o) in offsets {
            guard let o else {
                out[id] = tune.hideOnChange ? .some(nil) : (lastShown[id] ?? .zero)
                continue
            }
            let p = CGPoint(x: o.x / scale, y: o.y / scale)
            var v = CGPoint.zero
            if let m = motionState[id], now - m.t > 0.001, now - m.t < 0.25 {
                let inst = CGPoint(x: (p.x - m.p.x) / (now - m.t), y: (p.y - m.p.y) / (now - m.t))
                v = CGPoint(x: m.v.x * 0.5 + inst.x * 0.5, y: m.v.y * 0.5 + inst.y * 0.5)   // lissage
            }
            motionState[id] = (p, now, v)
            let a = tune.anticipationMs / 1000
            let shown = CGPoint(x: p.x + v.x * a, y: p.y + v.y * a)
            lastShown[id] = shown
            out[id] = shown
        }
        return out
    }

    private func updateStats(_ offsets: [String: CGPoint?]) {
        fpsCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        guard now - fpsStart >= 0.5 else { return }
        let st = LiveStats.shared
        st.captureFPS = Double(fpsCount) / (now - fpsStart)
        st.ocrPerSec = Double(ocrCount) / (now - fpsStart)
        fpsCount = 0; ocrCount = 0; fpsStart = now
        st.trackMs = trackMsCQ
        st.ocrMs = ocrMs
        st.blocks = analyzed.count
        st.tracked = offsets.values.filter { $0 != nil }.count
        st.hidden = offsets.values.filter { $0 == nil }.count
        overlay.updateHUD()
    }

    /// Décide quand relancer l'OCR (voir `settleDelay` / `maxOCRInterval`, réglables).
    private func scheduleOCR() {
        guard mode != nil, !ocrBusy, let f = latest, f.n > lastOCRFrame else { return }
        if !analyzed.isEmpty && dirtySinceOCR < minDirty { return }     // changement insignifiant
        let now = Date()
        let due = analyzed.isEmpty ? now
            : min(lastChange.addingTimeInterval(settleDelay), lastOCRTime.addingTimeInterval(maxOCRInterval))
        if due <= now {
            ocrTimer?.invalidate(); ocrTimer = nil
            runOCR()
        } else if ocrTimer == nil || ocrTimer!.fireDate > due {
            ocrTimer?.invalidate()
            let t = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.ocrTimer = nil; self?.scheduleOCR() }
            }
            RunLoop.main.add(t, forMode: .common)
            ocrTimer = t
        }
    }

    // MARK: OCR en continu (dès que le contenu a changé)

    private func runOCR() {
        guard let f = latest, f.n > lastOCRFrame else { return }
        ocrBusy = true
        lastOCRFrame = f.n
        lastOCRTime = Date()
        dirtySinceOCR = 0
        // Pendant un mouvement continu (défilement, vidéo), OCR rapide (~50 ms au lieu de ~550 ms) :
        // le mode précis n'est utilisé qu'une fois l'image stabilisée.
        let moving = Date().timeIntervalSince(lastChange) < settleDelay
        let mode = Tuning.current.ocrMode
        let fast = mode == .fast || (mode == .auto && moving)
        let dir = TranslatorHub.shared.direction, s = session
        ocrCount += 1
        work.async { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            let result = ScreenPipeline.analyze(f.pb, direction: dir, fast: fast)
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, s == self.session else { return }
                    self.ocrMs = ms
                    self.ocrPB = f.pb
                    self.ocrDone(result, gray: f.gray)
                    self.ocrBusy = false
                    self.scheduleOCR()     // une image plus récente est peut-être déjà arrivée
                }
            }
        }
    }

    private func ocrDone(_ result: [AnalyzedBlock], gray: GrayFrame) {
        // Identifiants stables : un même texte garde la même vue (pas de clignotement).
        var seen: [String: Int] = [:]
        analyzed = result.sorted { ($0.block.rect.minY, $0.block.rect.minX) < ($1.block.rect.minY, $1.block.rect.minX) }
            .map { a in
                var a = a
                let k = seen[a.block.text, default: 0]
                seen[a.block.text] = k + 1
                a.id = "\(a.block.text)#\(k)"
                return a
            }
        gen += 1
        let g = gen
        let blocks = renderNow()
        let sigs = analyzed.map { (id: $0.id, rect: $0.block.rect) }
        let refPB = ocrPB
        // Nouvelle référence de suivi = l'image de l'OCR ; on recale aussitôt sur l'image la plus récente.
        capture.queue.async { [weak self] in
            guard let self else { return }
            if let refPB { self.motion.setReference(gray, refPB, blocks: sigs) }
            self.motionGen = g
            let offs = self.latestCQ.map { self.motion.track($0.gray, $0.pb) } ?? [:]
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard g == self.gen, self.mode != nil else { return }
                    self.shownGen = g
                    self.overlay.show(cgFrame: self.captureFrame, blocks: blocks,
                                      offsets: offs.mapValues { $0.map { CGPoint(x: $0.x / self.scale, y: $0.y / self.scale) } })
                }
            }
        }
        translateMissing()
    }

    private func renderNow() -> [RenderBlock] {
        var tr: [String: String] = [:]
        for a in analyzed { if let t = TranslatorHub.shared.cached(a.block.text) { tr[a.block.text] = t } }
        let blocks = ScreenPipeline.render(analyzed, translations: tr, scale: scale, canvas: captureFrame.size)
        stats = "OCR \(ocrMs) ms · \(blocks.count)/\(analyzed.count) blocs traduits"
        return blocks
    }

    /// Les textes nouveaux partent en petits lots parallèles, dans l'ordre de lecture :
    /// le haut de la page s'affiche sans attendre la fin.
    private func translateMissing() {
        let missing = analyzed.map(\.block.text).filter { TranslatorHub.shared.cached($0) == nil }
        // Si le moteur est en erreur, on ne le relance qu'une OCR sur dix (évite de le saturer).
        guard !missing.isEmpty, TranslatorHub.shared.lastError == nil || Int.random(in: 0..<10) == 0 else { return }
        let context = analyzed.prefix(8).map(\.block.text).joined(separator: " · ")
        var chunks: [[String]] = [], cur: [String] = [], len = 0
        for t in missing {
            if !cur.isEmpty && (cur.count >= 3 || len + t.count > 320) { chunks.append(cur); cur = []; len = 0 }
            cur.append(t); len += t.count
        }
        if !cur.isEmpty { chunks.append(cur) }
        let s = session
        for c in chunks {
            Task { [weak self] in
                let t0 = CFAbsoluteTimeGetCurrent()
                await TranslatorHub.shared.translate(c, context: context)
                LiveStats.shared.translateMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                guard let self, s == self.session, self.shownGen == self.gen else { return }
                self.overlay.update(blocks: self.renderNow())
            }
        }
    }
}
