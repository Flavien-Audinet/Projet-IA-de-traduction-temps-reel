import Foundation
import AppKit
import CoreAudio

/// « Écouter traduit » : capte le son de l'app choisie (coupé à la source), l'envoie au moteur de
/// doublage (Engine/dub_server.py), qui rejoue fond + voix française imitée avec un délai D.
/// L'extension Firefox retarde la vidéo du même D (voir /v1/dub/status).
@MainActor
final class DubController: ObservableObject {
    static let shared = DubController()

    enum State: Equatable { case off, loading, running, failed(String) }
    @Published private(set) var state: State = .off
    /// Moteur chargé mais doublage pas encore demandé (préchargement) : ⌃⌥A l'active instantanément.
    @Published private(set) var armed = true
    @Published private(set) var info = ""            // dernière phrase, retard…
    @Published private(set) var lastEN = ""
    @Published private(set) var lastFR = ""

    private var process: Process?
    private var stdin: FileHandle?
    private let tap = ProcessTap()
    private var rescan: Timer?, poll: Timer?
    nonisolated(unsafe) private var writeOK = false

    static var script: URL? { Bundle.main.url(forResource: "dub_server", withExtension: "py") }
    static var aheadScript: URL? { Bundle.main.url(forResource: "dub_ahead", withExtension: "py") }
    /// Mode vidéos web : moteur anticipé (8771) ; mode direct : moteur temps réel (8769).
    var web: Bool { Tuning.current.dubSource == "web" }
    var controlURL: URL { URL(string: web ? "http://127.0.0.1:8771" : "http://127.0.0.1:8769")! }

    var isActive: Bool { state == .running && armed }

    func toggle() {
        switch state {
        case .running:
            if web && !armed { armed = true; info = "Prêt : lance une vidéo dans Firefox" }
            else if web && Tuning.current.dubPreload { disarm() }      // on garde le moteur chargé
            else { stop() }
        case .loading:
            armed.toggle()
        default:
            armed = true
            start()
        }
    }

    /// Chargement du moteur à l'ouverture de l'app, sans activer le doublage.
    func preload() {
        guard Tuning.current.dubPreload, Tuning.current.dubSource == "web", state == .off else { return }
        armed = false
        start()
    }

    private func disarm() {
        armed = false
        info = "Moteur prêt (⌃⌥A pour doubler)"
        var req = URLRequest(url: controlURL.appendingPathComponent("stop"))
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        URLSession.shared.dataTask(with: req).resume()
    }

    func start() {
        guard let script = web ? Self.aheadScript : Self.script,
              FileManager.default.isExecutableFile(atPath: LocalEngine.python.path) else {
            state = .failed("moteur de doublage absent"); return
        }
        stop()
        let t = Tuning.current
        guard web || !NSRunningApplication.runningApplications(withBundleIdentifier: t.dubApp).isEmpty else {
            state = .failed("\(Self.appName(t.dubApp)) n'est pas ouvert"); return
        }
        state = .loading
        info = "Chargement des modèles (≈ 20 s)…"
        OpusEngine.shared.ensureRunning()                 // la traduction passe par Opus-MT

        let p = Process()
        p.executableURL = LocalEngine.python
        p.arguments = web ? [script.path, "--voice", t.dubVoice]
                          : [script.path, "--delay", "\(t.dubDelay)", "--voice", t.dubVoice, "--mode", t.dubMode]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["DUB_SR"] = "\(Int(Self.outputSampleRate()))"
        env["DUB_TTS_WORKERS"] = "\(t.dubWorkers)"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        let log = LocalEngine.supportDir.appendingPathComponent("dub.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { p.standardError = h }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.process = nil
                self.tap.stop()
                self.state = .failed("le moteur de doublage s'est arrêté (voir dub.log)")
            }
        }
        do { try p.run() } catch { state = .failed(error.localizedDescription); return }
        process = p
        stdin = inPipe.fileHandleForWriting

