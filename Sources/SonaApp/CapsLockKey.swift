import Foundation
import IOKit
import IOKit.hidsystem
import NotesKit

/// While Caps Lock is in the dictation shortcut, it's remapped to F18 (the keyboards' `UserKeyMapping`, what
/// `hidutil property --set` changes, through the same IOKit calls), so it's held like a modifier instead of
/// toggling caps. Only our entry is added; other mappings stay. It's taken out again when the shortcut changes,
/// dictation is turned off or the app quits, and on the next launch after a crash (the saved marker, like `FnKey`).
/// macOS forgets the mapping at logout and reboot, and a keyboard plugged in later has none, so it's applied
/// again whenever a keyboard appears.
@MainActor
enum CapsLockKey {
    static let caps: UInt64 = 0x7_0000_0039
    static let f18: UInt64 = 0x7_0000_006D
    /// What Caps Lock was mapped to before (0: nothing). Its presence is the marker that ours is in place.
    private static let savedKey = "capsLockMappingBeforeDictation"
    /// The key probe keeps its marker apart from the app's.
    static var defaults = UserDefaults.standard
    private static var watching: IONotificationPortRef?
    /// Ours should be in place now (the shortcut uses Caps Lock), so a keyboard that appears gets it too. Not the
    /// marker: that can outlive a restore that failed.
    private static var wanted = false
    private static let srcKey = "HIDKeyboardModifierMappingSrc", dstKey = "HIDKeyboardModifierMappingDst"

    static var isTakenOver: Bool { defaults.object(forKey: savedKey) != nil }

    static func takeOver() {
        guard KeyMonitor.mayTouchKeyboard else { return }
        wanted = true
        let boards = keyboards()
        // Saved before changing anything, and only the first time: after a crash it's ours that's there now. Ours
        // (Caps Lock to F18, left by a crash that lost the marker) is never saved as the user's: giving that back would
        // keep Caps Lock as F18 for good.
        if !isTakenOver {
            let theirs = { (entry: [String: Any]) in isCaps(entry) && !isOurs(entry) }
            let before = boards.lazy.compactMap { mapping($0).first(where: theirs).flatMap(dst) }.first ?? 0
            defaults.set(NSNumber(value: before), forKey: savedKey)
        }
        var changed = 0
        for board in boards {
            var map = mapping(board)
            guard !map.contains(where: isOurs) else { continue }
            map.removeAll(where: isCaps)
            map.append([srcKey: NSNumber(value: caps), dstKey: NSNumber(value: f18)])
            if IOHIDServiceClientSetProperty(board, "UserKeyMapping" as CFString, map as CFArray) { changed += 1 }
        }
        if changed > 0 { Log.note("dictation: caps lock held as F18 on \(changed) keyboard(s)") }
        KeyMonitor.shared.capsRemapped(true)
        watchKeyboards()
    }

    static func restore() {
        KeyMonitor.shared.capsRemapped(false)
        wanted = false
        guard KeyMonitor.mayTouchKeyboard, let saved = defaults.object(forKey: savedKey) as? NSNumber else { return }
        // A saved F18 is ours (an older version could save it): that's no mapping of the user's.
        let before = saved.uint64Value == f18 ? 0 : saved.uint64Value
        var changed = 0, failed = 0
        for board in keyboards() {
            var map = mapping(board)
            guard map.contains(where: isOurs) else { continue }
            map.removeAll(where: isOurs)
            if before != 0 { map.append([srcKey: NSNumber(value: caps), dstKey: NSNumber(value: before)]) }
            if IOHIDServiceClientSetProperty(board, "UserKeyMapping" as CFString, map as CFArray) { changed += 1 } else { failed += 1 }
        }
        // A keyboard that didn't take it keeps the marker, so the next restore (the next launch, at the latest) tries
        // again instead of leaving Caps Lock as F18 with nothing to say so.
        if failed == 0 { defaults.removeObject(forKey: savedKey) }
        Log.note("dictation: caps lock given back on \(changed) keyboard(s)\(failed > 0 ? ", \(failed) failed (will try again)" : "")")
    }

    /// Kept for good: the services it hands out die with it.
    private static let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

    private static func keyboards() -> [IOHIDServiceClient] {
        let services = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
        return services.filter { IOHIDServiceClientConformsTo($0, 1, 6) != 0 }  // generic desktop, keyboard
    }

    private static func mapping(_ board: IOHIDServiceClient) -> [[String: Any]] {
        (IOHIDServiceClientCopyProperty(board, "UserKeyMapping" as CFString) as? [[String: Any]]) ?? []
    }

    private static func src(_ entry: [String: Any]) -> UInt64? { (entry[srcKey] as? NSNumber)?.uint64Value }
    private static func dst(_ entry: [String: Any]) -> UInt64? { (entry[dstKey] as? NSNumber)?.uint64Value }
    private static func isCaps(_ entry: [String: Any]) -> Bool { src(entry) == caps }
    private static func isOurs(_ entry: [String: Any]) -> Bool { src(entry) == caps && dst(entry) == f18 }

    /// A keyboard appeared (plugged in, or back after the last one went): map it too, once the HID system has it.
    private static func watchKeyboards() {
        guard watching == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        watching = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let matching = IOServiceMatching("IOHIDInterface") as NSMutableDictionary
        matching["DeviceUsagePage"] = 1
        matching["DeviceUsage"] = 6
        var iterator: io_iterator_t = 0
        let added: IOServiceMatchingCallback = { _, iterator in
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { if CapsLockKey.wanted { CapsLockKey.takeOver() } }
            }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching, added, nil, &iterator)
        // Going through the ones already there arms the notification.
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }
}
