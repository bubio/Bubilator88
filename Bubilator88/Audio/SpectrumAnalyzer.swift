import Accelerate
import AVFoundation

/// Real-time audio spectrum analyzer using vDSP FFT.
///
/// Consumes 1024-sample `AVAudioPCMBuffer` blocks delivered on the
/// AVAudioEngine render thread, converts to mono, applies a Hann window,
/// runs a real-input FFT via `vDSP_fft_zrip`, and groups the result into
/// `bandCount` log-frequency bands expressed as dB values.
///
/// Thread safety: `currentBands` can be read from any thread; internal
/// processing uses an `NSLock` to protect the shared output array.
final class SpectrumAnalyzer: @unchecked Sendable {

    // MARK: - Constants

    static let fftSize   = 1024
    static let bandCount = 32
    static let minDB: Float = -60
    static let maxDB: Float =   0
    static let sampleRate: Float = Float(44100)

    // MARK: - Private state

    private let fftSetup: FFTSetup
    private let log2N:    vDSP_Length
    private var window:   [Float]
    private var realp:    [Float]
    private var imagp:    [Float]

    private let lock = NSLock()
    private var _bands: [Float]

    // MARK: - Init / deinit

    init() {
        log2N = vDSP_Length(log2(Float(SpectrumAnalyzer.fftSize)))
        guard let setup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed for log2N=\(log2N)")
        }
        fftSetup = setup
        window   = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
        realp    = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize / 2)
        imagp    = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize / 2)
        _bands   = [Float](repeating: SpectrumAnalyzer.minDB,
                           count: SpectrumAnalyzer.bandCount)
        vDSP_hann_window(&window, vDSP_Length(SpectrumAnalyzer.fftSize),
                         Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Public interface

    /// Thread-safe snapshot of the latest 32-band spectrum.
    /// Values are in dB (min: -60, max: 0).
    var currentBands: [Float] {
        lock.lock()
        let copy = _bands
        lock.unlock()
        return copy
    }

    /// Reset all band values to floor.
    func reset() {
        lock.lock()
        _bands = [Float](repeating: SpectrumAnalyzer.minDB,
                         count: SpectrumAnalyzer.bandCount)
        lock.unlock()
    }

    /// Process one PCM buffer. Called on the AVAudioEngine render thread.
    ///
    /// Stereo buffers are downmixed to mono before analysis.
    func process(buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount >= SpectrumAnalyzer.fftSize else { return }

        // Downmix to mono (average channels).
        var mono = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 0 { return }
        for ch in 0..<channelCount {
            let ptr = data[ch]
            vDSP_vadd(mono, 1, ptr, 1, &mono, 1, vDSP_Length(SpectrumAnalyzer.fftSize))
        }
        if channelCount > 1 {
            var scale = Float(channelCount)
            vDSP_vsdiv(mono, 1, &scale, &mono, 1, vDSP_Length(SpectrumAnalyzer.fftSize))
        }

        // Apply Hann window.
        vDSP_vmul(mono, 1, window, 1, &mono, 1, vDSP_Length(SpectrumAnalyzer.fftSize))

        // Pack N real values into N/2 complex for vDSP_fft_zrip.
        realp.withUnsafeMutableBufferPointer { rBuf in
            imagp.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!,
                                            imagp: iBuf.baseAddress!)
                mono.withUnsafeBytes { raw in
                    raw.withMemoryRebound(to: DSPComplex.self) { cBuf in
                        vDSP_ctoz(cBuf.baseAddress!, 2,
                                  &split, 1,
                                  vDSP_Length(SpectrumAnalyzer.fftSize / 2))
                    }
                }

                // Forward real FFT.
                vDSP_fft_zrip(fftSetup, &split, 1, log2N, FFTDirection(FFT_FORWARD))

                // Compute magnitudes.
                var magnitudes = [Float](repeating: 0,
                                        count: SpectrumAnalyzer.fftSize / 2)
                vDSP_zvabs(&split, 1, &magnitudes, 1,
                           vDSP_Length(SpectrumAnalyzer.fftSize / 2))

                // Scale: vDSP_fft_zrip does not normalise.
                var scale = Float(SpectrumAnalyzer.fftSize)
                vDSP_vsdiv(magnitudes, 1, &scale, &magnitudes, 1,
                           vDSP_Length(SpectrumAnalyzer.fftSize / 2))

                // Group into log-frequency bands.
                let bands = Self.logBands(from: magnitudes,
                                         binCount: SpectrumAnalyzer.fftSize / 2)
                lock.lock()
                _bands = bands
                lock.unlock()
            }
        }
    }

    // MARK: - Log-band grouping

    /// Map a linear magnitude spectrum into `bandCount` log-spaced dB bands.
    private static func logBands(from magnitudes: [Float], binCount: Int) -> [Float] {
        let logMin = log10(20.0 as Float)
        let logMax = log10(sampleRate / 2)
        let logRange = logMax - logMin
        var bands = [Float](repeating: minDB, count: bandCount)

        for band in 0..<bandCount {
            let freqLow  = pow(10, logMin + Float(band)     / Float(bandCount) * logRange)
            let freqHigh = pow(10, logMin + Float(band + 1) / Float(bandCount) * logRange)
            let lo = max(1, min(Int(freqLow  * Float(binCount * 2) / sampleRate), binCount - 1))
            let hi = max(lo + 1, min(Int(freqHigh * Float(binCount * 2) / sampleRate) + 1, binCount))
            var peak: Float = 0
            vDSP_maxv(magnitudes.withUnsafeBufferPointer { $0.baseAddress! + lo },
                      1, &peak, vDSP_Length(hi - lo))
            let db = 20.0 * log10(max(peak, 1e-10))
            bands[band] = max(minDB, min(maxDB, db))
        }

        return bands
    }
}
