import Foundation
import SwiftUI
import Translation
import NaturalLanguage

enum Direction: String, CaseIterable, Identifiable {
    case enToFr, frToEn
    var id: String { rawValue }
    var source: String { self == .enToFr ? "en" : "fr" }
    var target: String { self == .enToFr ? "fr" : "en" }
    var nlSource: NLLanguage { self == .enToFr ? .english : .french }
    var nlTarget: NLLanguage { self == .enToFr ? .french : .english }
    var label: String { self == .enToFr ? "Anglais → Français" : "Français → Anglais" }
    var ocrLanguages: [String] { self == .enToFr ? ["en-US", "fr-FR"] : ["fr-FR", "en-US"] }
}

enum EngineKind: String, CaseIterable, Identifiable {
    case apple, opus, local
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple: return "Apple (instantané)"
        case .opus: return "Rapide (Opus-MT)"
        case .local: return "IA locale (contexte)"
        }
    }
}

/// Point d'entrée unique des traductions : cache + choix du moteur.
@MainActor
final class TranslatorHub: ObservableObject {
    static let shared = TranslatorHub()

    @Published var direction: Direction {
        didSet { UserDefaults.standard.set(direction.rawValue, forKey: "direction"); AppleBridge.shared.configure(direction) }
    }
    @Published var engine: EngineKind {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "engine") }
    }
    @Published var lastError: String?

    private var cache: [String: String] = [:]
    private var inflight: Set<String> = []

    private init() {
        direction = Direction(rawValue: UserDefaults.standard.string(forKey: "direction") ?? "") ?? .enToFr
        engine = EngineKind(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .local
        AppleBridge.shared.configure(direction)
    }

    private func key(_ t: String, _ e: EngineKind? = nil) -> String { "\(direction.rawValue)|\((e ?? engine).rawValue)|\(t)" }

    func cached(_ text: String, using e: EngineKind? = nil) -> String? { cache[key(text, e)] }

    func store(_ text: String, _ translation: String, using e: EngineKind? = nil) { cache[key(text, e)] = translation }

    /// Appel brut d'un moteur (sans cache).
    func run(_ e: EngineKind, _ texts: [String], context: String?, tagged: Bool) async throws -> [String] {
        switch e {
        case .apple: return try await AppleBridge.shared.translate(texts)
        case .opus: return try await OpusEngine.shared.translate(texts, direction: direction)
        case .local: return try await LocalLLM.shared.translate(texts, direction: direction, context: context, tagged: tagged)
        }
    }

    /// Traduit les textes absents du cache (un seul lot), et renvoie toutes les traductions connues.
    @discardableResult
    func translate(_ texts: [String], context: String? = nil, using e: EngineKind? = nil) async -> [String: String] {
        let eng = e ?? engine
        let missing = Array(Set(texts.filter { cache[key($0, eng)] == nil && !inflight.contains(key($0, eng)) }))
        if !missing.isEmpty {
            missing.forEach { inflight.insert(key($0, eng)) }
            let dir = direction
            do {
                let out = try await run(eng, missing, context: context, tagged: false)
                for (src, dst) in zip(missing, out) { cache["\(dir.rawValue)|\(eng.rawValue)|\(src)"] = dst }
                lastError = nil
            } catch {
                lastError = "\(eng.label) : \(error.localizedDescription)"
            }
            missing.forEach { inflight.remove("\(dir.rawValue)|\(eng.rawValue)|\($0)") }
            if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
        }
        var res: [String: String] = [:]
        for t in texts { if let v = cache[key(t, eng)] { res[t] = v } }
        return res
    }
}

// MARK: - Texte balisé (pages web)

