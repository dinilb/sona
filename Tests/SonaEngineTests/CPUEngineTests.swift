import Foundation
import NotesKit
import XCTest

@testable import SonaEngine

/// The CPU-only engine (an iPhone app in the background) transcribes like the Neural Engine one. Needs the test
/// models (test-home, or SONA_TEST_HOME) and macOS `say`; skips without them.
final class CPUEngineTests: XCTestCase {
    func testCPUOnlyEngineTranscribes() async throws {
        let testHome = ProcessInfo.processInfo.environment["SONA_TEST_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("test-home")
        let previous = ProcessInfo.processInfo.environment["SONA_HOME"]
        setenv("SONA_HOME", testHome.path, 1)
        defer { if let previous { setenv("SONA_HOME", previous, 1) } else { unsetenv("SONA_HOME") } }
        guard Models.isReady(model: "v2") else { throw XCTSkip("no v2 models in \(testHome.path); set SONA_TEST_HOME") }

        let aiff = FileManager.default.temporaryDirectory.appendingPathComponent("cpu-\(UUID().uuidString).aiff")
        let wav = aiff.deletingPathExtension().appendingPathExtension("wav")
        defer { for f in [aiff, wav] { try? FileManager.default.removeItem(at: f) } }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "Remind me to call the bank tomorrow morning."]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("macOS say couldn't synthesize speech") }
        let reader = try AudioFileReader(url: aiff)
        let writer = try WavFile(creating: wav)
        while let chunk = try reader.next() { try writer.append(chunk) }
        try writer.finish()

        let engine = try await Engine.load(model: "v2", cpuOnly: true)
        XCTAssertTrue(engine.cpuOnly)
        let t = try await engine.process(wav: wav, startedAt: Date())
        XCTAssertTrue(t.text.lowercased().contains("bank"), t.text)
    }
}
