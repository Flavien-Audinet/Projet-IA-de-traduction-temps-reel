import ScreenCaptureKit
import CoreMedia

/// Flux d'images d'une fenêtre, d'un écran ou d'une zone via ScreenCaptureKit.
/// ScreenCaptureKit n'envoie une image « complete » que lorsque le contenu a changé :
/// une page immobile ne coûte donc presque rien.
final class FrameCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Appelé sur la file de capture avec chaque nouvelle image (BGRA) et les zones modifiées (pixels).
    var onFrame: ((CVPixelBuffer, [CGRect]) -> Void)?
    var onStop: ((Error?) -> Void)?

    private var stream: SCStream?
    /// File de capture : les images y arrivent, et le suivi de mouvement y tourne.
    let queue = DispatchQueue(label: "mytranslate.capture", qos: .userInteractive)

    static func configuration(pixelSize: CGSize, sourceRect: CGRect?, fps: Double) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = max(2, Int(pixelSize.width))
        c.height = max(2, Int(pixelSize.height))
        if let sourceRect { c.sourceRect = sourceRect }
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        c.showsCursor = false
        c.queueDepth = 6     // une image peut rester tenue par l'OCR pendant que les suivantes arrivent
        c.colorSpaceName = CGColorSpace.sRGB
        return c
    }

    func start(filter: SCContentFilter, config: SCStreamConfiguration) async throws {
        await stop()
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func update(config: SCStreamConfiguration) async {
        try? await stream?.updateConfiguration(config)
    }

    func update(filter: SCContentFilter) async {
        try? await stream?.updateContentFilter(filter)
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = atts.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer else { return }
        let dirty = (info[.dirtyRects] as? [NSDictionary])?.compactMap { CGRect(dictionaryRepresentation: $0) } ?? []
        onFrame?(pb, dirty)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }
}
