import SwiftUI
import AppKit
import Translation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hostWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Mode test hors écran : MyTranslate --render entree.png sortie.png [--engine apple|local|fake]
            if let i = CommandLine.arguments.firstIndex(of: "--track-test") {
                RenderTest.trackTest(Array(CommandLine.arguments[(i + 1)...]))
                return
            }
            if let i = CommandLine.arguments.firstIndex(of: "--render") {
                RenderTest.run(Array(CommandLine.arguments[(i + 1)...]))
                return
            }

            // Fenêtre invisible qui garde ouverte la session de traduction Apple.
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: AppleBridge.sessions, height: 1), styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.contentView = NSHostingView(rootView: AppleTranslationHost())
            w.orderFrontRegardless()
            hostWindow = w

            let screen = ScreenTranslator.shared
            for m in ScreenMode.allCases {
                HotKeys.shared.register(m.hotkey) { screen.toggle(m) }
            }
            HotKeys.shared.register(.audio) { DubController.shared.toggle() }
            // Moteur de doublage chargé en arrière-plan (inactif) : ⌃⌥A sera instantané.
            Task { try? await Task.sleep(nanoseconds: 4_000_000_000); DubController.shared.preload() }
            TuningStore.shared.observe { old, new in
                if old.dubSource != new.dubSource, DubController.shared.state != .off {
                    DubController.shared.stop(); DubController.shared.start()
                }
                if old.dubDelay != new.dubDelay || old.dubMode != new.dubMode || old.dubVoice != new.dubVoice
                    || old.dubCookies != new.dubCookies || old.dubRoom != new.dubRoom
                    || old.dubGain != new.dubGain || old.bgGain != new.bgGain || old.origGain != new.origGain {
                    DubController.shared.pushConfig()
                }
            }
            if TranslatorHub.shared.engine == .local { LocalEngine.shared.ensureRunning() }
            LocalAPI.shared.start()      // service local pour l'extension navigateur
            TuningStore.shared.observe { old, new in
                if old.opusGPU != new.opusGPU, OpusEngine.shared.state != .stopped { OpusEngine.shared.start() }
            }
            // Préchauffage : au premier appel, macOS met plusieurs secondes à charger son modèle de
            // traduction ; on le fait tout de suite pour que la première page soit instantanée.
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                _ = await TranslatorHub.shared.translate(["Welcome to MyTranslate."], using: .apple)
                if OpusEngine.shared.isInstalled(TranslatorHub.shared.direction) { OpusEngine.shared.ensureRunning() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { DubController.shared.stop(); LocalEngine.shared.stop(); OpusEngine.shared.stop() }
    }
}

@main
struct MyTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
        } label: {
            MenuLabel()
        }
        .menuBarExtraStyle(.window)

        Window("Langues de traduction", id: "setup") {
            SetupView()
        }
        .windowResizability(.contentSize)

        Window("Réglages avancés", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}

struct MenuLabel: View {
    @ObservedObject var screen = ScreenTranslator.shared
    var body: some View {
        Image(systemName: screen.mode == nil ? "character.bubble" : "character.bubble.fill")
    }
}

