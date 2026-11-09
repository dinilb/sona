import AVFoundation
import Foundation

/// Audio from a file instead of the mic, for the simulator and tests: any file AVAudioFile reads, played in real time
/// through the same `FrameMaker` as the mic's audio. After the file ends, or with no file at all, it's silence, like a
/// quiet room, so a recording lasts as long as it ran. The simulator's mic is the Mac's, so it's never used there.
nonisolated final class FileAudioSource: AudioSource, @unchecked Sendable {
    static let tick: TimeInterval = 0.1

    private let url: URL?
    private let handlers: CaptureHandlers
    private let queue = DispatchQueue(label: "com.dinilb.sona.file-audio")

    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var maker: FrameMaker?
    private var started = Date()
    private var fed = 0

    /// `file`: nil for silence.
    init(file url: URL?, handlers: CaptureHandlers) {
        self.url = url
        self.handlers = handlers
    }

    func start() throws {
        try queue.sync {
            var format = AVAudioFormat(standardFormatWithSampleRate: Double(AudioFrame.sampleRate), channels: 1)!
            if let url {
                let file = try AVAudioFile(forReading: url)
                format = file.processingFormat
                self.file = file
            }
            guard let maker = FrameMaker(from: format, onFrame: handlers.frame) else { throw MicError.cantConvert }
            self.format = format
            self.maker = maker
            started = Date()
            fed = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.tick, repeating: Self.tick, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.feed() }
            timer.resume()
            self.timer = timer
        }
        handlers.state(.running, nil)
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            file = nil
            maker = nil
        }
        handlers.state(.stopped, nil)
    }

    /// Catches up with the wall clock, so the audio keeps real time even when a tick runs late.
    private func feed() {
        guard let maker, let format else { return }
        let due = Int(Date().timeIntervalSince(started) / Self.tick)
        while fed < due, let buffer = nextBuffer(format) {
            maker.process(buffer, startingAt: started.timeIntervalSince1970 + Double(fed) * Self.tick)
            fed += 1
        }
    }

    /// The next 100 ms of the file, padded with silence past its end.
    private func nextBuffer(_ format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * Self.tick)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        if let file, file.framePosition < file.length {
            try? file.read(into: buffer, frameCount: frames)
        }
        let have = Int(buffer.frameLength)
        if have < Int(frames), let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                channels[channel].advanced(by: have).update(repeating: 0, count: Int(frames) - have)
            }
        }
        buffer.frameLength = frames
        return buffer
    }
}
