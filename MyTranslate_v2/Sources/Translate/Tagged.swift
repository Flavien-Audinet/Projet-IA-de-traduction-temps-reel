import Foundation

/// Texte « balisé » envoyé par l'extension navigateur :
///   <g3>…</g3> = élément en ligne (lien, gras, italique…), <x4/> = élément vide (saut de ligne, image).
/// L'extension remplace ensuite, dans l'ordre, chaque morceau de texte entre deux balises :
/// la traduction renvoyée doit donc avoir EXACTEMENT la même suite de balises.
struct TaggedText: Equatable {
    var tags: [String]        // balises dans l'ordre
    var segments: [String]    // textes entre les balises (tags.count + 1 éléments)

    private static let regex = try! NSRegularExpression(pattern: "</?g\\d+>|<x\\d+/>")

    init(_ s: String) {
        tags = []; segments = []
        let ns = s as NSString
        var last = 0
        for m in Self.regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            segments.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            tags.append(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        segments.append(ns.substring(from: last))
    }

    var hasTags: Bool { !tags.isEmpty }

    var joined: String {
        var out = segments[0]
        for (i, t) in tags.enumerated() { out += t + segments[i + 1] }
        return out
    }

    /// Texte sans balises (pour la détection de langue, le contexte…).
    var plain: String { segments.joined() }
}

extension String {
    /// Remet les espaces de début / fin de `original` autour de `self` (les moteurs les suppriment).
    func keepingPadding(of original: String) -> String {
        let lead = original.prefix { $0.isWhitespace }, trail = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        return String(lead) + trimmingCharacters(in: .whitespaces) + trail
    }
}
