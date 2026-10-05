import Testing
import CoreGraphics
import Foundation
@testable import Bubilator88

struct ClickZoneDetectorTests {

  /// An OCR line at a rectangle given in 640×400 screen pixels.
  private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 16) -> ScreenTextLine {
    ScreenTextLine(text: text, rect: CGRect(x: x / 640, y: y / 400, width: w / 640, height: h / 400))
  }

  /// The lines of the 怨霊戦記 room screen: a title, a four-item numbered
  /// menu and the location in the message window.
  private var roomScreen: [ScreenTextLine] {
    [line("怨霊戦記", x: 430, y: 10, w: 190, h: 32),
     line("1 コンピューター", x: 440, y: 72, w: 140),
     line("2 外に出る", x: 440, y: 90, w: 100),
     line("3 休息をとる", x: 441, y: 108, w: 110),
     line("4 情報を記憶する", x: 439, y: 126, w: 150),
     line("部屋の中", x: 16, y: 280, w: 64)]
  }

  @Test("番号付きの行は番号キーの領域になり、同じ幅で縦に隙間なく並ぶ")
  func numberedMenu() {
    let zones = ClickZoneDetector.zones(from: roomScreen, existing: [])
    let menu = zones.filter { !$0.steps.isEmpty }
    #expect(menu.map(\.steps) == ["1", "2", "3", "4"].map { [ClickZoneStep(keys: [$0])] })
    #expect(menu.map(\.label) == ["コンピューター", "外に出る", "休息をとる", "情報を記憶する"])
    #expect(Set(menu.map(\.rect.x)).count == 1)
    #expect(Set(menu.map(\.rect.width)).count == 1)
    for (upper, lower) in zip(menu, menu.dropFirst()) {
      #expect(upper.rect.y + upper.rect.height == lower.rect.y)
    }
    // The widest item decides the width.
    let first = menu[0].rect
    #expect(first.x <= 439 && first.x + first.width >= 589)
  }

  @Test("番号のない行はキーなしの領域になる")
  func unnumberedLines() {
    let zones = ClickZoneDetector.zones(from: roomScreen, existing: [])
    let plain = zones.filter(\.steps.isEmpty)
    #expect(plain.map(\.label) == ["怨霊戦記", "部屋の中"])
    #expect(zones.count == 6)
    #expect(zones.allSatisfy { $0.rect == $0.rect.clamped() })
  }

  @Test("全角数字や括弧・区切り付きの番号も読む")
  func numberForms() {
    let lines = [line("１ はい", x: 100, y: 100, w: 60),
                 line("(2) いいえ", x: 100, y: 118, w: 80),
                 line("3.もどる", x: 100, y: 136, w: 70),
                 line("4つかう", x: 100, y: 154, w: 70),
                 line("A) こうげき", x: 300, y: 300, w: 90)]
    let zones = ClickZoneDetector.zones(from: lines, existing: [])
    #expect(zones.map(\.steps) == ["1", "2", "3", "4", "a"].map { [ClickZoneStep(keys: [$0])] })
    #expect(zones.map(\.label) == ["はい", "いいえ", "もどる", "つかう", "こうげき"])
  }

  @Test("番号に見えるだけの行にはキーを付けない")
  func notNumbers() {
    let lines = [line("1985年", x: 100, y: 100, w: 60),
                 line("I am here", x: 100, y: 200, w: 80),
                 line("  ", x: 100, y: 300, w: 20)]
    let zones = ClickZoneDetector.zones(from: lines, existing: [])
    #expect(zones.map(\.label) == ["1985年", "I am here"])
    #expect(zones.allSatisfy { $0.steps.isEmpty })
  }

  @Test("既存の領域と重なる候補は追加しない")
  func skipsExisting() {
    let existing = [ClickZone(rect: ClickZoneRect(x: 430, y: 70, width: 170, height: 20))]
    let zones = ClickZoneDetector.zones(from: roomScreen, existing: existing)
    #expect(!zones.contains { $0.steps == [ClickZoneStep(keys: ["1"])] })
    #expect(zones.contains { $0.steps == [ClickZoneStep(keys: ["2"])] })
  }
}
