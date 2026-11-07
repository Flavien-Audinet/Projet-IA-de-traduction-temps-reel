import Foundation
import Network

/// Petit service HTTP local (127.0.0.1:8770) utilisé par l'extension navigateur.
/// Il passe par le même moteur et le même cache que la traduction d'écran.
///   GET  /v1/status     → moteur, sens, prêt ou non
///   POST /v1/translate  {"units": [texte balisé…], "context": "…"} → {"translations": […]}
/// Sécurité : écoute uniquement en local, et refuse les requêtes venant de pages web
/// (seules les origines moz-extension:// et chrome-extension:// sont acceptées).
@MainActor
final class LocalAPI {
    static let shared = LocalAPI()
    nonisolated static let port: UInt16 = 8770

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mytranslate.api")
    private(set) var lastRequest: Date?

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else {
            NSLog("MyTranslate: impossible d'ouvrir le port %d", Self.port)
            return
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    nonisolated private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    nonisolated private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest(buf) {
                self.handle(req, c)
            } else if done || err != nil || buf.count > 40 << 20 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    nonisolated private func handle(_ req: HTTPRequest, _ c: NWConnection) {
        // Seuls l'app, les scripts locaux et l'extension sont acceptés : une page web ne doit pas pouvoir
        // piloter ce service (origine vérifiée), ni passer par un domaine qui pointe vers 127.0.0.1
        // (« DNS rebinding » : l'en-tête Host doit désigner 127.0.0.1 ou localhost).
        let host = (req.headers["host"] ?? "").lowercased()
        guard host == "127.0.0.1:\(Self.port)" || host == "localhost:\(Self.port)" else {
            return send(c, 403, ["error": "hôte refusé"], origin: nil)
        }
        let origin = req.headers["origin"]
        let fromExtension = origin.map { $0.hasPrefix("moz-extension://") || $0.hasPrefix("chrome-extension://") } ?? false
        let fetchSite = req.headers["sec-fetch-site"] ?? "none"
        let allowed = fromExtension || (origin == nil && (fetchSite == "none" || fetchSite == "same-origin"))
        guard allowed else { return send(c, 403, ["error": "origine refusée"], origin: nil) }
        if req.method == "OPTIONS" { return send(c, 204, nil, origin: origin) }

        switch (req.method, req.path) {
        case ("GET", "/v1/status"):
            Task { @MainActor in
                let hub = TranslatorHub.shared
                let ready: Bool
                switch hub.engine {
                case .apple: ready = AppleBridge.shared.installed == true
                case .opus: ready = OpusEngine.shared.isInstalled(hub.direction)
                case .local: ready = LocalEngine.shared.state == .ready
                }
                self.send(c, 200, ["app": "MyTranslate", "engine": hub.engine.rawValue, "engineLabel": hub.engine.label,
                                   "direction": hub.direction.rawValue, "source": hub.direction.source,
                                   "target": hub.direction.target, "ready": ready], origin: origin)
            }
        case ("POST", "/v1/translate"):
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let units = obj["units"] as? [String], units.count <= 300,
                  units.reduce(0, { $0 + $1.count }) <= 60_000 else {
                return send(c, 400, ["error": "requête invalide"], origin: origin)
            }
            let context = obj["context"] as? String
            let background = (obj["priority"] as? String) == "background"
            Task { @MainActor in
                self.lastRequest = Date()
                let hub = TranslatorHub.shared
                if hub.engine == .local { LocalEngine.shared.ensureRunning() }
                // Moteurs des pages web (Réglages avancés) : un pour le visible, un pour le reste de la page.
                // « screen » = le même que pour l'écran. Opus-MT n'est utilisé que s'il est installé.
                let tune = Tuning.current
                let name = background ? tune.webBackgroundEngine : tune.webVisibleEngine
                var using: EngineKind? = name == "screen" ? nil : EngineKind(rawValue: name)
                if using == .opus && !OpusEngine.shared.isInstalled(hub.direction) { using = nil }
                if using == .local { LocalEngine.shared.ensureRunning() }
                let out = await hub.translateTagged(units, context: context, using: using)
                var body: [String: Any] = ["translations": out]
                if let e = TranslatorHub.shared.lastError { body["warning"] = e }
                self.send(c, 200, body, origin: origin)
            }
        case ("GET", "/v1/dub/status"):
            Task { @MainActor in
                let t = Tuning.current
                self.send(c, 200, ["active": DubController.shared.isActive, "mode": t.dubSource, "app": t.dubApp,
                                   "delay": t.dubDelay + t.videoOffsetMs / 1000,
                                   "offset": t.videoOffsetMs / 1000], origin: origin)
            }
        case ("POST", "/v1/dub/video"), ("POST", "/v1/dub/sync"), ("POST", "/v1/dub/stop"):
            // Doublage anticipé : relais vers le moteur (127.0.0.1:8771).
            let path = String(req.path.dropFirst("/v1/dub".count))
            var r = URLRequest(url: URL(string: "http://127.0.0.1:8771" + (path == "/video" ? "/job" : path))!, timeoutInterval: 5)
            r.httpMethod = "POST"
            r.httpBody = req.body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            URLSession.shared.dataTask(with: r) { data, _, _ in
                let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? ["error": "moteur indisponible"]
                self.send(c, 200, j, origin: origin)
            }.resume()
        case ("POST", "/v1/ocr"):
            // Image (base64) venant de l'extension : texte dans une image, un canvas…
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let b64 = obj["image"] as? String, let data = Data(base64Encoded: b64), data.count < 30 << 20 else {
                return send(c, 400, ["error": "image invalide"], origin: origin)
            }
            let context = obj["context"] as? String
            Task { @MainActor in
                self.lastRequest = Date()
                self.send(c, 200, await ImageOCR.run(data, context: context), origin: origin)
            }
        default:
            send(c, 404, ["error": "inconnu"], origin: origin)
        }
    }

    nonisolated private func send(_ c: NWConnection, _ status: Int, _ json: [String: Any]?, origin: String?) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n"
        if let origin {
            head += "Access-Control-Allow-Origin: \(origin)\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            head += "Access-Control-Allow-Headers: Content-Type\r\nAccess-Control-Max-Age: 86400\r\n"
        }
        head += "\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// Requête HTTP/1.1 minimale (en-têtes + corps selon Content-Length). nil tant qu'elle est incomplète.
struct HTTPRequest {
    let method: String, path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var h: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let len = Int(h["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard data.count - bodyStart >= len else { return nil }
        method = String(first[0]); path = String(first[1].split(separator: "?")[0])
        headers = h
        body = data[bodyStart..<(bodyStart + len)]
    }
}
