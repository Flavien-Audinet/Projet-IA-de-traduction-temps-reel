import CoreVideo
import Foundation

/// Image en niveaux de gris réduite (1 pixel sur `step`), pour estimer grossièrement le défilement.
/// La vérification fine se fait ensuite en pleine résolution (MotionTracker) : un simple échantillonnage suffit ici.
struct GrayFrame {
    let w: Int, h: Int, step: Int
    let data: [UInt8]

    init?(_ pb: CVPixelBuffer, step: Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let w = W / step, h = H / step
        guard w > 8, h > 8 else { return nil }
        var d = [UInt8](repeating: 0, count: w * h)
        let src = base.assumingMemoryBound(to: UInt8.self)
        d.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                let row = src + (y * step) * bpr
                let o = y * w
                for x in 0..<w {
                    let p = row + (x * step) * 4      // BGRA
                    out[o + x] = UInt8((Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8)
                }
            }
        }
        self.w = w; self.h = h; self.step = step; data = d
    }

    @inline(__always) func at(_ x: Int, _ y: Int) -> UInt8 { data[y * w + x] }

    /// Sommes cumulées : profil de colonnes sur n'importe quelle plage de lignes (et inversement) en O(w).
    struct Integrals {
        let w: Int, h: Int
        let colCum: [Int32]   // (h+1) × w : somme des lignes 0..<y pour chaque colonne
        let rowCum: [Int32]   // h × (w+1) : somme des colonnes 0..<x pour chaque ligne

        func cols(_ y0: Int, _ y1: Int) -> [Int32] {
            var out = [Int32](repeating: 0, count: w)
            let a = y0 * w, b = y1 * w
            for x in 0..<w { out[x] = colCum[b + x] &- colCum[a + x] }
            return out
        }
        func rows(_ x0: Int, _ x1: Int) -> [Int32] {
            var out = [Int32](repeating: 0, count: h)
            let stride = w + 1
            for y in 0..<h { out[y] = rowCum[y * stride + x1] &- rowCum[y * stride + x0] }
            return out
        }
    }

    func integrals() -> Integrals {
        var cc = [Int32](repeating: 0, count: (h + 1) * w)
        var rc = [Int32](repeating: 0, count: h * (w + 1))
        data.withUnsafeBufferPointer { d in
            cc.withUnsafeMutableBufferPointer { c in
                rc.withUnsafeMutableBufferPointer { r in
                    for y in 0..<h {
                        var acc: Int32 = 0
                        for x in 0..<w {
                            let v = Int32(d[y * w + x])
                            c[(y + 1) * w + x] = c[y * w + x] &+ v
                            acc &+= v
                            r[y * (w + 1) + x + 1] = acc
                        }
                    }
                }
            }
        }
        return Integrals(w: w, h: h, colCum: cc, rowCum: rc)
    }

    /// Profils de colonnes (somme des gris par colonne) sur trois bandes horizontales : haut, milieu, bas.
    /// Servent à mesurer les déplacements horizontaux (défilement latéral, fenêtre interne qui glisse…).
    func colProfiles() -> [[Int32]] {
        let cuts = [0, h / 4, h * 3 / 4, h]
        return (0..<3).map { band in
            var p = [Int32](repeating: 0, count: w)
            data.withUnsafeBufferPointer { d in
                for y in cuts[band]..<cuts[band + 1] {
                    let o = y * w
                    for x in 0..<w { p[x] &+= Int32(d[o + x]) }
                }
            }
            return p
        }
    }

    /// Profils de lignes (somme des gris par ligne) sur trois bandes verticales : gauche, centre, droite.
    /// Les barres latérales ou en-têtes fixes n'empêchent ainsi pas de mesurer le défilement du contenu.
    func rowProfiles() -> [[Int32]] {
        let cuts = [0, w / 4, w * 3 / 4, w]
        return (0..<3).map { band in
            var p = [Int32](repeating: 0, count: h)
            data.withUnsafeBufferPointer { d in
                for y in 0..<h {
                    var s: Int32 = 0
                    let o = y * w
                    for x in cuts[band]..<cuts[band + 1] { s &+= Int32(d[o + x]) }
                    p[y] = s
                }
            }
            return p
        }
    }
}

