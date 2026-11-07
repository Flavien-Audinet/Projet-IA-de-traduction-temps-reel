import Carbon
import Foundation

/// Raccourcis clavier globaux (API Carbon : aucune autorisation « Accessibilité » nécessaire).
final class HotKeys {
    static let shared = HotKeys()

    struct Combo: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String

        static let ctrlOpt = UInt32(controlKey | optionKey)
        static let window = Combo(keyCode: UInt32(kVK_ANSI_W), modifiers: ctrlOpt, label: "⌃⌥W")
        static let region = Combo(keyCode: UInt32(kVK_ANSI_R), modifiers: ctrlOpt, label: "⌃⌥R")
        static let fullscreen = Combo(keyCode: UInt32(kVK_ANSI_F), modifiers: ctrlOpt, label: "⌃⌥F")
        static let audio = Combo(keyCode: UInt32(kVK_ANSI_A), modifiers: ctrlOpt, label: "⌃⌥A")
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false

    func register(_ combo: Combo, handler: @escaping () -> Void) {
        installIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x4D_54_52_4B), id: id)   // 'MTRK'
        if RegisterEventHotKey(combo.keyCode, combo.modifiers, hk, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            refs.append(ref)
        } else {
            NSLog("MyTranslate: raccourci %@ déjà utilisé par une autre app", combo.label)
        }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeys.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
