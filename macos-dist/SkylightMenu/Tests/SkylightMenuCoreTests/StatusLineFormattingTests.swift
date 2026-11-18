import Testing
@testable import SkylightMenuCore

@Suite("StatusLineFormatting")
struct StatusLineFormattingTests {
    @Test("resolution bucket boundaries")
    func resolutionBucketBoundaries() {
        #expect(StatusLineFormatting.resolutionBucket(2160) == "4K")
        #expect(StatusLineFormatting.resolutionBucket(2159) == "1440p")
        #expect(StatusLineFormatting.resolutionBucket(1440) == "1440p")
        #expect(StatusLineFormatting.resolutionBucket(1439) == "1080p")
        #expect(StatusLineFormatting.resolutionBucket(1080) == "1080p")
        #expect(StatusLineFormatting.resolutionBucket(1079) == "1079p")
        #expect(StatusLineFormatting.resolutionBucket(900) == "900p")
    }

    @Test("duration string boundaries")
    func durationStringBoundaries() {
        #expect(StatusLineFormatting.durationString(0) == "0s")
        #expect(StatusLineFormatting.durationString(59) == "59s")
        #expect(StatusLineFormatting.durationString(60) == "1 min")
        #expect(StatusLineFormatting.durationString(3600) == "60 min")
    }
}
