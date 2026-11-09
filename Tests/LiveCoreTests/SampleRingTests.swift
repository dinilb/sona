import XCTest

@testable import LiveCore

final class SampleRingTests: XCTestCase {
    private func write(_ ring: SampleRing, _ values: [Float], host: UInt64, stride: Int = 1) -> Bool {
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: values.count / stride, stride: stride, hostTime: host) }
    }

    private func drainAll(_ ring: SampleRing) -> [(SampleRing.Block, [Float])] {
        var out: [(SampleRing.Block, [Float])] = []
        ring.drain { block, samples in out.append((block, Array(samples))) }
        return out
    }

    func testBlocksComeOutInOrderWithMarks() {
        let ring = SampleRing(capacity: 100)
        XCTAssertTrue(write(ring, [1, 2, 3], host: 10))
        XCTAssertTrue(write(ring, [4, 5], host: 20))
        let blocks = drainAll(ring)
        XCTAssertEqual(blocks.map(\.1), [[1, 2, 3], [4, 5]])
        XCTAssertEqual(blocks.map(\.0.deviceIndex), [0, 3])
        XCTAssertEqual(blocks.map(\.0.hostTime), [10, 20])
        XCTAssertTrue(drainAll(ring).isEmpty)
    }

    func testWrapsAroundTheEnd() {
        let ring = SampleRing(capacity: 10)
        var next: Float = 0
        var expected: [Float] = []
        var got: [Float] = []
        // 7-sample blocks against a 10-sample ring: every other block straddles the end.
        for round in 0..<20 {
            let block = (0..<7).map { _ -> Float in next += 1; return next }
            expected += block
            XCTAssertTrue(write(ring, block, host: UInt64(round)))
            let out = drainAll(ring)
            XCTAssertEqual(out.count, 1)
            XCTAssertEqual(out.first?.0.deviceIndex, round * 7)
            got += out.flatMap(\.1)
        }
        XCTAssertEqual(got, expected)
        XCTAssertEqual(ring.droppedSamples, 0)
    }

    func testOverrunDropsWholeBlocksAndKeepsDeviceIndex() {
        let ring = SampleRing(capacity: 10)
        XCTAssertTrue(write(ring, [1, 2, 3, 4], host: 1))
        XCTAssertTrue(write(ring, [5, 6, 7, 8], host: 2))
        XCTAssertFalse(write(ring, [9, 10, 11, 12], host: 3))  // 8 used, 4 more don't fit
        XCTAssertFalse(write(ring, [13, 14, 15], host: 4))
        XCTAssertEqual(ring.droppedSamples, 7)
        XCTAssertTrue(write(ring, [16, 17], host: 5))  // exactly fills it
        let blocks = drainAll(ring)
        XCTAssertEqual(blocks.map(\.1), [[1, 2, 3, 4], [5, 6, 7, 8], [16, 17]])
        // The block after the gap still knows where it sits in the device's timeline.
        XCTAssertEqual(blocks.map(\.0.deviceIndex), [0, 4, 15])
        XCTAssertEqual(blocks.last?.0.hostTime, 5)
        // Space is back once drained.
        XCTAssertTrue(write(ring, [18, 19, 20, 21, 22, 23, 24, 25, 26, 27], host: 6))
        XCTAssertEqual(drainAll(ring).first?.0.deviceIndex, 17)
    }

    func testMarkCapacityAlsoCountsAsOverrun() {
        let ring = SampleRing(capacity: 100, blockCapacity: 2)
        XCTAssertTrue(write(ring, [1], host: 1))
        XCTAssertTrue(write(ring, [2], host: 2))
        XCTAssertFalse(write(ring, [3], host: 3))
        XCTAssertEqual(ring.droppedSamples, 1)
        XCTAssertEqual(drainAll(ring).map(\.1), [[1], [2]])
        XCTAssertTrue(write(ring, [4], host: 4))
        XCTAssertEqual(drainAll(ring).map(\.0.deviceIndex), [3])
    }

    func testTakesTheFirstChannelOfInterleavedAudio() {
        let ring = SampleRing(capacity: 4)
        XCTAssertTrue(write(ring, [1, -1, 2, -2, 3, -3], host: 0, stride: 2))
        XCTAssertTrue(drainAll(ring).first.map { $0.1 == [1, 2, 3] } ?? false)
        XCTAssertTrue(write(ring, [4, -4, 5, -5, 6, -6], host: 0, stride: 2))  // wraps
        XCTAssertEqual(drainAll(ring).first?.1, [4, 5, 6])
    }

    /// A real producer thread against a consumer: nothing reordered, lost or duplicated unless counted as dropped.
    func testConcurrentProducerAndConsumer() {
        let ring = SampleRing(capacity: 256)
        let blocks = 20_000, size = 13
        let producer = Thread {
            var block = [Float](repeating: 0, count: size)
            for b in 0..<blocks {
                for i in 0..<size { block[i] = Float(b * size + i) }
                block.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: size, hostTime: UInt64(b)) }
            }
        }
        producer.start()
        var received = 0
        var lastIndex = -1
        var finished = false
        while !finished {
            finished = producer.isFinished  // then one last drain
            ring.drain { block, samples in
                XCTAssertGreaterThan(block.deviceIndex, lastIndex)
                XCTAssertEqual(block.hostTime, UInt64(block.deviceIndex / size))
                for (i, x) in samples.enumerated() where x != Float(block.deviceIndex + i) {
                    XCTFail("sample \(block.deviceIndex + i) was \(x)")
                    break
                }
                lastIndex = block.deviceIndex
                received += samples.count
            }
        }
        XCTAssertGreaterThan(received, 0)
        XCTAssertEqual(received + ring.droppedSamples, blocks * size)
    }
}
