import Testing
import Foundation
@testable import Bubilator88

// MARK: - AudioRecorder.RecordingFormat invariants

/// These pin the rule "AAC is always written as stereo m4a" so accidental
/// regressions (e.g. re-enabling 8ch AAC, switching container to .caf)
/// fail loudly rather than producing unplayable files at runtime.
struct RecordingFormatTests {

    @Test("WAV uses .wav and supports 8ch separated mode")
    func wavInvariants() {
        #expect(AudioRecorder.RecordingFormat.wav.fileExtension == "wav")
        #expect(AudioRecorder.RecordingFormat.wav.supportsSeparated == true)
    }

    @Test("ALAC is packaged in .caf and supports 8ch separated mode")
    func alacInvariants() {
        // .caf is required because .m4a cannot reliably carry discrete
        // 8-channel layouts across decoders.
        #expect(AudioRecorder.RecordingFormat.alac.fileExtension == "caf")
        #expect(AudioRecorder.RecordingFormat.alac.supportsSeparated == true)
    }

    @Test("AAC is .m4a and rejects separated mode")
    func aacInvariants() {
        // AAC encoder cannot emit a discrete 8-channel bitstream, so the
        // recorder forces stereo for AAC. .m4a is fine for 2ch AAC.
        #expect(AudioRecorder.RecordingFormat.aac.fileExtension == "m4a")
        #expect(AudioRecorder.RecordingFormat.aac.supportsSeparated == false)
    }
}

// MARK: - DateFormatter.stable — locale-safety regression guard

/// Screenshots, recordings and save-state labels embed timestamps. Without
/// pinning the locale to `en_US_POSIX`, the `yyyy` pattern resolves to
/// era years on Japanese calendar locales — "20260424" turns into
/// "00080424", which breaks file sorting and confuses users.
struct StableTimestampTests {

    /// Fixed reference point: 2026-04-24 12:34:56 UTC (Gregorian).
    private static let sampleDate: Date = {
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(identifier: "UTC")
        comps.year = 2026; comps.month = 4; comps.day = 24
        comps.hour = 12; comps.minute = 34; comps.second = 56
        return comps.date!
    }()

    @Test("stable formatter emits Gregorian year even on Japanese calendar host")
    func stableIsCalendarIndependent() {
        let fmt = DateFormatter.stable(pattern: "yyyyMMdd-HHmmss")
        fmt.timeZone = TimeZone(identifier: "UTC")
        #expect(fmt.string(from: Self.sampleDate) == "20260424-123456")
    }

    @Test("dashed pattern used by AudioRecorder is also Gregorian")
    func stableAudioRecorderPattern() {
        let fmt = DateFormatter.stable(pattern: "yyyy-MM-dd-HHmmss")
        fmt.timeZone = TimeZone(identifier: "UTC")
        #expect(fmt.string(from: Self.sampleDate) == "2026-04-24-123456")
    }

    @Test("without POSIX locale the Japanese calendar would produce an era year")
    func naiveFormatterBreaksUnderJapaneseCalendar() {
        // This documents the bug we fixed: a bare DateFormatter with the
        // Japanese-calendar locale gives "0008" (Reiwa 8) instead of 2026.
        // If a future refactor drops the POSIX pin, the app-side timestamp
        // would collapse to this broken form.
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "ja_JP@calendar=japanese")
        naive.timeZone = TimeZone(identifier: "UTC")
        naive.dateFormat = "yyyyMMdd-HHmmss"
        let output = naive.string(from: Self.sampleDate)
        #expect(!output.hasPrefix("2026"),
                "Reference behavior — naive formatter must diverge from Gregorian.")
    }
}
