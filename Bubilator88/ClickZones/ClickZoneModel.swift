import Bubilator88Core
import CoreGraphics
import Foundation

// Control zones let a game with no mouse support be played with the mouse: a
// rectangle on the 640×400 screen, clicked, types a registered key sequence.
// Zones are grouped into named layouts, and each disk is assigned a layout.
// Disks are identified by file name and D88 image name rather than by path
// (which breaks when the file moves) or by content hash (which write-back
// changes).

/// Identifies a disk that a layout is assigned to.
///
/// Equality ignores letter case and Unicode normalization of the file name:
/// macOS hands back decomposed (NFD) names for some volumes, and the same file
/// copied elsewhere may differ only in case.
nonisolated struct ClickZoneDiskKey: Codable, Hashable, Sendable {
  var fileName: String
  var imageName: String

  init(fileName: String, imageName: String) {
    self.fileName = fileName
    self.imageName = imageName
  }

  /// The key for a mounted disk: the original archive's name for an
  /// archive-backed disk (not the extracted cache file), and the name of the
  /// D88 image currently selected in the drive.
  init(info: MountedDiskInfo) {
    let file = info.originArchiveURL?.lastPathComponent
      ?? info.sourceURL?.lastPathComponent
      ?? info.fileName
    let image = info.imageNames.indices.contains(info.currentImageIndex)
      ? info.imageNames[info.currentImageIndex] : ""
    self.init(fileName: file, imageName: image)
  }

  private var normalized: (String, String) {
    (fileName.precomposedStringWithCanonicalMapping.lowercased(),
     imageName.precomposedStringWithCanonicalMapping)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.normalized == rhs.normalized
  }

  /// Whether both keys name the same file, whatever the image.
  func isSameFile(as other: Self) -> Bool {
    normalized.0 == other.normalized.0
  }

  func hash(into hasher: inout Hasher) {
    let (f, i) = normalized
    hasher.combine(f)
    hasher.combine(i)
  }

  /// "file.d88 — IMAGE", or just the file name when the image has no name.
  var displayName: String {
    imageName.isEmpty ? fileName : "\(fileName) — \(imageName)"
  }
}

/// One step of a zone's key sequence: the keys held together, how long they
/// are held, and the pause before the next step. Keys are stored by their
/// b88script names (`ScriptWriter.keyName(for:)`), so the file stays readable
/// and survives any change to `PC88Key`'s layout.
nonisolated struct ClickZoneStep: Codable, Equatable, Hashable, Sendable {
  var keys: [String]
  var holdFrames: Int
  var gapFrames: Int

  /// Defaults match `TextPasteQueue`'s 12-frame cadence, which games that poll
  /// the keyboard slowly are known to accept.
  init(keys: [String], holdFrames: Int = 6, gapFrames: Int = 6) {
    self.keys = keys
    self.holdFrames = holdFrames
    self.gapFrames = gapFrames
  }

  private enum CodingKeys: String, CodingKey { case keys, holdFrames, gapFrames }

  /// The timings may be left out, so preset files can be written by hand.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(keys: try c.decode([String].self, forKey: .keys),
              holdFrames: try c.decodeIfPresent(Int.self, forKey: .holdFrames) ?? 6,
              gapFrames: try c.decodeIfPresent(Int.self, forKey: .gapFrames) ?? 6)
  }

  /// The keys this step presses; names that no longer resolve are dropped.
  var resolvedKeys: [PC88Key] {
    keys.compactMap { ScriptParser.key(named: $0) }
  }

  /// "SHIFT+1", for display.
  var displayName: String {
    keys.map { $0.uppercased() }.joined(separator: "+")
  }
}

