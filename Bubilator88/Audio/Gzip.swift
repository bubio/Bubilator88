import Foundation

/// gzip (RFC 1952) for `.vgz`: a DEFLATE stream wrapped in a 10-byte header
/// and a CRC-32 / size trailer.
///
/// Foundation's `.zlib` algorithm writes raw DEFLATE (RFC 1951) with neither
/// the zlib nor the gzip framing, so the framing is added here.
nonisolated enum Gzip {

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
