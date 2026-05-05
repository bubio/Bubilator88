import AppKit

/// Application delegate used only for shortcut-confirmation plumbing.
///
/// macOS lets Cmd+Q and Cmd+W tear the app/window down with a single
/// keypress. That's trivially easy to hit by accident while a game is
/// running, so we pop a confirmation dialog — **but only for the
/// keyboard-shortcut path**. Selecting the same command from the menu
/// bar skips the confirmation, on the theory that a deliberate menu
/// click already expresses intent.
///
/// Design: the local `.keyDown` monitor **does not** try to cancel the
/// event or present any UI. It only sets a flag recording "the next
/// terminate / window-close request was triggered by Cmd+Q / Cmd+W".
/// The actual cancel decision happens in the standard AppKit hooks:
///
/// - `applicationShouldTerminate(_:)` for Cmd+Q
/// - `NSWindowDelegate.windowShouldClose(_:)` for Cmd+W
///
/// Those hooks run *after* the event dispatch is complete, so we can
/// safely put up an `NSAlert` via `runModal()` without the reentrancy
/// problem we hit when we tried to present the alert from inside the
/// event monitor itself (the nested modal loop re-delivered the same
/// Cmd+W keystroke to the alert and matched its default button).
///
/// Menu-click path: the menu invokes the action directly via the
/// responder chain, so the keyDown monitor never fires → the flag
/// stays false → the shouldTerminate / shouldClose hooks return
/// without prompting. Exactly the behavior we want.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Set by the root SwiftUI scene so terminate hooks can reach the
    /// recorder. Weak to avoid a retain cycle; the view model outlives
    /// the delegate in practice.
    weak var viewModel: EmulatorViewModel?

    private var shortcutMonitor: Any?
    private var rewindMonitor: Any?

    /// US-keyboard "z" virtual key code. Used to detect Cmd+Z hold for
    /// rewind regardless of localized character (Z is the same physical
    /// position on JIS as well, where keyCode 6 maps to "z").
    private static let rewindKeyCode: UInt16 = 6
    private var rewindHoldActive = false

    /// Strong identity reference to the emulator window, captured the
    /// first time we observe it become key. Used by the rewind hold
    /// monitor to gate Cmd+Z so it doesn't engage while a Settings
    /// sheet, About panel, or Debugger window is foremost.
    private weak var emulatorWindow: NSWindow?

    /// True if the most recent terminate attempt was triggered by Cmd+Q.
    /// Cleared inside `applicationShouldTerminate(_:)` once consumed.
    private var lastTerminateWasShortcut = false

    /// True if the most recent window-close attempt was triggered by Cmd+W.
    /// Cleared inside `windowShouldClose(_:)` once consumed.
    private var lastCloseWasShortcut = false

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.recordShortcut(event)
            return event
        }
        rewindMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            self?.handleRewindEvent(event) ?? event
        }
        // The SwiftUI `Window` scene has created the NSWindow by this
        // point, but it may not be available on the first runloop tick.
        // Defer the delegate attach until the main window notifies us
        // that it has become key.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Finalize an in-progress recording. M4A/AAC needs its `moov` atom
        // written at close — skipping stopRecording here leaves the file
        // unreadable. Runs synchronously on the main thread before the
        // process exits.
        MainActor.assumeIsolated {
            viewModel?.stopRecording()
        }
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
        if let monitor = rewindMonitor {
            NSEvent.removeMonitor(monitor)
            rewindMonitor = nil
        }
    }

    // MARK: - Rewind hold detection

    /// Returns nil to swallow the event (so SwiftUI's menu shortcut
    /// doesn't double-fire), or `event` to let it propagate normally.
    /// Only the `Cmd+Z` chord is intercepted; everything else passes
    /// through unchanged.
    private func handleRewindEvent(_ event: NSEvent) -> NSEvent? {
        // Only intercept Cmd+Z when the emulator window itself is key —
        // not a Settings sheet, About panel, or Debugger window where
        // Cmd+Z legitimately means "undo" in a text field. Identity
        // comparison rather than title matching so localization or any
        // future title change doesn't silently disable rewind.
        guard let emu = emulatorWindow, NSApp.keyWindow === emu else {
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmdOnly = flags.contains(.command)
            && flags.isDisjoint(with: [.shift, .option, .control])

        switch event.type {
        case .keyDown:
            if event.keyCode == Self.rewindKeyCode && cmdOnly {
                if !rewindHoldActive {
                    rewindHoldActive = true
                    MainActor.assumeIsolated {
                        viewModel?.startRewindHold()
                    }
                }
                return nil  // swallow (also suppresses menu shortcut + autorepeat)
            }
        case .keyUp:
            if event.keyCode == Self.rewindKeyCode && rewindHoldActive {
                rewindHoldActive = false
                MainActor.assumeIsolated {
                    viewModel?.stopRewindHold()
                }
                return nil
            }
        case .flagsChanged:
            // User released Command before Z: end the hold immediately
            // so the emulator resumes from the current rewound frame.
            if rewindHoldActive && !flags.contains(.command) {
                rewindHoldActive = false
                MainActor.assumeIsolated {
                    viewModel?.stopRewindHold()
                }
            }
        default:
            break
        }
        return event
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard lastTerminateWasShortcut else { return .terminateNow }
        lastTerminateWasShortcut = false
        guard let host = mainEmulatorWindow() else {
            // Fallback: no host window → plain modal.
            MainActor.assumeIsolated { viewModel?.beginQuitDissolve() }
            let confirmed = confirmQuitShortcutModal()
            if !confirmed {
                MainActor.assumeIsolated { viewModel?.cancelQuitDissolve() }
            }
            return confirmed ? .terminateNow : .terminateCancel
        }
        MainActor.assumeIsolated { viewModel?.beginQuitDissolve() }
        presentQuitConfirmationSheet(on: host)
        // Defer the terminate decision until the sheet's completion handler
        // calls NSApp.reply(toApplicationShouldTerminate:).
        return .terminateLater
    }

    /// Closing the main emulator window should tear the whole app down,
    /// including any supplementary windows (Debugger, etc.). Without
    /// this override, the app would stay alive with only the debugger
    /// visible — a state that has no meaning on its own.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - NSWindowDelegate

    @objc private func mainWindowDidBecomeKey(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              window.title == "Bubilator88" else {
            return
        }
        // Cache identity for Cmd+Z gating. Title-based comparison is
        // brittle (localization, in-flight setTitle calls, etc.) so we
        // do it once here and from then on rely on `===` identity.
        if emulatorWindow == nil {
            emulatorWindow = window
        }
        if window.delegate !== self {
            window.delegate = self
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard lastCloseWasShortcut else { return true }
        lastCloseWasShortcut = false
        MainActor.assumeIsolated { viewModel?.beginQuitDissolve() }
        presentCloseConfirmationSheet(on: sender)
        // Always refuse the close here; if the user confirms, the sheet's
        // completion handler calls `sender.close()` directly, which bypasses
        // `windowShouldClose` and so won't recurse into this branch.
        return false
    }

    /// When the main emulator window is about to close, dismiss every
    /// other window so the "last window closed" check can fire and
    /// terminate the app. Without this the Debugger (and any other
    /// supplementary scene) would keep the process alive after the
    /// user has clearly asked to go away.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.title == "Bubilator88" else {
            return
        }
        for other in NSApp.windows where other !== window && other.isVisible {
            other.close()
        }
    }

    // MARK: - Sheet / modal helpers

    private func mainEmulatorWindow() -> NSWindow? {
        return NSApp.windows.first { $0.title == "Bubilator88" }
    }

    private func presentQuitConfirmationSheet(on host: NSWindow) {
        let alert = makeQuitAlert()
        alert.beginSheetModal(for: host) { [weak self] response in
            let confirmed = (response == .alertFirstButtonReturn)
            if !confirmed {
                MainActor.assumeIsolated { self?.viewModel?.cancelQuitDissolve() }
            }
            NSApp.reply(toApplicationShouldTerminate: confirmed)
        }
    }

    private func presentCloseConfirmationSheet(on host: NSWindow) {
        let alert = makeCloseAlert()
        alert.beginSheetModal(for: host) { [weak self] response in
            if response == .alertFirstButtonReturn {
                host.close()
            } else {
                MainActor.assumeIsolated { self?.viewModel?.cancelQuitDissolve() }
            }
        }
    }

    /// Last-resort screen-centered modal used when no suitable host window
    /// exists (shouldn't happen in practice — the main window lives for the
    /// entire app session — but keeps Cmd+Q working if it ever does).
    private func confirmQuitShortcutModal() -> Bool {
        return makeQuitAlert().runModal() == .alertFirstButtonReturn
    }

    // MARK: - Shortcut detection

    private func recordShortcut(_ event: NSEvent) {
        // Only bare Command+<letter> counts. Cmd+Shift+Q etc. are left
        // alone so the user can still build custom shortcuts elsewhere.
        let required: NSEvent.ModifierFlags = .command
        let forbidden: NSEvent.ModifierFlags = [.shift, .option, .control]
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(required), flags.isDisjoint(with: forbidden) else { return }
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return }

        switch chars {
        case "q":
            lastTerminateWasShortcut = true
        case "w":
            // Only gate Cmd+W for the main emulator window. Settings /
            // About / Help sheets should still close with a single keypress.
            if let emu = emulatorWindow, NSApp.keyWindow === emu {
                lastCloseWasShortcut = true
            }
        default:
            break
        }
    }

    // MARK: - Alert builders

    private func makeQuitAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "Quit Bubilator88?",
            comment: "Confirmation dialog shown when Cmd+Q is pressed"
        )
        alert.informativeText = NSLocalizedString(
            "Unsaved emulator state will be lost.",
            comment: "Cmd+Q confirmation body"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: "Quit button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        return alert
    }

    private func makeCloseAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "Close the emulator window?",
            comment: "Confirmation dialog shown when Cmd+W is pressed on the main window"
        )
        alert.informativeText = NSLocalizedString(
            "Unsaved emulator state will be lost.",
            comment: "Cmd+W confirmation body"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Close", comment: "Close button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        return alert
    }
}
