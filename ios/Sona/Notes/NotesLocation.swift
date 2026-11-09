import Foundation
import NotesKit
import UniformTypeIdentifiers
import os

/// Where the iPhone's notes go, as chosen in onboarding or Settings (`NotesChoice`):
/// - `.icloud`: the app's own iCloud container (`Documents/`), which the Mac reads;
/// - `.iphone`: `Documents/Notes` on this iPhone, in iCloud Backup but never in iCloud Drive;
/// - `.folder`: a folder the user picked once, kept as a security-scoped bookmark.
/// Every note is written in staging (`Documents/Sona`, kept out of backups) first and moves to its place once it's
/// whole. While nothing is chosen yet, or the chosen place can't be reached (iCloud off, the folder gone), notes wait
/// in staging (`.local`, with `waiting` saying why). Notes land in `<folder>/Conversations/YYYY-MM-DD/`.
nonisolated struct NotesLocation: Equatable, Sendable {
    enum Kind: String, Sendable {
        case picked
        case iCloudContainer
        /// `Documents/Notes` on this iPhone (the "On this iPhone" choice).
        case iphone
        /// Staging only: notes wait here (nothing chosen yet, or the chosen place can't be reached now).
        case local
    }

    /// Why notes wait in staging instead of going where they were chosen to go: for a banner.
    enum Waiting: String, Sendable {
        /// iCloud was chosen, but there's no container now (signed out, iCloud Drive off, or Sona off in its list).
        case iCloudOff
        /// The picked folder can't be found or opened now.
        case folderUnreachable
    }

    var kind: Kind
    /// The notes folder.
    var folder: URL
    /// Only for `.local`: a place was chosen and can't be reached now.
    var waiting: Waiting? = nil

    var conversations: URL { folder.appendingPathComponent("Conversations", isDirectory: true) }

    /// For a banner: the picked folder's name, "iCloud Drive", or "On this iPhone".
    var displayName: String {
        switch kind {
        case .picked: return FileManager.default.displayName(atPath: folder.path)
        case .iCloudContainer: return "iCloud Drive"
        case .iphone, .local: return "On this iPhone"
        }
    }

    /// The Mac imports notes from these places only (Sources/NotesKit/PhoneImport.swift, `defaultSources`): the app's
    /// own iCloud folder, and a folder called Sona at the top of iCloud Drive. A note in any other folder syncs but
    /// never reaches the Mac, which nothing would otherwise say.
    var reachesMac: Bool {
        switch kind {
        case .iCloudContainer: return true
        case .iphone, .local: return false
        case .picked: return Self.isICloudDriveSona(folder)
        }
    }

    /// Where every note is written first (`Documents/Sona`), and waits until its place can take it whole. Out of
    /// backups (`NotesService.protectPrivateFolders`): it holds raw WAVs and half-written notes. Except while notes
    /// wait here with nowhere to go (`NotesService.stagingBackedUp`): then they're this iPhone's only copy.
    static var stagingFolder: URL { Paths.defaultNotesFolder }

    /// The "On this iPhone" place: `Documents/Notes`, in iCloud Backup (unlike staging), never the iCloud container.
    static var iPhoneFolder: URL {
        if Paths.isTestHome { return Paths.support.appendingPathComponent("iPhone Notes", isDirectory: true) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notes", isDirectory: true)
    }

    /// `…/Mobile Documents/com~apple~CloudDocs/Sona`: iCloud Drive's own folder (com~apple~CloudDocs), then Sona.
    static func isICloudDriveSona(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 2 else { return false }
        return parts[parts.count - 2] == "com~apple~CloudDocs" && parts[parts.count - 1].lowercased() == "sona"
    }

    /// What to pick, for `.fileImporter(allowedContentTypes:)` or `UIDocumentPickerViewController(forOpeningContentTypes:)`.
    static let pickerTypes: [UTType] = [.folder]
    /// Copy for the banner that asks for a folder.
    static let pickerHint = "Pick iCloud Drive › Sona (make the folder if it isn't there) so your notes reach your Mac."

    /// The app's iCloud container, or nil when there's none (iCloud off, no entitlement). Can block for a while the
    /// first time: never call it on the main thread.
    static let iCloudContainer: @Sendable () -> URL? = {
        FileManager.default.url(forUbiquityContainerIdentifier: SonaIDs.iCloudContainer)
    }

    /// The place `choice` says (see the type's comment), never another: "On this iPhone" stays on this iPhone when
    /// iCloud shows up, and iCloud off or a folder that's gone means notes wait in staging, not somewhere else. With no
    /// choice yet (onboarding hasn't asked) an older install's picked folder still counts, and the container never
    /// does: this runs on background launches (an intent, the watch) before he's answered. Blocking: call it off the
    /// main thread (the container and the bookmark can take a while).
    static func resolve(
        choice: NotesChoice? = V1Settings.notesChoice,
        picked: () -> URL? = { debugFolder ?? PickedFolder.resolve() }, container: () -> URL? = iCloudContainer,
        iphone: URL = iPhoneFolder, staging: URL = stagingFolder
    ) -> NotesLocation {
        func wait(_ why: Waiting?) -> NotesLocation { NotesLocation(kind: .local, folder: staging, waiting: why) }
        switch choice {
        case .icloud:
            guard let cloud = container() else { return wait(.iCloudOff) }
            return NotesLocation(kind: .iCloudContainer, folder: cloud.appendingPathComponent("Documents", isDirectory: true))
        case .iphone:
            return NotesLocation(kind: .iphone, folder: iphone)
        case .folder:
            guard let folder = picked() else { return wait(.folderUnreachable) }
            return NotesLocation(kind: .picked, folder: folder)
        case nil:
            if let folder = picked() { return NotesLocation(kind: .picked, folder: folder) }
            return wait(nil)
        }
    }

    /// `-debugNotesFolder <path>` (DEBUG builds): that folder stands in for a picked one, for the simulator.
    static var debugFolder: URL? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-debugNotesFolder"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        #endif
        return nil
    }

    /// How a note's file gets into this location: into the app's container with `setUbiquitous` (Apple's way to hand
    /// a file to iCloud), anywhere else (a picked folder, maybe a file provider's) with a coordinated move.
    var mover: @Sendable (URL, URL) throws -> Void {
        kind == .iCloudContainer ? Self.moveIntoICloud : Self.coordinatedMove
    }

    static let moveIntoICloud: @Sendable (URL, URL) throws -> Void = { file, destination in
        try FileManager().setUbiquitous(true, itemAt: file, destinationURL: destination)
    }

    static let coordinatedMove: @Sendable (URL, URL) throws -> Void = { file, destination in
        var coordination: NSError?
        var failure: Error?
        let coordinator = NSFileCoordinator()
        let deadline = NotesLocation.giveUp(coordinator)
        defer { deadline.cancel() }
        coordinator.coordinate(
            writingItemAt: file, options: .forMoving, writingItemAt: destination, options: .forReplacing,
            error: &coordination
        ) { from, to in
            do {
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
    }

    /// A note's own files, by extension: the note, its words, its kept audio.
    static let noteExtensions = ["md", "json", "m4a", "wav", "mac.wav"]

    /// Moves the notes written into `from` (this iPhone's folder) into `to`, one note at a time with all its files.
    /// Only whole notes move: one with an empty `.md` or no `.json` (a write the app didn't finish) or whose audio is
    /// still a WAV stays here, so a synced folder never gets a half note or raw audio. A WAV is first made an m4a
    /// with `compress`; if that fails the note stays. Never loses or duplicates one: a move cut short is finished
    /// next time under the same name (see `moveNote`), and a different note with the same name moves under the next
    /// free name ("... 2"). Whatever can't move now stays here and is tried again next time. Returns how many notes
    /// moved. `moved` gets each moved note's `.md` here and where it went (it may be "... 2"), so something holding the
    /// old URL can find it. Blocking: call it off the main thread.
    @discardableResult
    static func moveNotes(
        from: URL, to: URL, move: (URL, URL) throws -> Void,
        compress: (URL) throws -> Void = { _ = try AudioCompressor.compress(note: $0) },
        moved: (_ from: URL, _ to: URL) -> Void = { _, _ in }
    ) -> Int {
        let fm = FileManager.default
        guard from.standardizedFileURL.resolvingSymlinksInPath() != to.standardizedFileURL.resolvingSymlinksInPath() else { return 0 }
        let source = from.appendingPathComponent("Conversations", isDirectory: true)
        let target = to.appendingPathComponent("Conversations", isDirectory: true)
        var count = 0
        for day in (try? fm.contentsOfDirectory(atPath: source.path)) ?? [] where isDay(day) {
            let dir = source.appendingPathComponent(day, isDirectory: true)
            let destDir = target.appendingPathComponent(day, isDirectory: true)
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let stems = names.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.sorted().map { String($0.dropLast(3)) }
            let others = Set(stems)
            for stem in stems {
                do {
                    switch try moveNote(stem, from: dir, to: destDir, others: others, move: move, compress: compress) {
                    case .stays(let why):
                        let ref = logRef(day: day, stem: stem)
                        reportOnce(dir.appendingPathComponent(stem).path, "a note stays on this iPhone for now (\(ref)): \(why)")
                    case .moved(let md):
                        count += 1
                        moved(dir.appendingPathComponent("\(stem).md"), md)
                    }
                } catch {
                    Log.note("couldn't move a note out of this iPhone's folder: \(Log.describe(error))")
                }
            }
            // An emptied day folder goes (hidden files the system left don't count).
            let left = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
            if left.isEmpty { try? fm.removeItem(at: dir) }
        }
        if count > 0 { Log.note("moved \(count) note(s) from this iPhone into the notes folder") }
        return count
    }

    /// `YYYY-MM-DD`, like NoteStore's day folders.
    static func isDay(_ name: String) -> Bool {
        name.count == 10 && name.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// What `moveNote` did: moved the note (its `.md` there now), or left it here and why (for the log: never a title).
    private enum Outcome {
        case moved(URL)
        case stays(String)
    }

    /// One note's files from `dir` to `destDir`. Returns `.moved` once it's only in `destDir`, or why it isn't whole
    /// yet and stays here. `others`: the notes in `dir`, this one included.
    ///
    /// Whether it's already there is decided by the `.md` alone. The `.md` moves last, and until it's there the note
    /// isn't there (not listed, and the Mac doesn't import it), so files with this note's name and no `.md` beside
    /// them are this note's own move, cut short (an error, the app killed between files): it's finished under the
    /// same name, never "... 2", or the `.json` already moved would be stranded without its note. The exception:
    /// with this note's `.json` still here, none of it moved (the `.json` goes first), so files there under its name
    /// are another note's, maybe another device's move with its `.md` still to come, unless that `.json` is a copy of
    /// ours (a file provider's move is a copy, cut short before ours went).
    private static func moveNote(
        _ stem: String, from dir: URL, to destDir: URL, others: Set<String>, move: (URL, URL) throws -> Void,
        compress: (URL) throws -> Void
    ) throws -> Outcome {
        let fm = FileManager.default
        func here(_ ext: String) -> URL { dir.appendingPathComponent("\(stem).\(ext)") }
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        let md = here("md")

        // A name is this note's if no .md has it there, or the same .md (this note, there already). Only a different
        // .md sends it on to the first free "<stem> N", and never one a note still here goes by: that name is the
        // other note's own to finish moving into.
        func ours(_ name: String) -> Bool {
            let there = destDir.appendingPathComponent(name + ".md")
            if exists(there) { return fm.contentsEqual(atPath: md.path, andPath: there.path) }
            // A note iCloud evicted can't be compared: one may be there, so its name is never taken over.
            if exists(stub(there)) { return false }
            if exists(here("json")), takenThere(name) {
                let json = destDir.appendingPathComponent(name + ".json")
                return exists(json) && fm.contentsEqual(atPath: here("json").path, andPath: json.path)
            }
            return name == stem || !others.contains(name)
        }
        func takenThere(_ name: String) -> Bool {
            noteExtensions.contains { ext in
                let file = destDir.appendingPathComponent("\(name).\(ext)")
                return exists(file) || exists(stub(file))
            }
        }
        var destStem = stem
        var n = 2
        while !ours(destStem) {
            destStem = "\(stem) \(n)"
            n += 1
        }
        func there(_ ext: String) -> URL { destDir.appendingPathComponent("\(destStem).\(ext)") }

        // Only a whole note moves. An empty .md is a name the Processor reserved and didn't write; no .json (here,
        // or there from a move cut short) is a write it didn't finish. It writes them again on its next try.
        let size = (try? fm.attributesOfItem(atPath: md.path)[.size] as? Int) ?? 0
        guard size > 0 else { return .stays("it's empty (not written yet)") }
        // A .json that moved there and was evicted since is only a stub there now, and still counts: otherwise the
        // rest of the note would wait here for it forever.
        guard exists(here("json")) || exists(there("json")) || exists(stub(there("json"))) else {
            return .stays("it has no .json yet")
        }
        // Raw audio never goes to a synced folder: the WAV is made an m4a first, or the note waits.
        var why = "its audio isn't an m4a yet"
        if exists(here("wav")) {
            do { try compress(md) } catch { why += " (\(Log.describe(error)))" }
        }
        guard !exists(here("wav")), !exists(here("mac.wav")) else { return .stays(why) }

        try NoteWriter.makePrivateDirectory(destDir)
        // Its .md is there already (the same one: `ours`), so its move finished and what's there is the note now,
        // maybe edited since: what's left here is an older copy, dropped, never put over it.
        let landed = exists(there("md"))
        // The .md last: it's what makes the note there, so it's never there half-moved.
        for ext in noteExtensions.filter({ $0 != "md" }) + ["md"] where exists(here(ext)) {
            let file = here(ext), dest = there(ext)
            let isThere = exists(dest) || exists(stub(dest))
            // This note's own copy (the note landed already, or a move cut short): drop ours if the note landed or
            // it's the same, else ours, whole, replaces it (a copy cut short, or one iCloud evicted since: only its
            // stub is there).
            if isThere, landed || (exists(dest) && fm.contentsEqual(atPath: file.path, andPath: dest.path)) {
                try fm.removeItem(at: file)
                continue
            }
            if isThere { try deleteThere(dest) }
            try move(file, dest)
        }
        return .moved(there("md"))
    }

    /// `.<name>.icloud`: all that's left on this iPhone of a file iCloud evicted.
    static func stub(_ file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).icloud")
    }

    /// Deletes `file` in the notes folder, coordinated, if it's there or iCloud evicted it (deleting it by its own
    /// name deletes it from iCloud; the stub goes too if that left it). Nothing there: nothing to do.
    static func deleteThere(_ file: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) { try coordinatedDelete(file) }
        let placeholder = stub(file)
        guard fm.fileExists(atPath: placeholder.path) else { return }
        try? coordinatedDelete(file)
        if fm.fileExists(atPath: placeholder.path) { try coordinatedDelete(placeholder) }
    }

    /// Deletes a file in the notes folder, coordinated (it may be a file provider's, like iCloud Drive).
    static func coordinatedDelete(_ url: URL) throws {
        var coordination: NSError?
        var failure: Error?
        let coordinator = NSFileCoordinator()
        let deadline = NotesLocation.giveUp(coordinator)
        defer { deadline.cancel() }
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordination) { url in
            do { try FileManager.default.removeItem(at: url) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }

    /// A file provider that never answers (iCloud busy or wedged) mustn't hold a move or a delete forever: the feed
    /// and every delete wait on staging while one runs. After `seconds` the wait is cancelled, the coordinate call
    /// returns an error, and the note is tried again next time. Only the wait: a move already under way finishes.
    /// Cancel the returned item when done.
    static func giveUp(_ coordinator: NSFileCoordinator, after seconds: Double = 30) -> DispatchWorkItem {
        nonisolated(unsafe) let toCancel = coordinator  // NSFileCoordinator.cancel() is made to be called from any thread
        let item = DispatchWorkItem { toCancel.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    /// A note in the log: its day and start minute ("2026-11-03/09-00"), never its title.
    static func logRef(day: String, stem: String) -> String {
        let time = stem.prefix(5)
        return time.range(of: #"^\d{2}-\d{2}$"#, options: .regularExpression) != nil ? "\(day)/\(time)" : day
    }

    /// Logs `message` the first time this launch for `key`: a note that keeps waiting is said once, not on every try.
    static func reportOnce(_ key: String, _ message: String) {
        guard reported.withLock({ $0.insert(key).inserted }) else { return }
        Log.note(message)
    }
    private static let reported = OSAllocatedUnfairLock<Set<String>>(initialState: [])
}

/// The folder the user picked for notes, remembered as a bookmark in the support folder. Access to it (it's outside
/// the app's sandbox) is started when it's resolved and kept while the app runs.
nonisolated enum PickedFolder {
    static var bookmarkFile: URL { Paths.support.appendingPathComponent("notes-folder.bookmark") }

    /// Remembers a folder from the picker. Throws if it can't be reached or remembered.
    static func save(_ url: URL, to file: URL = bookmarkFile) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        Paths.ensure(file.deletingLastPathComponent())
        try NoteWriter.writePrivate(data, to: file)
    }

    /// The picked folder with access started, or nil: none picked, it can't be found now, or access to it won't start
    /// or it can't be written (then every move would fail, so notes wait on this iPhone and a banner says so). A stale
    /// bookmark (the folder moved or was renamed) is renewed, only once access has started, so a bookmark without its
    /// security scope never replaces a good one.
    static func resolve(from file: URL = bookmarkFile) -> URL? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            Log.note("the picked notes folder can't be found now; notes stay on this iPhone until it's back")
            return nil
        }
        guard access(url), FileManager.default.isWritableFile(atPath: url.path) else {
            Log.note("the picked notes folder can't be opened now; notes stay on this iPhone until it can")
            return nil
        }
        if stale, let renewed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            try? NoteWriter.writePrivate(renewed, to: file)
        }
        return url
    }

    /// Starts access to the folder in use once (each start must be balanced by a stop). The one before keeps its
    /// access until `stopRetiredAccess`: this runs off the feed too (the audio count resolves the location), and a
    /// move into the old folder cut off mid-note would strand its .json there. True when Sona can use it: access
    /// started (now or earlier), or it's inside the app's own sandbox, which needs none (only tests pick one there:
    /// the picker never offers the app's own folders).
    private static func access(_ url: URL) -> Bool {
        accessed.withLock { state -> Bool in
            if state.current == url { return true }
            if let old = state.current { state.retired.append(old) }
            state.current = url.startAccessingSecurityScopedResource() ? url : nil
            return state.current != nil || isInSandbox(url)
        }
    }

    private nonisolated struct Access: Sendable {
        var current: URL?
        /// Folders picked before this one whose access hasn't been stopped yet.
        var retired: [URL] = []
    }
    private static let accessed = OSAllocatedUnfairLock(initialState: Access())

    /// Stops access to every picked folder: notes go somewhere else now. Call it with staging claimed, so no move
    /// into one is running.
    static func stopAccess() {
        accessed.withLock { state in
            for url in state.retired + [state.current].compactMap({ $0 }) { url.stopAccessingSecurityScopedResource() }
            state = Access()
        }
    }

    /// Stops access to the folders picked before the one in use. Call it with staging claimed, like `stopAccess`.
    static func stopRetiredAccess() {
        accessed.withLock { state in
            for url in state.retired { url.stopAccessingSecurityScopedResource() }
            state.retired = []
        }
    }

    /// Inside this app's own container, where no security scope is needed.
    static func isInSandbox(_ url: URL) -> Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == home || path.hasPrefix(home + "/")
    }

    /// A folder was picked (it may not resolve now).
    static var isRemembered: Bool { FileManager.default.fileExists(atPath: bookmarkFile.path) }

    static func forget(_ file: URL = bookmarkFile) {
        try? FileManager.default.removeItem(at: file)
    }
}
