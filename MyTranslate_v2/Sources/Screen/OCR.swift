import Vision
import NaturalLanguage
import CoreVideo

/// Une ligne de texte reconnue, en pixels de l'image (origine en haut à gauche).
struct OCRLine {
    let text: String
    let rect: CGRect
    let confidence: Float
}

enum TextAlign { case leading, center }

/// Un bloc = plusieurs lignes qui forment un même paragraphe (traduit d'un seul tenant
/// pour garder le sens des phrases coupées sur plusieurs lignes).
struct TextBlock {
    var lines: [OCRLine]
    var rect: CGRect
    var text: String
    var lineHeight: CGFloat      // hauteur moyenne d'une ligne (px)
    var linePitch: CGFloat       // distance moyenne entre le haut de deux lignes (px)
    var align: TextAlign
}

enum OCR {
    /// Reconnaît le texte d'une image. `fast` = moins précis mais ~4× plus rapide.
    static func recognize(_ pb: CVPixelBuffer, languages: [String], fast: Bool) -> [OCRLine] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = fast ? .fast : .accurate
        req.recognitionLanguages = languages
        req.usesLanguageCorrection = !fast && Tuning.current.languageCorrection
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        let W = CGFloat(CVPixelBufferGetWidth(pb)), H = CGFloat(CVPixelBufferGetHeight(pb))
        return (req.results ?? []).compactMap { obs in
            guard let c = obs.topCandidates(1).first, c.confidence > 0.3 else { return nil }
            let s = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            let bb = obs.boundingBox
            return OCRLine(text: s,
                           rect: CGRect(x: bb.minX * W, y: (1 - bb.maxY) * H, width: bb.width * W, height: bb.height * H),
                           confidence: c.confidence)
        }
    }

    /// Regroupe les lignes en paragraphes : lignes proches verticalement, de hauteur
    /// semblable et alignées (à gauche ou au centre).
    static func group(_ lines: [OCRLine]) -> [TextBlock] {
        let sorted = lines.sorted { $0.rect.minY < $1.rect.minY }
        var blocks: [[OCRLine]] = []

        for line in sorted {
            let h = line.rect.height
            var bestIndex: Int?
            var bestGap = CGFloat.infinity
            for (i, b) in blocks.enumerated() {
                guard let last = b.last else { continue }
                let lh = last.rect.height
                let ratio = h / lh
                guard ratio > 0.75, ratio < 1.33 else { continue }
                let gap = line.rect.minY - last.rect.maxY
                guard gap > -0.35 * lh, gap < 0.9 * lh else { continue }
                let leftAligned = abs(line.rect.minX - last.rect.minX) < 1.2 * lh
                let centered = abs(line.rect.midX - last.rect.midX) < 1.2 * lh
                let overlap = min(line.rect.maxX, last.rect.maxX) - max(line.rect.minX, last.rect.minX)
                guard leftAligned || centered, overlap > 0.3 * min(line.rect.width, last.rect.width) else { continue }
                if gap < bestGap { bestGap = gap; bestIndex = i }
            }
            if let i = bestIndex { blocks[i].append(line) } else { blocks.append([line]) }
        }

        return blocks.map(makeBlock)
    }

    /// Construit un bloc à partir de ses lignes (dans l'ordre de lecture).
    static func makeBlock(_ ls: [OCRLine]) -> TextBlock {
            var rect = ls[0].rect
            ls.dropFirst().forEach { rect = rect.union($0.rect) }
            let lh = ls.map(\.rect.height).reduce(0, +) / CGFloat(ls.count)
            var pitch = lh * 1.25
            if ls.count > 1 {
                pitch = (ls.last!.rect.minY - ls.first!.rect.minY) / CGFloat(ls.count - 1)
            }
            let lefts = ls.map(\.rect.minX), mids = ls.map(\.rect.midX)
            let spread = (lefts.max()! - lefts.min()!), midSpread = (mids.max()! - mids.min()!)
            let align: TextAlign = ls.count > 1 && midSpread < spread * 0.5 && spread > lh ? .center : .leading
            return TextBlock(lines: ls, rect: rect, text: joinLines(ls.map(\.text)), lineHeight: lh, linePitch: pitch, align: align)
    }

    /// Recolle les lignes en gérant les mots coupés en fin de ligne (« exam-\nple »).
    static func joinLines(_ lines: [String]) -> String {
        var out = ""
        for l in lines {
            if out.hasSuffix("-"), let f = l.first, f.isLowercase {
                out.removeLast()
                out += l
            } else {
                out += out.isEmpty ? l : " " + l
            }
        }
        return out
    }
}

/// Détection de langue d'un bloc (contrainte au couple FR/EN).
enum LanguageGuess {
    /// Vrai si le texte semble être dans la langue source (et mérite d'être traduit).
    static func isSource(_ text: String, source: NLLanguage, target: NLLanguage) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 2 else { return false }                       // nombres, symboles, heures…
        if text.hasPrefix("http") || text.contains("@") && !text.contains(" ") { return false }  // URL, e-mail
        let r = NLLanguageRecognizer()
        r.languageConstraints = [source, target]
        r.processString(text)
        let h = r.languageHypotheses(withMaximum: 2)
        let ps = h[source] ?? 0, pt = h[target] ?? 0
        // Les mots isolés sont ambigus (« Information », « Message ») : on traduit en cas de doute.
        return letters < 12 ? ps >= pt * 0.8 : ps > pt
    }
}
