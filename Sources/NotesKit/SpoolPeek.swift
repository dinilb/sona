import Foundation

/// A conversation still in the spool: being recorded right now, or finished and waiting for its note. What the MCP
/// server needs to know about it, read from the spool's `<id>.json` and the size of its `<id>.wav` without opening
/// the audio (NotesKit can't link the engine; `SpoolEntry` is SonaEngine's). Never writes anything.
public struct SpoolRecording: Equatable, Sendable {
    public var id: String
    public var startedAt: Date
    /// Seconds of audio so far, from the WAV's size (its header says 0 while it's being recorded).
    public var duration: Double
    /// False while it's being recorded (or the app stopped before it could close it).
    public var closed: Bool
    /// The note reserved for it once it's being written, relative to the Conversations folder.
    public var note: String?

    public init(id: String, startedAt: Date, duration: Double, closed: Bool, note: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.closed = closed
        self.note = note
    }

    public var endedAt: Date { startedAt.addingTimeInterval(duration) }

    /// The fields of the spool's `<id>.json` read here (it has more).
    private struct Entry: Decodable {
        var startedAt: Date
        var closed: Bool?
        var note: String?
    }

    /// Everything in `dir` (not `failed/`), oldest first. A WAV without its `.json` (the app stopped before writing it)
    /// counts from the file's creation date, as the processor does. Symlinks are skipped.
    public static func all(in dir: URL = Paths.spool) -> [SpoolRecording] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [SpoolRecording] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasSuffix(".wav") && !name.hasSuffix(".mac.wav") && !name.hasPrefix(".") {
            let id = String(name.dropLast(4))
            var st = stat()
            guard lstat(dir.path + "/" + name, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let duration = Double(max(0, Int(st.st_size) - 44) / 2) / 16_000
            let json = dir.appendingPathComponent(id + ".json")
            if let data = try? Data(contentsOf: json), let entry = try? decoder.decode(Entry.self, from: data) {
                out.append(SpoolRecording(id: id, startedAt: entry.startedAt, duration: duration, closed: entry.closed ?? false, note: entry.note))
            } else {
                let born = Date(timeIntervalSince1970: Double(st.st_birthtimespec.tv_sec))
                out.append(SpoolRecording(id: id, startedAt: born, duration: duration, closed: false))
            }
        }
        return out.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }
}

/// A stretch of a spool recording, transcribed on demand (`sona spool-serve`): what the helper sends back to the MCP
/// server, one JSON line per request.
public struct SpoolSlice: Codable, Equatable, Sendable {
    /// Times in seconds from the recording's start. Speakers are this slice's own ("Speaker 1", "Mac audio"): the
    /// recording is transcribed a few minutes at a time, and voices are matched across those pieces.
    public var words: [Word]
    /// The stretch asked for, cut to the audio there is.
    public var from: Double
    public var to: Double
    /// Words cover `doneFrom..<to`. Later than `from` when time ran out: the newest part is transcribed first, and the
    /// rest carries on in the background for the next call.
    public var doneFrom: Double
    /// Seconds of audio in the recording now.
    public var duration: Double
    /// Why nothing could be transcribed (no models, no such recording); words are then empty.
    public var error: String?

    public init(words: [Word], from: Double, to: Double, doneFrom: Double, duration: Double, error: String? = nil) {
        self.words = words
        self.from = from
        self.to = to
        self.doneFrom = doneFrom
        self.duration = duration
        self.error = error
    }

    public var complete: Bool { doneFrom <= from }
}

/// One request to `sona spool-serve`: transcribe `from..<to` seconds of recording `id`, giving up after `seconds`.
public struct SpoolRequest: Codable, Equatable, Sendable {
    public var id: String
    public var from: Double
    public var to: Double
    public var seconds: Double

    public init(id: String, from: Double, to: Double, seconds: Double) {
        self.id = id
        self.from = from
        self.to = to
        self.seconds = seconds
    }
}
