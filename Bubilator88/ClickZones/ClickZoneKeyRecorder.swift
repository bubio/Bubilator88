import Bubilator88Core

/// Turns key presses in the click-zone editor into sequence steps.
///
/// Keys pressed together make one step, in the order they went down; the step
/// is complete once every one of them is released.
nonisolated struct ClickZoneKeyRecorder {
  private var chord: [PC88Key] = []
  private var down: Set<PC88Key> = []

  /// Record a key going down. Repeats of a key already held are ignored.
  mutating func keyDown(_ key: PC88Key) -> ClickZoneStep? {
    guard down.insert(key).inserted else { return nil }
    if !chord.contains(key) { chord.append(key) }
    return nil
  }

  /// Record a key coming up. Returns the finished step when this was the last
  /// key of the chord still held.
  mutating func keyUp(_ key: PC88Key) -> ClickZoneStep? {
    guard down.remove(key) != nil else { return nil }
    guard down.isEmpty, !chord.isEmpty else { return nil }
    let step = ClickZoneStep(keys: chord.map { ScriptWriter.keyName(for: $0) })
    chord.removeAll()
    return step
  }
}