extension TranslatorHub {
    /// Traduit des textes balisés en garantissant que chaque traduction garde la même suite de balises.
    /// IA locale : traduction de la phrase entière, balises comprises (meilleur sens) ; si le modèle
    /// abîme les balises, ou avec le moteur Apple, on traduit les morceaux séparément.
    func translateTagged(_ units: [String], context: String?, using e: EngineKind? = nil) async -> [String] {
        let eng = e ?? engine
        let parsed = units.map(TaggedText.init)
        var out = units
        var missing: [Int] = []
        for i in units.indices {
            // Une traduction déjà faite par le moteur choisi OU par le moteur demandé est réutilisée.
            if let c = cached(units[i], using: eng) ?? cached(units[i]) { out[i] = c } else { missing.append(i) }
        }
        guard !missing.isEmpty else { return out }

        // 1. Un seul passage moteur pour tout le lot (textes simples et balisés ensemble) :
        //    l'IA locale est guidée par le prompt, le moteur Apple conserve en général les balises.
        // Unités chargées de balises (références, listes de liens) : directement morceau par morceau,
        // les moteurs abîmant presque toujours ces balises (le passage entier serait perdu).
        let maxTags = Tuning.current.maxTagsWhole
        let heavy = missing.filter { parsed[$0].tags.count > maxTags }
        missing.removeAll { parsed[$0].tags.count > maxTags }
        var whole: [String]?
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            if ProcessInfo.processInfo.environment["MT_TIMING"] != nil {
                NSLog("MTT %@ : %d unités, total %.0f ms", eng.rawValue, missing.count, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
        }
        do {
            whole = missing.isEmpty ? [] : try await run(eng, missing.map { units[$0] }, context: context, tagged: true)
            if ProcessInfo.processInfo.environment["MT_TIMING"] != nil {
                NSLog("MTT   passage 1 (%@) : %.0f ms", eng.rawValue, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            lastError = nil
        } catch {
            lastError = "\(eng.label) : \(error.localizedDescription)"
        }

        var fallback: [Int] = heavy
        var fixes: [(Int, Int)] = []          // (unité, segment) restés en anglais dans une balise
        func untouched(_ i: Int, _ k: Int, _ tt: TaggedText) -> Bool {
            let o = parsed[i].segments[k]
            return k > 0 && tt.segments[k] == o && o.contains(where: \.isLowercase)
                && !o.contains(where: { "/@#_.:0123456789".contains($0) })
        }
        var accepted: [Int: TaggedText] = [:]
        for (n, i) in missing.enumerated() {
            guard let w = whole?[n] else { fallback.append(i); continue }
            if !parsed[i].hasTags { out[i] = w; store(units[i], w, using: eng); continue }
            let tt = TaggedText(w)
            if tt.tags == parsed[i].tags {
                accepted[i] = tt
                for k in tt.segments.indices where untouched(i, k, tt) { fixes.append((i, k)) }
            } else {
                fallback.append(i)
            }
        }

        // 2. Second passage (si besoin) : morceaux restés en anglais + unités dont les balises ont été abîmées.
        var pieces = Set(fixes.map { parsed[$0.0].segments[$0.1].trimmingCharacters(in: .whitespaces) })
        for i in fallback {
            if parsed[i].hasTags {
                for seg in parsed[i].segments where seg.contains(where: \.isLetter) { pieces.insert(seg.trimmingCharacters(in: .whitespaces)) }
            } else {
                pieces.insert(units[i].trimmingCharacters(in: .whitespaces))
            }
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        let tr = pieces.isEmpty ? [:] : await translate(Array(pieces), context: context, using: eng)
        if ProcessInfo.processInfo.environment["MT_TIMING"] != nil {
            NSLog("MTT   passage 2 : %d morceaux (%d unités en repli, %d corrections) %.0f ms",
                  pieces.count, fallback.count, fixes.count, (CFAbsoluteTimeGetCurrent() - t1) * 1000)
        }
        func piece(_ seg: String, first: Bool) -> String {
            guard seg.contains(where: \.isLetter), var x = tr[seg.trimmingCharacters(in: .whitespaces)] else { return seg }
            // Les moteurs mettent une majuscule à chaque morceau : on garde la casse d'origine.
            if !first, let f = seg.first(where: { !$0.isWhitespace }), f.isLowercase, let g = x.first, g.isUppercase {
                x = g.lowercased() + x.dropFirst()
            }
            return x.keepingPadding(of: seg)
        }
        for (i, var tt) in accepted {
            for (j, k) in fixes where j == i { tt.segments[k] = piece(parsed[i].segments[k], first: false) }
            out[i] = tt.joined
            store(units[i], out[i], using: eng)
        }
        for i in fallback {
            if parsed[i].hasTags {
                var t = parsed[i]
                t.segments = t.segments.enumerated().map { k, seg in piece(seg, first: k == 0) }
                out[i] = t.joined
            } else if let x = tr[units[i].trimmingCharacters(in: .whitespaces)] {
                out[i] = x
            }
            if out[i] != units[i] { store(units[i], out[i], using: eng) }
        }
        return out
    }
}

// MARK: - Moteur Apple (framework Translation, 100 % local)

/// Le framework Translation n'expose une session que via le modificateur SwiftUI `.translationTask`.
/// Une vue invisible garde la session ouverte ; les demandes lui sont transmises par une file.
@MainActor
final class AppleBridge: ObservableObject {
    static let shared = AppleBridge()

    @Published var configuration: TranslationSession.Configuration?
    @Published var installed: Bool?          // nil = inconnu
    @Published var preparing = false

    private struct Job { let texts: [String]; let cont: CheckedContinuation<[String], Error> }
    private var jobs: [Job] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var generation: [Int: Int] = [:]
    /// Nombre de sessions (une par vue hôte). Mesuré : macOS sérialise de toute façon les traductions
    /// (~27 phrases/s), plusieurs sessions n'accélèrent rien — on en garde une.
    static let sessions = 1

    func configure(_ d: Direction) {
        let c = TranslationSession.Configuration(source: Locale.Language(identifier: d.source),
                                                 target: Locale.Language(identifier: d.target))
        if configuration != c { configuration = c }
        Task { await refreshStatus(d) }
    }

    func refreshStatus(_ d: Direction) async {
        let s = await LanguageAvailability().status(from: Locale.Language(identifier: d.source),
                                                    to: Locale.Language(identifier: d.target))
        installed = (s == .installed)
    }

    func translate(_ texts: [String]) async throws -> [String] {
        try await withCheckedThrowingContinuation { c in
            jobs.append(Job(texts: texts, cont: c))
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
    }

    private func wakeAll() { let w = waiters; waiters = []; w.forEach { $0.resume() } }

    /// Boucle de service d'une session, exécutée dans le `.translationTask` de sa vue hôte.
    func serve(_ session: TranslationSession, slot: Int) async {
        let gen = (generation[slot] ?? 0) + 1
        generation[slot] = gen
        while !Task.isCancelled && gen == generation[slot] {
            if jobs.isEmpty {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { c in
                        if !jobs.isEmpty || Task.isCancelled { c.resume() } else { waiters.append(c) }
                    }
                } onCancel: {
                    Task { @MainActor in AppleBridge.shared.wakeAll() }
                }
                continue
            }
            let job = jobs.removeFirst()
            // Garde-fou : si la session ne répond plus (moteur saturé, bloqué…), on la recrée.
            // Délai généreux et proportionnel au lot : au lancement, macOS met plusieurs secondes
            // à charger son modèle, et un long paragraphe prend ~0,1 s.
            let limit = UInt64(20 + job.texts.count) * 1_000_000_000
            let watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: limit)
                guard !Task.isCancelled, let self else { return }
                NSLog("MyTranslate: session Apple bloquée, redémarrage")
                self.configuration?.invalidate()
            }
            defer { watchdog.cancel() }
            do {
                let reqs = job.texts.enumerated().map {
                    TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                }
                let resps = try await session.translations(from: reqs)
                var out = job.texts
                for r in resps { if let id = r.clientIdentifier, let i = Int(id), i < out.count { out[i] = r.targetText } }
                job.cont.resume(returning: out)
            } catch {
                job.cont.resume(throwing: error)
            }
        }
    }

    /// Téléchargement des langues (affiche la fenêtre système de confirmation).
    func prepare(_ session: TranslationSession) async {
        preparing = true
        do { try await session.prepareTranslation() } catch { TranslatorHub.shared.lastError = error.localizedDescription }
        preparing = false
        await refreshStatus(TranslatorHub.shared.direction)
    }
}

/// Vues hôtes invisibles qui maintiennent les sessions Apple ouvertes (une par vue).
struct AppleTranslationHost: View {
    @ObservedObject var bridge = AppleBridge.shared
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<AppleBridge.sessions, id: \.self) { slot in
                Color.clear
                    .frame(width: 1, height: 1)
                    .translationTask(bridge.configuration) { session in
                        await bridge.serve(session, slot: slot)
                    }
            }
        }
    }
}

