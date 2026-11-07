import SwiftUI

/// Réglages avancés : tout s'applique en direct, pendant la traduction.
struct SettingsView: View {
    @ObservedObject var store = TuningStore.shared
    @ObservedObject var hub = TranslatorHub.shared
    @ObservedObject var opus = OpusEngine.shared

    var body: some View {
        TabView {
            tracking.tabItem { Label("Suivi", systemImage: "scope") }
            ocr.tabItem { Label("OCR", systemImage: "text.viewfinder") }
            rendering.tabItem { Label("Rendu", systemImage: "textformat.size") }
            engines.tabItem { Label("Moteurs", systemImage: "cpu") }
            dubbing.tabItem { Label("Doublage", systemImage: "waveform") }
            debug.tabItem { Label("Débogage", systemImage: "ladybug") }
        }
        .frame(width: 560, height: 520)
        .padding(.bottom, 8)
    }

    private var t: Binding<Tuning> { $store.t }

    // MARK: Suivi

    private var tracking: some View {
        Form {
            Section("Capture") {
                Picker("Images par seconde", selection: t.fps) {
                    ForEach([15.0, 30, 60, 90, 120], id: \.self) { Text("\(Int($0))").tag($0) }
                }
                note("Fréquence à laquelle l'écran est relu pour suivre le texte. 120 suit parfaitement un écran ProMotion mais coûte plus de calcul (seules les images qui changent sont traitées).")
            }
            Section("Suivi du texte") {
                Toggle("Suivre le texte entre deux OCR", isOn: t.tracking)
                note("Désactivé : les traductions ne bougent qu'à chaque nouvelle OCR (utile pour comparer).")
                slider("Tolérance de reconnaissance", t.trackThreshold, 8...45, step: 1, format: "%.0f",
                       help: "Écart maximal accepté entre un bloc et sa nouvelle position. Plus haut = suit mieux les textes qui changent légèrement (anticrénelage, vidéo), mais risque de « coller » au mauvais endroit.")
                Stepper("Rayon de recherche locale : \(store.t.localSearch) px", value: t.localSearch, in: 0...96, step: 4)
                note("Pour les éléments qui bougent seuls (animations, carrousels). 0 = désactivé.")
                Toggle("Prédire la position selon la vitesse", isOn: t.velocityPrediction)
                slider("Anticipation", t.anticipationMs, 0...50, step: 1, format: "%.0f ms",
                       help: "Projette la traduction en avant selon la vitesse du défilement, pour compenser le délai capture → affichage. Trop haut : la traduction « dépasse » à l'arrêt.")
                Picker("Image réduite du suivi", selection: t.trackStep) {
                    Text("Auto").tag(0); Text("1 pixel sur 2 (précis)").tag(2)
                    Text("1 sur 4").tag(4); Text("1 sur 6 (léger)").tag(6)
                }
                Toggle("Masquer un bloc dont le contenu change", isOn: t.hideOnChange)
                note("Désactivé : un bloc perdu reste à sa dernière position jusqu'à la prochaine OCR.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: OCR

    private var ocr: some View {
        Form {
            Section("Reconnaissance du texte") {
                Picker("Mode", selection: t.ocrMode) { ForEach(OCRMode.allCases) { Text($0.label).tag($0) } }
                Toggle("Correction linguistique (mode précis)", isOn: t.languageCorrection)
            }
            Section("Cadence") {
                slider("Attente de stabilisation", t.settleMs, 20...600, step: 10, format: "%.0f ms",
                       help: "Délai sans changement avant de relancer l'OCR. Plus court = texte nouveau reconnu plus vite ; plus long = moins de calcul pendant le défilement.")
                slider("Intervalle maximal pendant un mouvement", t.maxOCRIntervalMs, 100...3000, step: 50, format: "%.0f ms",
                       help: "Pendant un défilement ou une vidéo, l'OCR est relancée au plus tard après ce délai. C'est le réglage qui pèse le plus sur la chauffe du GPU.")
                slider("Changements ignorés en dessous de", t.minDirtyPercent, 0...3, step: 0.05, format: "%.2f %% de l'image",
                       help: "Un curseur qui clignote ou une petite animation ne relancent pas l'OCR.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Rendu

    private var rendering: some View {
        Form {
            Section("Police") {
                slider("Taille", t.fontScale, 0.7...1.5, step: 0.01, format: "× %.2f",
                       help: "Corrige la taille détectée (si la traduction paraît plus petite que l'original : augmenter).")
                Picker("Famille", selection: t.font) { ForEach(FontChoice.allCases) { Text($0.label).tag($0) } }
                Picker("Graisse", selection: t.weightShift) {
                    Text("Plus fine").tag(-1); Text("Détectée").tag(0); Text("Plus grasse").tag(1)
                }
            }
            Section("Traduction plus longue que l'original") {
                Picker("Si elle ne tient pas", selection: t.overflow) { ForEach(Overflow.allCases) { Text($0.label).tag($0) } }
                slider("Réduction maximale", t.minShrink, 0.4...1, step: 0.05, format: "%.0f %%", scale: 100,
                       help: "Jusqu'où la police peut rétrécir pour faire tenir la traduction (100 % = jamais).")
            }
            Section("Fond") {
                slider("Opacité sur photo / vidéo", t.photoOpacity, 0.5...1, step: 0.05, format: "%.0f %%", scale: 100,
                       help: "Sur un fond uni, la couleur exacte est toujours utilisée.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Moteurs

    private var engines: some View {
        Form {
            Section("Écran") {
                Picker("Moteur", selection: $hub.engine) { ForEach(EngineKind.allCases) { Text($0.label).tag($0) } }
                Picker("Sens", selection: $hub.direction) { ForEach(Direction.allCases) { Text($0.label).tag($0) } }
            }
            Section("Pages web (extension)") {
                enginePicker("Ce qui est visible", t.webVisibleEngine)
                enginePicker("Le reste de la page", t.webBackgroundEngine)
                Stepper("Liens par paragraphe avant découpage : \(store.t.maxTagsWhole)", value: t.maxTagsWhole, in: 2...40)
                note("Un paragraphe avec plus de liens (références, listes) est traduit morceau par morceau : plus rapide et sûr, sens un peu moins fin.")
            }
            Section("Opus-MT") {
                Toggle("Utiliser le GPU (6× plus rapide)", isOn: t.opusGPU)
                HStack {
                    Text("État")
                    Spacer()
                    Text(opusState).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var opusState: String {
        switch opus.state {
        case .ready: return "prêt"
        case .starting: return "démarrage…"
        case .stopped: return "arrêté (démarre à la demande)"
        case .failed(let m): return "erreur : \(m)"
        }
    }

    // MARK: Doublage

    private var dubbing: some View {
        Form {
            Section("Source") {
                Picker("Mode", selection: t.dubSource) {
                    Text("Vidéos Firefox, préparées à l'avance (recommandé)").tag("web")
                    Text("Son d'une app, en direct (différé)").tag("system")
                }
                note(store.t.dubSource == "web"
                     ? "L'app récupère l'audio et les sous-titres de la vidéo (yt-dlp) et prépare le doublage devant la tête de lecture. La vidéo n'est pas retardée ; au démarrage ou après un saut, courte mise en mémoire tampon."
                     : "Le son de l'app est capté et doublé en direct, avec un délai ; l'extension retarde la vidéo d'autant.")
                if store.t.dubSource == "web" {
                    Toggle("Utiliser les cookies de Firefox (vidéos réservées aux abonnés ou limitées par l'âge)", isOn: t.dubCookies)
                    Toggle("Charger le moteur dès l'ouverture de l'app (⌃⌥A instantané, ~8 Go de mémoire)", isOn: t.dubPreload)
                }
            }
            Section("Mode direct") {
                Picker("Application à doubler", selection: t.dubApp) {
                    let apps = DubController.candidateApps()
                    if !apps.contains(where: { $0.0 == store.t.dubApp }) {
                        Text(DubController.appName(store.t.dubApp)).tag(store.t.dubApp)
                    }
                    ForEach(apps, id: \.0) { Text($0.1).tag($0.0) }
                }
                note("Son de cette app coupé et remplacé par le doublage. Dans Firefox, l'extension retarde aussi la vidéo pour garder les lèvres synchronisées.")
            }
            Section("Synchronisation (mode direct)") {
                slider("Délai (son et image)", t.dubDelay, 3...12, step: 0.5, format: "%.1f s",
                       help: "Le temps laissé à l'IA pour écouter, traduire et parler. Mesuré : 7 s en simultané, 9 s en phrases entières. Trop court : des phrases arrivent en retard.")
                Picker("Découpage", selection: t.dubMode) {
                    Text("Simultané (segments courts)").tag("simultaneous")
                    Text("Phrases entières (plus naturel, délai plus long)").tag("sentence")
                }
                slider("Réglage fin de l'image", t.videoOffsetMs, -500...500, step: 10, format: "%+.0f ms",
                       help: "Si les lèvres sont en avance ou en retard sur la voix : décale la vidéo de quelques millisecondes.")
            }
            Section("Voix") {
                Picker("Voix", selection: t.dubVoice) {
                    Text("Chatterbox (meilleur français)").tag("chatterbox")
                    Text("Qwen3-TTS (plus rapide, accent possible)").tag("qwen3")
                }
                Stepper("Ateliers de voix en parallèle : \(store.t.dubWorkers)", value: t.dubWorkers, in: 1...4)
                note("Plus d'ateliers = moins de retard quand ça parle beaucoup, mais plus de mémoire et de chauffe. Pris en compte au prochain démarrage du doublage.")
            }
            Section("Réalisme") {
                slider("Intégration acoustique", t.dubRoom, 0...1, step: 0.05, format: "%.0f %%", scale: 100,
                       help: "Petite réverbération et aigus adoucis : la voix française semble enregistrée dans la même pièce que la vidéo, au lieu d'être « collée » par-dessus.")
            }
            Section("Mélange") {
                slider("Voix française", t.dubGain, 0...2, step: 0.05, format: "%.0f %%", scale: 100, help: "")
                slider("Fond (musique, bruitages)", t.bgGain, 0...2, step: 0.05, format: "%.0f %%", scale: 100, help: "")
                slider("Voix d'origine", t.origGain, 0...1, step: 0.05, format: "%.0f %%", scale: 100,
                       help: "Laisser un peu de la voix d'origine en fond, comme un doublage de documentaire.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Débogage

    private var debug: some View {
        Form {
            Section("Affichage") {
                Toggle("Cadres du suivi", isOn: t.debugBoxes)
                note("Vert = bloc suivi, rouge = perdu (montré en transparence), gris = pas encore d'information.")
                Toggle("Compteur en direct (images/s, OCR, suivi)", isOn: t.hud)
            }
            Section {
                Button("Revenir aux réglages par défaut") { store.reset() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Éléments

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double,
                        format: String, scale: Double = 1, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue * scale)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
            note(help)
        }
    }

    private func enginePicker(_ title: String, _ value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            Text("Comme l'écran").tag("screen")
            ForEach(EngineKind.allCases) { Text($0.label).tag($0.rawValue) }
        }
    }
}
