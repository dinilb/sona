import Foundation
import XCTest

@testable import NotesKit

/// The log: what an error says in it (never a path, so never a title), and the hook the iPhone copies it from.
final class LogTests: XCTestCase {
    /// A note's path: its file name starts with the title.
    let path = "/Users/someone/Library/Mobile Documents/iCloud~com~dinilb~sona/Documents/Conversations/2026-11-08/15-45 Secret plans.md"

    func testAFileErrorSaysOnlyItsCode() {
        let error = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        XCTAssertEqual(Log.describe(error), "NSCocoaErrorDomain error 513")
    }

    /// iCloud's errors wrap the file error that has the path: the path stays out, the codes under it stay in.
    func testAPathUnderAnotherErrorStaysOut() {
        let file = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSFilePathErrorKey: path])
        let cloud = NSError(
            domain: "BRCloudDocsErrorDomain", code: 35,
            userInfo: [NSUnderlyingErrorKey: file, NSLocalizedDescriptionKey: "The file “15-45 Secret plans.md” couldn’t be saved."])
        let said = Log.describe(cloud)
        XCTAssertEqual(said, "BRCloudDocsErrorDomain error 35 (NSCocoaErrorDomain 4)")
        XCTAssertFalse(said.contains("Secret"))
    }

    func testAURLOrAPathInAnyKeyStaysOut() {
        let url = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: ["NSURL": URL(fileURLWithPath: path)])
        XCTAssertEqual(Log.describe(url), "AVFoundationErrorDomain error -11800")
        let text = NSError(domain: "SomeDomain", code: 7, userInfo: ["SomePathKey": path])
        XCTAssertEqual(Log.describe(text), "SomeDomain error 7")
    }

    /// Sona's own errors that can't hold a name (`LogSafeError`) still say what happened in their own words.
    func testAnAllowedErrorSaysWhatItIs() {
        struct Broken: LogSafeError, CustomStringConvertible { var description: String { "the models aren't there" } }
        XCTAssertEqual(Log.describe(Broken()), "the models aren't there")
    }

    /// Any other error is only its domain and code, however it hides a name: a path mid-sentence, a title in its
    /// payload, a list of URLs.
    func testEveryOtherErrorIsOnlyItsCode() {
        let debug = NSError(
            domain: "SomeDomain", code: 3, userInfo: ["NSDebugDescription": "couldn't open \(path) for reading"])
        XCTAssertEqual(Log.describe(debug), "SomeDomain error 3")
        let urls = NSError(domain: "OtherDomain", code: 4, userInfo: ["files": [URL(fileURLWithPath: path)]])
        XCTAssertEqual(Log.describe(urls), "OtherDomain error 4")
        let quoted = NSError(
            domain: "ThirdDomain", code: 5, userInfo: [NSLocalizedDescriptionKey: "“15-45 Secret plans.md” is busy"])
        XCTAssertFalse(Log.describe(quoted).contains("Secret"))

        enum StoreError: Error, CustomStringConvertible {
            case notFound(String)
            var description: String { "No conversation matches \"2026-11-08/15-45 Secret plans\"" }
        }
        let said = Log.describe(StoreError.notFound("2026-11-08/15-45 Secret plans"))
        XCTAssertFalse(said.contains("Secret"))
        XCTAssertTrue(said.hasSuffix(" error 0"), said)

        // An allowed error with a path somewhere in it still says only its code.
        struct Careless: LogSafeError, CustomNSError, CustomStringConvertible {
            var errorUserInfo: [String: Any] { [NSFilePathErrorKey: "/tmp/15-45 Secret plans.md"] }
            var description: String { "couldn't write /tmp/15-45 Secret plans.md" }
        }
        XCTAssertFalse(Log.describe(Careless()).contains("Secret"))
    }

    func testTheHookRunsOnceTheLineIsWritten() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sona-log-\(UUID().uuidString)")
        let previousHome = ProcessInfo.processInfo.environment["SONA_HOME"]
        setenv("SONA_HOME", home.path, 1)
        defer {
            Log.didWrite = nil
            if let previousHome { setenv("SONA_HOME", previousHome, 1) } else { unsetenv("SONA_HOME") }
            try? FileManager.default.removeItem(at: home)
        }
        XCTAssertNil(Log.didWrite)  // the Mac and the CLI never set one

        let seen = Seen()
        Log.didWrite = { seen.add((try? String(contentsOf: Paths.logFile, encoding: .utf8)) ?? "") }
        Log.note("recording 2026-11-08/15-45 saved: 423.2 s")
        XCTAssertEqual(seen.all.count, 1)
        XCTAssertTrue(seen.all[0].hasSuffix("recording 2026-11-08/15-45 saved: 423.2 s\n"))
    }
}

/// What the hook saw, from any thread.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    func add(_ text: String) {
        lock.lock()
        seen.append(text)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}
