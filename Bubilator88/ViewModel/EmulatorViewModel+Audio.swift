import Foundation
import EmulatorCore

// MARK: - Audio Debug

extension EmulatorViewModel {

    var debugAudioMask: YM2608.DebugOutputMask {
        var mask: YM2608.DebugOutputMask = []
        if fmEnabled { mask.insert(.fm) }
        if ssgEnabled { mask.insert(.ssg) }
        if adpcmEnabled { mask.insert(.adpcm) }
        if rhythmEnabled { mask.insert(.rhythm) }
        return mask
    }

    /// Apply current volume setting to audio engine.
    func applyVolume() {
        audio.setVolume(volume)
    }

    func applyDebugAudioMask() {
        let mask = debugAudioMask
        emuQueue.async { [weak self] in
            guard let self else { return }
            machine.sound.debugOutputMask = mask
        }
    }

    /// Apply a per-channel mute mask to the YM2608 on the emu queue.
    ///
    /// Intentionally NOT persisted; the mask resets to `.all` on emulator reset.
    func applyDebugChannelMask(_ mask: YM2608.DebugChannelMask) {
        emuQueue.async { [weak self] in
            self?.machine.sound.debugChannelMask = mask
        }
    }
}
