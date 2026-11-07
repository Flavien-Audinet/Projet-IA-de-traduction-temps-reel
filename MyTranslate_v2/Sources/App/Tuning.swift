import Foundation

enum OCRMode: String, CaseIterable, Identifiable, Codable {
    case auto, accurate, fast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (rapide en mouvement, précis à l'arrêt)"
        case .accurate: return "Toujours précis (~550 ms)"
        case .fast: return "Toujours rapide (~50 ms)"
        }
    }
}

enum Overflow: String, CaseIterable, Identifiable, Codable {
    case shrink, overflow, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shrink: return "Réduire la police"
        case .overflow: return "Déborder (même taille)"
        case .both: return "Déborder, puis réduire si nécessaire"
        }
    }
}

enum FontChoice: String, CaseIterable, Identifiable, Codable {
    case auto, sans, serif
    var id: String { rawValue }
    var label: String {
        switch self { case .auto: return "Détectée"; case .sans: return "Toujours sans-serif"; case .serif: return "Toujours serif" }
    }
}

/// Tous les réglages fins de la traduction d'écran. Copiable et lisible depuis n'importe quelle file
/// (capture, OCR) via `Tuning.current`, modifiable depuis la fenêtre Réglages.
struct Tuning: Codable, Equatable {
    // Capture & suivi
    var fps: Double = 60
    var tracking = true
    var trackStep = 0                 // 0 = auto (4, ou 6 pour les très grandes zones)
    var trackThreshold = 20.0         // écart moyen maximal pour qu'un bloc soit considéré « retrouvé »
    var localSearch = 16              // rayon (px) de la recherche locale pour un bloc qui bouge seul
    var velocityPrediction = true
    var anticipationMs = 12.0         // décalage projeté en avant (compense le retard capture → affichage)
    var hideOnChange = true           // masquer un bloc dont le contenu a changé (sinon : dernière position)
    // OCR
    var ocrMode: OCRMode = .auto
    var settleMs = 120.0
    var maxOCRIntervalMs = 700.0
    var minDirtyPercent = 0.2
    var languageCorrection = true
    // Rendu
    var fontScale = 1.0
    var overflow: Overflow = .both
    var minShrink = 0.8
    var photoOpacity = 0.9
    var font: FontChoice = .auto
    var weightShift = 0               // -1, 0, +1 cran
    var debugBoxes = false
    var hud = false
    // Traduction
    var webVisibleEngine: String = "opus"     // moteur pour ce qui est visible dans les pages web
    var webBackgroundEngine: String = "opus"  // moteur pour le reste de la page
    var opusGPU = true
    var maxTagsWhole = 10             // au-delà, une unité balisée est traduite morceau par morceau d'emblée
    // Doublage (« Écouter traduit »)
    var dubSource = "web"             // web : vidéos Firefox, préparées à l'avance · system : son d'une app, en direct
    var dubCookies = false            // yt-dlp : cookies de Firefox (vidéos réservées aux abonnés / âge)
    var dubApp = "org.mozilla.firefox"
    var dubDelay = 7.0                // retard global D (s) : son ET vidéo (mesuré : 7 s suffit en mode simultané)
    var dubMode = "simultaneous"      // simultaneous | sentence
    var dubVoice = "chatterbox"       // chatterbox (meilleur français) | qwen3 (plus rapide)
    var dubGain = 1.0, bgGain = 1.0, origGain = 0.0
    var dubWorkers = 2                // ateliers de voix en parallèle
    var videoOffsetMs = 0.0           // réglage fin de la synchro image / son (extension)
    var dubPreload = true             // moteur de doublage chargé dès l'ouverture de l'app (⌃⌥A instantané)
    var dubRoom = 0.3                 // intégration acoustique (petite réverbération + aigus adoucis)

    static let defaults = Tuning()

    // MARK: Stockage + accès concurrent

    private static let lock = NSLock()
    private static var storage: Tuning = load()

    static var current: Tuning {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set {
            lock.lock(); storage = newValue; lock.unlock()
            if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: "tuning") }
        }
    }

    /// Lecture tolérante : les réglages enregistrés sont fusionnés sur les valeurs par défaut,
    /// pour qu'un nouveau réglage (mise à jour de l'app) n'efface pas ceux déjà choisis.
    private static func load() -> Tuning {
        guard let d = UserDefaults.standard.data(forKey: "tuning"),
              let saved = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let defData = try? JSONEncoder().encode(Tuning()),
              var merged = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return Tuning() }
        for (k, v) in saved where merged[k] != nil { merged[k] = v }
        guard let m = try? JSONSerialization.data(withJSONObject: merged),
              let t = try? JSONDecoder().decode(Tuning.self, from: m) else { return Tuning() }
        return t
    }
}

/// Pont SwiftUI ↔ `Tuning.current` (la fenêtre Réglages modifie, les modules lisent).
@MainActor
final class TuningStore: ObservableObject {
    static let shared = TuningStore()
    @Published var t: Tuning = Tuning.current {
        didSet { if t != oldValue { Tuning.current = t; onChange.forEach { $0(oldValue, t) } } }
    }
    private var onChange: [(Tuning, Tuning) -> Void] = []
    func observe(_ f: @escaping (Tuning, Tuning) -> Void) { onChange.append(f) }
    func reset() { t = Tuning() }
}

/// Statistiques en direct (compteur de débogage).
@MainActor
final class LiveStats: ObservableObject {
    static let shared = LiveStats()
    @Published var captureFPS = 0.0
    @Published var trackMs = 0.0
    @Published var ocrMs = 0
    @Published var ocrPerSec = 0.0
    @Published var blocks = 0
    @Published var tracked = 0
    @Published var hidden = 0
    @Published var translateMs = 0
}
