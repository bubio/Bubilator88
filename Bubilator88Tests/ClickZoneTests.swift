import Testing
import CoreGraphics
import Foundation
import Bubilator88Core
@testable import Bubilator88

@MainActor
struct ClickZonePlayerTests {

  private func run(_ player: ClickZonePlayer, frames: Int) -> [(Int, ClickZonePlayer.KeyEvent)] {
    var out: [(Int, ClickZonePlayer.KeyEvent)] = []
    for f in 0..<frames {
      player.tick { out.append((f, $0)) }
    }
    return out
  }

  @Test("単キー: 押下→hold フレーム後に解放")
  func singleKey() {
    let player = ClickZonePlayer()
    #expect(player.start([ClickZoneStep(keys: ["return"], holdFrames: 3, gapFrames: 2)]))
    let events = run(player, frames: 10)
    #expect(events.map(\.0) == [0, 3])
    #expect(events.map(\.1) == [.init(key: PC88Key.kpReturn, down: true),
                                .init(key: PC88Key.kpReturn, down: false)])
    #expect(player.isIdle)
  }

  @Test("修飾キーは先に押し、後で離す")
  func modifierOrdering() {
    let player = ClickZonePlayer()
    #expect(player.start([ClickZoneStep(keys: ["1", "shift"], holdFrames: 2, gapFrames: 1)]))
    let events = run(player, frames: 10)
    #expect(events.map(\.0) == [0, 1, 3, 4])
    #expect(events.map(\.1) == [.init(key: PC88Key.shift, down: true),
                                .init(key: PC88Key.key1, down: true),
                                .init(key: PC88Key.key1, down: false),
                                .init(key: PC88Key.shift, down: false)])
  }

  @Test("複数ステップは gap を空けて続く")
  func multipleSteps() {
    let player = ClickZonePlayer()
    player.start([ClickZoneStep(keys: ["a"], holdFrames: 2, gapFrames: 3),
                  ClickZoneStep(keys: ["b"], holdFrames: 2, gapFrames: 3)])
    let events = run(player, frames: 20)
    // a: down 0, up 2; gap 3 → b: down 5, up 7
    #expect(events.map(\.0) == [0, 2, 5, 7])
    #expect(events[2].1 == .init(key: PC88Key.b, down: true))
  }

  @Test("再生中の start は拒否される")
  func busyRejects() {
    let player = ClickZonePlayer()
    #expect(player.start([ClickZoneStep(keys: ["a"])]))
    #expect(!player.start([ClickZoneStep(keys: ["b"])]))
    _ = run(player, frames: 100)
    #expect(player.start([ClickZoneStep(keys: ["b"])]))
  }

  @Test("cancel は押したままのキーを全部離す")
  func cancelReleasesHeld() {
    let player = ClickZonePlayer()
    player.start([ClickZoneStep(keys: ["shift", "a"], holdFrames: 5, gapFrames: 1)])
    _ = run(player, frames: 2)  // shift + a are down
    var released: [ClickZonePlayer.KeyEvent] = []
    player.cancel { released.append($0) }
    #expect(Set(released.map(\.key)) == [PC88Key.shift, PC88Key.a])
    #expect(released.allSatisfy { !$0.down })
    #expect(player.isIdle)
    #expect(run(player, frames: 10).isEmpty)
  }

  @Test("不明なキー名は無視される")
  func unknownKeysSkipped() {
    let player = ClickZonePlayer()
    #expect(!player.start([ClickZoneStep(keys: ["nosuchkey"])]))
    #expect(player.isIdle)
  }
}

@MainActor
struct ClickZoneKeyRecorderTests {

  @Test("同時押しを 1 ステップにまとめ、全キーを離した時点で確定")
  func chord() {
    var rec = ClickZoneKeyRecorder()
    #expect(rec.keyDown(PC88Key.shift) == nil)
    #expect(rec.keyDown(PC88Key.key1) == nil)
    #expect(rec.keyUp(PC88Key.key1) == nil)
    let step = rec.keyUp(PC88Key.shift)
    #expect(step?.keys == ["shift", "1"])
  }

  @Test("キーリピートや重複押下は無視")
  func repeats() {
    var rec = ClickZoneKeyRecorder()
    _ = rec.keyDown(PC88Key.a)
    _ = rec.keyDown(PC88Key.a)
    #expect(rec.keyUp(PC88Key.a)?.keys == ["a"])
    #expect(rec.keyUp(PC88Key.a) == nil)
  }
}

