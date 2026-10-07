import AppKit
import Bubilator88Core
import Observation
import SwiftUI

/// Installs the emulator's Touch Bar on the window this view lands in.
///
/// Built on `NSTouchBar` rather than SwiftUI's `.touchBar`: SwiftUI renders its
/// buttons in the regular control style, which neither matches the system's own
/// Touch Bar buttons (esc, the Control Strip) nor honours tinting. A plain
/// `NSButton` is drawn by the Touch Bar in the system style.
struct TouchBarInstaller: NSViewRepresentable {

  let viewModel: EmulatorViewModel

  func makeNSView(context: Context) -> TouchBarInstallerView {
    TouchBarInstallerView(viewModel: viewModel)
  }

  func updateNSView(_ nsView: TouchBarInstallerView, context: Context) {}
}

final class TouchBarInstallerView: NSView {

  private let viewModel: EmulatorViewModel
  private var controller: EmulatorTouchBarController?

  init(viewModel: EmulatorViewModel) {
    self.viewModel = viewModel
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    controller?.uninstall()
    controller = nil
    if let window {
      let controller = EmulatorTouchBarController(viewModel: viewModel, window: window)
      controller.install()
      self.controller = controller
    }
  }
}

/// A main bar (a way into the state bar and the PC-8801 keys a Mac keyboard
/// cannot type directly), a slot bar with a horizontally scrolling strip of
/// the save-state slots, and a detail bar for the chosen slot.
///
/// Choosing a slot swaps the bar for Load and Save plus that slot's thumbnail,
/// date and drive 1 file name, so what a Save would overwrite is on screen when
/// it is tapped. Loading returns to the main bar; saving stays on the detail
/// bar, which then shows the fresh thumbnail as confirmation.
@MainActor
final class EmulatorTouchBarController: NSObject, NSTouchBarDelegate, NSScrubberDataSource, NSScrubberDelegate {

  private enum Page: Equatable {
    case main
    case slots
    case detail(Int)
  }

  private let viewModel: EmulatorViewModel
  private weak var window: NSWindow?
  private var page: Page = .main
  private var lastRevision: Int

  // Buttons whose state follows the view model.
  private var stateButton: NSButton?
  private var tapButtons: [PC88Key: NSButton] = [:]
  private var lockButtons: [PC88Key: NSButton] = [:]
  private var loadButton: NSButton?
  private var saveButton: NSButton?

  private static let slots = SaveSlotList.slots
  /// Width of the scrolling slot strip. The app region is only about 650pt
  /// wide (the system Control Strip takes the right side), less the close
  /// button and its gap; the Touch Bar drops an item that does not fit rather
  /// than clipping it, so this must stay well inside that.
  private static let slotStripWidth: CGFloat = 540
  /// A Touch Bar item is 30pt tall.
  private static let slotItemIdentifier = NSUserInterfaceItemIdentifier("slot")
  private static let slotStripHeight: CGFloat = 30
  /// Detail-bar thumbnail.
  private static let thumbSize = NSSize(width: 44, height: 28)
  /// Thumbnail drawn inside each slot item, centred in an item of
  /// `slotButtonWidth`.
  private static let slotThumbSize = NSSize(width: 42, height: 26)
  private static let slotButtonWidth: CGFloat = 52
  private static let slotSpacing: CGFloat = 4
  private static let thumbnailBorderWidth: CGFloat = 2
  /// Widest the detail line may grow, leaving room for the buttons beside it.
  private static let infoMaxWidth: CGFloat = 460
  /// How long a tapped key stays down; one frame is too short for the BASIC
  /// keyboard scan to notice.
  private static let keyTapDuration: Duration = .milliseconds(50)

  /// PC-8801 keys with no direct equivalent on a Mac keyboard.
  private static let tappedKeys: [(label: String, key: PC88Key)] = [
    ("STOP", .stop),
    ("画面消去", .clr),
    ("HELP", .help),
    ("INS", .ins),
    ("BS", .bs),
  ]

  /// Keys held until tapped again.
  private static let lockKeys: [(label: String, key: PC88Key)] = [
    ("GRPH", .grph),
    ("カナ", .kana),
  ]

  init(viewModel: EmulatorViewModel, window: NSWindow) {
    self.viewModel = viewModel
    self.window = window
    self.lastRevision = viewModel.saveStateRevision
    super.init()
  }

