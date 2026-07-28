import Testing
import Foundation
@testable import Bubilator88
import EmulatorCore

/// docs/DISK_WRITEBACK_PLAN.md §7 関連 — マルチエントリ .d88 で
/// `switchDiskImage` 後の書き戻しが正しいバンクに着地することを保証する。
///
/// 懸念シナリオ: Mount 0&1 でマルチエントリ D88 をマウントし、
/// switchDiskImage で別エントリに切替えた後にゲームがセーブすると、
/// 書き戻し先 imageIndex が古いままだと別バンクを破壊する。
///
/// 現状の防御策:
/// 1. `MountedDiskInfo.currentImageIndex` を `switchDiskImage` 内で更新
/// 2. 切替前に `diskWriteBackScheduler.flushNow` で旧 index で確定書き戻し
/// 3. 書き戻しは fire 時に `drive0Info.currentImageIndex` を読む
///
/// これらが揃ってはじめて「別バンク破壊」を防げる。
/// 順序が崩れる回帰を検出するため、ViewModel 統合テストで挙動を locked in する。
@MainActor
struct SwitchDiskImageTests {

  /// 3 バンクのマルチエントリ .d88 を一時ファイルに書き出して URL を返す。
  /// 各バンクは「ヘッダのみ・トラックなし」の最小構成 (688 バイト)。
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

    // 初期状態: drive 0 → imageIndex 0, drive 1 → imageIndex 1
    #expect(vm.drive0Info?.currentImageIndex == 0)
    #expect(vm.drive0Info?.allImages.count == 3)

    vm.switchDiskImage(drive: 0, index: 2)
    #expect(vm.drive0Info?.currentImageIndex == 2)
    // sourceURL / allImages は不変
    #expect(vm.drive0Info?.allImages.count == 3)
  }

  /// switchDiskImage は **flushNow → index 更新** の順で動かないと、
  /// 切替前の dirty バンクが新 index で書き戻されて別ディスクを壊す。
  /// 順序を保証する: writeBack callback が fire したタイミングで
  /// 観測される `currentImageIndex` は **旧 index (切替前)** であること。
  @Test("switchDiskImage: 旧 index で flush してから新 index に切替える")
  func switchFlushesBeforeIndexUpdate() throws {
    let url = try writeMultiBankD88(banks: 3)
    defer { try? FileManager.default.removeItem(at: url) }

    let vm = EmulatorViewModel()
    vm.mountDisk(url: url, drive: -1)
    #expect(vm.drive0Info?.currentImageIndex == 0)

    // writeBack を観測用クロージャに差し替える。
    // fire 時に観測される drive0Info.currentImageIndex を記録。
    var observedIndices: [Int] = []
    vm.diskWriteBackScheduler.writeBack = { [weak vm] drive in
      guard drive == 0, let vm else { return }
      if let idx = vm.drive0Info?.currentImageIndex {
        observedIndices.append(idx)
      }
    }

    // 旧 index (0) で書き戻し予約 → switch で flush が走るはず
    vm.diskWriteBackScheduler.schedule(drive: 0)
    vm.switchDiskImage(drive: 0, index: 2)

    // flush は switch の最初に走る = 観測時の index は **0** (旧)
    #expect(observedIndices == [0])
    // 切替後の info は新 index (2)
    #expect(vm.drive0Info?.currentImageIndex == 2)
  }

  /// 切替直後に新しい書き込みが発生した場合は新 index で書き戻される。
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
    // 切替後に新たな書込予約 → flushNow で fire
    vm.diskWriteBackScheduler.schedule(drive: 0)
    vm.diskWriteBackScheduler.flushNow(drive: 0)

    #expect(observedIndices == [2])
  }
}
