import AppKit
import EmulatorCore

extension EmulatorViewModel {

    /// Copy the current text screen as Unicode text to the general pasteboard.
    func copyTextToPasteboard() {
        let text = machine.copyTextAsUnicode()
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
            let key = Keyboard.Key(action.row, action.bit)
            if action.down {
                pressKey(key)
            } else {
                releaseKey(key)
            }
        }
    }

    /// Advance the paste queue by one logical frame. Called from
    /// `runFrameForMetal()` before the machine tick.
    func tickPasteQueue() {
        var actions: [TextPasteQueue.KeyAction] = []
        pasteQueueLock.lock()
        pasteQueue.tick { actions.append($0) }
        pasteQueueLock.unlock()

        for action in actions {
            let key = Keyboard.Key(action.row, action.bit)
            if action.down {
                pressKey(key)
            } else {
                releaseKey(key)
            }
        }
    }
}