        // « READY » sur la sortie standard = modèles chargés : on peut couper l'app et capter son son.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            if s.contains("READY") {
                h.readabilityHandler = nil
                Task { @MainActor in self?.engineReady() }
            }
        }
    }

    private func engineReady() {
        guard process != nil else { return }
        if web {
            // Vidéos web : pas de capture, l'extension envoie la vidéo et sa position.
            state = .running
            info = armed ? "Prêt : lance une vidéo dans Firefox" : "Moteur prêt (⌃⌥A pour doubler)"
            poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollStatus() }
            }
            pushConfig()
            return
        }
        let input = stdin
        tap.onAudio = { [weak self] samples, frames, ns in
            guard let self, self.writeOK, let input else { return }
            var head = Data(capacity: 16)
            head.append(contentsOf: Array("MTAU".utf8))
            withUnsafeBytes(of: UInt32(frames).littleEndian) { head.append(contentsOf: $0) }
            withUnsafeBytes(of: ns.littleEndian) { head.append(contentsOf: $0) }
            let body = Data(buffer: samples)
            do { try input.write(contentsOf: head + body) } catch { self.writeOK = false }
        }
        do {
            writeOK = true
            try tap.start(bundleID: Tuning.current.dubApp)
        } catch {
            // L'app ne joue pas encore de son : on réessaiera à la prochaine vérification.
            info = "En attente de son dans \(Self.appName(Tuning.current.dubApp))…"
        }
        state = .running
        rescan = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkProcesses() }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollStatus() }
        }
        pushConfig()
    }

    /// Un nouvel onglet / processus qui joue du son : on reconstruit le tap pour l'inclure.
    private func checkProcesses() {
        guard state == .running else { return }
        let now = Set(ProcessTap.audioProcesses(of: Tuning.current.dubApp).map(\.1))
        if now != tap.tappedPIDs && !now.isEmpty {
            try? tap.start(bundleID: Tuning.current.dubApp)
        }
    }

    func stop() {
        rescan?.invalidate(); poll?.invalidate(); rescan = nil; poll = nil
        writeOK = false
        tap.stop()                                        // le son d'origine revient immédiatement
        if let p = process { process = nil; p.terminate() }
        stdin = nil
        state = .off
        info = ""
    }

    // MARK: Moteur ↔ app

    func pushConfig() {
        guard state == .running else { return }
        let t = Tuning.current
        let body: [String: Any] = ["delay": t.dubDelay, "voice": t.dubVoice, "mode": t.dubMode,
                                   "dubGain": t.dubGain, "bgGain": t.bgGain, "origGain": t.origGain,
                                   "cookies": t.dubCookies, "room": t.dubRoom,
                                   "direction": TranslatorHub.shared.direction.rawValue]
        var req = URLRequest(url: controlURL.appendingPathComponent("config"))
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }

    private func pollStatus() {
        URLSession.shared.dataTask(with: controlURL.appendingPathComponent("status")) { data, _, _ in
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            Task { @MainActor in
                if self.web {
                    guard self.armed else { return }
                    self.lastFR = j["lastFR"] as? String ?? ""
                    let st = j["state"] as? String ?? "inactif"
                    let title = (j["title"] as? String).map { "« \($0.prefix(40)) » · " } ?? ""
                    switch st {
                    case "inactif": self.info = "Prêt : lance une vidéo dans Firefox"
                    case "erreur": self.info = "Erreur : \(j["message"] as? String ?? "")"
                    case "téléchargement": self.info = title + (j["message"] as? String ?? "récupération…")
                    default:
                        let seg = j["segments"] as? Int ?? 0
                        let sub = (j["subtitles"] as? Bool ?? false) ? " · sous-titres" : ""
                        let spk = j["speakers"] as? Int ?? 0
                        self.info = title + "\(seg) phrases doublées\(sub)" + (spk > 1 ? " · \(spk) voix" : "")
                    }
                    return
                }
                let seg = j["segments"] as? Int ?? 0, late = j["late"] as? Int ?? 0
                let margin = j["margin"] as? Double ?? 0
                self.lastEN = j["lastEN"] as? String ?? ""
                self.lastFR = j["lastFR"] as? String ?? ""
                self.info = seg == 0 ? (self.tap.tappedPIDs.isEmpty ? "En attente de son…" : "En écoute…")
                    : String(format: "%d phrases · marge %+.1f s%@", seg, margin, late > 0 ? " · \(late) en retard" : "")
            }
        }.resume()
    }

    // MARK: Utilitaires

    static func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent
            ?? bundleID
    }

    /// Apps ordinaires ouvertes (pour le choix de l'app à doubler).
    static func candidateApps() -> [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }
            .sorted { $0.1 < $1.1 }
    }

    static func outputSampleRate() -> Double {
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return 48000 }
        var rate = Float64(48000)
        size = UInt32(MemoryLayout<Float64>.size)
        addr.mSelector = kAudioDevicePropertyNominalSampleRate
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate)
        return rate
    }
}
