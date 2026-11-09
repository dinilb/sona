import Foundation

/// Reads and repairs the header of the WAVs the watch records (older builds, and its fallback when the AAC encoder
/// won't start; the watch repairs its own, and the iPhone reads where their samples start, to copy them into its spool
/// as they are). AVAudioRecorder only writes the RIFF and `data`
/// sizes when it stops, so a recording cut off by a crash or a flat battery says it holds no audio although the
/// samples are all on disk. Core Audio may put other chunks (FLLR padding) before `data`, so the chunks are walked.
nonisolated enum WAVFile {
    struct Info: Equatable {
        var sampleRate: Int
        var channels: Int
        var bitsPerSample: Int
        /// Where the `data` chunk's size field is, and where its samples start.
        var dataSizeOffset: Int
        var dataStart: Int
        /// The sizes the header claims.
        var riffSize: UInt32
        var dataSize: UInt32

        var bytesPerFrame: Int { max(1, channels * bitsPerSample / 8) }

        func seconds(ofDataBytes bytes: Int) -> Double {
            sampleRate > 0 ? Double(bytes / bytesPerFrame) / Double(sampleRate) : 0
        }
    }

    /// The header is looked for in at most this many bytes (Core Audio pads up to `data` to a 4 KB boundary).
    static let headerLimit = 64 * 1024

    /// The format and the `data` chunk of a WAV's first bytes; nil if they aren't a PCM WAV we can read.
    static func info(of header: Data) -> Info? {
        let bytes = [UInt8](header)
        guard bytes.count >= 12, ascii(bytes, 0) == "RIFF", ascii(bytes, 8) == "WAVE" else { return nil }
        var offset = 12
        var format: (rate: Int, channels: Int, bits: Int)?
        while offset + 8 <= bytes.count {
            let id = ascii(bytes, offset)
            let size = Int(uint32(bytes, offset + 4))
            if id == "fmt ", offset + 24 <= bytes.count {
                format = (Int(uint32(bytes, offset + 12)), Int(uint16(bytes, offset + 10)), Int(uint16(bytes, offset + 22)))
            } else if id == "data" {
                guard let format else { return nil }
                return Info(
                    sampleRate: format.rate, channels: format.channels, bitsPerSample: format.bits,
                    dataSizeOffset: offset + 4, dataStart: offset + 8,
                    riffSize: uint32(bytes, 4), dataSize: UInt32(size))
            }
            // Chunks are padded to an even size.
            offset += 8 + size + (size & 1)
        }
        return nil
    }

    /// Makes the header's sizes match the samples on disk and returns the audio's length in seconds; nil if the
    /// file isn't a WAV we can read. `force` trusts the file's length over the header (the recorder never
    /// stopped, so the header can't be right); otherwise only sizes that can't be right (0, unknown, past the end
    /// of the file) are rewritten. A half-written last sample is cut off.
    @discardableResult
    static func repair(_ url: URL, force: Bool) throws -> Double? {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: headerLimit), let info = info(of: header) else { return nil }
        let claimed = Int(info.dataSize)
        let broken = claimed == 0 || info.dataSize == .max || info.riffSize == 0 || info.dataStart + claimed > length
        guard force || broken else { return info.seconds(ofDataBytes: claimed) }

        let onDisk = max(0, length - info.dataStart) / info.bytesPerFrame * info.bytesPerFrame
        let dataSize = UInt32(clamping: onDisk)
        let end = info.dataStart + Int(dataSize)
        if end < length { try handle.truncate(atOffset: UInt64(end)) }
        try handle.seek(toOffset: UInt64(info.dataSizeOffset))
        try handle.write(contentsOf: littleEndian(dataSize))
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: littleEndian(UInt32(clamping: end - 8)))
        try handle.synchronize()
        return info.seconds(ofDataBytes: Int(dataSize))
    }

    private static func ascii(_ bytes: [UInt8], _ at: Int) -> String {
        String(decoding: bytes[at..<at + 4], as: UTF8.self)
    }

    private static func uint16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * $1) }
    }

    static func littleEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func littleEndian(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

/// The AAC files the watch records: ADTS (an `.aac`), a run of frames that each start with their own small header
/// (sync word, sample rate, frame length), with nothing at the start or the end to finish. So a recording cut off by a
/// crash or a flat battery is readable up to its last whole frame. About 14 MB an hour at 32 kbps, against 115 MB for
/// a 16-bit WAV, and that's what goes over the watch's radio. The watch reads it for a recording's length and cuts a
/// torn last frame off; the iPhone does the same before it decodes one.
nonisolated enum ADTSFile {
    /// The MPEG-4 sampling frequency index.
    static let sampleRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
    /// Samples in one AAC raw data block.
    static let samplesPerBlock = 1024
    /// The longest a frame can be (its length field is 13 bits), so the most a torn last frame can leave behind.
    static let longestFrame = 8191

    struct Frame: Equatable {
        /// Bytes, its header included.
        var length: Int
        var samples: Int
        var sampleRate: Int
    }

    /// The frame whose header starts at `i`; nil if there isn't a valid header there.
    static func frame(in bytes: [UInt8], at i: Int) -> Frame? {
        // 12 bits of sync word, then the MPEG version (either), the layer (always 0) and the CRC flag (either).
        guard i >= 0, i + 7 <= bytes.count, bytes[i] == 0xFF, bytes[i + 1] & 0xF6 == 0xF0 else { return nil }
        let rateIndex = Int((bytes[i + 2] >> 2) & 0x0F)
        guard rateIndex < sampleRates.count else { return nil }
        let length = (Int(bytes[i + 3] & 0x03) << 11) | (Int(bytes[i + 4]) << 3) | (Int(bytes[i + 5]) >> 5)
        let headerLength = bytes[i + 1] & 0x01 == 1 ? 7 : 9  // 9 with a CRC
        guard length >= headerLength else { return nil }
        let blocks = Int(bytes[i + 6] & 0x03) + 1
        return Frame(length: length, samples: blocks * samplesPerBlock, sampleRate: sampleRates[rateIndex])
    }

    /// Walks the frames and returns the audio's length in seconds: 0 for an empty file, nil if it isn't ADTS. With
    /// `repair`, a torn last frame is cut off, so what's left decodes to the end. Only a tail shorter than a frame is
    /// ever cut: anything longer is damage in the middle, and cutting there could throw away hours of audio. Reads a
    /// megabyte at a time, so an 8-hour recording never sits in memory. Throws when the file can't be opened or
    /// written, which says nothing about what it holds.
    @discardableResult
    static func scan(_ url: URL, repair: Bool) throws -> Double? {
        let handle = try repair ? FileHandle(forUpdating: url) : FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = Int(try handle.seekToEnd())
        guard length > 0 else { return 0 }
        try handle.seek(toOffset: 0)
        var bytes = [UInt8](try handle.read(upToCount: 1 << 20) ?? Data())
        var bytesStart = 0
        var offset = id3Length(bytes)
        var samples = 0
        var sampleRate = 0
        while offset < length {
            // A header is at most 9 bytes: read on from here when it might run past what's in memory.
            if offset + 9 > bytesStart + bytes.count {
                try handle.seek(toOffset: UInt64(offset))
                bytes = [UInt8](try handle.read(upToCount: 1 << 20) ?? Data())
                bytesStart = offset
            }
            // A frame that runs past the end of the file is the torn last one.
            guard let next = frame(in: bytes, at: offset - bytesStart), offset + next.length <= length else { break }
            samples += next.samples
            sampleRate = next.sampleRate
            offset += next.length
        }
        guard sampleRate > 0 else { return nil }
        if repair, offset < length, length - offset <= longestFrame {
            try handle.truncate(atOffset: UInt64(offset))
            try handle.synchronize()
        }
        return Double(samples) / Double(sampleRate)
    }

    /// The length of an ID3v2 tag at the start, if a writer put one there (0 if not): the frames start after it.
    static func id3Length(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return 0 }  // "ID3"
        let size = bytes[6...9].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
        let footer = bytes[5] & 0x10 != 0 ? 10 : 0
        return 10 + size + footer
    }
}
