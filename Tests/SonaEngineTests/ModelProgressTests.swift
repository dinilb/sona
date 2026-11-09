import XCTest

@testable import SonaEngine

/// The download bar follows the bytes on disk (Models.downloadFraction, Models.bytesOnDisk).
final class ModelProgressTests: XCTestCase {
    func testTheBarIsTheShareOfBytesUpToTheDownloadShare() {
        let expected: Int64 = 1_000
        XCTAssertEqual(Models.downloadFraction(bytes: 0, expected: expected), 0)
        XCTAssertEqual(Models.downloadFraction(bytes: 500, expected: expected), Models.downloadShare / 2, accuracy: 1e-9)
        XCTAssertEqual(Models.downloadFraction(bytes: 1_000, expected: expected), Models.downloadShare, accuracy: 1e-9)
        // More on disk than expected (a bigger model revision) never passes the prep's share.
        XCTAssertEqual(Models.downloadFraction(bytes: 5_000, expected: expected), Models.downloadShare, accuracy: 1e-9)
        XCTAssertEqual(Models.downloadFraction(bytes: -1, expected: expected), 0)
        XCTAssertEqual(Models.downloadFraction(bytes: 10, expected: 0), 0)
    }

    func testBytesOnDiskCountsNestedAndHalfDownloadedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sona-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let weights = root.appendingPathComponent("parakeet/Encoder.mlmodelc/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data(count: 300).write(to: weights.appendingPathComponent("weight.bin.partial"))
        try Data(count: 200).write(to: root.appendingPathComponent("parakeet/config.json"))
        try Data(count: 0).write(to: root.appendingPathComponent(".ready-v2"))
        XCTAssertEqual(Models.bytesOnDisk(root), 500)
        XCTAssertEqual(Models.bytesOnDisk(root.appendingPathComponent("missing")), 0)
    }

    func testTheV2SizeIsWhatItMeasured() {
        XCTAssertEqual(Models.expectedBytes(model: "v2"), 487_263_709)
        XCTAssertGreaterThan(Models.expectedBytes(model: "v3"), Models.expectedBytes(model: "v2"))
    }
}