@MainActor
struct ClickZoneDiskKeyTests {

  @Test("ファイル名は Unicode 正規化と大小文字を無視して照合")
  func normalization() {
    let nfd = "ｿｰｻﾘｱﾝ.d88".decomposedStringWithCanonicalMapping
    let a = ClickZoneDiskKey(fileName: "Game.D88", imageName: "")
    let b = ClickZoneDiskKey(fileName: "game.d88", imageName: "")
    #expect(a == b)
    #expect(ClickZoneDiskKey(fileName: nfd, imageName: "")
      == ClickZoneDiskKey(fileName: "ｿｰｻﾘｱﾝ.d88".precomposedStringWithCanonicalMapping, imageName: ""))
  }

  @Test("アーカイブ由来ならアーカイブ名、D88 イメージ名は現在のもの")
  func diskKeyFromInfo() {
    let info = MountedDiskInfo(
      sourceURL: URL(fileURLWithPath: "/cache/abc/game.d88"),
      archiveEntryName: "game.d88",
      originArchiveURL: URL(fileURLWithPath: "/games/Game.zip"),
      allImages: [], imageNames: ["DISK A", "DISK B"], currentImageIndex: 1,
      fileName: "Game.zip", imageGroups: [])
    let key = ClickZoneDiskKey(info: info)
    #expect(key == ClickZoneDiskKey(fileName: "Game.zip", imageName: "DISK B"))
  }
}

@MainActor
struct ClickZoneDiskFileTests {

  private func info(_ file: String, images: [String], current: Int = 0) -> MountedDiskInfo {
    MountedDiskInfo(sourceURL: URL(fileURLWithPath: "/games/\(file)"), archiveEntryName: nil,
                    originArchiveURL: nil, allImages: [], imageNames: images,
                    currentImageIndex: current, fileName: file, imageGroups: [])
  }

  @Test("同じファイルが両ドライブにあっても 1 行、全イメージを列挙")
  func mountedFileListedOnce() {
    let files = ClickZoneDiskFile.list(
      mounted: [info("game.d88", images: ["A", "B"]), info("game.d88", images: ["A", "B"], current: 1)],
      assigned: [])
    #expect(files.count == 1)
    #expect(files[0].images.map(\.imageName) == ["A", "B"])
  }

  @Test("マウントしていない割り当て済みディスクはファイルごとにまとめて後ろに並ぶ")
  func unmountedAssignedGrouped() {
    let files = ClickZoneDiskFile.list(
      mounted: [info("game.d88", images: ["A"])],
      assigned: [ClickZoneDiskKey(fileName: "old.d88", imageName: "X"),
                 ClickZoneDiskKey(fileName: "game.d88", imageName: "A"),
                 ClickZoneDiskKey(fileName: "old.d88", imageName: "Y")])
    #expect(files.map(\.fileName) == ["game.d88", "old.d88"])
    #expect(files[0].images.count == 1)
    #expect(files[1].images.map(\.imageName) == ["X", "Y"])
  }
}

@MainActor
struct ClickZoneStoreTests {