/// A rectangle in 640×400 screen pixels.
nonisolated struct ClickZoneRect: Codable, Equatable, Hashable, Sendable {
  static let screenWidth = 640
  static let screenHeight = 400
  /// Smallest width/height a drawn zone may have.
  static let minimumSize = 4

  var x: Int
  var y: Int
  var width: Int
  var height: Int

  init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  /// The pixel-snapped rectangle spanning two screen points, in either order,
  /// clamped to the screen.
  init(from a: CGPoint, to b: CGPoint) {
    func clampX(_ v: CGFloat) -> Int { min(max(Int(v.rounded(.down)), 0), Self.screenWidth) }
    func clampY(_ v: CGFloat) -> Int { min(max(Int(v.rounded(.down)), 0), Self.screenHeight) }
    let x0 = clampX(min(a.x, b.x)), x1 = clampX(max(a.x, b.x))
    let y0 = clampY(min(a.y, b.y)), y1 = clampY(max(a.y, b.y))
    self.init(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }

  var cgRect: CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }

  var isUsable: Bool {
    width >= Self.minimumSize && height >= Self.minimumSize
  }

  func contains(_ p: CGPoint) -> Bool {
    cgRect.contains(p)
  }

  /// Brought to at least the minimum size and wholly on screen, keeping the
  /// size where it fits. Used for values typed into the editor.
  func clamped() -> ClickZoneRect {
    let w = min(max(width, Self.minimumSize), Self.screenWidth)
    let h = min(max(height, Self.minimumSize), Self.screenHeight)
    return ClickZoneRect(x: min(max(x, 0), Self.screenWidth - w),
                         y: min(max(y, 0), Self.screenHeight - h),
                         width: w, height: h)
  }

  /// Moved by a pixel delta, kept wholly on screen.
  func moved(dx: Int, dy: Int) -> ClickZoneRect {
    ClickZoneRect(x: min(max(x + dx, 0), Self.screenWidth - width),
                  y: min(max(y + dy, 0), Self.screenHeight - height),
                  width: width, height: height)
  }

  /// A corner or edge handle of a zone being resized.
  enum Handle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Where the handle sits on `rect`, as a fraction of its size.
    var unitPosition: CGPoint {
      switch self {
      case .topLeft: CGPoint(x: 0, y: 0)
      case .top: CGPoint(x: 0.5, y: 0)
      case .topRight: CGPoint(x: 1, y: 0)
      case .right: CGPoint(x: 1, y: 0.5)
      case .bottomRight: CGPoint(x: 1, y: 1)
      case .bottom: CGPoint(x: 0.5, y: 1)
      case .bottomLeft: CGPoint(x: 0, y: 1)
      case .left: CGPoint(x: 0, y: 0.5)
      }
    }
  }

  /// Resized by dragging `handle` to `point`. The opposite corner or edge
  /// stays put; dragging past it flips the rectangle instead of inverting it.
  func resized(_ handle: Handle, to point: CGPoint) -> ClickZoneRect {
    let u = handle.unitPosition
    var a = CGPoint(x: x, y: y)
    var b = CGPoint(x: x + width, y: y + height)
    if u.x == 0 { a.x = point.x } else if u.x == 1 { b.x = point.x }
    if u.y == 0 { a.y = point.y } else if u.y == 1 { b.y = point.y }
    return ClickZoneRect(from: a, to: b)
  }
}

nonisolated struct ClickZone: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var label: String
  var rect: ClickZoneRect
  var steps: [ClickZoneStep]

  init(id: UUID = UUID(), label: String = "", rect: ClickZoneRect, steps: [ClickZoneStep] = []) {
    self.id = id
    self.label = label
    self.rect = rect
    self.steps = steps
  }

  private enum CodingKeys: String, CodingKey { case id, label, rect, steps }

  /// `id` and `label` may be left out, so preset files can be written by hand.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    rect = try c.decode(ClickZoneRect.self, forKey: .rect)
    steps = try c.decode([ClickZoneStep].self, forKey: .steps)
  }
}

/// A mouse input other than a left click that a layout can bind to a key
/// sequence. The raw values are the keys of `ClickZoneLayout.mouseBindings`.
nonisolated enum ClickZoneMouseButton: String, Codable, CaseIterable, Identifiable, Sendable {
  case right, button4, button5, wheelUp, wheelDown

  var id: String { rawValue }

  /// The button for an `NSEvent.buttonNumber` of a right or other mouse
  /// button. Button 0 is the left one, which clicks zones; button 2, the
  /// middle one, is turbo and cannot be bound.
  init?(buttonNumber: Int) {
    switch buttonNumber {
    case 1: self = .right
    case 3: self = .button4
    case 4: self = .button5
    default: return nil
    }
  }

  var isWheel: Bool { self == .wheelUp || self == .wheelDown }
}