// MARK: - Moteur IA locale (serveur MLX compatible OpenAI, lancé par l'app)

enum LocalLLMError: LocalizedError {
    case unavailable, badResponse(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "le moteur IA local ne répond pas"
        case .badResponse(let s): return "réponse inattendue du modèle (\(s.prefix(80)))"
        }
    }
}

final class LocalLLM: @unchecked Sendable {
    static let shared = LocalLLM()
    var endpoint = URL(string: "http://127.0.0.1:8765/v1/chat/completions")!

    func translate(_ texts: [String], direction: Direction, context: String?, tagged: Bool = false) async throws -> [String] {
        let (src, dst) = direction == .enToFr ? ("anglais", "français") : ("français", "anglais")
        var system = """
        Tu es un traducteur professionnel \(src) → \(dst). On te donne un tableau JSON de textes extraits \
        d'un écran (interface, articles, jeux, sous-titres). Traduis chaque élément en \(dst) naturel et idiomatique. \
        Conserve les nombres, les noms propres, les marques, la ponctuation et la casse. Pour les libellés \
        d'interface, reste aussi court que l'original. Si un élément est déjà en \(dst) ou intraduisible, recopie-le. \
        Réponds UNIQUEMENT avec un tableau JSON de chaînes, de même longueur et dans le même ordre.
        """
        if tagged {
            system += """
            \nLes textes viennent d'une page web et contiennent des balises : <g1>…</g1> entoure un lien ou un mot \
            mis en forme, <x2/> marque un saut de ligne ou une image. Garde EXACTEMENT les mêmes balises, avec les \
            mêmes numéros et dans le même ordre, autour des mots traduits correspondants.
            """
        }
        if let context, !context.isEmpty { system += "\nContexte de la page : \(context.prefix(600))" }
        let input = String(data: try JSONSerialization.data(withJSONObject: texts), encoding: .utf8)!
        let body: [String: Any] = [
            "model": "default_model",
            "chat_template_kwargs": ["enable_thinking": false],   // pas de « réflexion » : on veut la réponse directe
            "messages": [["role": "system", "content": system], ["role": "user", "content": input]],
            "temperature": 0.1,
            "max_tokens": max(256, input.count * 2),
        ]
        var req = URLRequest(url: endpoint, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: req) } catch { throw LocalLLMError.unavailable }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        else { throw LocalLLMError.badResponse(String(decoding: data, as: UTF8.self)) }
        return try Self.parseArray(msg, expected: texts.count)
    }

    /// Extrait le tableau JSON de la réponse (le modèle peut ajouter du texte ou des ``` autour).
    static func parseArray(_ s: String, expected: Int) throws -> [String] {
        guard let a = s.firstIndex(of: "["), let b = s.lastIndex(of: "]"), a < b,
              let arr = try? JSONSerialization.jsonObject(with: Data(s[a...b].utf8)) as? [Any] else {
            throw LocalLLMError.badResponse(s)
        }
        let out = arr.map { "\($0)" }
        guard out.count == expected else { throw LocalLLMError.badResponse("\(out.count)/\(expected) éléments") }
        return out
    }
}
