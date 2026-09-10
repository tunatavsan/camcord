import Foundation
import Testing

@testable import Camcord

/// Phase P/W4: the panel's audio channel strip. Everything it decides before a pixel is
/// drawn — which control is live in which state, what the meter has to show, and which
/// input a saved device resolves to once it is unplugged.
@Suite("Audio channel strip")
struct AudioChannelStripTests {
    @Test("the system channel's switch locks for a recording while its gain stays live")
    func systemChannelTable() {
        let idle = AudioChannelState.system(enabled: true, recording: false, paused: false, starting: false)
        #expect(idle.switchLive)
        #expect(idle.gainLive)
        // There is no system-audio probe: nothing measures the channel until a recording does.
        #expect(!idle.meterAnimates)

        let starting = AudioChannelState.system(enabled: true, recording: false, paused: false, starting: true)
        #expect(!starting.switchLive)

        let recording = AudioChannelState.system(enabled: true, recording: true, paused: false, starting: false)
        // The engine bound its sources at the start, so the switch would promise a track
        // the file will never carry; the gain is applied per sample and stays live.
        #expect(!recording.switchLive)
        #expect(recording.gainLive)
        #expect(recording.meterAnimates)

        let paused = AudioChannelState.system(enabled: true, recording: true, paused: true, starting: false)
        #expect(!paused.meterAnimates)

        let off = AudioChannelState.system(enabled: false, recording: true, paused: false, starting: false)
        #expect(!off.gainLive)
        #expect(!off.meterAnimates)
    }

    @Test("a denied microphone takes its whole channel out of service")
    func microphoneChannelTable() {
        let idle = AudioChannelState.microphone(
            enabled: true, denied: false, recording: false, paused: false, starting: false, testing: false
        )
        #expect(idle.switchLive)
        #expect(idle.gainLive)
        #expect(!idle.meterAnimates)

        // A rehearsal moves the meter with no recording at all — the point of the test button.
        let testing = AudioChannelState.microphone(
            enabled: true, denied: false, recording: false, paused: false, starting: false, testing: true
        )
        #expect(testing.meterAnimates)

        let recording = AudioChannelState.microphone(
            enabled: true, denied: false, recording: true, paused: false, starting: false, testing: false
        )
        #expect(!recording.switchLive)
        #expect(recording.gainLive)
        #expect(recording.meterAnimates)
        #expect(!AudioChannelState.microphone(
            enabled: true, denied: false, recording: true, paused: true, starting: false, testing: false
        ).meterAnimates)

        let denied = AudioChannelState.microphone(
            enabled: true, denied: true, recording: false, paused: false, starting: false, testing: true
        )
        #expect(!denied.switchLive)
        #expect(!denied.gainLive)
        #expect(!denied.meterAnimates)

        let off = AudioChannelState.microphone(
            enabled: false, denied: false, recording: true, paused: false, starting: false, testing: false
        )
        #expect(!off.gainLive)
        #expect(!off.meterAnimates)
    }

    @Test("an unplugged microphone falls back to the system default instead of nothing")
    func inputResolution() {
        let available = ["mic-a", "mic-b"]
        #expect(AudioChannelState.resolvedInput(saved: "mic-b", available: available) == "mic-b")
        // The saved device is gone: the picker shows the default rather than an empty row,
        // and a rehearsal opens the default rather than failing.
        #expect(AudioChannelState.resolvedInput(saved: "mic-gone", available: available) == nil)
        #expect(AudioChannelState.resolvedInput(saved: nil, available: available) == nil)
        #expect(AudioChannelState.resolvedInput(saved: "mic-a", available: []) == nil)
    }

    @Test("the strip's gains reach the recording through the same clamp as everything else")
    func gainClamping() throws {
        var settings = RecordingSettings()
        settings.systemAudioGainDB = 999
        settings.microphoneGainDB = -999
        #expect(settings.resolvedSystemAudioGainDB == 12)
        #expect(settings.resolvedMicrophoneGainDB == -24)

        settings.systemAudioGainDB = -60
        settings.microphoneGainDB = 24
        #expect(settings.resolvedSystemAudioGainDB == -60)
        #expect(settings.resolvedMicrophoneGainDB == 24)

        settings.systemAudioGainDB = .nan
        settings.microphoneGainDB = .infinity
        #expect(settings.resolvedSystemAudioGainDB == 0)
        #expect(settings.resolvedMicrophoneGainDB == 0)

        // The strip's writers go through UserDefaults like every other panel control.
        let defaults = try #require(UserDefaults(suiteName: "camcord.audio.strip.test"))
        defaults.removePersistentDomain(forName: "camcord.audio.strip.test")
        var stored = RecordingSettings()
        stored.microphoneDeviceID = "mic-b"
        stored.mixAudioTracks = false
        stored.save(to: defaults)
        let reloaded = RecordingSettings.load(from: defaults)
        #expect(reloaded.microphoneDeviceID == "mic-b")
        #expect(!reloaded.mixAudioTracks)
        // Mixing needs both channels, whatever the switch says.
        #expect(!RecordingSettings(systemAudio: true, microphone: false, mixAudioTracks: true)
            .shouldMixAudioTracks)
        #expect(RecordingSettings(systemAudio: true, microphone: true, mixAudioTracks: true)
            .shouldMixAudioTracks)
        defaults.removePersistentDomain(forName: "camcord.audio.strip.test")
    }
}
