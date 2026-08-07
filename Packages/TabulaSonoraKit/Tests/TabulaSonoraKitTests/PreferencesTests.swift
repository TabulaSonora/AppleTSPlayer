import Foundation
import Testing
@testable import TabulaSonoraKit

struct PreferencesTests {
    /// A scratch domain, so a test run never touches what the app remembers.
    private func scratch() -> UserDefaults {
        let name = "TabulaSonoraTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func emptyDefaultsGiveTheEnginesOwnSettings() {
        let preferences = Preferences(defaults: scratch())
        #expect(preferences.settings == .default)
        #expect(preferences.latencyMilliseconds == nil)
        #expect(preferences.isLooping == false)
    }

    @Test func settingsSurviveARoundTrip() {
        let defaults = scratch()

        var settings = EngineSettings.default
        settings.map = .sc55
        settings.polyphony = 256
        settings.ports = 4
        settings.reverb = false
        settings.chorus = false
        settings.delay = true
        settings.efx = false
        settings.extendedInterpolation = false
        settings.outputGain = 1.75

        Preferences(defaults: defaults).store(settings)

        // A second reader, as a later launch would be.
        #expect(Preferences(defaults: defaults).settings == settings)
    }

    @Test func theBufferAndLoopSwitchAreRemembered() {
        let defaults = scratch()

        let writer = Preferences(defaults: defaults)
        writer.latencyMilliseconds = 25
        writer.isLooping = true

        let reader = Preferences(defaults: defaults)
        #expect(reader.latencyMilliseconds == 25)
        #expect(reader.isLooping)
    }

    /// The restore has to reach the player, not just round-trip through the defaults.
    @Test @MainActor func aNewPlayerComesUpWithWhatWasStored() {
        let defaults = scratch()

        var stored = EngineSettings.default
        stored.map = .sc55
        stored.reverb = false
        stored.outputGain = 1.5

        let writer = Preferences(defaults: defaults)
        writer.store(stored)
        writer.latencyMilliseconds = 25
        writer.isLooping = true

        let player = Player(defaults: defaults)
        #expect(player.settings == stored)
        #expect(player.latencyMilliseconds == 25)
        #expect(player.isLooping)
    }

    /// Stored one key per setting so a value added later reads back as its default rather than
    /// invalidating everything saved before it -- which an encoded blob would have done.
    @Test func aPartiallyWrittenDomainFallsBackPerSetting() {
        let defaults = scratch()
        defaults.set(ToneMap.sc88Pro.rawValue, forKey: "engine.map")

        let settings = Preferences(defaults: defaults).settings
        #expect(settings.map == .sc88Pro)
        #expect(settings.polyphony == EngineSettings.default.polyphony)
        #expect(settings.reverb == EngineSettings.default.reverb)

        // The setting added last, which is the one a domain written before it will be missing.
        #expect(settings.extendedInterpolation == EngineSettings.default.extendedInterpolation)
    }

    /// The extended resampler is the one default that is not the module's own behaviour, so it is
    /// worth pinning: a change upstream should be a decision here, not a surprise.
    @Test func theExtendedResamplerIsOnByDefault() {
        #expect(EngineSettings.default.extendedInterpolation)
    }
}