  private let diskA = ClickZoneDiskKey(fileName: "game.d88", imageName: "A")
  private let diskB = ClickZoneDiskKey(fileName: "game.d88", imageName: "B")
  private let preset = ClickZoneLayout(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Zone Test Preset",
    zones: [ClickZone(rect: ClickZoneRect(x: 0, y: 0, width: 640, height: 400),
                      steps: [ClickZoneStep(keys: ["return"])])])

  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ClickZoneStoreTests-\(UUID().uuidString)")
      .appendingPathComponent("ClickZones.json")
  }

  private func makeStore(_ url: URL? = nil) -> ClickZoneStore {
    ClickZoneStore(fileURL: url ?? tempURL(), presets: [preset])
  }

  @Test("レイアウトと割り当てが保存・読み込みで往復する")
  func roundTrip() {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = makeStore(url)
    var layout = store.create(name: "Mine")
    layout.zones.append(ClickZone(label: "攻撃", rect: ClickZoneRect(x: 10, y: 20, width: 30, height: 40),
                                  steps: [ClickZoneStep(keys: ["shift", "1"], holdFrames: 4, gapFrames: 5)]))
    store.update(layout)
    store.assign(diskA, to: layout.id)
    store.assign(diskB, to: preset.id)

    let reloaded = makeStore(url)
    #expect(reloaded.userLayouts == [layout])
    #expect(reloaded.layoutID(assignedTo: diskA) == layout.id)
    #expect(reloaded.layoutID(assignedTo: diskB) == preset.id)
  }

  @Test("drive0 の割り当てを drive1 より優先し、無ければ drive1")
  func resolution() {
    let store = makeStore()
    let mine = store.create(name: "Mine")
    store.assign(diskA, to: mine.id)
    store.assign(diskB, to: preset.id)
    #expect(store.layout(for: [diskB, diskA])?.id == preset.id)
    #expect(store.layout(for: [nil, diskA])?.id == mine.id)
    #expect(store.layout(for: [ClickZoneDiskKey(fileName: "x", imageName: "")]) == nil)
  }

  @Test("割り当ては付け替え・解除できる")
  func reassign() {
    let store = makeStore()
    let mine = store.create(name: "Mine")
    store.assign(diskA, to: preset.id)
    store.assign(diskA, to: mine.id)
    #expect(store.assignments.count == 1)
    #expect(store.assignments(to: mine.id).map(\.disk) == [diskA])
    store.unassign(diskA)
    #expect(store.assignments.isEmpty)
  }

  @Test("削除するとそのレイアウトの割り当ても消える。プリセットは削除できない")
  func deleteCascades() {
    let store = makeStore()
    let mine = store.create(name: "Mine")
    store.assign(diskA, to: mine.id)
    store.assign(diskB, to: preset.id)
    store.delete(mine.id)
    store.delete(preset.id)
    #expect(store.userLayouts.isEmpty)
    #expect(store.layoutID(assignedTo: diskA) == nil)
    #expect(store.layoutID(assignedTo: diskB) == preset.id)
    #expect(store.layout(id: preset.id) != nil)
  }

  @Test("プリセットは update で変更できない")
  func presetIsReadOnly() {
    let store = makeStore()
    var edited = preset
    edited.zones.removeAll()
    store.update(edited)
    #expect(store.layout(id: preset.id)?.zones.count == 1)
    #expect(store.isPreset(preset.id))
  }

  @Test("複製は新しい ID のユーザーレイアウトになり、名前が重複しない")
  func duplicate() throws {
    let store = makeStore()
    let copy = try #require(store.duplicate(preset.id, name: "Zone Test Preset"))
    #expect(copy.id != preset.id)
    #expect(copy.name == "Zone Test Preset 2")
    #expect(copy.zones == preset.zones)
    #expect(!store.isPreset(copy.id))
  }

  @Test("書き出し → 読み込みで往復し、同名なら番号が付く")
  func exportImport() throws {
    let store = makeStore()
    var mine = store.create(name: "Mine")
    mine.zones = preset.zones
    store.update(mine)
    let data = try store.exportData(for: mine.id)
    let imported = try store.importLayout(from: data)
    #expect(imported.name == "Mine 2")
    #expect(imported.id != mine.id)
    #expect(imported.zones.map(\.rect) == mine.zones.map(\.rect))
    #expect(imported.zones.map(\.steps) == mine.zones.map(\.steps))
  }

  @Test("不正なファイルの読み込みは失敗し、何も追加しない")
  func importRejectsGarbage() {
    let store = makeStore()
    #expect(throws: (any Error).self) {
      try store.importLayout(from: Data("{\"hello\": 1}".utf8))
    }
    #expect(store.userLayouts.isEmpty)
  }

  @Test("複数ディスクをまとめて割り当て・解除できる")
  func bulkAssign() {
    let store = makeStore()
    let mine = store.create(name: "Mine")
    store.assign(diskA, to: preset.id)
    store.assign([diskA, diskB], to: mine.id)
    #expect(Set(store.assignments(to: mine.id).map(\.disk)) == [diskA, diskB])
    #expect(store.assignments(to: preset.id).isEmpty)
    store.unassign([diskA, diskB])
    #expect(store.assignments.isEmpty)
  }

  @Test("存在しないレイアウトへの割り当ては読み込み時に捨てる")
  func danglingAssignmentsDropped() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let json = """
    {"layouts": [], "assignments": [
      {"disk": {"fileName": "game.d88", "imageName": "A"},
       "layoutID": "00000000-0000-0000-0000-0000000000FF"},
      {"disk": {"fileName": "game.d88", "imageName": "B"},
       "layoutID": "00000000-0000-0000-0000-000000000001"}]}
    """
    try Data(json.utf8).write(to: url)
    let store = makeStore(url)
    #expect(store.assignments.map(\.disk) == [diskB])
  }

  @Test("同梱プリセットはすべて読め、キー名が解決でき、画面内に収まり、ID が一意")
  func bundledPresets() {
    let presets = ClickZoneStore.bundledPresets()
    #expect(presets.count >= 6)
    #expect(Set(presets.map(\.id)).count == presets.count)
    for layout in presets {
      #expect(!layout.zones.isEmpty, "\(layout.name)")
      for zone in layout.zones {
        #expect(zone.rect.clamped() == zone.rect, "\(layout.name): \(zone.label)")
        #expect(!zone.steps.isEmpty, "\(layout.name): \(zone.label)")
        for step in zone.steps {
          #expect(step.resolvedKeys.count == step.keys.count, "\(layout.name): \(step.keys)")
        }
      }
    }
  }
}

