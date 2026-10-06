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

  @Test("ファイル先頭のコメントはゲーム全体の注意書き、見出し直後のコメントはグループの説明になる")
  func notesForTheMenu() {
    let text = """
    ; ロードしてから有効にしてください。
    # EXPいっぱい
    ; 戦闘勝利時に増えます
    D0009C98 97FE
    80009C98 963E
    ; 出典: どこか
    """
    let store = CheatStore(fileURL: tempURL())
    let set = store.importSet(name: "CRIMSON", text: text, for: ["CRIMSON.D88"])
    #expect(store.notes(of: set) == ["ロードしてから有効にしてください。"])
    #expect(store.groups(of: set).map(\.notes) == [["戦闘勝利時に増えます"]])
  }

  @Test("プリセットから作ったセットは、同梱プリセットが変わると本文が追従し、同名の項目は ON のまま残る")
  func setsFollowTheirPreset() {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let old = CheatPreset(title: "ファンタジアン", text: "# HP MAX\n3000D014 00FF\n# GOLD MAX\n8000D018 7FFF\n")
    let store = CheatStore(fileURL: url, presets: [old])
    let set = store.importSet(name: old.title, text: old.text, for: ["F.D88"], preset: old.title)
    store.setGroup(0, enabled: true, in: set.id)
    store.setGroup(1, enabled: true, in: set.id)

    let new = CheatPreset(title: "ファンタジアン",
                          text: "# GOLD MAX\n8000D018 7FFF\n8000D058 7FFF\n# HP MAX（全員）\n3000D014 00FF\n")
    let reloaded = CheatStore(fileURL: url, presets: [new])
    let found = try! #require(reloaded.set(for: ["F.D88"]))
    #expect(found.text == new.text)
    #expect(found.enabledGroups == [0])  // GOLD MAX moved to 0; HP MAX was renamed
  }

  @Test("出典の行がある、プリセット名のセットは、記録がなくてもプリセットから作ったものとして扱う")
  func legacyPresetSetsAreAdopted() {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = CheatStore(fileURL: url)
    store.importSet(name: "Ys", text: "# HP\n8000A000 FFFF\n; 出典: KAJA「PC88-PAR改造部屋」(2001)\n", for: ["YS.D88"])
    let newer = CheatPreset(title: "Ys", text: "# HP\n8000A000 FFFF\n8000A002 FFFF\n")
    let reloaded = CheatStore(fileURL: url, presets: [newer])
    #expect(reloaded.set(for: ["YS.D88"])?.text == newer.text)
    #expect(reloaded.set(for: ["YS.D88"])?.preset == "Ys")
  }
}
