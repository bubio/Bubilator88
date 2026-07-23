import AppKit
import EmulatorCore

/// Host-side romaji → half-width katakana IME. Converted kana is fed into the
/// existing `pasteQueue`, which already knows how to press the right matrix key
/// with the KANA modifier and correct timing — so no EmulatorCore change is
/// needed and the result matches real KANA-mode typing.
///
/// Ordering: kana is injected through `pasteQueue` (async, ~200ms/char), while
/// un-converted keys normally hit the matrix immediately. To stop a pass-through
/// key (notably Return) from racing ahead of still-draining kana, any key that
/// arrives while the queue/buffer is non-empty is routed through the SAME queue
/// when it is representable there (Return/Tab/printable ASCII), preserving order.
extension EmulatorViewModel {

    /// Offered every `keyDown` while `romajiInputEnabled`. Returns true if the
    /// keystroke was consumed by the IME (so it must not reach the matrix).
    ///
    /// - a–z / `-` → fed to the converter; committed kana is enqueued.
    /// - Backspace → deletes an uncommitted romaji letter (consumed) or passes
    ///   through when the buffer is empty.
    /// - ESC → aborts the current input: discards the pending buffer and cancels
    ///   any in-flight kana injection.
    /// - Anything else (Return, digits, punctuation, arrows, function keys) →
    ///   flushes the pending buffer, then either queues (to preserve order while
    ///   kana drains) or passes through.
    func handleRomajiKeyDown(_ event: NSEvent) -> Bool {
        guard romajiInputEnabled else { return false }
        // Never intercept modified chords (⌘/⌃/⌥ shortcuts).
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            flushRomajiPending()
            return false
        }

        // Backspace (0x33): pop the pending buffer if there is one.
        if event.keyCode == 0x33 {
            if romajiConverter.backspace() {
                romajiPending = romajiConverter.pending
                return true
            }
            return false
        }
        // ESC (0x35): abort the in-progress input — drop the pending buffer and
        // cancel any kana still queued. Passes through only when there is
        // nothing to abort (so a bare ESC still reaches the emulator).
        if event.keyCode == 0x35 {
            let hadPending = !romajiConverter.pending.isEmpty
            romajiConverter.reset()
            romajiPending = ""
            if hadPending || !pasteQueueIsEmpty() {
                cancelPasteQueue()
                return true
            }
            return false
        }

        guard let ch = event.charactersIgnoringModifiers, ch.count == 1,
              let c = ch.first, (c.isLetter && c.isASCII) || c == "-" else {
            // Non-romaji key. Commit any tail, then keep it ordered behind
            // still-draining kana when the queue can represent it.
            flushRomajiPending()
            if !pasteQueueIsEmpty(), let s = queueableString(for: event) {
                enqueuePaste(s)
                return true
            }
            return false
        }

        let committed = romajiConverter.feed(c)
        romajiPending = romajiConverter.pending
        if !committed.isEmpty { enqueuePaste(committed) }
        return true
    }

    /// Commit any trailing uncommitted romaji (e.g. a lone "n" → ﾝ). Called when
    /// input leaves romaji context or the mode turns off.
    func flushRomajiPending() {
        let tail = romajiConverter.flush()
        romajiPending = ""
        if !tail.isEmpty { enqueuePaste(tail) }
    }

    /// The paste-queue string for a pass-through key, or nil if the queue can't
    /// represent it (arrows / function keys — those accept the ordering race).
    private func queueableString(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 0x24, 0x4C: return "\n"   // Return / keypad Enter
        case 0x30:       return "\t"   // Tab
        default:
            guard let s = event.characters, s.count == 1,
                  let scalar = s.unicodeScalars.first,
                  (0x20...0x7E).contains(scalar.value) else { return nil }
            return s
        }
    }

    private func pasteQueueIsEmpty() -> Bool {
        pasteQueueLock.lock()
        defer { pasteQueueLock.unlock() }
        return pasteQueue.isEmpty
    }

    private func enqueuePaste(_ text: String) {
        pasteQueueLock.lock()
        pasteQueue.enqueue(text)
        pasteQueueLock.unlock()
    }
}
