import Foundation

/// The engine settings, remembered between launches.
///
/// These are preferences, not document state: someone who plays everything as an SC-55 with the
/// reverb off means it next time too, and having to say so again each launch is the kind of thing
/// that makes a player feel like a demo.
///
/// Stored one key per setting rather than as an encoded blob, so a value added later reads back as
/// its default instead of invalidating everything saved before it.
struct Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let map = "engine.map"
        static let polyphony = "engine.polyphony"
        static let ports = "engine.ports"
        static let reverb = "engine.reverb"
        static let chorus = "engine.chorus"
        static let delay = "engine.delay"
        static let efx = "engine.efx"
        static let extendedInterpolation = "engine.extendedInterpolation"
        static let outputGain = "engine.outputGain"
        static let latency = "engine.latencyMilliseconds"
        static let looping = "transport.looping"
    }

    /// Reads back what was stored, falling back to the engine's own defaults per setting.
    var settings: EngineSettings {
        var settings = EngineSettings.default

        if let raw = defaults.object(forKey: Key.map) as? Int32,
           let map = ToneMap(rawValue: raw) {
            settings.map = map
        }
        if let value = defaults.object(forKey: Key.polyphony) as? Int { settings.polyphony = value }
        if let value = defaults.object(forKey: Key.ports) as? Int { settings.ports = value }
        if let value = defaults.object(forKey: Key.reverb) as? Bool { settings.reverb = value }
        if let value = defaults.object(forKey: Key.chorus) as? Bool { settings.chorus = value }
        if let value = defaults.object(forKey: Key.delay) as? Bool { settings.delay = value }
        if let value = defaults.object(forKey: Key.efx) as? Bool { settings.efx = value }
        if let value = defaults.object(forKey: Key.extendedInterpolation) as? Bool {
            settings.extendedInterpolation = value
        }
        // Clamped rather than taken as read, because this is the one setting whose range narrowed:
        // gain only ever adds now, and a value stored by a build that could also cut would leave a
        // slider sitting at its floor while the engine went on rendering below it -- a control
        // disagreeing with what is being heard, which is worse than a setting that moved.
        if let value = defaults.object(forKey: Key.outputGain) as? Double {
            settings.outputGain = min(max(value, EngineSettings.gainRange.lowerBound),
                                      EngineSettings.gainRange.upperBound)
        }

        return settings
    }

    func store(_ settings: EngineSettings) {
        defaults.set(settings.map.rawValue, forKey: Key.map)
        defaults.set(settings.polyphony, forKey: Key.polyphony)
        defaults.set(settings.ports, forKey: Key.ports)
        defaults.set(settings.reverb, forKey: Key.reverb)
        defaults.set(settings.chorus, forKey: Key.chorus)
        defaults.set(settings.delay, forKey: Key.delay)
        defaults.set(settings.efx, forKey: Key.efx)
        defaults.set(settings.extendedInterpolation, forKey: Key.extendedInterpolation)
        defaults.set(settings.outputGain, forKey: Key.outputGain)
    }

    /// The buffer, kept apart from the rest because it is a property of the machine rather than of
    /// the sound: the right value on one computer is not the right value on another.
    var latencyMilliseconds: Int? {
        get { defaults.object(forKey: Key.latency) as? Int }
        nonmutating set { defaults.set(newValue, forKey: Key.latency) }
    }

    /// Whether songs repeat. Outlives the song and the engine both, so it belongs here.
    var isLooping: Bool {
        get { defaults.bool(forKey: Key.looping) }
        nonmutating set { defaults.set(newValue, forKey: Key.looping) }
    }
}
