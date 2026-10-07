import Testing
import Foundation
@testable import Bubilator88

@MainActor
struct SaveSlotListTests {

  private func entry(_ slot: Int, _ age: TimeInterval?, _ names: [String] = []) -> SaveSlotEntry {
    SaveSlotEntry(
      slot: slot,
      modified: age.map { Date(timeIntervalSince1970: 1_000_000 + $0) },
      diskNames: names)
  }

  private var entries: [SaveSlotEntry] {
    [
      entry(1, 10, ["Xanadu.d88"]),
      entry(2, nil),
      entry(3, 30, ["Alpha.d88", "Data.d88"]),
      entry(4, 20, ["Xanadu.d88"]),
      entry(5, 5),
    ]
  }

  private func slots(_ sections: [SaveSlotSection]) -> [[Int]] {
    sections.map { $0.slots.map(\.slot) }
  }

  @Test("Slot order keeps empty slots when asked to")
  func numberOrder() {
    let result = SaveSlotList.sections(entries: entries.reversed(), query: "", sort: .number, hidesEmpty: false)
    #expect(slots(result) == [[1, 2, 3, 4, 5]])
  }

  @Test("Loading hides empty slots")
  func hidesEmpty() {
    let result = SaveSlotList.sections(entries: entries, query: "", sort: .number, hidesEmpty: true)
    #expect(slots(result) == [[1, 3, 4, 5]])
  }

  @Test("Recent order is newest first with empty slots last")
  func recentOrder() {
    let result = SaveSlotList.sections(entries: entries, query: "", sort: .recent, hidesEmpty: false)
    #expect(slots(result) == [[3, 4, 1, 5, 2]])
  }

  @Test("Oldest order is oldest first with empty slots last")
  func oldestOrder() {
    let result = SaveSlotList.sections(entries: entries, query: "", sort: .oldest, hidesEmpty: false)
    #expect(slots(result) == [[5, 1, 4, 3, 2]])
  }

  @Test("Empty-first order lists empty slots, then the oldest saves")
  func emptyFirstOrder() {
    let result = SaveSlotList.sections(entries: entries, query: "", sort: .emptyFirst, hidesEmpty: false)
    #expect(slots(result) == [[2, 5, 1, 4, 3]])
  }

  @Test("Search matches disk names ignoring case, or the slot number")
  func search() {
    let byName = SaveSlotList.sections(entries: entries, query: "xAnA", sort: .number, hidesEmpty: false)
    #expect(slots(byName) == [[1, 4]])
    let byNumber = SaveSlotList.sections(entries: entries, query: "3", sort: .number, hidesEmpty: false)
    #expect(slots(byNumber) == [[3]])
    let secondDrive = SaveSlotList.sections(entries: entries, query: "data", sort: .number, hidesEmpty: false)
    #expect(slots(secondDrive) == [[3]])
  }

  @Test("No match yields no sections")
  func noMatch() {
    #expect(SaveSlotList.sections(entries: entries, query: "zzz", sort: .number, hidesEmpty: false).isEmpty)
  }

  @Test("Game order groups by drive 0, current game first, no-disk slots last")
  func gameOrder() {
    let result = SaveSlotList.sections(
      entries: entries, query: "", sort: .game, hidesEmpty: false, currentGame: "Xanadu.d88")
    #expect(result.map(\.title) == ["Xanadu.d88", "Alpha.d88", nil])
    #expect(slots(result) == [[4, 1], [3], [5, 2]])
  }
}
