import Foundation

/// Lance et surveille le moteur IA local (serveur MLX sur 127.0.0.1:8765).
/// L'environnement Python et les modèles vivent en local :
///   ~/Library/Application Support/MyTranslate/venv  (+ cache Hugging Face)
@MainActor
final class LocalEngine: ObservableObject {
    static let shared = LocalEngine()

    enum State: Equatable { case stopped, starting, ready, failed(String) }

    @Published private(set) var state: State = .stopped
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "llmModel"); if state != .stopped { restart() } }
    }

    static let models = [
        ("mlx-community/gemma-4-e4b-it-4bit", "Gemma 4 E4B — rapide (5 Go)"),
        ("mlx-community/Qwen3.6-35B-A3B-4bit", "Qwen 3.6 35B-A3B — meilleure qualité (20 Go)"),
    ]

    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MyTranslate")
    static var python: URL { supportDir.appendingPathComponent("venv/bin/python") }
    let port = 8765

    private var process: Process?

    private init() {
        model = UserDefaults.standard.string(forKey: "llmModel") ?? Self.models[0].0
    }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.python.path) }

    func ensureRunning() {
        switch state {
        case .ready, .starting: return
        default: start()
        }
    }

    func start() {
        guard isInstalled else { state = .failed("environnement Python absent (voir README)"); return }
        stop()
        state = .starting
        let p = Process()
        p.executableURL = Self.python
        // Plusieurs petites requêtes traitées en parallèle : les blocs s'affichent au fil de l'eau.
        p.arguments = ["-m", "mlx_lm.server", "--model", model, "--host", "127.0.0.1", "--port", "\(port)",
                       "--decode-concurrency", "8", "--prompt-concurrency", "4"]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"          // jamais de réseau en fonctionnement normal
        p.environment = env
        let log = Self.supportDir.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.process = nil
                self.state = .failed("le moteur s'est arrêté (code \(proc.terminationStatus)), voir engine.log")
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

    func restart() { stop(); start() }

    /// Attend que le serveur réponde (le chargement du modèle prend quelques secondes).
    private func waitReady() async {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        for _ in 0..<240 {
            guard state == .starting else { return }
            if let (_, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200 {
                state = .ready
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if state == .starting { state = .failed("délai dépassé au démarrage du moteur") }
    }
}
