import AVFoundation
import Foundation

/// Multichannel audio recorder.
///
/// Two modes:
///   - `.separated`: 8-channel file. ch0/1 FM, ch2/3 SSG, ch4/5 ADPCM, ch6/7 Rhythm.
///                   Intended for DAW import (Logic/Audacity). QuickTime and most
///                   media players will only play ch0/ch1.
///   - `.stereo`:    Standard 2-channel mix. Plays in any player.
///
/// AAC cannot encode discrete 8-channel layouts and is therefore always
/// written as stereo regardless of the requested mode.
///
/// Writes are offloaded to a serial dispatch queue so the audio drain path
/// is not blocked by disk I/O or encoder latency.
@MainActor
@Observable
final class AudioRecorder {

    enum RecordingFormat: String, CaseIterable, Identifiable {
        case wav, alac, aac

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .wav:  return "wav"
            case .alac: return "caf"
            case .aac:  return "m4a"
            }
        }

        var displayName: String {
            switch self {
            case .wav:  return "WAV"
            case .alac: return "Apple Lossless (ALAC)"
            case .aac:  return "AAC"
            }
        }

        /// Whether this format can encode the separated (8-channel) mode.
        /// AAC cannot; the encoder rejects discrete 8-channel layouts.
        var supportsSeparated: Bool {
            switch self {
            case .wav, .alac: return true
            case .aac:        return false
            }
        }

        /// AVAudioFile writer settings for 44100 Hz.
        /// `layoutData` is required for channel counts > 2 — AVAudioFile
        /// rejects multichannel settings without an explicit channel layout.
        func settings(channels: UInt32, layoutData: Data?) -> [String: Any] {
            var base: [String: Any]
            switch self {
            case .wav:
                base = [
                    AVFormatIDKey:               kAudioFormatLinearPCM,
                    AVSampleRateKey:             44_100.0,
                    AVNumberOfChannelsKey:       channels,
                    AVLinearPCMBitDepthKey:      16,
                    AVLinearPCMIsFloatKey:       false,
                    AVLinearPCMIsBigEndianKey:   false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            case .alac:
                base = [
                    AVFormatIDKey:            kAudioFormatAppleLossless,
                    AVSampleRateKey:          44_100.0,
                    AVNumberOfChannelsKey:    channels,
                    AVEncoderBitDepthHintKey: 16,
                ]
            case .aac:
                base = [
                    AVFormatIDKey:         kAudioFormatMPEG4AAC,
                    AVSampleRateKey:       44_100.0,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey:   256_000,
                ]
            }
            if let layoutData {
                base[AVChannelLayoutKey] = layoutData
            }
            return base
        }
    }

    /// Channel layout mode selected at session start.
    enum ChannelMode: String, CaseIterable, Identifiable {
        case separated, stereo
        var id: String { rawValue }
    }

    private(set) var isRecording: Bool = false
    /// URL of the current (or most recent) session's file, for UI display.
    private(set) var lastOutputURL: URL?

    /// Mode of the *current or most recent* session. Audio-thread readable.
    @ObservationIgnored
    nonisolated(unsafe) private(set) var mode: ChannelMode = .stereo

    /// Discrete 8-channel layout for separated mode.
    /// `kAudioChannelLayoutTag_DiscreteInOrder` carries the channel count in
    /// its low 16 bits.
    @ObservationIgnored
    nonisolated private static let discrete8Layout: AVAudioChannelLayout = {
        let tag = kAudioChannelLayoutTag_DiscreteInOrder | 8
        return AVAudioChannelLayout(layoutTag: tag)!
    }()

    /// `AudioChannelLayout` encoded as Data for AVChannelLayoutKey (separated mode).
    @ObservationIgnored
    nonisolated private static let discrete8LayoutData: Data = {
        var layout = discrete8Layout.layout.pointee
        return Data(bytes: &layout,
                    count: MemoryLayout<AudioChannelLayout>.size)
    }()

    /// Build a Float32 interleaved AVAudioFormat with the requested channel count.
    /// The no-layout convenience initializer returns nil for channel counts > 2,
    /// so we always go through streamDescription + channelLayout.
    nonisolated private static func makeInputFormat(channels: UInt32) -> AVAudioFormat {
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * channels
        var asbd = AudioStreamBasicDescription(
            mSampleRate:       44_100,
            mFormatID:         kAudioFormatLinearPCM,
            mFormatFlags:      kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket:   bytesPerFrame,
            mFramesPerPacket:  1,
            mBytesPerFrame:    bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel:   32,
            mReserved:         0
        )
        let layout: AVAudioChannelLayout
        if channels == 8 {
            layout = discrete8Layout
        } else {
            layout = AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_Stereo
            )!
        }
        return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)!
    }

    /// Buffer format for the current session. Accessed from audio thread.
    @ObservationIgnored
    nonisolated(unsafe) private var inputFormat: AVAudioFormat =
        AudioRecorder.makeInputFormat(channels: 2)

    /// Access to `file` is serialized on writeQueue.
    @ObservationIgnored nonisolated(unsafe) private var file: AVAudioFile?

    /// Serial queue for file writes; isolates audio drain path from I/O.
    @ObservationIgnored
    private let writeQueue = DispatchQueue(label: "com.bubilator88.audiorecorder",
                                           qos: .utility)

    /// Non-isolated flag readable from the audio thread to avoid actor hops.
    @ObservationIgnored
    nonisolated(unsafe) private(set) var isRecordingFlag: Bool = false

    /// Start a new recording session.
    /// - Parameters:
    ///   - baseDirectory: Parent directory where the file is created.
    ///   - format: Output format.
    ///   - separation: Channel mode. Forced to `.stereo` when the format
    ///     cannot carry separated audio (i.e. AAC).
    ///   - baseName: Base name for the file, typically the mounted disk's
    ///     file name (without extension). Sanitized for filesystem safety.
    func start(baseDirectory: URL,
               format: RecordingFormat,
               separation: ChannelMode,
               baseName: String) throws {
        guard !isRecording else { return }

        try FileManager.default.createDirectory(at: baseDirectory,
                                                withIntermediateDirectories: true)

        let effectiveMode: ChannelMode = format.supportsSeparated ? separation : .stereo
        let channels: UInt32 = (effectiveMode == .separated) ? 8 : 2
        let layoutData: Data? = (effectiveMode == .separated) ? Self.discrete8LayoutData : nil
        let newFormat = Self.makeInputFormat(channels: channels)

        let fmt = DateFormatter.stable(pattern: "yyyy-MM-dd-HHmmss")
        let sanitized = Self.sanitize(baseName)
        let fileName = "\(sanitized)-\(fmt.string(from: Date())).\(format.fileExtension)"
        let url = baseDirectory.appendingPathComponent(fileName)

        let settings = format.settings(channels: channels, layoutData: layoutData)
        let newFile = try AVAudioFile(forWriting: url,
                                      settings: settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: true)

        writeQueue.sync {
            self.file = newFile
            self.inputFormat = newFormat
        }
        self.mode = effectiveMode

        lastOutputURL = url
        isRecording = true
        isRecordingFlag = true
    }

    /// Stop the current session and close the file.
    func stop() {
        guard isRecording else { return }
        isRecordingFlag = false
        isRecording = false
        writeQueue.sync { self.file = nil }
    }

    // MARK: - Audio-thread tap entry points

    /// Append one chunk of per-channel samples (separated mode). Each
    /// parameter is interleaved stereo [L,R,L,R,...] of equal length.
    /// No-op when not recording in separated mode. Called from the audio
    /// drain path; I/O is offloaded to writeQueue.
    nonisolated func appendChannels(fm: [Float],
                                    ssg: [Float],
                                    adpcm: [Float],
                                    rhythm: [Float]) {
        guard isRecordingFlag, mode == .separated else { return }
        writeQueue.async { [self] in
            writeSeparated(fm: fm, ssg: ssg, adpcm: adpcm, rhythm: rhythm)
        }
    }

    /// Append one chunk of stereo samples [L,R,L,R,...] (stereo mode).
    /// No-op when not recording in stereo mode.
    nonisolated func appendStereo(_ samples: [Float]) {
        guard isRecordingFlag, mode == .stereo else { return }
        guard !samples.isEmpty else { return }
        // Copy now — the caller will clear its buffer after returning.
        let snapshot = samples
        writeQueue.async { [self] in
            writeStereo(snapshot)
        }
    }

    // MARK: - Serial-queue write helpers

    /// Compose an 8-channel interleaved frame buffer from four 2-channel
    /// sources. If sources differ in length (can happen briefly around
    /// configuration changes), the shortest is used so channels stay in sync.
    nonisolated private func writeSeparated(fm: [Float],
                                            ssg: [Float],
                                            adpcm: [Float],
                                            rhythm: [Float]) {
        guard let file else { return }
        let minPairs = min(fm.count, ssg.count, adpcm.count, rhythm.count) / 2
        guard minPairs > 0 else { return }

        let frameCount = AVAudioFrameCount(minPairs)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                            frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        guard let dst = buffer.floatChannelData?[0] else { return }

        var w = 0
        for i in 0..<minPairs {
            let s = i * 2
            dst[w + 0] = fm[s];      dst[w + 1] = fm[s + 1]
            dst[w + 2] = ssg[s];     dst[w + 3] = ssg[s + 1]
            dst[w + 4] = adpcm[s];   dst[w + 5] = adpcm[s + 1]
            dst[w + 6] = rhythm[s];  dst[w + 7] = rhythm[s + 1]
            w += 8
        }

        try? file.write(from: buffer)
    }

    nonisolated private func writeStereo(_ samples: [Float]) {
        guard let file else { return }
        let frames = samples.count / 2
        guard frames > 0 else { return }
        let frameCount = AVAudioFrameCount(frames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                            frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        guard let dst = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: frames * 2)
        }
        try? file.write(from: buffer)
    }

    /// Sanitize a string for use as a file-name component.
    private static func sanitize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Bubilator88" }
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
                    .union(.controlCharacters)
        let cleaned = trimmed.unicodeScalars.map {
            bad.contains($0) ? "_" : String($0)
        }.joined()
        return cleaned.isEmpty ? "Bubilator88" : cleaned
    }
}
