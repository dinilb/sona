import AVFoundation
import Foundation

/// Reads any audio file AVFoundation can open as 16 kHz mono float chunks, so a 2-hour file never sits in
/// memory whole. One persistent converter, so there are no clicks at chunk edges.
public final class AudioFileReader {
    public let duration: Double
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let chunkFrames: AVAudioFrameCount
    private var done = false

    public init(url: URL, chunkSeconds: Double = 30) throws {
        file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: input, to: output)
        else { throw ReaderError.unsupported(url.lastPathComponent) }
        converter.downmix = true
        self.output = output
        self.converter = converter
        chunkFrames = AVAudioFrameCount(chunkSeconds * input.sampleRate)
        duration = Double(file.length) / input.sampleRate
    }

    /// The next chunk, or nil at the end.
    public func next() throws -> [Float]? {
        guard !done else { return nil }
        let capacity = AVAudioFrameCount(Double(chunkFrames) * 16_000 / file.processingFormat.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var readError: Error?
        var status: AVAudioConverterOutputStatus
        var error: NSError?
        status = converter.convert(to: out, error: &error) { [file, chunkFrames, format = file.processingFormat] want, inputStatus in
            guard file.framePosition < file.length,
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: min(want, chunkFrames))
            else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: buffer, frameCount: min(want, chunkFrames))
            } catch {
                readError = error
            }
            if buffer.frameLength == 0 {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        if let readError { throw readError }
        if let error { throw error }
        if status == .endOfStream || status == .error { done = true }
        guard out.frameLength > 0 else { return done ? nil : [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    enum ReaderError: Error, CustomStringConvertible {
        case unsupported(String)
        var description: String {
            switch self {
            case .unsupported(let name): return "can't convert \(name) to 16 kHz mono"
            }
        }
    }
}