/// Lecture de la luminance pleine résolution dans une image BGRA verrouillée.
struct LumaReader {
    let base: UnsafePointer<UInt8>, bpr: Int, w: Int, h: Int
    init?(_ pb: CVPixelBuffer) {
        guard let b = CVPixelBufferGetBaseAddress(pb) else { return nil }
        base = UnsafePointer(b.assumingMemoryBound(to: UInt8.self))
        bpr = CVPixelBufferGetBytesPerRow(pb); w = CVPixelBufferGetWidth(pb); h = CVPixelBufferGetHeight(pb)
    }
    @inline(__always) func at(_ x: Int, _ y: Int) -> Int {
        let p = base + y * bpr + x * 4
        return (Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8
    }
}

/// Suit les blocs traduits d'une image à l'autre, en 2D, comme des points de repère :
///  1. décalages d'ensemble candidats (x et y) estimés sur l'image réduite : profils de lignes
///     (3 bandes verticales) et de colonnes (3 bandes horizontales) — barres latérales et en-têtes fixes compris ;
///  2. vérification de chaque bloc au pixel près, en pleine résolution, sur ~400 points de son texte et de son fond ;
///  3. si un bloc bouge seul (animation, carrousel…), recherche locale autour de la position prédite par sa vitesse.
/// Toutes les méthodes sont appelées sur la file de capture.
final class MotionTracker: @unchecked Sendable {
    private struct Signature {
        let xs: [Int32], ys: [Int32], vs: [Int16]   // pixels pleine résolution
        let minX: Int, maxX: Int, minY: Int, maxY: Int
    }

    private var refW = 0, refH = 0, step = 4
    private var refRows: [[Int32]] = [], refCols: [[Int32]] = []
    private var refInt: GrayFrame.Integrals?
    private var sigs: [String: Signature] = [:]
    private var last: [String: CGPoint] = [:], prev: [String: CGPoint] = [:]

    var hasReference: Bool { !sigs.isEmpty }

    /// Nouvelle référence = l'image sur laquelle l'OCR a tourné, avec les zones des blocs (pixels).
    func setReference(_ gray: GrayFrame, _ pb: CVPixelBuffer, blocks: [(id: String, rect: CGRect)]) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let px = LumaReader(pb) else { return }
        refW = px.w; refH = px.h; step = gray.step
        refRows = gray.rowProfiles()
        refCols = gray.colProfiles()
        refInt = gray.integrals()
        last = [:]; prev = [:]
        sigs = [:]
        for b in blocks {
            let x0 = max(0, Int(b.rect.minX)), x1 = min(px.w, Int(b.rect.maxX))
            let y0 = max(0, Int(b.rect.minY)), y1 = min(px.h, Int(b.rect.maxY))
            guard x1 - x0 > 4, y1 - y0 > 3 else { continue }
            let sx = max(1, (x1 - x0) / 160), sy = max(1, (y1 - y0) / 24)
            // Fond = gris médian du bloc ; encre = pixels qui s'en écartent nettement.
            var hist = [Int](repeating: 0, count: 256), n = 0
            for y in stride(from: y0, to: y1, by: sy) { for x in stride(from: x0, to: x1, by: sx) { hist[px.at(x, y)] += 1; n += 1 } }
            var acc = 0, bg = 0
            for v in 0..<256 { acc += hist[v]; if acc * 2 >= n { bg = v; break } }
            var ink: [(Int32, Int32, Int16)] = [], plain: [(Int32, Int32, Int16)] = []
            for y in stride(from: y0, to: y1, by: sy) {
                for x in stride(from: x0, to: x1, by: sx) {
                    let v = px.at(x, y)
                    if abs(v - bg) > 60 { ink.append((Int32(x), Int32(y), Int16(v))) }
                    else if abs(v - bg) < 12 { plain.append((Int32(x), Int32(y), Int16(v))) }
                }
            }
            guard ink.count >= 8 else { continue }
            let pick = Self.spread(ink, 260) + Self.spread(plain, 140)   // assez de fond pour ne pas confondre avec une zone de la même couleur que le texte
            sigs[b.id] = Signature(xs: pick.map(\.0), ys: pick.map(\.1), vs: pick.map(\.2),
                                   minX: x0, maxX: x1, minY: y0, maxY: y1)
        }
    }

