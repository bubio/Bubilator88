import Bubilator88Core
import Foundation

extension EmulatorViewModel {

  /// Click zones are usable only while the PC-8801 mouse is off: with the bus
  /// mouse on, a click captures the pointer for the game instead.
  var clickZonesAvailable: Bool {
    Settings.shared.clickZonesEnabled && !Settings.shared.mouseEnabled
  }

  /// Keys of the mounted disks, drive 0 first.
  var clickZoneDiskKeys: [ClickZoneDiskKey?] {
    [drive0Info.map(ClickZoneDiskKey.init(info:)),
     drive1Info.map(ClickZoneDiskKey.init(info:))]
  }

  /// Every disk of every mounted file, whichever drive holds it: what a new
  /// layout is assigned to from the start.
  var mountedClickZoneDisks: [ClickZoneDiskKey] {
    ClickZoneDiskFile.list(mounted: [drive0Info, drive1Info].compactMap { $0 }, assigned: [])
      .flatMap(\.images)
  }

  /// The layout to play: the one assigned to the mounted disks.
  var activeClickZoneLayout: ClickZoneLayout? {
    ClickZoneStore.shared.layout(for: clickZoneDiskKeys)
  }

  var isEditingClickZones: Bool {
    clickZoneEditingLayout != nil
  }

  // MARK: - Playback

  /// Play the zone's key sequence. A click while a sequence is still playing
  /// is ignored, so rapid clicks cannot interleave two sequences.
  func playClickZone(_ zone: ClickZone) {
    guard !isEditingClickZones else { return }
    clickZonePlayer.start(zone.steps)
  }

  /// Advance the sequence by one frame. Emulation thread, next to
  /// `tickPasteQueue()`, so the keys are applied directly.
  nonisolated func tickClickZonePlayer() {
    clickZonePlayer.tick { event in
      apply(event.down ? .pressKey(event.key, record: false)
        : .releaseKey(event.key, record: false))
    }
  }

  /// Stop the sequence and release whatever it holds down. Called for ESC and
  /// reset, with the loop either parked or about to be.
  func cancelClickZonePlayer() {
    clickZonePlayer.cancel { releaseKey($0.key) }
  }

  // MARK: - Editing

  /// Open an editing session on user layout `layoutID`, ending any session
  /// already open. Pauses emulation so the screen holds still and no key
  /// leaks into the game. Returns false when the PC-8801 mouse is on
  /// (explained in an alert: a click would capture the pointer instead of
  /// drawing) or the layout is not a user layout.
  @discardableResult
  func beginClickZoneEditing(layoutID: UUID) -> Bool {
    if Settings.shared.mouseEnabled {
      showAlert(
        title: String(localized: "Click Zones Unavailable"),
        message: String(localized: "Click zones cannot be used while mouse input is on. Turn off Enable Mouse Input in Settings > Mouse."))
      return false
    }
    let store = ClickZoneStore.shared
    guard !store.isPreset(layoutID), let layout = store.layout(id: layoutID) else { return false }
    if clickZoneEditingLayout?.id == layoutID { return true }
    if isEditingClickZones { endClickZoneEditing() }
    clickZoneEditingLayout = layout
    selectedClickZoneID = nil
    cancelClickZonePlayer()
    clickZoneEditPausedEmulation = isRunning
    if isRunning { stop() }
    return true
  }

  /// Close the editing session, resuming emulation if the editor paused it.
  /// Every edit has already been saved.
  func endClickZoneEditing() {
    guard isEditingClickZones else { return }
    clickZoneEditingLayout = nil
    selectedClickZoneID = nil
    isRecordingClickZoneKeys = false
    if clickZoneEditPausedEmulation {
      clickZoneEditPausedEmulation = false
      start()
    }
  }

  /// Apply an edit to the working layout and save it.
  func editClickZones(_ edit: (inout ClickZoneLayout) -> Void) {
    guard var layout = clickZoneEditingLayout else { return }
    edit(&layout)
    clickZoneEditingLayout = layout
    ClickZoneStore.shared.update(layout)
  }

  /// Apply an edit to one zone of the working layout and save it.
  func editClickZone(id: UUID, _ edit: (inout ClickZone) -> Void) {
    editClickZones { layout in
      guard let i = layout.zones.firstIndex(where: { $0.id == id }) else { return }
      edit(&layout.zones[i])
    }
  }

  /// Add a zone drawn in the editor and select it.
  func addClickZone(rect: ClickZoneRect) {
    let zone = ClickZone(rect: rect)
    editClickZones { $0.zones.append(zone) }
    selectedClickZoneID = zone.id
  }

  func deleteSelectedClickZone() {
    guard let id = selectedClickZoneID else { return }
    editClickZones { $0.zones.removeAll { $0.id == id } }
    selectedClickZoneID = nil
  }
}