@MainActor
struct ScreenFitTests {

  @Test("ウィンドウ時: 2 倍でオフセットなし")
  func windowed() {
    let fit = ScreenFit(container: CGSize(width: 1280, height: 800), integerScaling: false)
    #expect(fit.scale == 2)
    #expect(fit.origin == .zero)
    #expect(fit.toScreen(CGPoint(x: 100, y: 50)) == CGPoint(x: 50, y: 25))
  }

  @Test("全画面 aspect-fit: 左右にレターボックス")
  func aspectFit() {
    let fit = ScreenFit(container: CGSize(width: 1920, height: 1000), integerScaling: false)
    #expect(fit.scale == 2.5)
    #expect(fit.origin == CGPoint(x: 160, y: 0))
    #expect(fit.toView(CGRect(x: 0, y: 0, width: 640, height: 400))
      == CGRect(x: 160, y: 0, width: 1600, height: 1000))
    #expect(fit.toScreen(CGPoint(x: 160 + 25, y: 50)) == CGPoint(x: 10, y: 20))
  }

  @Test("全画面の整数スケーリング: 中央寄せ")
  func integerScaling() {
    let fit = ScreenFit(container: CGSize(width: 1920, height: 1000), integerScaling: true)
    #expect(fit.scale == 2)
    #expect(fit.origin == CGPoint(x: 320, y: 100))
  }
}

@MainActor
struct ClickZoneRectTests {

  private let r = ClickZoneRect(x: 100, y: 100, width: 50, height: 40)

  @Test("移動は画面内にクランプ")
  func moveClamps() {
    #expect(r.moved(dx: -500, dy: 0) == ClickZoneRect(x: 0, y: 100, width: 50, height: 40))
    #expect(r.moved(dx: 1000, dy: 1000) == ClickZoneRect(x: 590, y: 360, width: 50, height: 40))
  }

  @Test("右下ハンドルで変形、反転しても正規化")
  func resize() {
    #expect(r.resized(.bottomRight, to: CGPoint(x: 200, y: 180))
      == ClickZoneRect(x: 100, y: 100, width: 100, height: 80))
    // Dragging the bottom-right handle past the top-left corner flips it.
    #expect(r.resized(.bottomRight, to: CGPoint(x: 80, y: 90))
      == ClickZoneRect(x: 80, y: 90, width: 20, height: 10))
  }

  @Test("数値入力は最小サイズと画面内に補正")
  func clamped() {
    #expect(ClickZoneRect(x: -10, y: 390, width: 2, height: 50).clamped()
      == ClickZoneRect(x: 0, y: 350, width: 4, height: 50))
    #expect(ClickZoneRect(x: 600, y: 0, width: 1000, height: 400).clamped()
      == ClickZoneRect(x: 0, y: 0, width: 640, height: 400))
    #expect(r.clamped() == r)
  }

  @Test("2 点から整数ピクセルの矩形を作る")
  func fromPoints() {
    #expect(ClickZoneRect(from: CGPoint(x: 10.6, y: 20.2), to: CGPoint(x: 5.1, y: 40.9))
      == ClickZoneRect(x: 5, y: 20, width: 5, height: 20))
    #expect(ClickZoneRect(from: CGPoint(x: -5, y: -5), to: CGPoint(x: 700, y: 500))
      == ClickZoneRect(x: 0, y: 0, width: 640, height: 400))
  }
}
