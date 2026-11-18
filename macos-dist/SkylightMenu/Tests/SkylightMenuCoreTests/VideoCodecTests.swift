import Testing
@testable import SkylightMenuCore

@Suite("VideoCodec")
struct VideoCodecTests {
    @Test("forward mapping raw pairs")
    func forwardMappingRawPairs() {
        #expect(VideoCodec.automatic.rawPair.hevcMode == "0")
        #expect(VideoCodec.automatic.rawPair.av1Mode == "0")
        #expect(VideoCodec.h264.rawPair.hevcMode == "1")
        #expect(VideoCodec.h264.rawPair.av1Mode == "1")
        #expect(VideoCodec.hevc.rawPair.hevcMode == "2")
        #expect(VideoCodec.hevc.rawPair.av1Mode == "1")
        #expect(VideoCodec.av1.rawPair.hevcMode == "0")
        #expect(VideoCodec.av1.rawPair.av1Mode == "2")
    }

    @Test("round-trip invariant for every case")
    func roundTripInvariantForEveryCase() {
        for codec in VideoCodec.allCases {
            let pair = codec.rawPair
            #expect(
                VideoCodec.from(hevcMode: pair.hevcMode, av1Mode: pair.av1Mode) == codec,
                "rawPair -> from(...) must be the exact inverse for \(codec)"
            )
        }
    }

    /// The doc-comment-flagged tricky case: an AV1 selection also carries hevc_mode=0, so AV1
    /// must be checked before HEVC/H.264 or it would fall through to Automatic.
    @Test("AV1 checked before HEVC fallthrough")
    func av1CheckedBeforeHEVCFallthrough() {
        #expect(VideoCodec.from(hevcMode: "0", av1Mode: "3") == .av1Main10)
    }

    @Test("garbage inputs fall back to Automatic")
    func garbageInputsFallBackToAutomatic() {
        #expect(VideoCodec.from(hevcMode: nil, av1Mode: nil) == .automatic)
        #expect(VideoCodec.from(hevcMode: "not-a-number", av1Mode: "also-not") == .automatic)
        #expect(VideoCodec.from(hevcMode: "", av1Mode: "") == .automatic)
    }

    @Test("HEVC requires hevc_mode at least two with av1 below")
    func hevcRequiresHevcModeAtLeastTwoWithAV1Below() {
        #expect(VideoCodec.from(hevcMode: "3", av1Mode: "1") == .hevcMain10)
        #expect(VideoCodec.from(hevcMode: "2", av1Mode: "0") == .hevc)
    }

    @Test("H.264 requires exactly one and one")
    func h264RequiresExactlyOneAndOne() {
        #expect(VideoCodec.from(hevcMode: "1", av1Mode: "1") == .h264)
    }

    /// The shipped config sets only hevc_mode = 1, which the host treats as H.264 only.
    @Test("a new install's H.264 config reads as H.264, not Automatic")
    func newInstallConfigReadsAsH264() {
        #expect(VideoCodec.from(hevcMode: "1", av1Mode: nil) == .h264)
        #expect(VideoCodec.from(hevcMode: "1", av1Mode: "0") == .h264)
        #expect(VideoCodec.from(hevcMode: "0", av1Mode: "0") == .automatic)
    }
}
