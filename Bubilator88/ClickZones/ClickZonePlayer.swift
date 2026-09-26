import Bubilator88Core
import Foundation

/// Plays a click zone's key sequence into the keyboard matrix, one frame at a
/// time.
///
/// The main thread starts a sequence on a click and the emulation loop ticks
/// it once per frame, next to the paste queue; a lock covers the handoff.
/// Within a step, modifiers (SHIFT, CTRL, GRPH, カナ) go down one frame before
/// the other keys and come up one frame after them, as `TextPasteQueue` does,
/// so a game sampling the matrix never sees the key without its modifier.
nonisolated final class ClickZonePlayer: @unchecked Sendable {

  struct KeyEvent: Equatable, Sendable {
    let key: PC88Key
    let down: Bool
  }

  private static let modifiers: Set<PC88Key> = [.shift, .ctrl, .grph, .kana]

  private let lock = NSLock()
  /// Pending events, sorted by frame.
  private var schedule: [(frame: Int, event: KeyEvent)] = []
  private var frame = 0
  private var held: Set<PC88Key> = []

  /// True when no sequence is playing.
  var isIdle: Bool {
    lock.lock()
    defer { lock.unlock() }
    return schedule.isEmpty
  }

  /// Start playing `steps`. Returns false, and does nothing, if a sequence is
  /// already playing or the steps press no key.
  @discardableResult
  func start(_ steps: [ClickZoneStep]) -> Bool {
    let built = Self.buildSchedule(steps)
    guard !built.isEmpty else { return false }
    lock.lock()
    defer { lock.unlock() }
    guard schedule.isEmpty else { return false }
    schedule = built
    frame = 0
    return true
  }

  /// Emit this frame's events and advance one frame. Emulation thread.
  func tick(emit: (KeyEvent) -> Void) {
    lock.lock()
    guard !schedule.isEmpty else {
      lock.unlock()
      return
    }
    var due: [KeyEvent] = []
    while let first = schedule.first, first.frame <= frame {
      due.append(first.event)
      schedule.removeFirst()
    }
    frame += 1
    for event in due {
      if event.down { held.insert(event.key) } else { held.remove(event.key) }
    }
    lock.unlock()
    due.forEach(emit)
  }

  /// Stop playing and release every key the sequence is holding down.
  func cancel(emit: (KeyEvent) -> Void) {
    lock.lock()
    let release = held
    schedule.removeAll()
    held.removeAll()
    lock.unlock()
    for key in release {
      emit(KeyEvent(key: key, down: false))
    }
  }

  private static func buildSchedule(_ steps: [ClickZoneStep]) -> [(frame: Int, event: KeyEvent)] {
    var out: [(frame: Int, event: KeyEvent)] = []
    var t = 0
    for step in steps {
      let keys = step.resolvedKeys
      guard !keys.isEmpty else { continue }
      let mods = keys.filter { modifiers.contains($0) }
      let others = keys.filter { !modifiers.contains($0) }
      let hold = max(1, step.holdFrames)
      // Only a mixed chord needs the one-frame lead/lag for its modifiers.
      let lead = (!mods.isEmpty && !others.isEmpty) ? 1 : 0
      let down = t + lead
      let up = down + hold
      for key in mods { out.append((t, KeyEvent(key: key, down: true))) }
      for key in others { out.append((down, KeyEvent(key: key, down: true))) }
      for key in others { out.append((up, KeyEvent(key: key, down: false))) }
      for key in mods { out.append((up + lead, KeyEvent(key: key, down: false))) }
      t = up + lead + max(0, step.gapFrames)
    }
    return out
  }
}
