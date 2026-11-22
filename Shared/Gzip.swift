import Compression
import Foundation

/// gzip (RFC 1952) for `.vgz`: a DEFLATE stream wrapped in a 10-byte header
/// and a CRC-32 / size trailer.
///
/// Foundation's `.zlib` algorithm reads and writes raw DEFLATE (RFC 1951)
/// with neither the zlib nor the gzip framing, so the framing is handled
/// here. Shared by the app (recording) and the VGM Quick Look preview.
nonisolated enum Gzip {

  enum DecompressError: Error {
    case notGzip
    case corrupt
    case tooLarge
  }

  /// Compress `data` into a gzip member. Throws if the DEFLATE encoder fails.
  static func compress(_ data: Data) throws -> Data {
    let deflated = try (data as NSData).compressed(using: .zlib) as Data
    var out = Data([
      0x1F, 0x8B,              // magic
      0x08,                    // CM = DEFLATE
      0x00,                    // FLG: no name, comment or extra field
      0x00, 0x00, 0x00, 0x00,  // MTIME: not recorded
      0x00,                    // XFL
      0xFF,                    // OS: unknown
    ])
    out.append(deflated)
    appendLE(crc32(data), to: &out)
    appendLE(UInt32(truncatingIfNeeded: data.count), to: &out)
    return out
  }

  /// True when `data` starts with the gzip magic number.
  static func isGzip(_ data: Data) -> Bool {
    data.starts(with: [0x1F, 0x8B])
  }

  /// Expand `data`, a single-member gzip file, refusing output larger than
  /// `limit` bytes so a hostile file cannot exhaust memory.
  static func decompress(_ data: Data, limit: Int) throws(DecompressError) -> Data {
    // Zero-based indices; a file read whole already is, so no copy is made.
    let bytes = data.startIndex == 0 ? data : Data(data)
    guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else {
      throw .notGzip
    }
    let flags = bytes[3]
    guard flags & 0xE0 == 0 else { throw .corrupt }  // reserved bits
    var position = 10
    if flags & 0x04 != 0 {  // FEXTRA
      guard position + 2 <= bytes.count else { throw .corrupt }
      position += 2 + (Int(bytes[position]) | Int(bytes[position + 1]) << 8)
    }
    for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT
      guard let end = bytes[min(position, bytes.count)...].firstIndex(of: 0) else { throw .corrupt }
      position = end + 1
    }
    if flags & 0x02 != 0 { position += 2 }  // FHCRC
    guard position <= bytes.count - 8 else { throw .corrupt }

    var output = Data()
    var overflowed = false
    do {
      let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
        guard let chunk else { return }
        guard output.count + chunk.count <= limit else {
          overflowed = true
          throw DecompressError.tooLarge
        }
        output.append(chunk)
      }
      // Only one member is read; its trailer is the last eight bytes.
      try filter.write(bytes[position..<(bytes.count - 8)])
      try filter.finalize()
    } catch {
      throw overflowed ? .tooLarge : .corrupt
    }

    func le(_ at: Int) -> UInt32 {
      (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * $1) }
    }
    guard le(bytes.count - 8) == crc32(output),
          le(bytes.count - 4) == UInt32(truncatingIfNeeded: output.count) else {
      throw .corrupt
    }
    return output
  }

  /// CRC-32 as gzip uses it (reflected polynomial 0xEDB88320).
  static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
  }

  private static let table: [UInt32] = (0..<256).map { n in
    var c = UInt32(n)
    for _ in 0..<8 {
      c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
    }
    return c
  }

  private static func appendLE(_ value: UInt32, to data: inout Data) {
    for i in 0..<4 { data.append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
  }
}