  // MARK: - Lifecycle

  func install() {
    window?.touchBar = makeBar(for: page)
    observe()
  }

  func uninstall() {
    window?.touchBar = nil
    for lock in Self.lockKeys where viewModel.heldKeys.contains(lock.key) {
      viewModel.releaseKey(lock.key)
    }
  }

  /// Re-arming observation of everything the bars display. `onChange` fires
  /// before the value changes, so the refresh hops to a task to see the new one.
  private func observe() {
    withObservationTracking {
      _ = viewModel.saveStateRevision
      _ = viewModel.allows(.state)
      _ = viewModel.allows(.input)
      _ = viewModel.heldKeys
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.viewModelChanged()
        self?.observe()
      }
    }
  }

  private func viewModelChanged() {
    if viewModel.saveStateRevision != lastRevision {
      lastRevision = viewModel.saveStateRevision
      // Thumbnails and the detail line come from the state files.
      if page != .main { show(page) }
    }
    refreshButtons()
  }

  private func show(_ newPage: Page) {
    page = newPage
    window?.touchBar = makeBar(for: newPage)
  }

  private func refreshButtons() {
    stateButton?.isEnabled = viewModel.allows(.state)
    let inputAllowed = viewModel.allows(.input)
    for button in tapButtons.values { button.isEnabled = inputAllowed }
    for (key, button) in lockButtons {
      button.isEnabled = inputAllowed
      button.bezelColor = viewModel.heldKeys.contains(key) ? .controlAccentColor : nil
    }
    let stateAllowed = viewModel.allows(.state)
    if case .detail(let slot) = page {
      loadButton?.isEnabled = stateAllowed && viewModel.hasState(slot: slot)
      saveButton?.isEnabled = stateAllowed
    }
  }

  // MARK: - Bars

  private func makeBar(for page: Page) -> NSTouchBar {
    stateButton = nil
    tapButtons = [:]
    lockButtons = [:]
    loadButton = nil
    saveButton = nil

    let bar = NSTouchBar()
    bar.delegate = self
    switch page {
    case .main:
      // The gap after State matches the one the system leaves after esc.
      let keys = Self.tappedKeys.map(\.label) + Self.lockKeys.map(\.label)
      bar.defaultItemIdentifiers = [Item.state.identifier, .fixedSpaceSmall] + keys.map { Item.key($0).identifier }
    case .slots:
      bar.defaultItemIdentifiers = [Item.close.identifier, .fixedSpaceLarge, Item.slots.identifier]
    case .detail(let slot):
      bar.defaultItemIdentifiers = [Item.back, .load(slot), .save(slot), .thumbnail(slot), .info(slot)].map(\.identifier)
    }
    return bar
  }

  func touchBar(_ touchBar: NSTouchBar,
                makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
    guard let view = makeView(for: Item(identifier)) else { return nil }
    let item = NSCustomTouchBarItem(identifier: identifier)
    item.view = view
    // Enabled states depend on the view model; apply them once the page's
    // buttons exist.
    DispatchQueue.main.async { [weak self] in self?.refreshButtons() }
    return item
  }

  private func makeView(for item: Item?) -> NSView? {
    switch item {
    case .state:
      let title = String(localized: "State", comment: "Touch Bar button that opens the save-state slots")
      let button = ActionButton(title: title) { [weak self] in self?.show(.slots) }
      stateButton = button
      return button
    case .slots:
      // A scrubber scrolls, which thirty slots need; its flow layout keeps the
      // gaps tighter than the Touch Bar's own spacing between items. The Touch
      // Bar sizes an item by its intrinsic size, which a scrubber lacks, so it
      // sits in a view that supplies one.
      let layout = NSScrubberFlowLayout()
      layout.itemSize = NSSize(width: Self.slotButtonWidth, height: Self.slotStripHeight)
      layout.itemSpacing = Self.slotSpacing
      let size = NSSize(width: Self.slotStripWidth, height: Self.slotStripHeight)
      let scrubber = NSScrubber(frame: NSRect(origin: .zero, size: size))
      scrubber.autoresizingMask = [.width, .height]
      scrubber.scrubberLayout = layout
      scrubber.mode = .free
      scrubber.showsAdditionalContentIndicators = true
      scrubber.register(NSScrubberImageItemView.self, forItemIdentifier: Self.slotItemIdentifier)
      scrubber.dataSource = self
      scrubber.delegate = self
      scrubber.selectionOverlayStyle = .outlineOverlay
      scrubber.selectionBackgroundStyle = .outlineOverlay
      // Open on the slot last used.
      if let last = viewModel.lastUsedSlot, Self.slots.contains(last) {
        scrubber.scrollItem(at: last - Self.slots.lowerBound, to: .center)
      }
      let container = FixedSizeView(size: size)
      container.addSubview(scrubber)
      return container
    case .close:
      // A round close button, like the one the system draws for its own bars.
      let configuration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        .applying(.init(hierarchicalColor: .lightGray))
      let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
      let button = ActionButton(image: image) { [weak self] in self?.show(.main) }
      button.isBordered = false
      return button
    case .back:
      let image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
      return ActionButton(image: image) { [weak self] in self?.show(.slots) }
    case .load(let slot):
      let button = ActionButton(title: String(localized: "Load", comment: "")) { [weak self] in
        self?.viewModel.loadState(slot: slot)
        self?.show(.main)
      }
      loadButton = button
      return button
    case .save(let slot):
      let button = ActionButton(title: String(localized: "Save to Slot", comment: "")) { [weak self] in
        self?.viewModel.saveState(slot: slot)
      }
      saveButton = button
      return button
    case .thumbnail(let slot):
      return NSImageView(image: Self.thumbnailImage(viewModel.slotThumbnail(slot), number: slot))
    case .info(let slot):
      let label = NSTextField(labelWithString: infoText(slot))
      label.font = .systemFont(ofSize: NSFont.systemFontSize)
      label.lineBreakMode = .byTruncatingMiddle
      label.textColor = viewModel.hasState(slot: slot) ? .labelColor : .secondaryLabelColor
      label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.infoMaxWidth).isActive = true
      return label
    case .key(let label):
      if let entry = Self.tappedKeys.first(where: { $0.label == label }) {
        let button = ActionButton(title: label) { [weak self] in self?.tap(entry.key) }
        tapButtons[entry.key] = button
        return button
      }
      if let entry = Self.lockKeys.first(where: { $0.label == label }) {
        let button = ActionButton(title: label) { [weak self] in self?.toggleHeld(entry.key) }
        lockButtons[entry.key] = button
        return button
      }
      return nil
    case nil:
      return nil
    }
  }

  // MARK: - Slot scrubber

  func numberOfItems(for scrubber: NSScrubber) -> Int { Self.slots.count }

  func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
    let slot = Self.slots.lowerBound + index
    let view = scrubber.makeItem(withIdentifier: Self.slotItemIdentifier, owner: nil) as? NSScrubberImageItemView
      ?? NSScrubberImageItemView()
    view.image = Self.thumbnailImage(viewModel.slotThumbnail(slot), number: slot, size: Self.slotThumbSize, borderWidth: 0)
    view.imageView.imageScaling = .scaleNone
    return view
  }

  func scrubber(_ scrubber: NSScrubber, didSelectItemAt selectedIndex: Int) {
    let slot = Self.slots.lowerBound + selectedIndex
    viewModel.lastUsedSlot = slot
    show(.detail(slot))
  }

  // MARK: - Actions

  /// Hold `key` down until tapped again, as the real KANA lock does and as a
  /// modifier needs to be to combine with a key typed elsewhere.
  private func toggleHeld(_ key: PC88Key) {
    if viewModel.heldKeys.contains(key) {
      viewModel.releaseKey(key)
    } else {
      viewModel.pressKey(key)
    }
  }

  private func tap(_ key: PC88Key) {
    viewModel.pressKey(key)
    Task { @MainActor [viewModel] in
      try? await Task.sleep(for: Self.keyTapDuration)
      viewModel.releaseKey(key)
    }
  }

  // MARK: - Helpers

  /// "date  drive 1 file name", or "Empty".
  private func infoText(_ slot: Int) -> String {
    guard viewModel.hasState(slot: slot) else { return String(localized: "Empty") }
    let path = viewModel.saveStatePath(forSlot: slot)
    let modified = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
    let format = DateFormatter.stable(pattern: "MM/dd HH:mm")
    // The mounted file's name, falling back to the name stored in the disk image.
    let meta = viewModel.loadSlotMeta(slot)
    let diskName = (meta?.drive0FileName ?? meta?.disk0) ?? ""
    return [modified.map(format.string(from:)), diskName.isEmpty ? nil : diskName]
      .compactMap { $0 }.joined(separator: "  ")
  }

  /// A slot's thumbnail, rounded and optionally bordered. Only an empty slot
  /// shows its number; a filled one is told apart by its picture.
  private static func thumbnailImage(_ thumbnail: NSImage?, number: Int, size: NSSize = thumbSize,
                                     borderWidth: CGFloat = thumbnailBorderWidth) -> NSImage {
    NSImage(size: size, flipped: false) { rect in
      let inset = borderWidth / 2
      let shape = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: 4, yRadius: 4)
      NSGraphicsContext.saveGraphicsState()
      shape.addClip()
      if let thumbnail {
        // Aspect-fill.
        let scale = max(rect.width / thumbnail.size.width, rect.height / thumbnail.size.height)
        let size = NSSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
        thumbnail.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                                  width: size.width, height: size.height))
      } else {
        NSColor.black.withAlphaComponent(0.6).setFill()
        rect.fill()
      }
      NSGraphicsContext.restoreGraphicsState()

      if thumbnail == nil {
        let text = NSAttributedString(string: "\(number)", attributes: [
          .font: NSFont.boldSystemFont(ofSize: 12),
          .foregroundColor: NSColor.white,
        ])
        let textSize = text.size()
        text.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2))
      }

      if borderWidth > 0 {
        NSColor.white.withAlphaComponent(0.6).setStroke()
        shape.lineWidth = borderWidth
        shape.stroke()
      }
      return true
    }
  }
}

