import Foundation
import Testing
@testable import SonaWatch

struct WatchTransferTests {
    @Test func metadataRoundTrips() {
        let recording = WatchRecording(startedAt: Date(timeIntervalSince1970: 1_000), duration: 12.5)
        let back = WatchRecording(metadata: recording.metadata)
        #expect(back?.id == recording.id)
        #expect(back?.startedAt == recording.startedAt)
        #expect(back?.duration == 12.5)
    }

    @Test func ackCarriesTheID() {
        #expect(Ack.id(in: Ack.message("abc")) == "abc")
        #expect(Ack.id(in: ["kind": "other", "id": "abc"]) == nil)
    }
}
