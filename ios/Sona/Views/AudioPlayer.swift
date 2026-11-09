import AVFoundation
import Observation

/// Plays a note's kept audio. One at a time; `seek` jumps to a transcript line.
@MainActor
@Observable
final class AudioPlayer {
    private(set) var isPlaying = false
    private(set) var current: Double = 0
    private(set) var duration: Double = 0
    private var player: AVAudioPlayer?
    private var url: URL?
    private var timer: Timer?
    /// Plays silently (`-debugPlayNote` only): screenshots of a note playing in the simulator shouldn't come out of
    /// the Mac's speakers.
    @ObservationIgnored var muted = false
    /// The player playing now, if any, so a recording that starts can stop it first.
    private static weak var playing: AudioPlayer?

    /// A recording is starting: a note playing is paused first. The recorder turns the session to play and record on
    /// the speaker, and the mic would record the note into the new one.
    static func pauseForRecording() {
        playing?.pause()
    }

    /// Loads `url` (nil: no audio). The same file again does nothing while it's loaded, so the playhead stays; after
    /// `stop` it loads again.
    func load(_ url: URL?) {
        guard url != self.url || (url != nil && player == nil) else { return }
        stop()
        self.url = url
        guard let url else { return }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
        } catch {
            player = nil
        }
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        // While recording, the session is the recorder's (play and record): switching it to playback would stop the
        // mic. It plays through that session as it is.
        if !PhoneRecorder.shared.isRecording {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        player.volume = muted ? 0 : 1
        // One at a time.
        if let other = Self.playing, other !== self { other.pause() }
        Self.playing = self
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
        if Self.playing === self { Self.playing = nil }
    }

    /// Lets go of the file. The next `load`, even of the same file, opens it again.
    func stop() {
        pause()
        player?.stop()
        player = nil
        url = nil
        current = 0
        duration = 0
    }

    /// Jumps to `seconds`. `play`: start playing from there (a tapped line); the slider only moves the playhead, so
    /// dragging it, or VoiceOver adjusting it, doesn't start the audio.
    func seek(to seconds: Double, play: Bool = true) {
        guard let player else { return }
        player.currentTime = max(0, min(seconds, player.duration))
        current = player.currentTime
        if play, !isPlaying { self.play() }
    }

    private func tick() {
        guard let player else { return }
        current = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            timer?.invalidate()
            timer = nil
        }
    }
}