// MARK: - Items

/// Everything the bars can hold, and its Touch Bar identifier. Slot-specific
/// items carry their slot, so an item built late still belongs to the slot it
/// was asked for.
private enum Item {
  case state, slots, close, back
  case load(Int), save(Int), thumbnail(Int), info(Int)
  /// An entry of `tappedKeys` or `lockKeys`, by its label.
  case key(String)

  private static let prefix = "com.bubio.Bubilator88.touchbar."

  var identifier: NSTouchBarItem.Identifier {
    let name: String
    switch self {
    case .state: name = "state"
    case .slots: name = "slots"
    case .close: name = "close"
    case .back: name = "back"
    case .load(let slot): name = "load.\(slot)"
    case .save(let slot): name = "save.\(slot)"
    case .thumbnail(let slot): name = "thumbnail.\(slot)"
    case .info(let slot): name = "info.\(slot)"
    case .key(let label): name = "key.\(label)"
    }
    return NSTouchBarItem.Identifier(Self.prefix + name)
  }

  init?(_ identifier: NSTouchBarItem.Identifier) {
    let raw = identifier.rawValue
    guard raw.hasPrefix(Self.prefix) else { return nil }
    let parts = raw.dropFirst(Self.prefix.count).split(separator: ".", maxSplits: 1).map(String.init)
    let argument = parts.count > 1 ? parts[1] : nil
    let slot = argument.flatMap { Int($0) }
    switch (parts.first, slot, argument) {
    case ("state", _, _): self = .state
    case ("slots", _, _): self = .slots
    case ("close", _, _): self = .close
    case ("back", _, _): self = .back
    case ("load", let slot?, _): self = .load(slot)
    case ("save", let slot?, _): self = .save(slot)
    case ("thumbnail", let slot?, _): self = .thumbnail(slot)
    case ("info", let slot?, _): self = .info(slot)
    case ("key", _, let label?): self = .key(label)
    default: return nil
    }
  }
}

// MARK: - Fixed-size container

/// Reports a fixed intrinsic size, for views the Touch Bar cannot size itself.
private final class FixedSizeView: NSView {

  private let size: NSSize

  init(size: NSSize) {
    self.size = size
    super.init(frame: NSRect(origin: .zero, size: size))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var intrinsicContentSize: NSSize { size }
}

// MARK: - Button

/// A Touch Bar button, running a closure on tap.
private final class ActionButton: NSButton {

  private let handler: () -> Void

  init(title: String = "", image: NSImage? = nil, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(frame: .zero)
    self.title = title
    self.image = image
    // The bezel is deliberately left at its default: a Touch Bar draws an
    // `NSButton` in its own style, and forcing one here left the button blank.
    target = self
    action = #selector(fire)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  @objc private func fire() { handler() }
}
