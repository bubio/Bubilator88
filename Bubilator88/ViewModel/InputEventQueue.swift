import EmulatorCore
import Foundation

/// A host input event, queued on the main thread and applied to the machine
/// by the emulation loop at a frame boundary.
///
/// Keyboard matrix and bus-mouse state used to be mutated straight from the
/// main thread under a bare lock. That was only ever safe because emulation
/// itself ran on the main thread, so a mutation could never land in the middle
/// of `machine.runFrame()`. Once the emulation loop owns its own thread that
/// guarantee is gone, so every input mutation goes through this queue instead
/// and is applied where the machine is quiescent.
enum InputEvent {
  case pressKey(Keyboard.Key)
  case releaseKey(Keyboard.Key)
  case releaseAllKeys
  case mouseMovement(dx: Int, dy: Int)
  case mouseButtons(left: Bool, right: Bool)
  case mouseEnabled(Bool)
  case mouseJoyMode(Bool)
}

/// FIFO handoff for `InputEvent`s between the producing thread (main) and the
/// consuming thread (the emulation loop).
///
/// Ordering is the whole point: a press followed by a release must reach the
/// matrix in that order, and `releaseAllKeys` must not overtake the presses it
/// is meant to clear.
final class InputEventQueue: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [InputEvent] = []

  /// Queue an event for the next drain. Safe from any thread.
  func post(_ event: InputEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }

  /// Take everything queued so far, leaving the queue empty.
  func drain() -> [InputEvent] {
    lock.lock()
    let taken = events
    events.removeAll(keepingCapacity: true)
    lock.unlock()
    return taken
  }
}
