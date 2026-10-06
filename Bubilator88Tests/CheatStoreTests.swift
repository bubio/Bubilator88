import Bubilator88Core
import Foundation
import Testing
@testable import Bubilator88

@MainActor
struct CheatStoreTests {

  private let pat = """
  ;イース
  # 無敵
  D00047CF 4B00
  80004B00 FFFF
  # HP
  3000E50C 0004
  """

  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("CheatStoreTests-\(UUID().uuidString)")
      .appendingPathComponent("Cheats.json")
  }

  @Test("取り込んだ直後は全グループ無効で、有効にしたグループは保存・読み込みで往復する")
  func enabledGroupsRoundTrip() {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = CheatStore(fileURL: url)
    let set = store.importSet(name: "YS1.PAT", text: pat, for: ["YS1.D88"])
    #expect(store.enabledCodes(of: set).isEmpty)
    store.setGroup(1, enabled: true, in: set.id)

    let reloaded = CheatStore(fileURL: url)
    let found = try! #require(reloaded.set(for: ["ys1.d88"]))
    #expect(reloaded.groups(of: found).map(\.name) == ["無敵", "HP"])
    #expect(reloaded.enabledCodes(of: found)
      == [[PATCode(opcode: 0x30, area: 0x00, address: 0xE50C, value: 0x0004)]])
  }

  @Test("ドライブ1のディスクのセットが優先され、なければドライブ2を見る")
  func driveOneDecides() {
    let store = CheatStore(fileURL: tempURL())
    store.importSet(name: "A.PAT", text: pat, for: ["A.D88"])
    store.importSet(name: "B.PAT", text: pat, for: ["B.D88"])
    #expect(store.set(for: ["A.D88", "B.D88"])?.name == "A.PAT")
    #expect(store.set(for: [nil, "B.D88"])?.name == "B.PAT")
    #expect(store.set(for: ["C.D88", nil]) == nil)
  }

  @Test("同じディスクに取り込み直すと前のセットから外れ、ディスクがなくなったセットは消える")
  func reimportReplaces() {
    let store = CheatStore(fileURL: tempURL())
    store.importSet(name: "OLD.PAT", text: pat, for: ["A.D88", "B.D88"])
    store.importSet(name: "NEW.PAT", text: pat, for: ["A.D88"])
    #expect(store.set(for: ["A.D88"])?.name == "NEW.PAT")
    #expect(store.set(for: ["B.D88"])?.name == "OLD.PAT")
    store.importSet(name: "NEWER.PAT", text: pat, for: ["B.D88"])
    #expect(store.sets.map(\.name) == ["NEW.PAT", "NEWER.PAT"])
  }

  @Test("同梱プリセットはすべて読み込めて、どのグループにもコードがある")
  func bundledPresetsParse() {
    let presets = CheatStore.bundledPresets()
    #expect(presets.count == 69)
    for preset in presets {
      let groups = PATFile.parse(preset.text)
      #expect(!groups.isEmpty && groups.count <= PATFile.maxGroups, "\(preset.title)")
      #expect(groups.allSatisfy { !$0.codes.isEmpty }, "\(preset.title)")
    }
  }

  @Test("プリセットを選ぶとマウント中のディスクのセットになる")
  func presetBecomesASet() {
    let preset = CheatPreset(title: "Ys2", text: pat)
    let store = CheatStore(fileURL: tempURL(), presets: [preset])
    store.importSet(name: preset.title, text: preset.text, for: ["ys2_a.d88"])
    #expect(store.set(for: ["YS2_A.D88"])?.name == "Ys2")
  }
}
