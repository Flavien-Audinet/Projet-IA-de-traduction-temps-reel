import Foundation

/// Moteur « Rapide » : Opus-MT (Université d'Helsinki) via CTranslate2, sur le processeur.
/// Serveur Python local (127.0.0.1:8767) livré dans l'app (Resources/mt_server.py), lancé à la demande.
/// Sert aussi de renfort pour l'extension : pendant que le moteur choisi traduit ce qui est visible,
/// Opus-MT traduit le reste de la page en parallèle (il ne touche ni au GPU ni au moteur Apple).
@MainActor
final class OpusEngine: ObservableObject {
    static let shared = OpusEngine()
    let port = 8767

    enum State: Equatable { case stopped, starting, ready, failed(String) }
    @Published private(set) var state: State = .stopped
    private var process: Process?

    static var script: URL? { Bundle.main.url(forResource: "mt_server", withExtension: "py") }
    static let modelsDir = LocalEngine.supportDir.appendingPathComponent("models")

    /// Modèles convertis présents pour ce sens ?
    func isInstalled(_ d: Direction) -> Bool {
        let name = d == .enToFr ? "opus-mt-tc-big-en-fr-ct2" : "opus-mt-tc-big-fr-en-ct2"
        return Self.script != nil
            && FileManager.default.fileExists(atPath: Self.modelsDir.appendingPathComponent(name).path)
            && FileManager.default.isExecutableFile(atPath: LocalEngine.python.path)
    }

    func ensureRunning() {
        switch state {
        case .ready, .starting: return
        default: start()
        }
    }

    func start() {
        guard let script = Self.script else { state = .failed("script absent de l'app"); return }
        stop()
        state = .starting
        let p = Process()
        p.executableURL = LocalEngine.python
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["MT_PORT"] = "\(port)"
        env["MT_DEVICE"] = Tuning.current.opusGPU ? "auto" : "cpu"
        env["HF_HUB_OFFLINE"] = "1"
        p.environment = env
        let log = LocalEngine.supportDir.appendingPathComponent("opus.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.process = nil
                self.state = .failed("Opus-MT s'est arrêté (code \(proc.terminationStatus)), voir opus.log")
            }
        }
        do { try p.run() } catch { state = .failed(error.localizedDescription); return }
        process = p
        Task { await waitReady() }
    }

    func stop() {
        if let p = process { process = nil; p.terminate() }
        state = .stopped
    }

    private func waitReady() async {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<120 {
            guard state == .starting else { return }
            if let (_, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200 {
                state = .ready
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if state == .starting { state = .failed("délai dépassé au démarrage d'Opus-MT") }
    }

    /// Attend (au plus quelques secondes) que le serveur soit prêt.
    func waitUntilReady() async -> Bool {
        ensureRunning()
        for _ in 0..<80 {
            if state == .ready { return true }
            if case .failed = state { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return state == .ready
    }

    nonisolated func translate(_ texts: [String], direction: Direction) async throws -> [String] {
        let ok = await waitUntilReady()
        guard ok else { throw LocalLLMError.unavailable }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/translate")!, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["texts": texts, "direction": direction.rawValue])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let out = j["translations"] as? [String], out.count == texts.count else {
            throw LocalLLMError.badResponse(String(decoding: data, as: UTF8.self))
        }
        return out
    }
}
