#if os(macOS)
import XCTest

@testable import NotesKit

/// What the iPhone adds to a note after it's written (its place, Keep audio, its AI title) and the titles this Mac
/// makes for the iPhone's notes, as they reach this Mac's copy. Uses `PhoneImportTests`' folders and helpers.
extension PhoneImportTests {
    /// The note's day and file name, as the list and the titles files key it.
    func key(_ md: URL) -> (day: String, stem: String) {
        (md.deletingLastPathComponent().lastPathComponent, md.deletingPathExtension().lastPathComponent)
    }

    // MARK: what the iPhone adds later

    func testEveryFieldTheiPhoneWritesReachesThisMacsCopy() throws {
        let md = try phoneNote(audio: true, source: "Apple Watch")
        imp()
        // Added on the iPhone after the first import: the street name (from the foreground), Keep audio, the AI title.
        try NoteFrontMatter.update(fileAt: md, set: [
            "ai_title": "March launch budget", "place": "4 Main St", "geo": "-27.4698,153.0251", "place_end": "10 Queen St",
            "geo_end": "-27.4710,153.0234", "keep_audio": "true",
        ])
        try setDate(md, 1_790_000_100)
        XCTAssertEqual(imp().updated, 1)
        XCTAssertEqual(try Data(contentsOf: mac(md)), try Data(contentsOf: md))
        let read = try XCTUnwrap(NoteStore(root: notes).conversations().first)
        XCTAssertEqual(read.source, "Apple Watch")
        XCTAssertEqual(read.recordedOn, "Apple Watch")
        XCTAssertEqual(read.displayTitle, "March launch budget")
        XCTAssertEqual(read.title, "Budget for the March launch", "the first-words title and the file name stay")
        XCTAssertEqual(
            [read.place, read.geo, read.placeEnd, read.geoEnd], ["4 Main St", "-27.4698,153.0251", "10 Queen St", "-27.4710,153.0234"])
        XCTAssertTrue(read.keepAudio)
        XCTAssertEqual(read.speakers, ["Speaker 1"])

        // The iPhone's 30-day sweep takes its audio: this Mac's copy keeps it (nothing is deleted here).
        try FileManager.default.removeItem(at: sibling(md, "m4a"))
        XCTAssertEqual(imp().unchanged, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mac(md, "m4a").path))
        // Deleted on the iPhone: this Mac's copy stays too.
        for ext in ["md", "json"] { try FileManager.default.removeItem(at: sibling(md, ext)) }
        XCTAssertEqual(imp(), PhoneImport.Summary())
        XCTAssertEqual(NoteStore(root: notes).conversations().count, 1)
    }

    func testWhatTheiPhoneAddsLaterReachesACopyEditedHere() throws {
        let md = try phoneNote()
        imp()
        let id = try XCTUnwrap(NoteStore(root: notes).names().first?.id)
        try NoteStore(root: notes).renameSpeaker(in: id, from: "Speaker 1", to: "Alex")

        // The iPhone adds its place, Keep audio and title: they come over, and the rename stays.
        try NoteFrontMatter.update(
            fileAt: md, set: ["ai_title": "Launch budget", "place": "4 Main St", "geo": "-27.4698,153.0251", "keep_audio": "true"])
        try setDate(md, 1_790_000_100)
        logged = []
        XCTAssertEqual(imp().updated, 1)
        var read = try NoteStore(root: notes).read(id)
        XCTAssertEqual(read.speakers, ["Alex"])
        XCTAssertEqual(read.lines.map(\.speaker), ["Alex"])
        XCTAssertEqual([read.aiTitle, read.place, read.geo], ["Launch budget", "4 Main St", "-27.4698,153.0251"])
        XCTAssertTrue(read.keepAudio)
        XCTAssertEqual(imp().unchanged, 1)

        // Keep audio turned off there: off here too. The title is never taken away.
        try NoteFrontMatter.update(fileAt: md, set: ["keep_audio": nil, "ai_title": nil])
        try setDate(md, 1_790_000_200)
        XCTAssertEqual(imp().updated, 1)
        read = try NoteStore(root: notes).read(id)
        XCTAssertFalse(read.keepAudio)
        XCTAssertEqual(read.aiTitle, "Launch budget")
        XCTAssertEqual(read.speakers, ["Alex"])

        // Anything else the iPhone changes still leaves this Mac's copy as it is.
        let before = try Data(contentsOf: mac(md))
        let text = try String(contentsOf: md, encoding: .utf8).replacingOccurrences(of: "launch.", with: "zeppelin.")
        try change(md, to: text, at: 1_790_000_300)
        XCTAssertEqual(imp().kept, 1)
        XCTAssertEqual(try Data(contentsOf: mac(md)), before)
    }

    func testACopyCutHereGetsThePlaceButNotTheTitle() throws {
        let md = try phoneNote()
        imp()
        // Cut here ("delete the last N minutes" by whole lines): its only line is gone.
        let cut = try String(contentsOf: mac(md), encoding: .utf8).components(separatedBy: "\n")
            .filter { NoteStore.parseLine($0) == nil }.joined(separator: "\n")
        try Data(cut.utf8).write(to: mac(md))

        try NoteFrontMatter.update(fileAt: md, set: ["ai_title": "Launch budget", "place": "4 Main St"])
        try setDate(md, 1_790_000_100)
        XCTAssertEqual(imp().updated, 1)
        let read = try NoteStore(root: notes).read(url: mac(md))
        XCTAssertEqual(read.place, "4 Main St")
        XCTAssertNil(read.aiTitle, "it may describe what was cut")
        XCTAssertTrue(read.lines.isEmpty)
    }

    func testANoteDeletedHereGetsNothingLater() throws {
        let md = try phoneNote()
        imp()
        XCTAssertTrue(NoteStore.remove(mac(md)))
        try NoteFrontMatter.update(fileAt: md, set: ["place": "4 Main St"])
        try setDate(md, 1_790_000_100)
        XCTAssertEqual(imp().kept, 1)
        XCTAssertEqual(files(notes), [])
    }

    func testLaterKeysAreThePhonesAndTheTitleOnlyWhenNoLineWasCut() {
        let phone = "---\ntitle: \"T\"\nai_title: \"A title\"\nplace: \"4 Main St\"\ngeo: 1.0,2.0\nkeep_audio: true\n---\n\n[00:00] Speaker 1: Hi.\n"
        let mac = "---\ntitle: \"T\"\nplace_end: \"Old\"\n---\n\n[00:00] Alex: Hi.\n"
        let keys = PhoneImport.laterKeys(phone: phone, mac: mac)
        XCTAssertEqual(keys["ai_title"], .some("A title"))
        XCTAssertEqual(keys["place"], .some("4 Main St"))
        XCTAssertEqual(keys["geo"], .some("1.0,2.0"))
        XCTAssertEqual(keys["keep_audio"], .some("true"))
        XCTAssertEqual(keys["place_end"], .some(nil), "gone from the iPhone's: gone here")
        XCTAssertEqual(keys["geo_end"], .some(nil))
        XCTAssertNil(PhoneImport.laterKeys(phone: phone, mac: "---\ntitle: \"T\"\n---\n\n")["ai_title"], "a line was cut here")
        XCTAssertNil(PhoneImport.laterKeys(phone: mac, mac: mac)["ai_title"], "never removed")
    }

    // MARK: this Mac's titles for the iPhone's notes

    func testATitleThisMacMadeGoesIntoItsCopyAndTheiPhonesNextChangeStillReplacesIt() throws {
        let md = try phoneNote()
        imp()
        let (day, stem) = key(md)
        XCTAssertTrue(PhoneImport.addTitle("Launch budget", day: day, stem: stem, to: notes, statePath: state))
        XCTAssertEqual(try NoteStore(root: notes).read(url: mac(md)).displayTitle, "Launch budget")
        // Once only.
        XCTAssertFalse(PhoneImport.addTitle("Something else", day: day, stem: stem, to: notes, statePath: state))
        XCTAssertEqual(imp().unchanged, 1)

        // The iPhone folds it in (and adds a place): the copy is still taken as untouched, so it's replaced.
        try NoteFrontMatter.update(fileAt: md, set: ["ai_title": "Launch budget", "place": "4 Main St"])
        try setDate(md, 1_790_000_100)
        XCTAssertEqual(imp().updated, 1)
        XCTAssertEqual(try Data(contentsOf: mac(md)), try Data(contentsOf: md))
    }

    func testATitleIsNotAddedToACopyEditedHereOrNotOnTheList() throws {
        let md = try phoneNote()
        let (day, stem) = key(md)
        XCTAssertFalse(PhoneImport.addTitle("Launch budget", day: day, stem: stem, to: notes, statePath: state), "not copied yet")
        imp()
        let id = try XCTUnwrap(NoteStore(root: notes).names().first?.id)
        try NoteStore(root: notes).renameSpeaker(in: id, from: "Speaker 1", to: "Alex")
        let edited = try Data(contentsOf: mac(md))
        XCTAssertFalse(PhoneImport.addTitle("Launch budget", day: day, stem: stem, to: notes, statePath: state))
        XCTAssertEqual(try Data(contentsOf: mac(md)), edited)
        XCTAssertFalse(
            PhoneImport.addTitle("Launch budget", day: day, stem: stem, to: otherNotes, statePath: state), "another notes folder")
    }

    func testATitleThatIsntOneIsNotAdded() throws {
        let md = try phoneNote()
        imp()
        let (day, stem) = key(md)
        XCTAssertFalse(PhoneImport.addTitle("Sorry, I can't help with that", day: day, stem: stem, to: notes, statePath: state))
        XCTAssertFalse(PhoneImport.addTitle("   ", day: day, stem: stem, to: notes, statePath: state))
        XCTAssertNil(try NoteStore(root: notes).read(url: mac(md)).aiTitle)
        XCTAssertEqual(try Data(contentsOf: mac(md)), try Data(contentsOf: md))
    }

    func testThisMacsTitlesFileIsUsedUntilTheiPhoneFoldsItIn() throws {
        let md = try phoneNote()
        let (day, stem) = key(md)
        // Beside the iPhone's Conversations folder (here PhoneInbox, so beside it is `base`).
        let titles = TitlesFile.url(forConversations: inbox, day: day)
        try FileManager.default.createDirectory(at: titles.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TitlesFile(titles: [stem: "Launch budget"]).encoded().write(to: titles)

        XCTAssertEqual(imp().imported, 1)
        XCTAssertEqual(try NoteStore(root: notes).read(url: mac(md)).aiTitle, "Launch budget")
        XCTAssertNil(try NoteStore(root: inbox).read(url: md).aiTitle, "the iPhone's copy isn't touched")
        XCTAssertEqual(imp().unchanged, 1)

        // The iPhone adds a place before it folds the title in: the copy here gets the place and keeps the title.
        try NoteFrontMatter.update(fileAt: md, set: ["place": "4 Main St"])
        try setDate(md, 1_790_000_100)
        XCTAssertEqual(imp().updated, 1)
        let read = try NoteStore(root: notes).read(url: mac(md))
        XCTAssertEqual([read.aiTitle, read.place], ["Launch budget", "4 Main St"])

        // Then it folds it in, the same way: byte for byte the copy here already, so nothing is written.
        try NoteFrontMatter.update(fileAt: md, set: ["ai_title": "Launch budget"])
        try setDate(md, 1_790_000_200)
        XCTAssertEqual(try Data(contentsOf: mac(md)), try Data(contentsOf: md))
        XCTAssertEqual(imp().unchanged, 1)
        // And its next change replaces the copy as usual.
        try NoteFrontMatter.update(fileAt: md, set: ["keep_audio": "true"])
        try setDate(md, 1_790_000_300)
        XCTAssertEqual(imp().updated, 1)
        XCTAssertEqual(try Data(contentsOf: mac(md)), try Data(contentsOf: md))
    }
}
#endif
