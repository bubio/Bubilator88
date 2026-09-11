import AppKit
import EmulatorCore

extension EmulatorViewModel {

  /// Copy the current text screen as Unicode text to the general pasteboard.
  ///
  /// The read takes `emuQueue`: this runs on the main thread from a menu
  /// command, while the emulation thread is writing text VRAM every frame.
  /// One delayed frame at ⌘C is not worth noticing (`RELEASE_1_5_0_PLAN.md`
  /// §3.3(e), §9.6).
  func copyTextToPasteboard() {
    let text = emuQueue.sync { pc88.copyTextAsUnicode() }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
  }

  /// Enqueue the clipboard text as simulated keystrokes.
  func pasteTextFromPasteboard() {
    guard let text = NSPasteboard.general.string(forType: .string),
          !text.isEmpty else { return }
    pasteQueueLock.lock()
    pasteQueue.enqueue(text)
    pasteQueueLock.unlock()
  }

  /// Cancel any in-flight paste. Called from keyboard handlers (ESC) and reset.
  /// Any keys the queue had pressed down are released here so the emulator's
  /// keyboard matrix doesn't end up with a stuck key after the cancel.
  func cancelPasteQueue() {
    var actions: [TextPasteQueue.KeyAction] = []
    pasteQueueLock.lock()
    pasteQueue.cancel { actions.append($0) }
    pasteQueueLock.unlock()

    for action in actions {
      let key = PC88Key(action.row, action.bit)
      apply(action.down ? .pressKey(key, record: false)
        : .releaseKey(key, record: false))
    }
  }

  /// Advance the paste queue by one logical frame. Called from
  /// `runFrameForMetal()` before the machine tick.
  /// Drain one tick of the paste queue into the matrix.
  ///
  /// Runs on the emulation thread inside the frame, so the keys are applied
  /// directly rather than posted — they are already at the frame boundary, and
  /// injected keys must not be captured by a script recording.
  nonisolated func tickPasteQueue() {
    var actions: [TextPasteQueue.KeyAction] = []
    pasteQueueLock.lock()
    pasteQueue.tick { actions.append($0) }
    pasteQueueLock.unlock()

    for action in actions {
      let key = PC88Key(action.row, action.bit)
      apply(action.down ? .pressKey(key, record: false)
        : .releaseKey(key, record: false))
    }
  }
}