struct MenuView: View {
    @ObservedObject var screen = ScreenTranslator.shared
    @ObservedObject var hub = TranslatorHub.shared
    @ObservedObject var apple = AppleBridge.shared
    @ObservedObject var engine = LocalEngine.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MyTranslate").font(.headline)
                Spacer()
                Text(screen.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            // Texte à l'écran
            VStack(alignment: .leading, spacing: 4) {
                Text("Texte à l'écran").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(ScreenMode.allCases) { m in
                    Button { screen.toggle(m) } label: {
                        HStack {
                            Image(systemName: m.symbol).frame(width: 20)
                            Text(m.label)
                            Spacer()
                            if screen.mode == m { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            Text(m.hotkey.label).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                }
                if screen.mode != nil {
                    Button("Arrêter la traduction") { screen.stop() }
                    if !screen.stats.isEmpty {
                        Text(screen.stats).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if screen.needsPermission {
                    Label("Autorise MyTranslate dans Réglages Système › Confidentialité › Enregistrement de l'écran, puis relance l'app.",
                          systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Ouvrir les réglages") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }

            Divider()

            // Langues et moteur
            Picker("Sens", selection: $hub.direction) {
                ForEach(Direction.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Moteur", selection: $hub.engine) {
                ForEach(EngineKind.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: hub.engine) { _, e in
                if e == .local { engine.ensureRunning() } else { engine.stop() }
                if e == .opus { OpusEngine.shared.ensureRunning() }
            }

            if hub.engine == .apple, apple.installed == false {
                Button("Télécharger les langues FR/EN…") {
                    openWindow(id: "setup")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            if hub.engine == .local {
                Picker("Modèle", selection: $engine.model) {
                    ForEach(LocalEngine.models, id: \.0) { Text($0.1).tag($0.0) }
                }
                HStack(spacing: 6) {
                    Circle().fill(engineColor).frame(width: 8, height: 8)
                    Text(engineLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Réglages avancés…", systemImage: "slider.horizontal.3")
            }

            if let err = hub.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            DubMenuSection()

            Divider()
            HStack {
                Spacer()
                Button("Quitter") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var engineColor: Color {
        switch engine.state {
        case .ready: return .green
        case .starting: return .yellow
        case .stopped: return .gray
        case .failed: return .red
        }
    }

    private var engineLabel: String {
        switch engine.state {
        case .ready: return "Moteur IA prêt"
        case .starting: return "Chargement du modèle…"
        case .stopped: return "Moteur arrêté"
        case .failed(let m): return "Erreur : \(m)"
        }
    }
}

/// Téléchargement des modèles de traduction Apple (une seule fois, géré par macOS).
struct SetupView: View {
    @ObservedObject var apple = AppleBridge.shared
    @ObservedObject var hub = TranslatorHub.shared
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Langues de traduction hors-ligne", systemImage: "arrow.down.circle")
                .font(.title2.bold())
            Text("macOS va télécharger les modèles de traduction anglais ↔ français (quelques centaines de Mo, une seule fois). Ensuite, tout fonctionne sans Internet.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            if apple.installed == true {
                Label("Langues installées, tout est prêt.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(apple.preparing ? "Téléchargement…" : "Télécharger") {
                    config = TranslationSession.Configuration(source: Locale.Language(identifier: hub.direction.source),
                                                              target: Locale.Language(identifier: hub.direction.target))
                }
                .buttonStyle(.borderedProminent)
                .disabled(apple.preparing)
            }
        }
        .padding(24)
        .frame(width: 440)
        .translationTask(config) { session in await apple.prepare(session) }
    }
}

/// Section du menu : doublage en direct.
struct DubMenuSection: View {
    @ObservedObject var dub = DubController.shared
    @ObservedObject var store = TuningStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Écouter traduit").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Button { dub.toggle() } label: {
                HStack {
                    Image(systemName: "waveform").frame(width: 20)
                    Text(!dub.isActive ? (store.t.dubSource == "web" ? "Doubler les vidéos Firefox" : "Doubler \(DubController.appName(store.t.dubApp))") : "Arrêter le doublage")
                    Spacer()
                    if dub.isActive { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    Text(HotKeys.Combo.audio.label).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)
            switch dub.state {
            case .off:
                Text(store.t.dubSource == "web" ? "Voix imitée, préparée à l'avance sur la ligne de temps" : "Voix imitée, délai \(Int(store.t.dubDelay)) s (image et son décalés ensemble)")
                    .font(.caption).foregroundStyle(.secondary)
            case .loading, .running:
                Text(dub.info).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if !dub.lastFR.isEmpty {
                    Text("« \(dub.lastFR) »").font(.caption).italic().lineLimit(2)
                }
            case .failed(let m):
                Label(m, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

