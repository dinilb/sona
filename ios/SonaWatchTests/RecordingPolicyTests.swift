import AVFoundation
import Foundation
import Testing
@testable import SonaWatch

/// The decision, with no recorder, mic or clock in it: a call saves the recording, its end starts a new one.
struct InterruptionPolicyTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func aCallSavesTheRecordingAndItsEndStartsANewOne() {
        var policy = InterruptionPolicy()
        #expect(policy.handle(.began, isRecording: true, now: start) == .saveAndWait)
        #expect(policy.isWaiting)
        #expect(policy.handle(.ended(shouldResume: true), isRecording: false, now: start + 20) == .startNewRecording)
        #expect(!policy.isWaiting)
    }

    @Test func theEndStartsOneWhetherOrNotTheSystemSaysShouldResume() {
        // He never asked to stop, so "should resume" being false (Siri, say) changes nothing.
        var policy = InterruptionPolicy()
        _ = policy.handle(.began, isRecording: true, now: start)
        #expect(policy.handle(.ended(shouldResume: false), isRecording: false, now: start + 5) == .startNewRecording)
    }

    @Test func anEndWithNothingWaitingDoesNothing() {
        var policy = InterruptionPolicy()
        #expect(policy.handle(.ended(shouldResume: true), isRecording: false, now: start) == .nothing)
        #expect(policy.handle(.ended(shouldResume: false), isRecording: true, now: start) == .nothing)
    }

    @Test func aCallWhileNotRecordingDoesNothing() {
        var policy = InterruptionPolicy()
        #expect(policy.handle(.began, isRecording: false, now: start) == .nothing)
        #expect(!policy.isWaiting)
        // ...so its end can't start a recording he never made.
        #expect(policy.handle(.ended(shouldResume: true), isRecording: false, now: start + 5) == .nothing)
    }

    @Test func aSecondBeganDuringTheWaitChangesNothing() {
        var policy = InterruptionPolicy()
        _ = policy.handle(.began, isRecording: true, now: start)
        #expect(policy.handle(.began, isRecording: false, now: start + 3) == .nothing)  // Siri during the call
        #expect(policy.waitingSince == start)
        #expect(policy.handle(.ended(shouldResume: true), isRecording: false, now: start + 9) == .startNewRecording)
    }

    @Test func eachEndStartsAtMostOneRecording() {
        var policy = InterruptionPolicy()
        _ = policy.handle(.began, isRecording: true, now: start)
        #expect(policy.handle(.ended(shouldResume: true), isRecording: false, now: start + 5) == .startNewRecording)
        #expect(policy.handle(.ended(shouldResume: true), isRecording: true, now: start + 6) == .nothing)
    }

    @Test func startingByHandEndsTheWait() {
        var policy = InterruptionPolicy()
        _ = policy.handle(.began, isRecording: true, now: start)
        policy.stopWaiting()  // a recording is going again
        #expect(policy.handle(.ended(shouldResume: true), isRecording: true, now: start + 5) == .nothing)
    }

    @Test func aRecordingIsNotStartedWhenSomethingIsAlreadyRecording() {
        var policy = InterruptionPolicy()
        _ = policy.handle(.began, isRecording: true, now: start)
        #expect(policy.handle(.ended(shouldResume: true), isRecording: true, now: start + 5) == .nothing)
    }

    @Test func anEndMuchLaterIsNotResumed() {
        var late = InterruptionPolicy()
        _ = late.handle(.began, isRecording: true, now: start)
        let tooLate = start + InterruptionPolicy.resumeWindow + 1
        // Left to him; the notification scheduled when the mic went has told him already.
        #expect(late.handle(.ended(shouldResume: true), isRecording: false, now: tooLate) == .leaveItToHim(tell: false))
        #expect(!late.isWaiting)

        var inTime = InterruptionPolicy()
        _ = inTime.handle(.began, isRecording: true, now: start)
        let lastMoment = start + InterruptionPolicy.resumeWindow
        #expect(inTime.handle(.ended(shouldResume: true), isRecording: false, now: lastMoment) == .startNewRecording)
    }
}

struct InterruptionNotificationTests {
    private func info(_ type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions? = nil)
        -> [AnyHashable: Any]
    {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if let options { info[AVAudioSessionInterruptionOptionKey] = options.rawValue }
        return info
    }

    @Test func readsBeganAndEnded() {
        #expect(Interruption(userInfo: info(.began)) == .began)
        #expect(Interruption(userInfo: info(.ended, options: .shouldResume)) == .ended(shouldResume: true))
        #expect(Interruption(userInfo: info(.ended, options: [])) == .ended(shouldResume: false))
        #expect(Interruption(userInfo: info(.ended)) == .ended(shouldResume: false))
    }

    @Test func ignoresAnythingElse() {
        #expect(Interruption(userInfo: nil) == nil)
        #expect(Interruption(userInfo: [:]) == nil)
        #expect(Interruption(userInfo: [AVAudioSessionInterruptionTypeKey: 99 as UInt]) == nil)
        #expect(Interruption(userInfo: [AVAudioSessionInterruptionTypeKey: "began"]) == nil)
    }
}

struct DiskPolicyTests {
    @Test func noRecordingStartsUnder100MB() {
        #expect(!DiskPolicy.canStart(freeBytes: 0))
        #expect(!DiskPolicy.canStart(freeBytes: 99_999_999))
        #expect(DiskPolicy.canStart(freeBytes: 100_000_000))
        #expect(DiskPolicy.canStart(freeBytes: 8_000_000_000))
    }

    @Test func aRecordingStopsUnder50MB() {
        #expect(DiskPolicy.mustStop(freeBytes: 0))
        #expect(DiskPolicy.mustStop(freeBytes: 49_999_999))
        #expect(!DiskPolicy.mustStop(freeBytes: 50_000_000))
        // Between the two it keeps going: it may not start, but one already running isn't cut off at 99 MB.
        #expect(!DiskPolicy.mustStop(freeBytes: 99_000_000))
    }

    @Test func anUnknownAmountNeverStopsAnything() {
        #expect(DiskPolicy.canStart(freeBytes: nil))
        #expect(!DiskPolicy.mustStop(freeBytes: nil))
    }

    @Test func theRealDiskReportsSomethingForAFolderThatDoesntExistYet() throws {
        let missing = try temporaryFolder().appending(path: "not/made/yet", directoryHint: .isDirectory)
        let free = try #require(SystemDisk.freeBytes(at: missing))
        #expect(free > 0)
    }
}
