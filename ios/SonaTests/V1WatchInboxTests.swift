import Foundation
import SonaEngine
import Testing
@testable import Sona

/// The list of watch recordings the iPhone publishes to the watch (`PhoneInventory`): what it has, newest last.
struct V1WatchInboxTests {
    let dir = makeTempDir()

    func inbox(_ acks: FakeAcknowledger) -> WatchInbox {
        WatchInbox(
            spool: Spool(dir: dir.appendingPathComponent("Spool")), receivedFile: dir.appendingPathComponent("received.json"),
            acknowledger: acks)
    }

    func incoming(seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent("incoming-\(UUID().uuidString).wav")
        try makeSpoolWAV(url, seconds: seconds)
        return url
    }

    @Test func listsWhatItReceivedAcrossLaunches() throws {
        let acks = FakeAcknowledger()
        #expect(inbox(acks).receivedIDs().isEmpty)  // a fresh install has nothing, so the watch sends again

        let kept = WatchRecording(startedAt: Date(), duration: 2)
        let short = WatchRecording(startedAt: Date(), duration: 0.2)
        try inbox(acks).receive(file: try incoming(seconds: 2), metadata: kept.metadata)
        try inbox(acks).receive(file: try incoming(seconds: 0.2), metadata: short.metadata)

        // Too short to keep still counts: the watch should let it go.
        #expect(inbox(acks).receivedIDs() == [kept.id, short.id])
        #expect(inbox(acks).receivedIDs(last: 1) == [short.id])
    }

    @Test func theInventoryItPublishesReadsBackOnTheWatch() throws {
        let ids = (0..<(PhoneInventory.kept + 5)).map { _ in UUID().uuidString }
        let inventory = PhoneInventory(ids: Array(ids.suffix(PhoneInventory.kept)), at: Date(timeIntervalSince1970: 1_800_000_000))
        let back = try #require(PhoneInventory(context: inventory.context))
        #expect(back.ids.count == PhoneInventory.kept)
        #expect(back == inventory)
        // Plist types only, as WatchConnectivity needs.
        #expect(PropertyListSerialization.propertyList(inventory.context, isValidFor: .binary))
    }
}
