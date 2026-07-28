import SwiftUI
import AppKit

/// NSView that captures keyboard events and forwards them to the emulator.
/// When the PC-8801 bus mouse is enabled, it also captures (hides + locks)
/// the host cursor and forwards relative motion and left/right buttons.
struct KeyEventView: NSViewRepresentable {
  let onKeyDown: (UInt16) -> Void
  let onKeyUp: (UInt16) -> Void
  var onTurbo: ((Bool) -> Void)?

  /// Romaji-input hook. When set, each keyDown is offered here first; if the
  /// handler returns true it consumed the keystroke (routed to the kana IME)
  /// and the key must NOT reach the emulator matrix. The matching keyUp is
  /// suppressed automatically.
  var onRomajiKeyDown: ((NSEvent) -> Bool)?

  /// Relative mouse movement (dx, dy) in emulator units.
  var onMouseMove: ((Int, Int) -> Void)?
  /// Left/right button state.
  var onMouseButton: ((Bool, Bool) -> Void)?
  /// Whether bus-mouse capture is active (mirrors Settings.mouseEnabled).
  var mouseCaptureEnabled: Bool = false
  /// Movement sensitivity multiplier.
  var mouseSensitivity: Float = 1.0
  /// Fires when the host cursor capture engages / releases.
  var onCaptureChange: ((Bool) -> Void)?

  func makeNSView(context: Context) -> KeyCaptureNSView {
    let view = KeyCaptureNSView()
    view.onKeyDown = onKeyDown
    view.onKeyUp = onKeyUp
    view.onTurbo = onTurbo
    view.onRomajiKeyDown = onRomajiKeyDown
    view.onMouseMove = onMouseMove
    view.onMouseButton = onMouseButton
    view.onCaptureChange = onCaptureChange
    view.mouseSensitivity = mouseSensitivity
    view.setMouseCaptureEnabled(mouseCaptureEnabled)
    return view
  }

  func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
    nsView.onKeyDown = onKeyDown
    nsView.onKeyUp = onKeyUp
    nsView.onTurbo = onTurbo
    nsView.onRomajiKeyDown = onRomajiKeyDown
    nsView.onMouseMove = onMouseMove
    nsView.onMouseButton = onMouseButton
    nsView.onCaptureChange = onCaptureChange
    nsView.mouseSensitivity = mouseSensitivity
    nsView.setMouseCaptureEnabled(mouseCaptureEnabled)
  }
}

class KeyCaptureNSView: NSView {
  var onKeyDown: ((UInt16) -> Void)?
  var onKeyUp: ((UInt16) -> Void)?
  var onTurbo: ((Bool) -> Void)?
  var onRomajiKeyDown: ((NSEvent) -> Bool)?

  /// keyCodes consumed by the romaji IME on keyDown, so their keyUp can be
  /// swallowed too (the emulator never saw the press).
  private var romajiConsumed: Set<UInt16> = []
  var onMouseMove: ((Int, Int) -> Void)?
  var onMouseButton: ((Bool, Bool) -> Void)?
  var onCaptureChange: ((Bool) -> Void)?
  var mouseSensitivity: Float = 1.0

  private var monitors: [Any] = []
  private var turboActive: Bool = false