    func clear() { sigs = [:]; last = [:]; prev = [:]; refRows = []; refCols = []; refInt = nil }

    /// Décalage (x, y) de chaque bloc en pixels, ou nil si son contenu a changé / a disparu.
    func track(_ gray: GrayFrame, _ pb: CVPixelBuffer) -> [String: CGPoint?] {
        guard !sigs.isEmpty, gray.step == step else { return [:] }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let px = LumaReader(pb), px.w == refW, px.h == refH else { return [:] }

        // Candidats par axe (unités réduites), puis chaque axe ré-estimé sur la zone qui se recouvre
        // une fois l'autre axe compensé : indispensable pour les déplacements en diagonale.
        var dys: Set<Int> = [0], dxs: Set<Int> = [0]
        let rows = gray.rowProfiles(), cols = gray.colProfiles()
        for b in 0..<3 {
            if b < refRows.count, let d = Self.bestShift(refRows[b], rows[b]) { dys.insert(d) }
            if b < refCols.count, let d = Self.bestShift(refCols[b], cols[b]) { dxs.insert(d) }
        }
        var pairs = Set<[Int]>()
        for dy in dys { for dx in dxs { pairs.insert([dx, dy]) } }
        if let ri = refInt {
            let ci = gray.integrals()
            let W = gray.w, H = gray.h
            // Zones immobiles (barre latérale, en-tête fixe) : colonnes / lignes identiques d'une image à l'autre.
            // On les exclut de l'estimation, sinon elles « tirent » le décalage vers zéro.
            func moving(_ a: [Int32], _ b: [Int32]) -> [Bool] {
                zip(a, b).map { x, y in abs(Int(x) - Int(y)) > max(8, Int(x) / 200) }
            }
            let movCols = moving(ri.cols(0, H), ci.cols(0, H)), movRows = moving(ri.rows(0, W), ci.rows(0, W))
            if let dx = Self.bestShift(ri.cols(0, H), ci.cols(0, H), mask: movCols) { dxs.insert(dx) }
            if let dy = Self.bestShift(ri.rows(0, W), ci.rows(0, W), mask: movRows) { dys.insert(dy) }
            for dy in dys where dy != 0 && abs(dy) < H * 7 / 10 {
                let y0 = max(0, -dy), y1 = min(H, H - dy)
                if let dx = Self.bestShift(ri.cols(y0, y1), ci.cols(y0 + dy, y1 + dy), mask: movCols) { pairs.insert([dx, dy]) }
            }
            for dx in dxs where dx != 0 && abs(dx) < W * 7 / 10 {
                let x0 = max(0, -dx), x1 = min(W, W - dx)
                if let dy = Self.bestShift(ri.rows(x0, x1), ci.rows(x0 + dx, x1 + dx), mask: movRows) { pairs.insert([dx, dy]) }
            }
            for dy in dys { for dx in dxs { pairs.insert([dx, dy]) } }
        }
        var out: [String: CGPoint?] = [:]
        let tune = Tuning.current
        let limit = tune.trackThreshold, radius = tune.localSearch
        for (id, sig) in sigs {
            var tests: [(Int, Int)] = pairs.map { ($0[0] * step, $0[1] * step) }
            if let l = last[id] {
                tests.append((Int(l.x), Int(l.y)))
                if tune.velocityPrediction, let p = prev[id] { tests.append((Int(2 * l.x - p.x), Int(2 * l.y - p.y))) }   // prédiction par la vitesse
            }
            var best = (dx: 0, dy: 0, e: Double.infinity)
            for (dx, dy) in tests {
                let e = Self.error(sig, px, dx: dx, dy: dy, limit: best.e)
                if e < best.e { best = (dx, dy, e) }
            }
            // Bloc qui bouge seul : recherche locale (grille grossière) autour de la meilleure hypothèse.
            if best.e >= limit, radius > 0 {
                let c = (best.dx, best.dy)
                for gy in stride(from: -radius, through: radius, by: 4) {
                    for gx in stride(from: -radius, through: radius, by: 4) {
                        let e = Self.error(sig, px, dx: c.0 + gx, dy: c.1 + gy, limit: best.e)
                        if e < best.e { best = (c.0 + gx, c.1 + gy, e) }
                    }
                }
            }
            // Affinage au pixel près, vertical puis horizontal.
            for _ in 0..<2 {
                let cy = best.dy
                for dy in (cy - step - 1)...(cy + step + 1) where dy != cy {
                    let e = Self.error(sig, px, dx: best.dx, dy: dy, limit: best.e)
                    if e < best.e { best = (best.dx, dy, e) }
                }
                let cx = best.dx
                for dx in (cx - step - 1)...(cx + step + 1) where dx != cx {
                    let e = Self.error(sig, px, dx: dx, dy: best.dy, limit: best.e)
                    if e < best.e { best = (dx, best.dy, e) }
                }
            }
            if best.e < limit {
                let p = CGPoint(x: best.dx, y: best.dy)
                if let l = last[id], l != p { prev[id] = l }
                last[id] = p
                out[id] = p
            } else {
                out[id] = .some(nil)
            }
        }
        return out
    }

