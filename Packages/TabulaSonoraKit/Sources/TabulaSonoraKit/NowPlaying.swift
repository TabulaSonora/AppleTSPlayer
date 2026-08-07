import Foundation
import MediaPlayer

/// The system's transport: Control Center, the lock screen, media keys and headphone buttons.
///
/// Two halves that are easy to confuse. `MPRemoteCommandCenter` is the system asking *this* app to
/// do something, and its handlers are registered once. `MPNowPlayingInfoCenter` is this app telling
/// the system what is playing, and it is pushed on every state change -- but *not* continuously:
/// the elapsed time is published with a playback rate beside it, and the system extrapolates from
/// there. Republishing ten times a second would be worse than useless, because each push resets
/// that extrapolation.
@MainActor
final class NowPlaying {
    /// What the system can ask for. The player supplies these once, at construction.
    struct Commands {
        let play: () -> Void
        let pause: () -> Void
        let toggle: () -> Void
        let seek: (TimeInterval) -> Void
        let skip: (TimeInterval) -> Void
    }

    /// Seconds a skip command moves by, and what the system is told to label its buttons.
    private static let skipInterval: TimeInterval = 15

    private let info = MPNowPlayingInfoCenter.default()
    private var registered = false

    init(commands: Commands) {
        register(commands)
    }

    private func register(_ commands: Commands) {
        guard !registered else { return }
        registered = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { _ in commands.play(); return .success }
        center.pauseCommand.addTarget { _ in commands.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { _ in commands.toggle(); return .success }
        center.stopCommand.addTarget { _ in commands.pause(); return .success }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipForwardCommand.addTarget { _ in commands.skip(Self.skipInterval); return .success }
        center.skipBackwardCommand.addTarget { _ in commands.skip(-Self.skipInterval); return .success }

        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            commands.seek(event.positionTime)
            return .success
        }

        // There is no playlist, so offering track skip would put buttons on the lock screen that
        // do nothing. Left off deliberately rather than left at their defaults.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    /// Publishes what is playing. Call on load, play, pause, seek and completion -- not on a timer.
    func update(title: String,
                module: String,
                duration: TimeInterval,
                position: TimeInterval,
                isPlaying: Bool) {
        var now: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            // The voice it is being rendered through. A MIDI file carries no artist the engine
            // exposes, and inventing one would be worse than naming the thing that made the sound.
            MPMediaItemPropertyArtist: module,
            MPMediaItemPropertyAlbumTitle: "Tabula Sonora",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            // The rate is what the system extrapolates the elapsed time with, so a paused
            // transport must publish zero or the scrubber keeps running on its own.
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]

        // Omitted rather than sent as zero when unknown: a zero duration makes the lock screen draw
        // a scrubber that cannot be dragged.
        if duration > 0 {
            now[MPMediaItemPropertyPlaybackDuration] = duration
        }

        info.nowPlayingInfo = now

        // macOS will not show the app in Control Center without this; on iOS the audio session
        // implies it, and setting it does no harm.
        info.playbackState = isPlaying ? .playing : .paused
    }

    /// Removes the app from the system transport, for when there is nothing loaded.
    func clear() {
        info.nowPlayingInfo = nil
        info.playbackState = .stopped
    }
}
