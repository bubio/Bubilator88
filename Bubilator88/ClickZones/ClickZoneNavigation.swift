import CoreGraphics
import Foundation

/// Moving a focus between control zones, for playing them from a controller:
/// the D-pad steps to the zone in that direction.
nonisolated enum ClickZoneNavigation {

  enum Direction: Sendable {
    case up, down, left, right
  }

  /// The zone to focus after a step in `direction` from `current`. Without a
  /// current zone (none yet, or it is gone) the first in reading order. Stays
  /// on `current` when no zone lies that way.
  ///
  /// A zone lies "that way" when its center is past the current center along
  /// the direction; the nearest wins, with a sideways offset counting double
  /// so a menu's next line beats a zone far to the side.
  static func move(from current: UUID?, _ direction: Direction, in zones: [ClickZone]) -> UUID? {
    guard let origin = zones.first(where: { $0.id == current }) else { return readingOrder(zones).first?.id }
    let c = center(origin)
    var best: (id: UUID, score: CGFloat)?
    for zone in zones where zone.id != origin.id {
      let p = center(zone)
      let dx = p.x - c.x, dy = p.y - c.y
      let (along, across): (CGFloat, CGFloat) = switch direction {
      case .up: (-dy, abs(dx))
      case .down: (dy, abs(dx))
      case .left: (-dx, abs(dy))
      case .right: (dx, abs(dy))
      }
      guard along > 0 else { continue }
      let score = along + 2 * across
      if best == nil || score < best!.score { best = (zone.id, score) }
    }
    return best?.id ?? origin.id
  }

  /// Top to bottom, then left to right. A zone whose top is within half the
  /// height of a row's first zone joins that row.
  static func readingOrder(_ zones: [ClickZone]) -> [ClickZone] {
    var rows: [[ClickZone]] = []
    for zone in zones.sorted(by: { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }) {
      if let first = rows.last?.first, zone.rect.y - first.rect.y <= first.rect.height / 2 {
        rows[rows.count - 1].append(zone)
      } else {
        rows.append([zone])
      }
    }
    return rows.flatMap { $0.sorted { $0.rect.x < $1.rect.x } }
  }

  private static func center(_ zone: ClickZone) -> CGPoint {
    CGPoint(x: CGFloat(zone.rect.x) + CGFloat(zone.rect.width) / 2,
            y: CGFloat(zone.rect.y) + CGFloat(zone.rect.height) / 2)
  }
}
