import SwiftUI

/// Click zones drawn over the emulator screen.
///
/// In play mode each zone is an invisible click target that outlines itself
/// on hover; everywhere else, clicks fall through to the views below. While
/// the editor is open the whole screen takes drags instead: on empty space to
/// draw a zone, inside a zone to move it, on the selected zone's handles to
/// resize it.
struct ClickZoneOverlayView: View {
  @Bindable var viewModel: EmulatorViewModel
  let fit: ScreenFit

  var body: some View {
    if viewModel.isEditingClickZones {
      ClickZoneEditLayer(viewModel: viewModel, fit: fit)
    } else if let layout = viewModel.activeClickZoneLayout {
      ClickZonePlayLayer(viewModel: viewModel, zones: layout.zones, fit: fit)
    }
  }
}

// MARK: - Play

private struct ClickZonePlayLayer: View {
  let viewModel: EmulatorViewModel
  let zones: [ClickZone]
  let fit: ScreenFit
  @State private var hovered: UUID?

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(zones) { zone in
        let frame = fit.toView(zone.rect.cgRect)
        Rectangle()
          .fill(Color.accentColor.opacity(hovered == zone.id ? 0.15 : 0))
          .strokeBorder(Color.accentColor.opacity(hovered == zone.id ? 0.8 : 0), lineWidth: 1)
          .contentShape(Rectangle())
          .frame(width: frame.width, height: frame.height)
          .offset(x: frame.minX, y: frame.minY)
          .onHover { inside in
            if inside {
              hovered = zone.id
            } else if hovered == zone.id {
              hovered = nil
            }
          }
          .pointerStyle(.link)
          .onTapGesture { viewModel.playClickZone(zone) }
          .help(zone.label)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

// MARK: - Edit

private struct ClickZoneEditLayer: View {
  @Bindable var viewModel: EmulatorViewModel
  let fit: ScreenFit

  /// What the current drag is doing, decided when it starts.
  private enum DragMode {
    case create(start: CGPoint)
    case move(id: UUID, original: ClickZoneRect, start: CGPoint)
    case resize(id: UUID, original: ClickZoneRect, handle: ClickZoneRect.Handle)
  }

  @State private var dragMode: DragMode?
  /// The rectangle being drawn, moved or resized, until the drag ends.
  @State private var preview: (id: UUID?, rect: ClickZoneRect)?

  /// Side of a resize handle, in view points.
  private static let handleSize: CGFloat = 8

  private var zones: [ClickZone] {
    viewModel.clickZoneEditingLayout?.zones ?? []
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Dims the screen slightly so it is obvious the machine is paused for
      // editing, and gives the whole area a hit shape for the drag.
      Color.black.opacity(0.2)
        .contentShape(Rectangle())

      ForEach(zones) { zone in
        let rect = preview?.id == zone.id ? preview!.rect : zone.rect
        zoneView(zone, rect: rect, selected: zone.id == viewModel.selectedClickZoneID)
      }
      if let preview, preview.id == nil {
        let frame = fit.toView(preview.rect.cgRect)
        Rectangle()
          .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .frame(width: frame.width, height: frame.height)
          .offset(x: frame.minX, y: frame.minY)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .gesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .local)
        .onChanged(dragChanged)
        .onEnded(dragEnded)
    )
    .pointerStyle(.rectSelection)
  }

  @ViewBuilder
  private func zoneView(_ zone: ClickZone, rect: ClickZoneRect, selected: Bool) -> some View {
    let frame = fit.toView(rect.cgRect)
    ZStack(alignment: .topLeading) {
      Rectangle()
        .fill(Color.accentColor.opacity(selected ? 0.3 : 0.15))
        .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 1)
      Text(Self.caption(for: zone))
        .font(.caption2)
        .lineLimit(1)
        .padding(.horizontal, 3)
        .background(Color.accentColor.opacity(0.8))
        .foregroundStyle(.white)
    }
    .frame(width: frame.width, height: frame.height, alignment: .topLeading)
    .clipped()
    .offset(x: frame.minX, y: frame.minY)

    if selected {
      ForEach(ClickZoneRect.Handle.allCases, id: \.self) { handle in
        let p = Self.handleCenter(handle, in: frame)
        Rectangle()
          .fill(.white)
          .strokeBorder(Color.accentColor, lineWidth: 1)
          .frame(width: Self.handleSize, height: Self.handleSize)
          .offset(x: p.x - Self.handleSize / 2, y: p.y - Self.handleSize / 2)
      }
    }
  }

  /// The label, or the key sequence when the zone has no label yet.
  private static func caption(for zone: ClickZone) -> String {
    if !zone.label.isEmpty { return zone.label }
    return zone.steps.map(\.displayName).joined(separator: " ")
  }

  private static func handleCenter(_ handle: ClickZoneRect.Handle, in frame: CGRect) -> CGPoint {
    let u = handle.unitPosition
    return CGPoint(x: frame.minX + frame.width * u.x, y: frame.minY + frame.height * u.y)
  }

  // MARK: Drag

  private func dragChanged(_ value: DragGesture.Value) {
    if dragMode == nil { dragMode = mode(forDragAt: value.startLocation) }
    let current = fit.toScreen(value.location)
    switch dragMode {
    case .create(let start):
      preview = (nil, ClickZoneRect(from: start, to: current))
    case .move(let id, let original, let start):
      let dx = Int((current.x - start.x).rounded())
      let dy = Int((current.y - start.y).rounded())
      preview = (id, original.moved(dx: dx, dy: dy))
    case .resize(let id, let original, let handle):
      preview = (id, original.resized(handle, to: current))
    case nil:
      break
    }
  }

  private func dragEnded(_ value: DragGesture.Value) {
    defer {
      dragMode = nil
      preview = nil
    }
    guard let preview else { return }
    switch dragMode {
    case .create:
      // A click on empty space (or a tiny drag) just clears the selection.
      if preview.rect.isUsable {
        viewModel.addClickZone(rect: preview.rect)
      } else {
        viewModel.selectedClickZoneID = nil
      }
    case .move(let id, let original, _), .resize(let id, let original, _):
      if preview.rect != original, preview.rect.isUsable {
        viewModel.editClickZone(id: id) { $0.rect = preview.rect }
      }
    case nil:
      break
    }
  }

  /// Decide what a drag starting at `location` (view points) does, selecting
  /// the zone it grabs.
  private func mode(forDragAt location: CGPoint) -> DragMode {
    let point = fit.toScreen(location)
    if let id = viewModel.selectedClickZoneID,
       let zone = zones.first(where: { $0.id == id }) {
      let frame = fit.toView(zone.rect.cgRect)
      let hit = Self.handleSize
      for handle in ClickZoneRect.Handle.allCases {
        let c = Self.handleCenter(handle, in: frame)
        if abs(c.x - location.x) <= hit, abs(c.y - location.y) <= hit {
          return .resize(id: id, original: zone.rect, handle: handle)
        }
      }
    }
    if let zone = zones.last(where: { $0.rect.contains(point) }) {
      viewModel.selectedClickZoneID = zone.id
      return .move(id: zone.id, original: zone.rect, start: point)
    }
    return .create(start: point)
  }
}
