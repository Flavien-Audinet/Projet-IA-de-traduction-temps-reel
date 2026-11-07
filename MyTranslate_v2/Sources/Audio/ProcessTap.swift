import Foundation
import CoreAudio
import AudioToolbox
import AppKit

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePID(_ pid: pid_t) -> pid_t

/// Capte le son d'une application (et de ses processus auxiliaires : onglets Firefox, etc.)
/// via un « process tap » Core Audio, en le COUPANT à la source (le doublage le remplace).
/// Le son arrive en float32 stéréo entrelacé, avec l'heure de capture (CLOCK_UPTIME_RAW, ns).
final class ProcessTap {
    var onAudio: ((UnsafeBufferPointer<Float>, Int, UInt64) -> Void)?   // (échantillons entrelacés, images, heure ns)
    private(set) var sampleRate: Double = 48000
    private(set) var tappedPIDs: Set<pid_t> = []

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "mytranslate.tap", qos: .userInteractive)
    private var scratch: [Float] = []
    private var timebase = mach_timebase_info_data_t()

    enum TapError: LocalizedError {
        case noProcess, create(OSStatus, String)
        var errorDescription: String? {
            switch self {
            case .noProcess: return "l'application ne joue aucun son pour l'instant"
            case .create(let s, let w): return "\(w) (code \(s)) — autorise MyTranslate dans Réglages Système › Confidentialité › Enregistrement audio"
            }
        }
    }

    init() { mach_timebase_info(&timebase) }

    /// Processus audio appartenant à l'app : elle-même et ceux dont elle est « responsable ».
    static func audioProcesses(of bundleID: String) -> [(AudioObjectID, pid_t)] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
        let main = app.processIdentifier
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { obj in
            var pid: pid_t = 0
            var s = UInt32(MemoryLayout<pid_t>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(obj, &a, 0, nil, &s, &pid) == noErr else { return nil }
            return pid == main || responsiblePID(pid) == main ? (obj, pid) : nil
        }
    }

    func start(bundleID: String) throws {
        stop()
        let procs = Self.audioProcesses(of: bundleID)
        guard !procs.isEmpty else { throw TapError.noProcess }
        tappedPIDs = Set(procs.map(\.1))

        let desc = CATapDescription(stereoMixdownOfProcesses: procs.map(\.0))
        desc.uuid = UUID()
        desc.name = "MyTranslate"
        desc.isPrivate = true
        desc.muteBehavior = .muted                       // la voix d'origine ne sort plus des haut-parleurs
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw TapError.create(err, "création du tap audio impossible") }

        // Format du tap (fréquence d'échantillonnage du périphérique de sortie).
        var fmt = AudioStreamBasicDescription()
        var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var faddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &faddr, 0, nil, &fsize, &fmt) == noErr, fmt.mSampleRate > 0 { sampleRate = fmt.mSampleRate }

        // Appareil agrégé privé : périphérique de sortie (horloge) + tap (entrée).
        let outputUID = Self.defaultOutputUID() ?? ""
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MyTranslate (capture)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID)
        guard err == noErr else { stop(); throw TapError.create(err, "création de l'appareil de capture impossible") }

        err = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, queue) { [weak self] _, input, inTime, _, _ in
            self?.handle(input, inTime)
        }
        guard err == noErr else { stop(); throw TapError.create(err, "lecture du tap impossible") }
        err = AudioDeviceStart(aggregateID, ioProc)
        guard err == noErr else { stop(); throw TapError.create(err, "démarrage de la capture impossible") }
    }

    private func handle(_ list: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = abl.first, let d0 = first.mData else { return }
        let ns = UInt64(Double(time.pointee.mHostTime) * Double(timebase.numer) / Double(timebase.denom))
        if abl.count >= 2, let d1 = abl[1].mData {
            // Non entrelacé (un tampon par canal) → entrelacé
            let n = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            if scratch.count < n * 2 { scratch = [Float](repeating: 0, count: n * 2) }
            let l = d0.assumingMemoryBound(to: Float.self), r = d1.assumingMemoryBound(to: Float.self)
            for i in 0..<n { scratch[2 * i] = l[i]; scratch[2 * i + 1] = r[i] }
            scratch.withUnsafeBufferPointer { onAudio?(UnsafeBufferPointer(rebasing: $0[0..<(n * 2)]), n, ns) }
        } else {
            let ch = Int(max(1, first.mNumberChannels))
            let total = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let n = total / ch
            let p = d0.assumingMemoryBound(to: Float.self)
            if ch == 2 {
                onAudio?(UnsafeBufferPointer(start: p, count: total), n, ns)
            } else {
                if scratch.count < n * 2 { scratch = [Float](repeating: 0, count: n * 2) }
                for i in 0..<n { scratch[2 * i] = p[i * ch]; scratch[2 * i + 1] = p[i * ch + (ch > 1 ? 1 : 0)] }
                scratch.withUnsafeBufferPointer { onAudio?(UnsafeBufferPointer(rebasing: $0[0..<(n * 2)]), n, ns) }
            }
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let p = ioProc { AudioDeviceStop(aggregateID, p); AudioDeviceDestroyIOProcID(aggregateID, p) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProc = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedPIDs = []
    }

    static func defaultOutputUID() -> String? {
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let u = uid else { return nil }
        return u.takeRetainedValue() as String
    }
}
