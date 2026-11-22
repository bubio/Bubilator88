import Foundation

/// The YM2608's six rhythm sounds, as WAV files (fmgen format: signed 16-bit
/// PCM).
///
/// Shared by the app and the VGM Quick Look preview. A `2608_*.WAV` dumped
/// from the chip wins; otherwise the bundled stand-in is used so the rhythm
/// part is never silent.
enum RhythmSamples {
  /// BD, SD, TOP, HH, TOM, RIM: the chip's own order, and the index the
  /// synthesizers take.
  static let names = ["BD", "SD", "TOP", "HH", "TOM", "RIM"]

  struct Sample: Sendable {
    /// Position in `names`.
    let index: Int
    let samples: [Int16]
    let sampleRate: Int
  }

  /// The samples for every sound that could be read, with its index.
  /// `userDirectory` holds the `2608_*.WAV` files; `nil` uses only the
  /// bundled ones.
  static func load(userDirectory: URL?,
                   bundle: Bundle = .main) -> [Sample] {
    names.enumerated().compactMap { index, name in
      let userFile = userDirectory?.appending(component: "2608_\(name).WAV")
      let bundled = bundle.url(forResource: "Rhythm_\(name)", withExtension: "wav")
      for url in [userFile, bundled].compactMap({ $0 }) {
        if let data = try? Data(contentsOf: url), let (samples, sampleRate) = parseWAV(data) {
          return Sample(index: index, samples: samples, sampleRate: sampleRate)
        }
      }
      return nil
    }
  }

  /// Parse a WAV file and extract signed 16-bit PCM samples.
  static func parseWAV(_ data: Data) -> (samples: [Int16], sampleRate: Int)? {
    guard data.count > 44 else { return nil }
    // Verify RIFF header
    guard data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46 else { return nil }
    // Verify WAVE format
    guard data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45 else { return nil }

    // Find "fmt " and "data" chunks
    var sampleRate = 44100
    var bitsPerSample = 16
    var numChannels = 1
    var dataOffset = 0
    var dataSize = 0

    var offset = 12
    while offset + 8 <= data.count {
      let chunkID = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
      let chunkSize = Int(data[offset+4]) | Int(data[offset+5]) << 8 |
        Int(data[offset+6]) << 16 | Int(data[offset+7]) << 24
      if chunkID == "fmt " {
        // A user's file may be damaged: read only a whole fmt chunk.
        guard chunkSize >= 16, offset + 24 <= data.count else { return nil }
        numChannels = Int(data[offset+10]) | Int(data[offset+11]) << 8
        sampleRate = Int(data[offset+12]) | Int(data[offset+13]) << 8 |
          Int(data[offset+14]) << 16 | Int(data[offset+15]) << 24
        bitsPerSample = Int(data[offset+22]) | Int(data[offset+23]) << 8
      } else if chunkID == "data" {
        dataOffset = offset + 8
        dataSize = chunkSize
        break
      }
      offset += 8 + chunkSize
      if chunkSize & 1 != 0 { offset += 1 }  // Word-align
    }

    guard dataOffset > 0, bitsPerSample == 16, numChannels > 0 else { return nil }
    let sampleCount = min(dataSize, data.count - dataOffset) / (2 * numChannels)
    // An empty file falls back to the bundled sound rather than silence.
    guard sampleCount > 0 else { return nil }
    var samples = [Int16](repeating: 0, count: sampleCount)
    for i in 0..<sampleCount {
      let byteOffset = dataOffset + i * 2 * numChannels
      samples[i] = Int16(bitPattern: UInt16(data[byteOffset]) | UInt16(data[byteOffset+1]) << 8)
    }
    return (samples, sampleRate)
  }
}
