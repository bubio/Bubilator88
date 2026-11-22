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
}
