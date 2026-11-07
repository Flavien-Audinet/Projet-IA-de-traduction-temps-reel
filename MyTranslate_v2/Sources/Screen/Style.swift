import CoreVideo
import CoreGraphics
import SwiftUI

struct RGB: Equatable {
    var r: Double, g: Double, b: Double   // 0…255

    func distance(_ o: RGB) -> Double {
        let dr = r - o.r, dg = g - o.g, db = b - o.b
        return (dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11).squareRoot()   // pondéré par la perception
    }
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var color: Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255) }
}

/// Mesures typographiques d'une ligne, prises directement dans les pixels.
struct LineMetrics {
    var xHeight: CGFloat        // hauteur des minuscules (ou des capitales si `caps`), px
    var baseline: CGFloat       // position de la ligne de base depuis le haut de la boîte OCR, px
    var stem: CGFloat           // épaisseur des fûts verticaux, px
    var serifScore: Double      // élargissement des traits au pied des lettres (> ~1,35 : empattements)
    var caps: Bool
    var ink: RGB
    var underline: Bool         // trait continu sous la ligne de base (liens…)

    var weightRatio: Double { Double(stem / max(1, xHeight)) }
}

/// Style visuel estimé d'un bloc de texte.
struct TextStyle {
    var text: RGB
    var background: RGB
    var fontSize: CGFloat         // px
    var weight: Font.Weight
    var weightStep: Int           // 0 normal, 1 medium, 2 semi-gras, 3 gras
    var serif: Bool
    var underline: Bool
    var uniformBackground: Bool   // fond uni ? (sinon : photo, dégradé… → fond semi-transparent)
    var baseline: CGFloat         // ligne de base de la 1re ligne depuis le haut du bloc, px
    var freeRight: CGFloat        // espace libre (même fond) à droite / à gauche / en dessous, px
    var freeLeft: CGFloat
    var freeBelow: CGFloat
}

/// Accès en lecture aux pixels BGRA d'une image capturée (le buffer doit être verrouillé).
struct PixelReader {
    let base: UnsafeRawPointer
    let width: Int, height: Int, bytesPerRow: Int

    init?(_ pb: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
              let b = CVPixelBufferGetBaseAddress(pb) else { return nil }
        base = UnsafeRawPointer(b)
        width = CVPixelBufferGetWidth(pb)
        height = CVPixelBufferGetHeight(pb)
        bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
    }

    @inline(__always) func pixel(_ x: Int, _ y: Int) -> RGB {
        let p = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return RGB(r: Double(p[2]), g: Double(p[1]), b: Double(p[0]))
    }

    @inline(__always) func clamped(_ x: Int, _ y: Int) -> RGB {
        pixel(min(max(x, 0), width - 1), min(max(y, 0), height - 1))
    }
}

enum StyleEstimator {
    // Seuils calibrés sur une image de référence (SF Pro, Helvetica, Georgia, Times ; 12 à 28 pt en Retina) :
    //   fût / hauteur d'x : normal 0,18–0,21 · medium 0,23–0,25 · semi-gras 0,24–0,27 · gras 0,29–0,36
    //   contraste épais/fin : linéales normales 1,0–1,5 (grasses jusqu'à 1,7) · Georgia/Times 1,5–3,5
    //   hauteur d'x / taille : SF et Helvetica 0,535 · Georgia 0,50 · Times 0,46
    static var weightThresholds: [Double] = [0.222, 0.240, 0.280]
    static var serifThreshold = (regular: 1.58, bold: 1.9)
    static let xHeightRatio = (sans: 0.535, serif: 0.49, caps: 0.71)

    static func step(_ ratio: Double) -> Int { weightThresholds.filter { ratio >= $0 }.count }
    static func weight(_ step: Int) -> Font.Weight { [.regular, .medium, .semibold, .bold][min(3, max(0, step))] }

    // MARK: Couleurs

    static func background(around lines: [OCRLine], _ px: PixelReader) -> (RGB, Double) {
        var ring: [RGB] = []
        for line in lines {
            let r = line.rect.insetBy(dx: -3, dy: -3)
            let step = max(1, Int(r.width / 60))
            for x in stride(from: Int(r.minX), to: Int(r.maxX), by: step) {
                ring.append(px.clamped(x, Int(r.minY)))
                ring.append(px.clamped(x, Int(r.maxY)))
            }
            for y in stride(from: Int(r.minY), to: Int(r.maxY), by: max(1, Int(r.height / 8))) {
                ring.append(px.clamped(Int(r.minX), y))
                ring.append(px.clamped(Int(r.maxX), y))
            }
        }
        let bg = median(ring)
        let spread = ring.isEmpty ? 0 : ring.map { $0.distance(bg) }.sorted()[ring.count * 3 / 4]
        return (bg, spread)
    }

