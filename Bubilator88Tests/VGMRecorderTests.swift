import Foundation
import Testing
@testable import Bubilator88

@MainActor
struct VGMRecorderTests {
  @Test func takenNamesGetANumberedSuffix() throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(component: "VGMRecorderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let first = VGMRecorder.unusedURL(in: dir, stem: "Game", extension: "vgz")
    #expect(first.lastPathComponent == "Game.vgz")
    try Data().write(to: first)
    let second = VGMRecorder.unusedURL(in: dir, stem: "Game", extension: "vgz")
    #expect(second.lastPathComponent == "Game-1.vgz")
    try Data().write(to: second)
    #expect(VGMRecorder.unusedURL(in: dir, stem: "Game", extension: "vgz")
      .lastPathComponent == "Game-2.vgz")
  }
}

extension VGMRecorderTests {
  @Test func gameNameIsKeptFromStart() throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(component: "VGMRecorderTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = VGMRecorder()
    try recorder.start(baseDirectory: dir, format: .vgm, baseName: "ザナドゥ",
                       gameName: "ザナドゥ")
    #expect(recorder.gameName == "ザナドゥ")
    #expect(recorder.lastOutputURL?.lastPathComponent.hasPrefix("ザナドゥ-") == true)
  }
}
