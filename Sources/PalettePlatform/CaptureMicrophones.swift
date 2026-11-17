import AVFoundation
import Foundation

/// Audio input devices, by the `uniqueID` that `screencapture -G` expects.
public enum CaptureMicrophones {
    public static func active() -> [(id: String, name: String)] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { (id: $0.uniqueID, name: $0.localizedName) }
    }
}
