import SwiftUI
import AppKit

/// NSView that captures keyboard events and forwards them to the emulator.
struct KeyEventView: NSViewRepresentable {
    let onKeyDown: (UInt16) -> Void
    let onKeyUp: (UInt16) -> Void
    var onTurbo: ((Bool) -> Void)?

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyDown = onKeyDown
        view.onKeyUp = onKeyUp
        view.onTurbo = onTurbo
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
        nsView.onKeyUp = onKeyUp
        nsView.onTurbo = onTurbo
    }
}

class KeyCaptureNSView: NSView {
    var onKeyDown: ((UInt16) -> Void)?
    var onKeyUp: ((UInt16) -> Void)?
    var onTurbo: ((Bool) -> Void)?

    private var monitors: [Any] = []
    private var turboActive: Bool = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitors()
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification, object: window)
        } else {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
            removeMonitors()
        }
    }

    @objc private func windowDidResignKey() {
        turboActive = false
        onTurbo?(false)
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            guard !event.isARepeat else { return event }
            guard !event.modifierFlags.contains(.command) else { return event }
            // Shift+Tab → turbo mode (no PC88 key event)
            if event.keyCode == 0x30 && event.modifierFlags.contains(.shift) {
                self.turboActive = true
                self.onTurbo?(true)
                return event
            }
            self.onKeyDown?(event.keyCode)
            return event
        } as Any)

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            // Tab release while turbo → turbo off (no PC88 key event)
            if event.keyCode == 0x30 && self.turboActive {
                self.turboActive = false
                self.onTurbo?(false)
                return event
            }
            self.onKeyUp?(event.keyCode)
            return event
        } as Any)

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            let modifiers: [(NSEvent.ModifierFlags, UInt16)] = [
                (.shift, 0x38),
                (.control, 0x3B),
                (.option, 0x3A),
                (.capsLock, 0x39),
            ]
            for (flag, keyCode) in modifiers {
                if event.modifierFlags.contains(flag) {
                    self.onKeyDown?(keyCode)
                } else {
                    self.onKeyUp?(keyCode)
                }
            }
            return event
        } as Any)

        // Middle mouse button → turbo mode
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            if event.buttonNumber == 2 { self.onTurbo?(true) }
            return event
        } as Any)

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            if event.buttonNumber == 2 { self.onTurbo?(false) }
            return event
        } as Any)
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if turboActive {
            turboActive = false
            onTurbo?(false)
        }
    }

    deinit {
        removeMonitors()
    }
}
