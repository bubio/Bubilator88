import Testing
import Foundation
@testable import Bubilator88
import EmulatorCore

/// Related to docs/DISK_WRITEBACK_PLAN.md §7 — ensures that on a multi-entry
/// .d88, write-back after `switchDiskImage` lands in the correct bank.
///
/// The scenario of concern: mount a multi-entry D88 with Mount 0&1, switch to a
/// different entry with switchDiskImage, then have the game save. If the
/// write-back imageIndex is still the old one, it destroys the wrong bank.
///
/// The current defences:
/// 1. `switchDiskImage` updates `MountedDiskInfo.currentImageIndex`
/// 2. Before switching, `diskWriteBackScheduler.flushNow` commits a write-back
///    at the old index
/// 3. Write-back reads `drive0Info.currentImageIndex` at the moment it fires
///
/// Only all three together prevent the wrong bank being destroyed. These
/// ViewModel integration tests lock the behaviour in so a regression in the
/// ordering is caught.
@MainActor
struct SwitchDiskImageTests {

  /// Writes a three-bank multi-entry .d88 to a temporary file and returns its
  /// URL. Each bank is the minimum 688 bytes: header only, no tracks.
  private func writeMultiBankD88(banks: Int = 3) throws -> URL {
    var concatenated: [UInt8] = []
    for i in 0..<banks {
      var disk = D88Disk()
      disk.name = "Bank\(Character(UnicodeScalar(UInt8(0x41 + i))))"
      guard let bytes = disk.serialize() else {
        throw NSError(domain: "Test", code: 0)
      }
      concatenated.append(contentsOf: bytes)
    }
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("SwitchDiskImageTests-\(UUID().uuidString).d88")
    try Data(concatenated).write(to: url)
    return url
  }

  @Test("switchDiskImage: currentImageIndex が新 index に更新される")
  func switchUpdatesCurrentImageIndex() throws {
    let url = try writeMultiBankD88(banks: 3)
    defer { try? FileManager.default.removeItem(at: url) }

    let vm = EmulatorViewModel()
    vm.mountDisk(url: url, drive: -1)  // Mount 0&1

    // Initial state: drive 0 at imageIndex 0, drive 1 at imageIndex 1
    #expect(vm.drive0Info?.currentImageIndex == 0)
    #expect(vm.drive0Info?.allImages.count == 3)

    vm.switchDiskImage(drive: 0, index: 2)
    #expect(vm.drive0Info?.currentImageIndex == 2)
    // sourceURL and allImages do not change
    #expect(vm.drive0Info?.allImages.count == 3)
  }

  /// switchDiskImage must run **flushNow before updating the index**, or the
  /// bank that was dirty before the switch gets written back at the new index
  /// and corrupts a different disk. This pins the ordering down: the
  /// `currentImageIndex` observed when the writeBack callback fires must be the
  /// **old index, from before the switch**.
  @Test("switchDiskImage: 旧 index で flush してから新 index に切替える")
  func switchFlushesBeforeIndexUpdate() throws {
    let url = try writeMultiBankD88(banks: 3)
    defer { try? FileManager.default.removeItem(at: url) }

    let vm = EmulatorViewModel()
    vm.mountDisk(url: url, drive: -1)
    #expect(vm.drive0Info?.currentImageIndex == 0)

    // Swap writeBack for an observing closure that records
    // drive0Info.currentImageIndex as seen at fire time.
    var observedIndices: [Int] = []
    vm.diskWriteBackScheduler.writeBack = { [weak vm] drive in
      guard drive == 0, let vm else { return }
      if let idx = vm.drive0Info?.currentImageIndex {
        observedIndices.append(idx)
      }
    }

    // Schedule a write-back at the old index (0); the switch should flush it
    vm.diskWriteBackScheduler.schedule(drive: 0)
    vm.switchDiskImage(drive: 0, index: 2)

    // The flush runs first thing in switch, so the observed index is **0**, the old one
    #expect(observedIndices == [0])
    // After the switch, info carries the new index (2)
    #expect(vm.drive0Info?.currentImageIndex == 2)
  }

  /// A write arriving right after the switch is written back at the new index.
  @Test("switchDiskImage: 切替後の dirty は新 index で書き戻される")
  func writeAfterSwitchUsesNewIndex() throws {
    let url = try writeMultiBankD88(banks: 3)
    defer { try? FileManager.default.removeItem(at: url) }

    let vm = EmulatorViewModel()
    vm.mountDisk(url: url, drive: -1)

    var observedIndices: [Int] = []
    vm.diskWriteBackScheduler.writeBack = { [weak vm] drive in
      guard drive == 0, let vm else { return }
      if let idx = vm.drive0Info?.currentImageIndex {
        observedIndices.append(idx)
      }
    }

    vm.switchDiskImage(drive: 0, index: 2)
    // Schedule a new write after the switch, then fire it with flushNow
    vm.diskWriteBackScheduler.schedule(drive: 0)
    vm.diskWriteBackScheduler.flushNow(drive: 0)

    #expect(observedIndices == [2])
  }
}
