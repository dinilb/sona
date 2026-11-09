import Foundation

/// Why audio not yet in a note couldn't be read. Its text is Sona's own (never a path or anything heard).
public struct SpoolFailure: Error, CustomStringConvertible {
    public var description: String
    /// The helper went away mid-request: worth one fresh start.
    var restart = false
    public init(_ description: String) { self.description = description }

    func restarting() -> Self {
        var copy = self
        copy.restart = true
        return copy
    }
}

/// How the MCP server reaches audio not yet in a note: what's in the spool, and a way to transcribe a stretch of it.
/// The server never links the speech models itself, so `sona-mcp` still starts instantly: `SpoolHelper` runs `sona
/// spool-serve` for that, only once a tool needs it. Tests pass their own.
public struct SpoolAccess {
    public var recordings: () -> [SpoolRecording]
    /// Seconds `from..<to` of recording `id`, waiting at most about `seconds` for audio still to be transcribed.
    public var transcribe: (_ id: String, _ from: Double, _ to: Double, _ seconds: Double) throws -> SpoolSlice
    /// Ends the helper, and everything it heard with it (AI access was turned off).
    public var stop: () -> Void

    public init(
        recordings: @escaping () -> [SpoolRecording],
        transcribe: @escaping (_ id: String, _ from: Double, _ to: Double, _ seconds: Double) throws -> SpoolSlice,
        stop: @escaping () -> Void = {}
    ) {
        self.recordings = recordings
        self.transcribe = transcribe
        self.stop = stop
    }

    /// No spool: everything is in the notes.
    public static var none: SpoolAccess {
        SpoolAccess(recordings: { [] }, transcribe: { _, _, _, _ in throw SpoolFailure("Audio not yet in a note can't be read here.") })
    }

    #if os(macOS)
    /// The app's spool, transcribed by `helper` (nil: there's no `sona` CLI beside this binary, so it can only say
    /// what's waiting).
    public static func helper(_ helper: SpoolHelper?, dir: URL = Paths.spool) -> SpoolAccess {
        SpoolAccess(
            recordings: { SpoolRecording.all(in: dir) },
            transcribe: { id, from, to, seconds in
                guard let helper else { throw SpoolFailure("The sona command-line tool isn't beside sona-mcp, so audio not yet in a note can't be transcribed.") }
                return try helper.slice(SpoolRequest(id: id, from: from, to: to, seconds: seconds))
            },
            stop: { helper?.stop() })
    }
    #endif
}

#if os(macOS)
/// Runs `sona spool-serve` (the CLI, which has the speech models) and talks to it over a pipe: a `SpoolRequest` as one
/// JSON line out, a `SpoolSlice` back. Started on first use and kept, so its models stay loaded and what it transcribed
/// stays in its memory; it ends when this process does (its stdin closes), on `stop()`, or after 10 idle minutes (then
/// the next request starts it again). Its stderr goes nowhere. Not thread-safe: the MCP server handles one call at a time.
public final class SpoolHelper {
    typealias Failure = SpoolFailure

    public let executable: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    /// Nil if `executable` isn't there.
    public init?(executable: URL) {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        self.executable = executable
    }

    /// The `sona` CLI next to a binary: `Sona.app/Contents/Helpers/sona` for `Contents/MacOS/sona-mcp`, or `sona` in the
    /// same folder (a plain `swift build`). Symlinks (`build/sona-mcp`) are followed first.
    public static func beside(_ binary: URL) -> SpoolHelper? {
        let dir = binary.resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [dir.deletingLastPathComponent().appendingPathComponent("Helpers/sona"), dir.appendingPathComponent("sona")]
        return candidates.lazy.compactMap { SpoolHelper(executable: $0) }.first
    }

    deinit { stop() }

    public func slice(_ request: SpoolRequest) throws -> SpoolSlice {
        var last: Failure?
        for _ in 0..<2 {
            do {
                try start()
                var line = try JSONEncoder().encode(request)
                line.append(10)
                do { try input?.write(contentsOf: line) } catch { throw Failure("The transcriber stopped.").restarting() }
                // Its budget, plus room for a piece already under way and for loading the models the first time.
                return try receive(timeout: request.seconds + 90)
            } catch let failure as Failure where failure.restart {
                stop()
                last = failure
            }
        }
        throw last ?? Failure("The transcriber stopped.")
    }

    public func stop() {
        if let process, process.isRunning { process.terminate() }
        try? input?.close()
        try? output?.close()
        process = nil
        input = nil
        output = nil
        buffer = Data()
    }

    private func start() throws {
        if let process, process.isRunning { return }
        stop()
        // A write to a helper that just quit must fail, not end this server.
        signal(SIGPIPE, SIG_IGN)
        let p = Process()
        p.executableURL = executable
        p.arguments = ["spool-serve"]
        let toHelper = Pipe(), fromHelper = Pipe()
        p.standardInput = toHelper
        p.standardOutput = fromHelper
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw Failure("Couldn't start the transcriber (sona spool-serve).") }
        process = p
        input = toHelper.fileHandleForWriting
        output = fromHelper.fileHandleForReading
    }

    /// The next line it sends, waiting at most `timeout` seconds.
    private func receive(timeout: Double) throws -> SpoolSlice {
        guard let fd = output?.fileDescriptor else { throw Failure("The transcriber stopped.").restarting() }
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let slice = try? JSONDecoder().decode(SpoolSlice.self, from: Data(line)) else {
                    stop()
                    throw Failure("The transcriber sent something unreadable.")
                }
                return slice
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else {
                stop()
                throw Failure("Transcribing took too long, so it was stopped.")
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(left, 1) * 1000))
            if ready <= 0 { continue }  // nothing yet, or interrupted
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { throw Failure("The transcriber stopped.").restarting() }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}
#endif
