import AVFoundation
import Foundation

/// Match the AVFoundation capture inputs consumed by the host's AVAudio.findMicrophone.
/// Discovery does not request microphone permission or start a capture session.
enum AudioDeviceLister {
    struct Device: Identifiable, Equatable {
        var id: String { name }
        let name: String
    }

    static func inputDevices() -> [Device] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        )
        // The host currently addresses inputs by localized name. Collapse duplicate names so
        // SwiftUI identity/selection matches that contract, rather than inventing device IDs.
        return Set(discovery.devices.map(\.localizedName)).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Device(name: $0) }
    }

    static let blackHoleInfoURL = URL(string: "https://existential.audio/blackhole/")!
}