/// A named set of zones and mouse-button bindings. Bundled presets and the
/// user's own layouts share this type; which one a layout is follows from
/// where `ClickZoneStore` keeps it.
nonisolated struct ClickZoneLayout: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var name: String
  var zones: [ClickZone]
  /// Key sequences of the other mouse inputs, by `ClickZoneMouseButton.rawValue`.
  /// A string key keeps the JSON an object that can be written by hand.
  var mouseBindings: [String: [ClickZoneStep]]

  init(id: UUID = UUID(), name: String, zones: [ClickZone] = [],
       mouseBindings: [String: [ClickZoneStep]] = [:]) {
    self.id = id
    self.name = name
    self.zones = zones
    self.mouseBindings = mouseBindings
  }

  private enum CodingKeys: String, CodingKey { case id, name, zones, mouseBindings }

  /// The bindings a layout starts with, and gets when its file has none.
  static let defaultMouseBindings: [String: [ClickZoneStep]] = [
    ClickZoneMouseButton.right.rawValue: [ClickZoneStep(keys: ["shift"])],
    ClickZoneMouseButton.button4.rawValue: [ClickZoneStep(keys: ["return"])],
    ClickZoneMouseButton.button5.rawValue: [ClickZoneStep(keys: ["esc"])],
    ClickZoneMouseButton.wheelUp.rawValue: [ClickZoneStep(keys: ["kp8"])],
    ClickZoneMouseButton.wheelDown.rawValue: [ClickZoneStep(keys: ["kp2"])],
  ]

  /// `mouseBindings` may be left out, as in layouts saved before it existed
  /// and in hand-written presets: they get the defaults. One that is present,
  /// even empty, is kept, so unbinding every input sticks.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    zones = try c.decode([ClickZone].self, forKey: .zones)
    mouseBindings = try c.decodeIfPresent([String: [ClickZoneStep]].self, forKey: .mouseBindings)
      ?? Self.defaultMouseBindings
  }

  /// The keys `button` types, empty when it is unbound.
  func steps(for button: ClickZoneMouseButton) -> [ClickZoneStep] {
    mouseBindings[button.rawValue] ?? []
  }

  /// Bind `button` to `steps`; no steps unbinds it.
  mutating func setSteps(_ steps: [ClickZoneStep], for button: ClickZoneMouseButton) {
    mouseBindings[button.rawValue] = steps.isEmpty ? nil : steps
  }
}

/// Which layout a disk uses. One layout can serve several disks, such as
/// every disk of a multi-disk game.
nonisolated struct ClickZoneAssignment: Codable, Hashable, Sendable {
  var disk: ClickZoneDiskKey
  var layoutID: UUID
}

/// One file in the editor's disk list: its images, each of which can be
/// assigned on its own, or all at once from the file's row.
nonisolated struct ClickZoneDiskFile: Equatable, Identifiable {
  let fileName: String
  let images: [ClickZoneDiskKey]

  var id: String { fileName }

  /// The files to list: every mounted file with all of its images, whichever
  /// drive holds it, then the files of `assigned` disks that are not mounted,
  /// with just those disks.
  static func list(mounted: [MountedDiskInfo], assigned: [ClickZoneDiskKey]) -> [ClickZoneDiskFile] {
    var files: [ClickZoneDiskFile] = []
    for info in mounted {
      let current = ClickZoneDiskKey(info: info)
      guard !files.contains(where: { $0.images.first?.isSameFile(as: current) ?? false }) else { continue }
      // Images may share a name; they then share a key, so list it once.
      var images: [ClickZoneDiskKey] = []
      for name in info.imageNames {
        let key = ClickZoneDiskKey(fileName: current.fileName, imageName: name)
        if !images.contains(key) { images.append(key) }
      }
      files.append(ClickZoneDiskFile(fileName: current.fileName, images: images))
    }
    for disk in assigned {
      if let i = files.firstIndex(where: { $0.images.first?.isSameFile(as: disk) ?? false }) {
        if !files[i].images.contains(disk) {
          files[i] = ClickZoneDiskFile(fileName: files[i].fileName, images: files[i].images + [disk])
        }
      } else {
        files.append(ClickZoneDiskFile(fileName: disk.fileName, images: [disk]))
      }
    }
    return files
  }
}

/// The contents of an exported `.b88zones` file: one layout without its ID,
/// which the importing side issues afresh.
nonisolated struct ClickZoneLayoutFile: Codable, Sendable {
  var name: String
  var zones: [ClickZone]
  var mouseBindings: [String: [ClickZoneStep]]

  init(name: String, zones: [ClickZone], mouseBindings: [String: [ClickZoneStep]] = [:]) {
    self.name = name
    self.zones = zones
    self.mouseBindings = mouseBindings
  }

  private enum CodingKeys: String, CodingKey { case name, zones, mouseBindings }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    zones = try c.decode([ClickZone].self, forKey: .zones)
    mouseBindings = try c.decodeIfPresent([String: [ClickZoneStep]].self, forKey: .mouseBindings)
      ?? ClickZoneLayout.defaultMouseBindings
  }
}
