import Bubilator88Core
import CoreGraphics
import Foundation

/// Turns the text lines OCR found on the screen into control zones, so a menu
/// need not be drawn line by line.
///
/// Every line becomes a zone. A line that starts with an item number
/// ("1 コンピューター", "(2) いいえ", "A) こうげき") gets that key; any other
/// line gets no keys, for the user to record. Lines stacked at the same left
/// edge are taken as one menu: they share its width and meet halfway between
/// lines, so the whole menu is clickable without gaps. Detection is a
/// starting point, not a verdict: wrong zones are deleted in the editor.
nonisolated enum ClickZoneDetector {

  /// How far apart, in screen pixels, the left edges of one menu's lines may be.
  static let alignmentTolerance: CGFloat = 16
  /// Margin added around each zone, in screen pixels.
  static let padding: CGFloat = 2

  /// Zones for `lines`, top to bottom, leaving out any that would mostly
  /// cover a zone in `existing`.
  static func zones(from lines: [ScreenTextLine], existing: [ClickZone]) -> [ClickZone] {
    let items = lines.compactMap(Item.init)
      .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }

    var blocks: [[Item]] = []
    for item in items {
      if let i = blocks.firstIndex(where: { continues($0, with: item) }) {
        blocks[i].append(item)
      } else {
        blocks.append([item])
      }
    }

    return blocks.flatMap(zones(for:))
      .filter { zone in !existing.contains { overlapsMostly(zone.rect, $0.rect) } }
  }

  /// Whether `item` is the next line of the menu `block`: its left edge lines
  /// up and it starts no more than a line's height below the last line.
  private static func continues(_ block: [Item], with item: Item) -> Bool {
    guard let last = block.last else { return false }
    let left = block.map(\.frame.minX).min() ?? last.frame.minX
    let gap = item.frame.minY - last.frame.maxY
    return abs(item.frame.minX - left) <= alignmentTolerance
      && gap >= -padding
      && gap <= max(last.frame.height, item.frame.height)
  }

  /// One zone per line of a menu: the menu's full width, with neighbouring
  /// zones meeting halfway between their lines.
  private static func zones(for block: [Item]) -> [ClickZone] {
    let minX = (block.map(\.frame.minX).min() ?? 0) - padding
    let maxX = (block.map(\.frame.maxX).max() ?? 0) + padding
    // Boundaries[i] is the top of line i; the last one is the menu's bottom.
    var boundaries = [block[0].frame.minY - padding]
    for (upper, lower) in zip(block, block.dropFirst()) {
      boundaries.append((upper.frame.maxY + lower.frame.minY) / 2)
    }
    boundaries.append(block[block.count - 1].frame.maxY + padding)
    let edges = boundaries.map { Int($0.rounded()) }
    let x = Int(minX.rounded(.down))
    let width = Int(maxX.rounded(.up)) - x

    return block.indices.map { i in
      let rect = ClickZoneRect(x: x, y: edges[i], width: width, height: edges[i + 1] - edges[i])
      return ClickZone(label: block[i].label, rect: rect.clamped(),
                       steps: block[i].key.map { [ClickZoneStep(keys: [$0])] } ?? [])
    }
  }

  /// Whether the two rectangles share at least half of the smaller one.
  private static func overlapsMostly(_ a: ClickZoneRect, _ b: ClickZoneRect) -> Bool {
    let shared = a.cgRect.intersection(b.cgRect)
    guard !shared.isNull else { return false }
    let smaller = min(a.cgRect.width * a.cgRect.height, b.cgRect.width * b.cgRect.height)
    return shared.width * shared.height * 2 >= smaller
  }

  /// One OCR line in screen pixels, with its item number split off.
  private struct Item {
    let frame: CGRect
    let label: String
    /// The b88script name of the item-number key, if the line starts with one.
    let key: String?

    init?(_ line: ScreenTextLine) {
      let text = line.text.trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { return nil }
      frame = CGRect(x: line.rect.minX * CGFloat(ClickZoneRect.screenWidth),
                     y: line.rect.minY * CGFloat(ClickZoneRect.screenHeight),
                     width: line.rect.width * CGFloat(ClickZoneRect.screenWidth),
                     height: line.rect.height * CGFloat(ClickZoneRect.screenHeight))
      if let (key, body) = Self.itemNumber(in: text) {
        self.key = key
        label = body
      } else {
        key = nil
        label = text
      }
    }

    /// The key and the text after it, when `text` starts with an item number:
    /// a digit or letter, optionally in parentheses or followed by `.`/`:`.
    /// A digit needs a separator, a space or non-ASCII text after it, so
    /// "1985年" is not item 1; a letter needs a separator, so "I am" is not
    /// item I.
    private static func itemNumber(in text: String) -> (String, String)? {
      // NFKC folds full-width digits, letters and punctuation to ASCII.
      var rest = Substring(text.precomposedStringWithCompatibilityMapping)
      let opened = rest.first == "("
      if opened { rest = rest.dropFirst() }
      guard let mark = rest.first, mark.isASCII, mark.isLetter || mark.isNumber else { return nil }
      rest = rest.dropFirst()
      var separated = false
      if let c = rest.first, ").:".contains(c) {
        separated = true
        rest = rest.dropFirst()
      } else if opened {
        return nil
      }
      let spaced = rest.first?.isWhitespace ?? false
      let body = rest.trimmingCharacters(in: .whitespaces)
      guard let next = body.first else { return nil }
      let accepted = mark.isNumber
        ? separated || spaced || !next.isASCII
        : separated
      guard accepted,
            let key = ScriptParser.key(named: String(mark)) else { return nil }
      return (ScriptWriter.keyName(for: key), body)
    }
  }
}
