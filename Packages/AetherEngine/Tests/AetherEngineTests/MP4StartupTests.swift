import Testing
@testable import AetherEngine

@Suite("MP4 startup avoids remote cue prewarming")
struct MP4StartupTests {
    @Test func mp4FamilyUsesExistingIndex() {
        #expect(HLSVideoEngine.skipsCuePrewarm(containerFormatName: "mov,mp4,m4a,3gp,3g2,mj2"))
        #expect(HLSVideoEngine.skipsCuePrewarm(containerFormatName: "mp4"))
    }

    @Test func otherContainersKeepExistingBehavior() {
        #expect(!HLSVideoEngine.skipsCuePrewarm(containerFormatName: "matroska,webm"))
        #expect(!HLSVideoEngine.skipsCuePrewarm(containerFormatName: "mpegts"))
        #expect(!HLSVideoEngine.skipsCuePrewarm(containerFormatName: nil))
    }
}
