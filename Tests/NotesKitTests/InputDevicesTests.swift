import CoreAudio
import XCTest

@testable import NotesKit

final class InputDevicesTests: XCTestCase {
    let builtIn = InputDevice(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone", transport: kAudioDeviceTransportTypeBuiltIn)
    let airPods = InputDevice(id: 2, uid: "AA-BB-CC:input", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
    let airPodsLE = InputDevice(id: 3, uid: "LE-AA-BB", name: "Beats", transport: kAudioDeviceTransportTypeBluetoothLE)
    let usb = InputDevice(id: 4, uid: "USB-Yeti", name: "Yeti", transport: kAudioDeviceTransportTypeUSB)
    let blackHole = InputDevice(id: 5, uid: "BlackHole2ch_UID", name: "BlackHole 2ch", transport: kAudioDeviceTransportTypeVirtual)

    func choose(_ devices: [InputDevice], _ uid: String? = nil) -> String? {
        InputDevices.choose(from: devices, preferredUID: uid)?.uid
    }

    func defaulted(_ d: InputDevice) -> InputDevice {
        var d = d
        d.isDefault = true
        return d
    }

    func testChosenDeviceWinsWhenConnected() {
        XCTAssertEqual(choose([builtIn, usb], "USB-Yeti"), "USB-Yeti")
    }

    func testChosenBluetoothIsAllowed() {
        XCTAssertEqual(choose([builtIn, defaulted(airPods)], "AA-BB-CC:input"), "AA-BB-CC:input")
    }

    func testChosenMissingFallsBackToAutomatic() {
        XCTAssertEqual(choose([defaulted(usb), builtIn], "gone"), "USB-Yeti")
        XCTAssertEqual(choose([usb, builtIn], "gone"), "BuiltInMicrophoneDevice")
    }

    func testAutomaticUsesTheSystemDefaultUnlessBluetooth() {
        // A USB mic set as the default is used (and keeps working with the lid closed).
        XCTAssertEqual(choose([defaulted(usb), builtIn]), "USB-Yeti")
        XCTAssertEqual(choose([usb, defaulted(builtIn)]), "BuiltInMicrophoneDevice")
        XCTAssertEqual(choose([airPods, defaulted(blackHole)]), "BlackHole2ch_UID")
    }

    func testBluetoothDefaultIsNeverPickedAutomatically() {
        XCTAssertEqual(choose([defaulted(airPods), builtIn]), "BuiltInMicrophoneDevice")
        XCTAssertNil(choose([defaulted(airPods)]))
        XCTAssertNil(choose([defaulted(airPodsLE), airPods]))
        // No guessing among other inputs (an iPhone Continuity mic, say): built-in or nothing.
        XCTAssertNil(choose([defaulted(airPods), blackHole, usb]))
    }

    func testNoDevices() {
        XCTAssertNil(choose([]))
        XCTAssertNil(choose([], "USB-Yeti"))
    }

    func testFlags() {
        XCTAssertTrue(airPods.isBluetooth)
        XCTAssertTrue(airPodsLE.isBluetooth)
        XCTAssertFalse(builtIn.isBluetooth)
        XCTAssertTrue(builtIn.isBuiltIn)
        XCTAssertEqual(airPodsLE.label, "\"Beats\" (Bluetooth)")
        XCTAssertEqual(builtIn.label, "\"MacBook Air Microphone\" (built-in)")
    }

    func testOldSettingsFileDecodesWithAutomaticMic() throws {
        let old = #"{"notesFolder":"/tmp/n","quietMinutes":3,"model":"v2","keepAudio":false,"launchAtLogin":true}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        XCTAssertNil(settings.micUID)
        XCTAssertEqual(settings.notesFolder, "/tmp/n")
    }

    func testMicRoundTrips() throws {
        var settings = Settings()
        settings.micUID = "USB-Yeti"
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.micUID, "USB-Yeti")
    }

    /// A file from before the one app gets the new switches' defaults: always on, dictation on fn, AI access
    /// and speakers on.
    func testOldSettingsGetTheNewDefaults() throws {
        let old = #"{"notesFolder":"/tmp/n","quietMinutes":0.1,"model":"v2","keepAudio":false,"launchAtLogin":false}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        XCTAssertTrue(s.alwaysOn)
        XCTAssertTrue(s.dictation)
        XCTAssertEqual(s.dictationKey, .fn)
        XCTAssertTrue(s.mcp)
        XCTAssertTrue(s.speakers)
        XCTAssertNil(s.pausedUntil)
        XCTAssertFalse(s.isPaused())
        XCTAssertEqual(s.quietMinutes, 0.1, "kept, even though the app no longer shows it")
        XCTAssertFalse(s.launchAtLogin)
    }

    func testNewSettingsRoundTrip() throws {
        var s = Settings()
        s.alwaysOn = false
        s.dictation = false
        s.dictationKey = .rightCommand
        s.mcp = false
        s.speakers = false
        s.pausedUntil = Date(timeIntervalSince1970: 1_790_003_600)
        let data = try JSONEncoder().encode(s)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("2026-"), "the pause is a readable date")
        let back = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(back, s)
        XCTAssertTrue(back.isPaused(now: Date(timeIntervalSince1970: 1_790_000_000)))
        XCTAssertFalse(back.isPaused(now: Date(timeIntervalSince1970: 1_790_003_601)))
        // An unknown key or a bad date falls back instead of losing the whole file.
        let odd = #"{"dictationKey":"capsLock","pausedUntil":"soon","notesFolder":"/tmp/x"}"#
        let o = try JSONDecoder().decode(Settings.self, from: Data(odd.utf8))
        XCTAssertEqual(o.dictationKey, .fn)
        XCTAssertNil(o.pausedUntil)
        XCTAssertEqual(o.notesFolder, "/tmp/x")
    }
}
