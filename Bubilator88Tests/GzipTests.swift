import Foundation
import Testing
@testable import Bubilator88

struct GzipTests {
  @Test func crc32MatchesTheStandardCheckValue() {
    #expect(Gzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
  }

  /// The system's gzip, not Foundation, must accept the member: that is what
  /// checks the framing around Foundation's DEFLATE stream.
  @Test func systemGzipDecompressesTheMember() throws {
    let input = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 * 7 / 3) })
    let gz = try Gzip.compress(input)
    #expect(Array(gz.prefix(4)) == [0x1F, 0x8B, 0x08, 0x00])
    #expect(gz.count < input.count)

    let dir = FileManager.default.temporaryDirectory
      .appending(component: "GzipTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(component: "test.gz")
    try gz.write(to: file)

    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/gzip")
    process.arguments = ["-dc", file.path(percentEncoded: false)]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(output == input)
  }

  /// A member from the system's gzip carries the file name (FNAME), which
  /// the reader must skip.
  @Test func decompressesWhatSystemGzipWrites() throws {
    let input = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 * 5 / 7) })
    let dir = FileManager.default.temporaryDirectory
      .appending(component: "GzipTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(component: "song.vgm")
    try input.write(to: file)

    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/gzip")
    process.arguments = ["-c", "-N", file.path(percentEncoded: false)]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let gz = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0 && gz.count > 10)
    #expect(gz[3] & 0x08 != 0)

    #expect(Gzip.isGzip(gz))
    #expect(try Gzip.decompress(gz, limit: input.count) == input)
    #expect(throws: Gzip.DecompressError.tooLarge) {
      try Gzip.decompress(gz, limit: input.count - 1)
    }
  }

  @Test func rejectsADamagedMember() throws {
    let input = Data("Vgm ".utf8) + Data(repeating: 0x42, count: 1000)
    var gz = try Gzip.compress(input)
    #expect(try Gzip.decompress(gz, limit: .max) == input)
    gz[gz.count - 1] ^= 0xFF  // ISIZE
    #expect(throws: Gzip.DecompressError.corrupt) { try Gzip.decompress(gz, limit: .max) }
    #expect(throws: Gzip.DecompressError.notGzip) { try Gzip.decompress(input, limit: .max) }
  }
}
