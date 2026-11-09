import Foundation
import SQLite3

/// A SQLite FTS5 index over every transcript line, kept next to the settings (`search.sqlite` in the support
/// folder), never in the notes folder. The notes stay the only source of truth: the index is a cache that
/// syncs itself on every search by comparing each note's mtime, size and inode with what it indexed, and
/// reindexing only the notes that changed. Deleting the file just costs one full rebuild.
///
/// Several `sona-mcp` processes can share it (one per AI app): WAL mode, a busy timeout, and every
/// reindex runs in one `BEGIN IMMEDIATE` transaction that rechecks the files table, so a racing process
/// either waits or finds the work already done. Any SQLite error makes `search` return nil, and the caller
/// falls back to scanning the files.
public final class SearchIndex {
    /// Bump when the schema or what gets indexed changes: the old tables are dropped and rebuilt.
    static let schemaVersion: Int32 = 3
    /// Line rowids are `fid << lineBits | lineIndex`, so one note's rows are a single rowid range.
    static let lineBits: Int64 = 20

    public let url: URL
    let store: NoteStore
    private var db: OpaquePointer?
    private var ready = false
    private var broken = false
    /// Inode of the file when it was opened: if someone deletes or replaces it, reopen instead of writing
    /// into the orphaned file through its old WAL.
    private var openedInode: UInt64 = 0

