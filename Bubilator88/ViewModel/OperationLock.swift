import Foundation

/// A kind of user operation that an `OperationLock` can hold back. Menu items,
/// drops, opened files and other entry points each name the kind they belong
/// to and ask `EmulatorViewModel.allows(_:)` before acting.
nonisolated enum LockableOperation: CaseIterable, Sendable {
  /// Pause/Resume, Reset, boot mode, CPU clock, emulation speed.
  case emulation
  /// Keys sent to the machine outside the emulator view: Paste Text, the
  /// software keyboard, romaji input.
  case input
  /// Mounting, ejecting and switching disks and tapes, including drops and
  /// files opened from Finder or a `bubilator88://` URL.
  case media
  /// Quick save/load, save states and rewind.
  case state
  /// Audio and video recording.
  case recording
  /// Script playback and recording.
  case script
  /// Screenshots and copying the screen or its text.
  case capture
  /// Window size, scanlines, video filter, translation overlay.
  case display
  /// Volume.
  case audio
  /// The Develop menu.
  case develop
}

/// Why operations are held back right now. Each reason lists what it still
/// allows; everything else is refused while it is active.
///
/// Add a case here, list what it allows, and report it from
/// `EmulatorViewModel.operationLocks` — entry points need no change.
nonisolated enum OperationLock: Hashable, Sendable {
  /// A click-zone layout is being edited: emulation is paused and the screen
  /// must hold still, so nothing may change the machine or the mounted disks.
  case clickZoneEditing

  func allows(_ operation: LockableOperation) -> Bool {
    switch self {
    case .clickZoneEditing:
      switch operation {
      case .capture, .display, .audio: true
      case .emulation, .input, .media, .state, .recording, .script, .develop: false
      }
    }
  }

  /// Shown when a refused operation came from outside the menus (a file
  /// opened from Finder, for one), where no disabled item explains it.
  var refusalMessage: String {
    switch self {
    case .clickZoneEditing:
      String(localized: "Close the click zone editor first.")
    }
  }
}

extension EmulatorViewModel {

  /// The locks in force, derived from the state that causes them so a lock
  /// can never outlive its reason.
  var operationLocks: [OperationLock] {
    var locks: [OperationLock] = []
    if isEditingClickZones { locks.append(.clickZoneEditing) }
    return locks
  }

  /// Whether every active lock allows `operation`.
  func allows(_ operation: LockableOperation) -> Bool {
    operationLocks.allSatisfy { $0.allows(operation) }
  }

  /// For entry points outside the menus: returns true when `operation` may
  /// run, otherwise explains the refusal in an alert and returns false.
  func checkAllowed(_ operation: LockableOperation) -> Bool {
    guard let lock = operationLocks.first(where: { !$0.allows(operation) }) else { return true }
    showAlert(title: String(localized: "Not Available Now"), message: lock.refusalMessage)
    return false
  }
}
