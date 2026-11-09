import Foundation
import Testing
@testable import Sona

/// What the app does with a link it's opened by. This is the real model, which in the simulator records from silence
/// (never the mic), so a link that wrongly got through would show up as a recording. Only links that must be refused
/// are sent: nothing here is meant to start one.
@MainActor
struct LinkHandlingTests {
    @Test func aRecordLinkWithoutThisDevicesKeyStartsNothing() async throws {
        let model = AppModel.shared
        #expect(!model.isRecording)
        // The same link with the key is one the app acts on (so refusing the others below is the key's doing).
        #expect(DeepLink.trusted(url: DeepLink.record.url) == .record)

        let refused: [(why: String, url: URL)] = [
            ("no key: what a page or another app can open", URL(string: "sona://record")!),
            ("an empty key", URL(string: "sona://record?k=")!),
            ("another device's key", DeepLink.record.url(key: "not-this-devices-key")),
            ("the right key, another scheme", URL(string: "https://record?k=\(LinkKey.current())")!),
        ]
        // One at a time, looking after each: a link that got through starts a recording, and the next one that got
        // through would stop it again (the model toggles), so sending them all first could cancel out.
        for (why, url) in refused {
            model.handle(url)
            // A start is a Task on the main actor: give it every chance to run before looking.
            try await Task.sleep(for: .milliseconds(250))
            let started = model.isRecording
            if started { await model.recorder.stop() }  // so a failure here can't leave a recording running
            #expect(!started, "\(why)")
        }
    }
}
