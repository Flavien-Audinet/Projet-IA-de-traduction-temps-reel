import Foundation
import CoreVideo
import ImageIO
import CryptoKit
import SwiftUI

/// OCR + traduction d'une image envoyée par l'extension (texte dans une image, un canvas…).
/// Même chaîne que pour l'écran ; renvoie les blocs en pixels de l'image, avec leur style.
@MainActor
enum ImageOCR {
    private static var cache: [String: [String: Any]] = [:]

    static func run(_ data: Data, context: String?) async -> [String: Any] {
        let hub = TranslatorHub.shared
        let dir = hub.direction
        let key = "\(dir.rawValue)|\(hub.engine.rawValue)|" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let c = cache[key] { return c }

        // Décodage + OCR + style hors du fil principal.
        let analyzed: (w: Int, h: Int, blocks: [AnalyzedBlock])? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  img.width >= 40, img.height >= 16,
                  let pb = PixelBuffers.make(from: img) else { return nil }
            return (img.width, img.height, ScreenPipeline.analyze(pb, direction: dir, fast: false))
        }.value
        guard let analyzed else { return ["error": "image illisible"] }

        let texts = analyzed.blocks.map(\.block.text)
        let tr = texts.isEmpty ? [:] : await hub.translate(texts, context: context)
        let canvas = CGSize(width: analyzed.w, height: analyzed.h)
        let blocks = ScreenPipeline.render(analyzed.blocks, translations: tr, scale: 1, canvas: canvas)
        func hex(_ c: RGB) -> String { String(format: "#%02x%02x%02x", Int(c.r), Int(c.g), Int(c.b)) }
        let weights: [Font.Weight: Int] = [.regular: 400, .medium: 500, .semibold: 600, .bold: 700]
        let out: [String: Any] = [
            "width": analyzed.w, "height": analyzed.h,
            "blocks": blocks.map { b -> [String: Any] in
                ["x": b.rect.minX, "y": b.rect.minY, "w": b.rect.width, "h": b.rect.height,
                 "text": b.translation, "fontSize": b.fontSize, "lineSpacing": b.lineSpacing,
                 "weight": weights[b.weight] ?? 400, "serif": b.serif, "underline": b.underline,
                 "color": hex(b.text), "background": hex(b.background), "opaque": b.opaqueBackground,
                 "align": b.align == .center ? "center" : "left", "singleLine": b.singleLine,
                 "maxWidth": b.maxWidth, "maxHeight": b.maxHeight, "topShift": b.topShift]
            },
        ]
        if !blocks.isEmpty || texts.isEmpty { cache[key] = out }   // pas de cache si les traductions manquent
        if cache.count > 500 { cache.removeAll() }
        return out
    }
}

/// Création d'un CVPixelBuffer BGRA à partir d'une image (OCR d'images, mode test).
enum PixelBuffers {
    static func make(from img: CGImage) -> CVPixelBuffer? {
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
        // Fond blanc sous les images transparentes (PNG) : l'OCR et les couleurs restent cohérentes.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return pb
    }
}
