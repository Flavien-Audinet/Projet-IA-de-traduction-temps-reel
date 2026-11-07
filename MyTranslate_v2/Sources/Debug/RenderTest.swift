import AppKit
import SwiftUI
import CoreVideo
import ImageIO

/// Mode test : applique toute la chaîne (OCR → style → traduction → surimpression) à une image
/// et écrit le résultat dans un PNG. Utile pour régler le rendu sans autorisation d'écran.
///   MyTranslate --render entree.png sortie.png [--engine local|fake] [--dir enToFr|frToEn] [--fast]
@MainActor
enum RenderTest {
    /// Test du suivi : on simule un déplacement (dx, dy) px de la zone à droite de `fixedX` (barre latérale fixe).
    ///   MyTranslate --track-test capture.png dy fixedX [dx]
    static func trackTest(_ args: [String]) {
        let dx = args.count >= 4 ? Int(args[3]) ?? 0 : 0
        guard args.count >= 3, let dy = Int(args[1]), let fixedX = Int(args[2]),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[0]) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let a = pixelBuffer(from: img), let b = pixelBuffer(from: img) else { print("usage: --track-test img dy fixedX"); exit(64) }
        // b = a avec la zone de droite décalée vers le haut de dy (défilement vers le bas de la page)
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, [])
        let W = CVPixelBufferGetWidth(a), H = CVPixelBufferGetHeight(a), bpr = CVPixelBufferGetBytesPerRow(a)
        let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<H {
            let sy = y + dy
            for x in fixedX..<W {
                let sx = x + dx
                let inside = sy >= 0 && sy < H && sx >= fixedX && sx < W
                for c in 0..<4 { pb[y * bpr + x * 4 + c] = inside ? pa[sy * bpr + sx * 4 + c] : 255 }
            }
        }
        CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, [])

        let analyzed = ScreenPipeline.analyze(a, direction: .enToFr, fast: false)
        let tracker = MotionTracker()
        guard let ga = GrayFrame(a, step: 4), let gb = GrayFrame(b, step: 4) else { exit(1) }
        tracker.setReference(ga, a, blocks: analyzed.map { (id: $0.block.text, rect: $0.block.rect) })
        let t0 = CFAbsoluteTimeGetCurrent()
        var offs: [String: CGPoint?] = [:]
        for _ in 0..<10 { offs = tracker.track(gb, b) }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 100
        var ok = 0, bad = 0
        for blk in analyzed {
            let r = blk.block.rect
            let fixed = r.maxX <= CGFloat(fixedX)
            let gone = !fixed && (r.minY - CGFloat(dy) < 0 || r.minX - CGFloat(dx) < CGFloat(fixedX) || r.maxX - CGFloat(dx) > CGFloat(W))
            let expected: CGPoint? = gone ? nil : (fixed ? .zero : CGPoint(x: -dx, y: -dy))
            let got = offs[blk.block.text] ?? .zero
            let good: Bool
            if let e = expected, let g = got { good = abs(e.x - g.x) <= 2 && abs(e.y - g.y) <= 2 } else { good = (expected == nil && got == nil) }
            good ? (ok += 1) : (bad += 1)
            print(String(format: "  %@ attendu %@ obtenu %@  « %@ »", good ? "✓" : "✗",
                         expected.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "masqué", got.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "masqué",
                         String(blk.block.text.prefix(40))))
        }
        print(String(format: "déplacement (%d, %d) px : %d/%d corrects, suivi %.1f ms par image", dx, dy, ok, ok + bad, ms))
        exit(bad == 0 ? 0 : 1)
    }

    static func run(_ args: [String]) {
        guard args.count >= 2 else { print("usage: --render entree.png sortie.png [--engine local|fake]"); exit(64) }
        let input = URL(fileURLWithPath: args[0]), output = URL(fileURLWithPath: args[1])
        func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let engine = opt("--engine") ?? "local"
        let dir = Direction(rawValue: opt("--dir") ?? "") ?? .enToFr
        let fast = args.contains("--fast")

        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let pb = pixelBuffer(from: img) else { print("image illisible"); exit(1) }

        Task { @MainActor in
            let t0 = CFAbsoluteTimeGetCurrent()
            let analyzed = ScreenPipeline.analyze(pb, direction: dir, fast: fast)
            let ocrMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            print("OCR + style : \(ocrMs) ms, \(analyzed.count) blocs à traduire")
            if args.contains("--lines") {
                // Calibration : mesures brutes de chaque ligne.
                for a in analyzed { for (l, m) in zip(a.block.lines, a.metrics) {
                    print(String(format: "LINE xh=%.0f stem=%.1f ratio=%.3f serif=%.2f | %@",
                                 m.xHeight, m.stem, m.weightRatio, m.serifScore, l.text))
                } }
            }
            for a in analyzed {
                let s = a.style
                print(String(format: "  [%4.0f,%4.0f %4.0f×%3.0f] taille %.1f px · graisse %@ · texte #%02X%02X%02X · fond #%02X%02X%02X%@ · « %@ »",
                             a.block.rect.minX, a.block.rect.minY, a.block.rect.width, a.block.rect.height, s.fontSize,
                             ["normal", "medium", "semi-gras", "gras"][s.weightStep] + (s.serif ? " serif" : ""),
                             Int(s.text.r), Int(s.text.g), Int(s.text.b), Int(s.background.r), Int(s.background.g), Int(s.background.b),
                             s.uniformBackground ? "" : " (fond varié)", String(a.block.text.prefix(70))))
            }

            let texts = analyzed.map(\.block.text)
            var tr: [String: String] = [:]
            let t1 = CFAbsoluteTimeGetCurrent()
            if engine == "fake" {
                for t in texts { tr[t] = "«" + t + "»" }
            } else {
                do {
                    let out = try await LocalLLM.shared.translate(texts, direction: dir, context: texts.prefix(8).joined(separator: " · "))
                    for (a, b) in zip(texts, out) { tr[a] = b }
                } catch {
                    print("traduction impossible : \(error.localizedDescription)")
                    exit(2)
                }
            }
            print("Traduction : \(Int((CFAbsoluteTimeGetCurrent() - t1) * 1000)) ms")
            for t in texts { print("  « \(t.prefix(50)) » → « \((tr[t] ?? "∅").prefix(60)) »") }

            let model = OverlayModel()
            let w = CGFloat(img.width), h = CGFloat(img.height)
            model.blocks = ScreenPipeline.render(analyzed, translations: tr, scale: 1, canvas: CGSize(width: w, height: h))
            let view = ZStack(alignment: .topLeading) {
                Image(decorative: img, scale: 1)
                OverlayView(model: model)
            }
            .frame(width: w, height: h)
            let r = ImageRenderer(content: view)
            r.scale = 1
            guard let out = r.cgImage,
                  let dest = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
                print("rendu impossible"); exit(3)
            }
            CGImageDestinationAddImage(dest, out, nil)
            CGImageDestinationFinalize(dest)
            print("→ \(output.path)")
            exit(0)
        }
    }

    static func pixelBuffer(from img: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, img.width, img.height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: img.width, height: img.height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return pb
    }
}