    // MARK: Calculs

    /// Écart moyen entre la signature et l'image courante décalée de (dx, dy) (arrêt anticipé si > limit).
    private static func error(_ s: Signature, _ px: LumaReader, dx: Int, dy: Int, limit: Double) -> Double {
        guard s.minY + dy >= 0, s.maxY + dy <= px.h, s.minX + dx >= 0, s.maxX + dx <= px.w else { return .infinity }
        let n = s.xs.count
        let cap = limit.isFinite ? Int(limit * Double(n)) : Int.max
        var sum = 0
        for i in 0..<n {
            sum += abs(px.at(Int(s.xs[i]) + dx, Int(s.ys[i]) + dy) - Int(s.vs[i]))
            if sum > cap { return .infinity }
        }
        return Double(sum) / Double(max(1, n))
    }

    /// Meilleur décalage entre deux profils (unités de l'image réduite).
    /// `mask` (facultatif) : indices de référence à prendre en compte (zones qui bougent).
    private static func bestShift(_ a: [Int32], _ b: [Int32], mask: [Bool]? = nil) -> Int? {
        let h = a.count
        guard h > 16, b.count == h else { return nil }
        if let mask, mask.filter({ $0 }).count < h / 10 { return nil }     // presque rien ne bouge
        let maxShift = h * 7 / 10, minOverlap = h * 3 / 10
        var best = (d: 0, e: Int64.max)
        let m = mask ?? []
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                m.withUnsafeBufferPointer { pm in
                    let useMask = !pm.isEmpty
                    for d in -maxShift...maxShift {
                        let y0 = max(0, -d), y1 = min(h, h - d)
                        guard y1 - y0 >= minOverlap else { continue }
                        var e: Int64 = 0, n: Int64 = 0
                        var y = y0
                        while y < y1 {
                            if !useMask || pm[y] { e += Int64(abs(pa[y] - pb[y + d])); n += 1 }
                            y += 2
                        }
                        guard n >= Int64(minOverlap / 6) else { continue }
                        e = e * 1000 / n
                        if e < best.e { best = (d, e) }
                    }
                }
            }
        }
        return best.e == .max ? nil : best.d
    }

    private static func spread<T>(_ a: [T], _ n: Int) -> [T] {
        guard a.count > n else { return a }
        let step = Double(a.count) / Double(n)
        return (0..<n).map { a[Int(Double($0) * step)] }
    }
}