  /// Mouse mode requested by settings.
  private var mouseModeEnabled: Bool = false
  /// True while the host cursor is hidden + decoupled (pointer lock active).
  private var capturing: Bool = false
  /// Fractional movement remainder, so low sensitivity stays smooth.
  private var accumX: Float = 0
  private var accumY: Float = 0

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let window {
      window.acceptsMouseMovedEvents = true
      installMonitors()
      NotificationCenter.default.addObserver(
        self, selector: #selector(windowDidResignKey),
        name: NSWindow.didResignKeyNotification, object: window)
    } else {
      NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
      endCapture()
      removeMonitors()
    }
  }

  // MARK: - Mouse capture lifecycle

  /// Reflects the settings toggle. Capture itself does NOT auto-engage here —
  /// it begins only when the user clicks inside the emulation view. Turning
  /// the setting off releases any active capture.
  func setMouseCaptureEnabled(_ enabled: Bool) {
    mouseModeEnabled = enabled
    if !enabled {
      endCapture()
    }
  }

  /// True when a mouse event occurred inside this view's bounds (the emulation
  /// screen area). Clicks on the status bar / other chrome fall outside.
  private func eventInsideView(_ event: NSEvent) -> Bool {
    guard let window, event.window === window else { return false }
    let pt = convert(event.locationInWindow, from: nil)
    return bounds.contains(pt)
  }

  private func beginCapture() {
    guard !capturing, mouseModeEnabled else { return }
    capturing = true
    accumX = 0
    accumY = 0
    // Clear any button state left over from a prior capture session that
    // ended (window-resign / Control+Esc) while a button was held — its
    // matching mouseUp was ignored, so the held flag would otherwise leak
    // a phantom press into this session.
    leftHeld = false
    rightHeld = false
    // Decouple the hardware mouse from the on-screen cursor so deltas keep
    // flowing without the pointer drifting off-window, and hide the cursor.
    CGAssociateMouseAndMouseCursorPosition(0)
    NSCursor.hide()
    onCaptureChange?(true)
  }

  private func endCapture() {
    guard capturing else { return }
    capturing = false
    CGAssociateMouseAndMouseCursorPosition(1)
    NSCursor.unhide()
    // Release any held buttons so a game doesn't see them stuck.
    onMouseButton?(false, false)
    onCaptureChange?(false)
  }

  @objc private func windowDidResignKey() {
    turboActive = false
    onTurbo?(false)
    endCapture()
  }

  private func forwardMovement(_ event: NSEvent) {
    guard capturing else { return }
    // deltaX/deltaY are raw hardware deltas (independent of the decoupled
    // cursor). The bus mouse negates internally; if a game's Y feels
    // inverted, flip event.deltaY here.
    let dxF = Float(event.deltaX) * mouseSensitivity + accumX
    let dyF = Float(event.deltaY) * mouseSensitivity + accumY
    let dxI = Int(dxF)
    let dyI = Int(dyF)
    accumX = dxF - Float(dxI)
    accumY = dyF - Float(dyI)
    if dxI != 0 || dyI != 0 {
      onMouseMove?(dxI, dyI)
    }
  }

  private func installMonitors() {
    guard monitors.isEmpty else { return }

    monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.window?.isKeyWindow == true else { return event }
      guard !event.isARepeat else { return event }
      guard !event.modifierFlags.contains(.command) else { return event }
      // Control+Esc → release the captured cursor (re-grab by clicking
      // the emulation view again).
      if event.keyCode == 0x35 && event.modifierFlags.contains(.control) && self.capturing {
        self.endCapture()
        return nil  // consume; do not forward Esc to the emulator
      }
      // Shift+Tab → turbo mode (no PC88 key event)
      if event.keyCode == 0x30 && event.modifierFlags.contains(.shift) {
        self.turboActive = true
        self.onTurbo?(true)
        return event
      }
      // Romaji IME: offer the keystroke to the converter. If consumed, it
      // is routed to kana (via the paste queue) and must not reach the
      // matrix — remember the keyCode so its keyUp is swallowed too.
      if let romaji = self.onRomajiKeyDown, romaji(event) {
        self.romajiConsumed.insert(event.keyCode)
        return nil
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
      // Swallow the keyUp for a key the romaji IME consumed on keyDown.
      if self.romajiConsumed.remove(event.keyCode) != nil {
        return nil
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

    // Mouse movement (with and without buttons held).
    for mask: NSEvent.EventTypeMask in [.mouseMoved, .leftMouseDragged, .rightMouseDragged] {
      monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
        guard let self, self.window?.isKeyWindow == true else { return event }
        self.forwardMovement(event)
        return event
      } as Any)
    }

    // Left button.
    monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      guard let self, self.window?.isKeyWindow == true else { return event }
      // Not yet captured: a click *inside the emulation view* grabs the
      // cursor. Clicks elsewhere (status bar, chrome) are left alone.
      if self.mouseModeEnabled && !self.capturing {
        if self.eventInsideView(event) {
          self.beginCapture()
        }
        return event
      }
      if self.capturing { self.onMouseButton?(true, self.rightHeld); self.leftHeld = true }
      return event
    } as Any)

    monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
      guard let self, self.window?.isKeyWindow == true else { return event }
      if self.capturing { self.leftHeld = false; self.onMouseButton?(false, self.rightHeld) }
      return event
    } as Any)

    // Right button.
    monitors.append(NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
      guard let self, self.window?.isKeyWindow == true else { return event }
      if self.capturing { self.rightHeld = true; self.onMouseButton?(self.leftHeld, true) }
      return self.capturing ? nil : event  // suppress context menu while captured
    } as Any)

    monitors.append(NSEvent.addLocalMonitorForEvents(matching: .rightMouseUp) { [weak self] event in
      guard let self, self.window?.isKeyWindow == true else { return event }
      if self.capturing { self.rightHeld = false; self.onMouseButton?(self.leftHeld, false) }
      return self.capturing ? nil : event
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

  private var leftHeld: Bool = false
  private var rightHeld: Bool = false

  private func removeMonitors() {
    monitors.forEach { NSEvent.removeMonitor($0) }
    monitors.removeAll()
    if turboActive {
      turboActive = false
      onTurbo?(false)
    }
  }

  deinit {
    endCapture()
    removeMonitors()
  }
}
