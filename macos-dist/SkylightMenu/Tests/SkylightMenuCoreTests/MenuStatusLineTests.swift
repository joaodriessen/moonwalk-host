import Testing
@testable import SkylightMenuCore

@Suite("MenuStatusLine")
struct MenuStatusLineTests {
    @Test("resumable target is ready, while active streaming takes precedence")
    func resumableTarget() {
        #expect(MenuStatusLine.text(phase: .connected, streaming: false, clientName: "", height: 0, fps: 0, encoder: "", resumable: true) == "Ready to Resume")
        #expect(MenuStatusLine.text(phase: .connected, streaming: true, clientName: "", height: 0, fps: 0, encoder: "", resumable: true) == "Streaming")
        #expect(MenuStatusLine.text(phase: .offline, streaming: false, clientName: "", height: 0, fps: 0, encoder: "", resumable: true) == "Not Running")
    }
    @Test("connecting")
    func connecting() {
        #expect(
            MenuStatusLine.text(phase: .connecting, streaming: false, clientName: "", height: 0, fps: 0, encoder: "")
                == "Starting Up…"
        )
    }

    @Test("offline")
    func offline() {
        #expect(
            MenuStatusLine.text(phase: .offline, streaming: false, clientName: "", height: 0, fps: 0, encoder: "")
                == "Not Running"
        )
    }

    @Test("untrusted")
    func untrusted() {
        #expect(
            MenuStatusLine.text(phase: .untrusted, streaming: false, clientName: "", height: 0, fps: 0, encoder: "")
                == "Can't Verify Moonwalk Host"
        )
    }

    @Test("connected idle")
    func connectedIdle() {
        #expect(
            MenuStatusLine.text(phase: .connected, streaming: false, clientName: "", height: 0, fps: 0, encoder: "")
                == "Ready"
        )
    }

    @Test("connected streaming with full metrics")
    func connectedStreamingWithFullMetrics() {
        #expect(
            MenuStatusLine.text(phase: .connected, streaming: true, clientName: "Living Room PC", height: 1080, fps: 60, encoder: "hevc")
                == "Streaming to Living Room PC · 1080p60 · HEVC"
        )
    }

    @Test("connected streaming with no metrics yet")
    func connectedStreamingWithNoMetricsYet() {
        #expect(
            MenuStatusLine.text(phase: .connected, streaming: true, clientName: "Living Room PC", height: 0, fps: 0, encoder: "")
                == "Streaming to Living Room PC"
        )
    }

    @Test("connected streaming, height known, fps unknown omits fps")
    func connectedStreamingHeightKnownFpsUnknownOmitsFps() {
        #expect(
            MenuStatusLine.text(phase: .connected, streaming: true, clientName: "Living Room PC", height: 1080, fps: 0, encoder: "")
                == "Streaming to Living Room PC · 1080p"
        )
    }

    @Test("connected streaming, unrecognized encoder omits codec")
    func connectedStreamingUnrecognizedEncoderOmitsCodec() {
        #expect(
            MenuStatusLine.text(phase: .connected, streaming: true, clientName: "Living Room PC", height: 1080, fps: 60, encoder: "mystery")
                == "Streaming to Living Room PC · 1080p60"
        )
    }

    @Test("connected streaming H.264")
    func connectedStreamingH264() {
        #expect(
            MenuStatusLine.text(phase: .connected, streaming: true, clientName: "Living Room PC", height: 2160, fps: 30, encoder: "h264")
                == "Streaming to Living Room PC · 4K30 · H.264"
        )
    }

    @Test("connected streaming AV1")
    func connectedStreamingAV1() {
        #expect(
            MenuStatusLine.text(phase: .connected, streaming: true, clientName: "Living Room PC", height: 1440, fps: 60, encoder: "av1")
                == "Streaming to Living Room PC · 1440p60 · AV1"
        )
    }

    @Test("connected streaming, empty client name falls back to generic Streaming")
    func connectedStreamingEmptyClientNameFallsBack() {
        #expect(
            MenuStatusLine.text(phase: .connected, streaming: true, clientName: "", height: 1080, fps: 60, encoder: "hevc")
                == "Streaming · 1080p60 · HEVC"
        )
    }

    @Test("connected streaming, empty client name and no metrics")
    func connectedStreamingEmptyClientNameNoMetrics() {
        #expect(
            MenuStatusLine.text(phase: .connected, streaming: true, clientName: "", height: 0, fps: 0, encoder: "")
                == "Streaming"
        )
    }
}