    static func inkColor(_ rect: CGRect, bg: RGB, _ px: PixelReader) -> RGB {
        var d: [(Double, RGB)] = []
        let sx = max(1, Int(rect.width / 120)), sy = max(1, Int(rect.height / 16))
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: sy) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: sx) {
                let c = px.clamped(x, y)
                d.append((c.distance(bg), c))
            }
        }
        d.sort { $0.0 > $1.0 }
        guard let maxD = d.first?.0, maxD >= 25 else {
            return bg.luminance > 128 ? RGB(r: 20, g: 20, b: 20) : RGB(r: 240, g: 240, b: 240)
        }
        return average(d.prefix(max(1, d.count / 12)).map(\.1))
    }

    // MARK: Mesures typographiques d'une ligne

    static func measure(_ line: OCRLine, bg: RGB, _ px: PixelReader) -> LineMetrics? {
        let ink = inkColor(line.rect, bg: bg, px)
        let thr = max(18, ink.distance(bg) * 0.5)
        // Vision rogne parfois les hampes : on élargit la zone verticalement.
        let x0 = max(0, Int(line.rect.minX)), x1 = min(px.width, Int(line.rect.maxX))
        let y0 = max(0, Int(line.rect.minY - line.rect.height * 0.15)), y1 = min(px.height, Int(line.rect.maxY + line.rect.height * 0.15))
        let w = x1 - x0, h = y1 - y0
        guard w > 4, h > 4 else { return nil }

        var mask = [Bool](repeating: false, count: w * h)
        var rows = [Int](repeating: 0, count: h)
        let xs = w > 1600 ? 2 : 1
        for y in 0..<h {
            var n = 0
            for x in stride(from: 0, to: w, by: xs) where px.pixel(x0 + x, y0 + y).distance(bg) > thr {
                mask[y * w + x] = true
                n += 1
            }
            rows[y] = n
        }
        guard let maxRow = rows.max(), maxRow > 0 else { return nil }

        // Bande des minuscules : plus longue suite de lignes de pixels bien remplies.
        let t = Int(Double(maxRow) * 0.45)
        var best = (0, 0), cur = 0, start = 0
        for y in 0..<h {
            if rows[y] >= t { if cur == 0 { start = y }; cur += 1; if cur > best.1 { best = (start, cur) } } else { cur = 0 }
        }
        let bandTop = best.0, xh = best.1
        guard xh >= 3 else { return nil }
        let bandBottom = bandTop + xh

        // Épaisseur des fûts : longueur médiane des segments horizontaux au milieu de la bande.
        var runs: [Int] = []
        let mid0 = bandTop + xh * 3 / 10, mid1 = max(mid0 + 1, bandBottom - xh * 3 / 10)
        for y in mid0..<mid1 {
            var run = 0
            for x in stride(from: 0, to: w, by: xs) {
                if mask[y * w + x] { run += xs } else if run > 0 { runs.append(run); run = 0 }
            }
            if run > 0 { runs.append(run) }
        }
        runs.sort()
        guard !runs.isEmpty else { return nil }
        // Moyenne de l'intervalle interquartile : précision au sous-pixel (les fûts ne font que 2 à 5 px).
        let iq = runs[(runs.count / 4)...(max(runs.count / 4, runs.count * 3 / 4 - 1))]
        let stem = CGFloat(Double(iq.reduce(0, +)) / Double(iq.count))

        // Traits fins : épaisseur verticale des traits horizontaux (haut des « o », barre des « e »…).
        var vruns: [Int] = []
        for x in stride(from: 0, to: w, by: xs) {
            var run = 0
            for y in bandTop..<bandBottom {
                if mask[y * w + x] { run += 1 } else if run > 0 { vruns.append(run); run = 0 }
            }
            if run > 0 { vruns.append(run) }
        }
        let thinRuns = vruns.filter { Double($0) < Double(xh) * 0.45 }.sorted()
        let thin = thinRuns.isEmpty ? stem : CGFloat(thinRuns[thinRuns.count * 3 / 10])

        // Empattements : au pied des lettres, les traits s'élargissent (serif) ou non (sans).
        func meanRun(_ y: Int) -> Double {
            guard y >= 0, y < h else { return 0 }
            var rs: [Int] = [], run = 0
            for x in stride(from: 0, to: w, by: xs) {
                if mask[y * w + x] { run += xs } else if run > 0 { rs.append(run); run = 0 }
            }
            if run > 0 { rs.append(run) }
            let small = rs.filter { CGFloat($0) < CGFloat(xh) * 0.9 }   // on ignore les barres horizontales
            return small.isEmpty ? 0 : Double(small.reduce(0, +)) / Double(small.count)
        }
        _ = meanRun
        // Contraste épais / fin : ~1 pour les linéales (SF, Helvetica), nettement plus pour Georgia, Times…
        let serifScore = Double(stem / max(0.5, thin))

        // Soulignement : une ligne de pixels presque pleine (sur la largeur du texte) juste sous la ligne de base.
        var minX = w, maxX = 0
        for y in bandTop..<bandBottom { for x in stride(from: 0, to: w, by: xs) where mask[y * w + x] { minX = min(minX, x); maxX = max(maxX, x) } }
        var underline = false
        if maxX > minX {
            let need = Int(Double((maxX - minX) / xs) * 0.7)
            for y in bandBottom..<min(h, bandBottom + Int(Double(xh) * 0.7) + 2) {
                var n = 0
                for x in stride(from: minX, through: maxX, by: xs) where mask[y * w + x] { n += 1 }
                if n >= need { underline = true; break }
            }
        }

        let letters = line.text.filter(\.isLetter)
        let caps = letters.count >= 2 && Double(letters.filter(\.isUppercase).count) / Double(letters.count) > 0.7

        return LineMetrics(xHeight: CGFloat(xh), baseline: CGFloat(y0 + bandBottom) - line.rect.minY,
                           stem: stem, serifScore: serifScore, caps: caps, ink: ink, underline: underline)
    }

    // MARK: Espace libre autour d'un bloc (même couleur de fond)

    static func free(_ rect: CGRect, bg: RGB, _ px: PixelReader) -> (left: CGFloat, right: CGFloat, below: CGFloat) {
        let tol = 10.0   // les captures d'écran sont propres : même une teinte pâle (carte jaune) doit arrêter le balayage
        func scanX(_ y: Int, from x: Int, dir: Int, limit: Int) -> Int {
            var n = 0, xx = x
            while n < limit, xx >= 0, xx < px.width, px.pixel(xx, y).distance(bg) < tol { n += 1; xx += dir }
            return n
        }
        let limitX = Int(rect.width * 2.5) + 40
        let ys = [rect.minY + rect.height * 0.25, rect.midY, rect.maxY - rect.height * 0.25].map { min(max(0, Int($0)), px.height - 1) }
        let right = ys.map { scanX($0, from: Int(rect.maxX) + 2, dir: 1, limit: limitX) }.min() ?? 0
        let left = ys.map { scanX($0, from: Int(rect.minX) - 2, dir: -1, limit: limitX) }.min() ?? 0

        let limitY = Int(rect.height * 1.5) + 20
        var below = Int.max
        for f in stride(from: 0.05, through: 0.95, by: 0.15) {
            let x = min(max(0, Int(rect.minX + rect.width * f)), px.width - 1)
            var n = 0, y = Int(rect.maxY) + 2
            while n < limitY, y < px.height, px.pixel(x, y).distance(bg) < tol { n += 1; y += 1 }
            below = min(below, n)
        }
        // marge de sécurité pour ne pas coller aux éléments voisins
        return (CGFloat(max(0, left - 6)), CGFloat(max(0, right - 6)), CGFloat(max(0, (below == .max ? 0 : below) - 6)))
    }

    // MARK: Style d'un bloc

    static func estimate(_ block: TextBlock, metrics: [LineMetrics], pixels px: PixelReader) -> TextStyle {
        let (bg, spread) = background(around: block.lines, px)
        let ms = metrics
        let text = ms.isEmpty ? inkColor(block.rect, bg: bg, px) : average(ms.map(\.ink))
        let ratio = ms.isEmpty ? 0.2 : medianD(ms.map(\.weightRatio))
        let stepW = step(ratio)
        // Les linéales grasses ont naturellement plus de contraste : seuil plus haut pour le gras.
        let serif = !ms.isEmpty && medianD(ms.map(\.serifScore)) >= (stepW >= 3 ? serifThreshold.bold : serifThreshold.regular)
        var size = block.lineHeight / 1.2
        if !ms.isEmpty {
            let caps = ms.filter(\.caps).count * 2 > ms.count
            let k = caps ? xHeightRatio.caps : serif ? xHeightRatio.serif : xHeightRatio.sans
            size = CGFloat(medianD(ms.map { Double($0.xHeight) })) / CGFloat(k)
        }
        let f = free(block.rect, bg: bg, px)
        return TextStyle(text: text, background: bg, fontSize: size, weight: weight(stepW), weightStep: stepW,
                         serif: serif, underline: !ms.isEmpty && ms.filter(\.underline).count * 2 > ms.count,
                         uniformBackground: spread < 18,
                         baseline: ms.first?.baseline ?? block.lineHeight * 0.8,
                         freeRight: f.right, freeLeft: f.left, freeBelow: f.below)
    }

    // MARK: Utilitaires

    private static func median(_ c: [RGB]) -> RGB {
        guard !c.isEmpty else { return RGB(r: 255, g: 255, b: 255) }
        func med(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        return RGB(r: med(c.map(\.r)), g: med(c.map(\.g)), b: med(c.map(\.b)))
    }

    static func medianD(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }

    private static func average(_ c: [RGB]) -> RGB {
        guard !c.isEmpty else { return RGB(r: 0, g: 0, b: 0) }
        let n = Double(c.count)
        return RGB(r: c.map(\.r).reduce(0, +) / n, g: c.map(\.g).reduce(0, +) / n, b: c.map(\.b).reduce(0, +) / n)
    }
}