    public init(url: URL, store: NoteStore) {
        self.url = url
        self.store = store
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    /// True when this Mac's SQLite was built with FTS5.
    public static var fts5Available: Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return false }
        defer { sqlite3_close_v2(db) }
        return sqlite3_exec(db, "CREATE VIRTUAL TABLE t USING fts5(x)", nil, nil, nil) == SQLITE_OK
    }

    struct SQLError: Error {
        var message: String
        /// Primary SQLite result code (SQLITE_BUSY, SQLITE_CORRUPT, ...), 0 when not from SQLite.
        var code: Int32 = 0
    }

    // MARK: search

    /// Same contract as `NoteStore.search`, or nil when the index can't answer (no FTS5, a SQLite error, a
    /// query with nothing to match on): the caller then scans the files instead.
    public func search(
        _ query: String, from: String?, to: String?, speaker: String?, limit: Int
    ) -> (hits: [NoteStore.Hit], total: Int)? {
        guard let match = Self.matchExpression(query) else { return nil }
        // Two tries on a fresh connection: covers another process creating the index at the same moment, and
        // the index file being deleted or replaced under an open connection.
        var failure = ""
        for attempt in 0..<2 {
            do {
                if ready, Self.inode(url.path) != openedInode { close() }
                try open()
                try sync()
                return try run(match, from: from, to: to, speaker: speaker, limit: limit)
            } catch {
                let sqlError = error as? SQLError
                // SQLite's own messages can quote the search text: log only their code.
                failure = sqlError.map { $0.code == 0 ? $0.message : "SQLite error \($0.code)" } ?? Log.describe(error)
                close()
                if broken { break }
                switch sqlError?.code ?? 0 {
                case SQLITE_BUSY, SQLITE_LOCKED:
                    // Another process is (re)building: scanning now beats waiting on it.
                    failure += " (busy)"
                    onError?("search index: \(failure); scanning instead")
                    return nil
                case SQLITE_CORRUPT, SQLITE_NOTADB:
                    // It's only a cache: throw it away and rebuild on the next try.
                    removeFiles()
                default:
                    if attempt == 0 { usleep(50_000) }
                }
            }
        }
        onError?("search index: \(failure); scanning instead")
        return nil
    }

    /// Where failures get reported (the app log for the real index; nothing in tests).
    public var onError: ((String) -> Void)?

    private func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        ready = false
    }

    private func removeFiles() { Self.discard(at: url) }

    /// Deletes the index (it's only a cache) after notes were deleted or cut, so none of their words stay in it,
    /// its log or its free pages. The next search builds it again from the notes; open connections notice.
    public static func discard(at url: URL = Paths.searchIndex) {
        for suffix in ["", "-wal", "-shm"] { unlink(url.path + suffix) }
    }

    static func inode(_ path: String) -> UInt64 {
        var st = stat()
        return stat(path, &st) == 0 ? UInt64(st.st_ino) : 0
    }

    /// `"pricing" "page"`: every term quoted (so FTS5 syntax in user input is just text) and all required.
    /// The trigram tokenizer makes each one a substring match, like the file scan: "ona" finds "Sona",
    /// and it works for languages without spaces. Nil (so the caller scans) when the query is empty or any
    /// term is shorter than 3 characters, which trigrams can't match.
    static func matchExpression(_ query: String) -> String? {
        let terms = NoteStore.searchTerms(query)
        guard !terms.isEmpty, terms.allSatisfy({ $0.count >= 3 }) else { return nil }
        return terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " ")
    }

    /// Speaker filter key: case and accent insensitive, like the file scan.
    static func speakerKey(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private func run(
        _ match: String, from: String?, to: String?, speaker: String?, limit: Int
    ) throws -> (hits: [NoteStore.Hit], total: Int) {
        let filters = """
            FROM lines JOIN files ON files.fid = (lines.rowid >> \(Self.lineBits))
            WHERE lines MATCH ?1 AND (?2 IS NULL OR files.day >= ?2) AND (?3 IS NULL OR files.day <= ?3)
              AND (?4 IS NULL OR lines.speaker_key = ?4)
            """
        let speakerKey = speaker.map(Self.speakerKey)
        func bindFilters(_ stmt: Statement) {
            stmt.bind(1, match)
            stmt.bind(2, from)
            stmt.bind(3, to)
            stmt.bind(4, speakerKey)
        }

        // One read transaction, so the count and the rows see the same snapshot.
        try exec("BEGIN")
        defer { try? exec("COMMIT") }
        // Another process may have pointed the index at a different notes folder since we opened it.
        let root = try prepare("SELECT value FROM meta WHERE key = 'root'")
        let stored = try root.step() ? root.text(0) : nil
        root.reset()
        guard stored == store.root.standardizedFileURL.path else { throw SQLError(message: "index is for another notes folder") }

        let count = try prepare("SELECT count(*) \(filters)")
        bindFilters(count)
        guard try count.step() else { throw SQLError(message: "count returned no row") }
        let total = count.int(0)
        count.reset()

        let rows = try prepare(
            """
            SELECT lines.offset, lines.clock, lines.speaker, lines.text, \(Self.noteColumns)
            \(filters)
            ORDER BY bm25(lines), files.started DESC, files.id DESC, lines.offset
            LIMIT ?5
            """)
        bindFilters(rows)
        rows.bind(5, Int64(max(0, limit)))
        var hits: [NoteStore.Hit] = []
        var notes: [String: ConversationNote] = [:]
        while try rows.step() {
            let id = rows.text(4)
            let note = notes[id] ?? Self.note(rows, from: 4)
            notes[id] = note
            let line = NoteLine(offset: rows.double(0), clock: rows.text(1), speaker: rows.text(2), text: rows.text(3))
            hits.append(NoteStore.Hit(note: note, line: line))
        }
        return (hits, total)
    }

    /// The `files` columns a note is read back from, in `note(_:from:)`'s order: all its header needs (the AI title,
    /// place, device and likely-media mark too), so a note listed from here reads as it does from its file.
    static let noteColumns = """
        files.id, files.path, files.title, files.date, files.start, files.end_time, files.duration, files.speakers, \
        files.ai_title, files.place, files.place_end, files.source, files.media
        """

    /// The note in a row whose `noteColumns` start at column `first`. Its lines aren't in it.
    private static func note(_ rows: Statement, from first: Int32) -> ConversationNote {
        ConversationNote(
            id: rows.text(first), url: URL(fileURLWithPath: rows.text(first + 1)), title: rows.text(first + 2),
            date: rows.text(first + 3), start: rows.text(first + 4), end: rows.text(first + 5),
            duration: rows.text(first + 6), speakers: rows.text(first + 7).split(separator: "\n").map(String.init),
            lines: [], media: rows.optionalText(first + 12), source: rows.optionalText(first + 11),
            aiTitle: rows.optionalText(first + 8), place: rows.optionalText(first + 9),
            placeEnd: rows.optionalText(first + 10))
    }

    /// Same contract as `NoteStore.notesMatching`, from the index's list of notes (no note is opened), or nil when
    /// the index can't answer: the caller then reads the notes' headers instead.
    public func notesMatching(_ query: String, from: String?, to: String?) -> [ConversationNote]? {
        let terms = NoteStore.searchTerms(query)
        guard !terms.isEmpty else { return [] }
        for attempt in 0..<2 {
            do {
                if ready, Self.inode(url.path) != openedInode { close() }
                try open()
                try sync()
                return try matching(terms, from: from, to: to)
            } catch {
                close()
                if broken { break }
                if let code = (error as? SQLError)?.code, code == SQLITE_CORRUPT || code == SQLITE_NOTADB { removeFiles() }
                if attempt == 0 { usleep(50_000) }
            }
        }
        // SQLite's own messages can quote what was searched for: say only that it failed.
        onError?("search index: couldn't list notes by title or place; reading the notes instead")
        return nil
    }

    private func matching(_ terms: [String], from: String?, to: String?) throws -> [ConversationNote] {
        try exec("BEGIN")
        defer { try? exec("COMMIT") }
        let root = try prepare("SELECT value FROM meta WHERE key = 'root'")
        let stored = try root.step() ? root.text(0) : nil
        root.reset()
        guard stored == store.root.standardizedFileURL.path else { throw SQLError(message: "index is for another notes folder") }
        let rows = try prepare(
            """
            SELECT \(Self.noteColumns) FROM files
            WHERE (?1 IS NULL OR files.day >= ?1) AND (?2 IS NULL OR files.day <= ?2)
            ORDER BY files.started DESC, files.id DESC
            """)
        rows.bind(1, from)
        rows.bind(2, to)
        var out: [ConversationNote] = []
        while try rows.step() {
            let note = Self.note(rows, from: 0)
            if NoteStore.matches(note, terms: terms) { out.append(note) }
        }
        return out
    }

    // MARK: setup

    private func open() throws {
        if ready { return }
        if broken { throw SQLError(message: "unavailable") }
        do {
            guard Self.fts5Available else { throw SQLError(message: "this SQLite has no FTS5") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
            guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                sqlite3_close_v2(handle)
                throw SQLError(message: message)
            }
            db = handle
            // It holds every transcript line: this user's only. SQLite makes the -wal and -shm with the same mode.
            for suffix in ["", "-wal", "-shm"] { chmod(url.path + suffix, 0o600) }
            openedInode = Self.inode(url.path)
            // Short: a write lock held by another process means it's rebuilding, and the caller scans instead.
            sqlite3_busy_timeout(handle, 300)
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA synchronous=NORMAL")
            try migrate()
            ready = true
        } catch {
            if let db { sqlite3_close_v2(db) }
            db = nil
            if (error as? SQLError)?.message == "this SQLite has no FTS5" { broken = true }
            if let code = (error as? SQLError)?.code, code == SQLITE_CORRUPT || code == SQLITE_NOTADB { removeFiles() }
            throw error
        }
    }

    private func migrate() throws {
        try exec("BEGIN IMMEDIATE")
        do {
            let version = try prepare("PRAGMA user_version")
            _ = try version.step()
            let current = Int32(version.int(0))
            version.reset()
            if current != Self.schemaVersion {
                try exec(
                    """
                    DROP TABLE IF EXISTS lines;
                    DROP TABLE IF EXISTS files;
                    DROP TABLE IF EXISTS meta;
                    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    CREATE TABLE files(
                        fid INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, path TEXT NOT NULL,
                        mtime REAL NOT NULL, size INTEGER NOT NULL, inode INTEGER NOT NULL,
                        day TEXT NOT NULL, started REAL NOT NULL, title TEXT NOT NULL, date TEXT NOT NULL,
                        start TEXT NOT NULL, end_time TEXT NOT NULL, duration TEXT NOT NULL, speakers TEXT NOT NULL,
                        ai_title TEXT, place TEXT, place_end TEXT, source TEXT, media TEXT);
                    CREATE INDEX files_day ON files(day);
                    CREATE VIRTUAL TABLE lines USING fts5(
                        haystack, speaker UNINDEXED, text UNINDEXED, speaker_key UNINDEXED, offset UNINDEXED,
                        clock UNINDEXED, tokenize = 'trigram remove_diacritics 1');
                    PRAGMA user_version = \(Self.schemaVersion);
                    """)
            }
            // A different notes folder means none of the rows are ours.
            let root = store.root.standardizedFileURL.path
            let get = try prepare("SELECT value FROM meta WHERE key = 'root'")
            let stored = try get.step() ? get.text(0) : nil
            get.reset()
            if stored != root {
                try exec("DELETE FROM lines; DELETE FROM files;")
                let put = try prepare("INSERT OR REPLACE INTO meta(key, value) VALUES ('root', ?1)")
                put.bind(1, root)
                try put.run()
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: sync

    struct FileStamp: Equatable {
        var mtime: Double
        var size: Int64
        var inode: Int64
    }

    /// Every note on disk right now, by id. Plain readdir + fstatat (Foundation's directory listing is several
    /// times slower): a few thousand notes take a few milliseconds.
    func scanDisk() -> [String: (path: String, day: String, stamp: FileStamp)] {
        var out: [String: (path: String, day: String, stamp: FileStamp)] = [:]
        let rootPath = store.root.standardizedFileURL.path
        for day in Self.entries(rootPath) where Self.isDay(day) {
            let dirPath = rootPath + "/" + day
            // Like `NoteStore.days`: a symlinked day folder could point anywhere on the Mac.
            guard NoteWriter.isRealDirectory(dirPath), let dir = opendir(dirPath) else { continue }
            defer { closedir(dir) }
            let fd = dirfd(dir)
            while let entry = readdir(dir) {
                let name = Self.name(entry)
                guard name.hasSuffix(".md"), !name.hasPrefix(".") else { continue }
                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }  // no symlinks
                let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                out[day + "/" + name.dropLast(3)] = (
                    dirPath + "/" + name, day, FileStamp(mtime: mtime, size: Int64(st.st_size), inode: Int64(st.st_ino))
                )
            }
        }
        return out
    }

    static func name(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafeBytes(of: entry.pointee.d_name) { raw in
            String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
        }
    }

    static func entries(_ path: String) -> [String] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) { names.append(name(entry)) }
        return names
    }

    /// `YYYY-MM-DD`, like `NoteStore.days`.
    static func isDay(_ name: String) -> Bool {
        let u = Array(name.utf8)
        guard u.count == 10, u[4] == 45, u[7] == 45 else { return false }
        return u.enumerated().allSatisfy { $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }
    }

    private func indexedStamps() throws -> [String: (fid: Int64, stamp: FileStamp)] {
        let stmt = try prepare("SELECT id, fid, mtime, size, inode FROM files")
        var out: [String: (fid: Int64, stamp: FileStamp)] = [:]
        while try stmt.step() {
            out[stmt.text(0)] = (stmt.int64(1), FileStamp(mtime: stmt.double(2), size: stmt.int64(3), inode: stmt.int64(4)))
        }
        return out
    }

    /// Brings the index up to date with the notes folder. Cheap when nothing changed: one directory walk and
    /// one small table read, no writes.
    func sync() throws {
        if !Self.differs(scanDisk(), try indexedStamps()) { return }

        // Another process may be doing the same; IMMEDIATE takes the write lock (or fails fast as busy), then
        // we look at the disk and the table again so neither its work nor a newer listing is undone.
        try exec("BEGIN IMMEDIATE")
        do {
            let disk = scanDisk()
            let indexed = try indexedStamps()
            for (id, old) in indexed where disk[id] == nil {
                try deleteRows(fid: old.fid)
                let del = try prepare("DELETE FROM files WHERE fid = ?1")
                del.bind(1, old.fid)
                try del.run()
            }
            for (id, file) in disk where indexed[id]?.stamp != file.stamp {
                try reindex(id: id, url: URL(fileURLWithPath: file.path), day: file.day, stamp: file.stamp, fid: indexed[id]?.fid)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    static func differs(
        _ disk: [String: (path: String, day: String, stamp: FileStamp)], _ indexed: [String: (fid: Int64, stamp: FileStamp)]
    ) -> Bool {
        guard disk.count == indexed.count else { return true }
        return disk.contains { indexed[$0.key]?.stamp != $0.value.stamp }
    }

    private func deleteRows(fid: Int64) throws {
        let del = try prepare("DELETE FROM lines WHERE rowid BETWEEN ?1 AND ?2")
        del.bind(1, fid << Self.lineBits)
        del.bind(2, (fid << Self.lineBits) | ((1 << Self.lineBits) - 1))
        try del.run()
    }

    private func reindex(id: String, url: URL, day: String, stamp: FileStamp, fid existing: Int64?) throws {
        // A note that vanished or can't be read mid-sync is indexed as empty; its stamp makes the next
        // search retry if it changes again.
        let note = try? store.read(url: url)
        let fid: Int64
        if let existing {
            fid = existing
            try deleteRows(fid: fid)
        } else {
            let insert = try prepare("INSERT INTO files(id, path, mtime, size, inode, day, started, title, date, start, end_time, duration, speakers) VALUES (?1, '', 0, 0, 0, '', 0, '', '', '', '', '', '')")
            insert.bind(1, id)
            try insert.run()
            fid = sqlite3_last_insert_rowid(db)
        }
        let update = try prepare(
            """
            UPDATE files SET path = ?2, mtime = ?3, size = ?4, inode = ?5, day = ?6, started = ?7, title = ?8, date = ?9,
              start = ?10, end_time = ?11, duration = ?12, speakers = ?13, ai_title = ?14, place = ?15, place_end = ?16,
              source = ?17, media = ?18 WHERE fid = ?1
            """)
        update.bind(1, fid)
        update.bind(2, url.path)
        update.bind(3, stamp.mtime)
        update.bind(4, stamp.size)
        update.bind(5, stamp.inode)
        update.bind(6, day)
        update.bind(7, note?.startedAt?.timeIntervalSince1970 ?? 0)
        update.bind(8, note?.title ?? url.deletingPathExtension().lastPathComponent)
        update.bind(9, note?.date ?? day)
        update.bind(10, note?.start ?? "")
        update.bind(11, note?.end ?? "")
        update.bind(12, note?.duration ?? "")
        update.bind(13, (note?.speakers ?? []).joined(separator: "\n"))
        update.bind(14, note?.aiTitle)
        update.bind(15, note?.place)
        update.bind(16, note?.placeEnd)
        update.bind(17, note?.source)
        update.bind(18, note?.media)
        try update.run()

        guard let note else { return }
        let insert = try prepare(
            "INSERT INTO lines(rowid, speaker, text, speaker_key, offset, clock, haystack) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)")
        for (i, line) in note.lines.prefix(Int(1 << Self.lineBits)).enumerated() {
            insert.reset()
            insert.bind(1, (fid << Self.lineBits) | Int64(i))
            insert.bind(2, line.speaker)
            insert.bind(3, line.text)
            insert.bind(4, Self.speakerKey(line.speaker))
            insert.bind(5, line.offset)
            insert.bind(6, line.clock)
            // What the file scan matches against.
            insert.bind(7, line.speaker + ": " + line.text)
            try insert.run()
        }
    }

    // MARK: sqlite plumbing

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        guard rc == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLError(message: message, code: rc & 0xff)
        }
    }

    private func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLError(message: String(cString: sqlite3_errmsg(db)), code: rc & 0xff)
        }
        return Statement(stmt, db: db)
    }

    final class Statement {
        static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let stmt: OpaquePointer
        let db: OpaquePointer?

        init(_ stmt: OpaquePointer, db: OpaquePointer?) {
            self.stmt = stmt
            self.db = db
        }

        deinit { sqlite3_finalize(stmt) }

        func bind(_ i: Int32, _ value: String?) {
            // Explicit byte length, so a NUL inside the text doesn't cut it short.
            if let value { sqlite3_bind_text(stmt, i, value, Int32(value.utf8.count), Self.transient) } else { sqlite3_bind_null(stmt, i) }
        }
        func bind(_ i: Int32, _ value: Int64) { sqlite3_bind_int64(stmt, i, value) }
        func bind(_ i: Int32, _ value: Double) { sqlite3_bind_double(stmt, i, value) }

        func reset() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        /// True when there's a row to read.
        func step() throws -> Bool {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SQLError(message: String(cString: sqlite3_errmsg(db)), code: rc & 0xff)
            }
        }

        func run() throws { _ = try step() }

        func text(_ col: Int32) -> String {
            guard let p = sqlite3_column_text(stmt, col) else { return "" }
            return String(decoding: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(stmt, col))), as: UTF8.self)
        }
        /// Nil for SQL NULL (a note with no AI title, place or source).
        func optionalText(_ col: Int32) -> String? {
            sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : text(col)
        }
        func int(_ col: Int32) -> Int { Int(sqlite3_column_int64(stmt, col)) }
        func int64(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
        func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }
    }
}
