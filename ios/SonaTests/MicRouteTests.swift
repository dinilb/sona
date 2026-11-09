import Testing
@testable import Sona

/// When a route change rebuilds the mic's engine: only when the input changed under it, or the engine stopped.
struct MicRouteTests {
    let phoneMic = MicInput(port: "Built-In Microphone", sampleRate: 48_000, channels: 1)

    @Test func airPodsConnectingForMusicLeaveTheEngineAlone() {
        // The output moved to AirPods (A2DP); the input is still the iPhone's mic, in the same format.
        #expect(!MicInput.needsRestart(builtFor: phoneMic, now: phoneMic, engineRunning: true))
    }

    @Test func anotherInputPortRebuildsIt() {
        let headset = MicInput(port: "Wired Headset Microphone", sampleRate: 48_000, channels: 1)
        #expect(MicInput.needsRestart(builtFor: phoneMic, now: headset, engineRunning: true))
    }

    @Test func anotherFormatRebuildsIt() {
        var slower = phoneMic
        slower.sampleRate = 44_100
        #expect(MicInput.needsRestart(builtFor: phoneMic, now: slower, engineRunning: true))
        var stereo = phoneMic
        stereo.channels = 2
        #expect(MicInput.needsRestart(builtFor: phoneMic, now: stereo, engineRunning: true))
    }

    @Test func aStoppedEngineIsRebuiltEvenWithTheSameInput() {
        #expect(MicInput.needsRestart(builtFor: phoneMic, now: phoneMic, engineRunning: false))
    }

    @Test func noInputOrNoRecordOfOneRebuildsIt() {
        // A call can leave no input at all; and with no record of what it was built for, play safe.
        let none = MicInput(port: nil, sampleRate: 48_000, channels: 0)
        #expect(MicInput.needsRestart(builtFor: phoneMic, now: none, engineRunning: true))
        #expect(MicInput.needsRestart(builtFor: nil, now: phoneMic, engineRunning: true))
    }
}
