import Foundation
import NotesKit

/// The Places folder: one small JSON per recording (`PlaceRecord`). Out of iCloud Backup, like the spool, and readable
/// once the phone has been unlocked since it started (a recording stopped on the Lock Screen saves its fix).
nonisolated struct PlaceStore: Sendable {
    let folder: URL

    static var standard: PlaceStore { PlaceStore(folder: Paths.support.appendingPathComponent("Places", isDirectory: true)) }

    func url(_ id: String) -> URL { folder.appendingPathComponent(id + ".json") }

    func load(_ id: String) -> PlaceRecord? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? Self.decoder.decode(PlaceRecord.self, from: data)
    }

    /// Changes the record (a new one if there's none) and saves it.
    func update(_ id: String, _ change: (inout PlaceRecord) -> Void) {
        var record = load(id) ?? PlaceRecord()
        change(&record)
        save(record, id)
    }

    func save(_ record: PlaceRecord, _ id: String) {
        prepareFolder()
        guard let data = try? Self.encoder.encode(record) else { return }
        do {
            try data.write(to: url(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Log.note("places: couldn't save a fix: \(Log.describe(error))")
        }
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: url(id))
    }

    /// Every record, with when it was last saved.
    func all() -> [(id: String, record: PlaceRecord, savedAt: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else {
            return []
        }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            let id = file.deletingPathExtension().lastPathComponent
            guard let record = load(id) else { return nil }
            let savedAt = (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return (id, record, savedAt)
        }
    }

    /// Deletes what `PlaceRules.shouldDelete` says has had its use.
    func prune(now: Date = Date()) {
        for item in all() where PlaceRules.shouldDelete(item.record, savedAt: item.savedAt, now: now) {
            remove(item.id)
        }
    }

    private func prepareFolder() {
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        Paths.ensure(folder)
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
