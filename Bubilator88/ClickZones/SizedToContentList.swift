import AppKit
import SwiftUI

/// Sizes a List to its rows and turns its own scrolling off.
///
/// A List nested in a grouped Form's scroll view could not be scrolled, so
/// lists inside Forms grow to their content and the Form scrolls everything.
private struct SizedToContentList: ViewModifier {
  @State private var height: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .onScrollGeometryChange(for: CGFloat.self) { geo in
        geo.contentSize.height + geo.contentInsets.top + geo.contentInsets.bottom
      } action: { _, newHeight in
        height = newHeight
      }
      .frame(height: max(height, 28))
      .scrollDisabled(true)
  }
}

extension View {
  func sizedToContentList() -> some View {
    modifier(SizedToContentList())
  }
}

/// Hands keyboard focus to the enclosing List when `value` (its selection)
/// changes.
///
/// A List in a grouped Form selects a clicked row without taking first
/// responder: it stays with the window's hosting view, so the arrow keys,
/// Return and Delete never reach the list. Searching up from the view this
/// sits behind finds the list's own table view.
private struct FocusListOnChange<Value: Equatable>: ViewModifier {
  let value: Value

  func body(content: Content) -> some View {
    content.background(ListFocuser(value: value))
  }
}

private struct ListFocuser<Value: Equatable>: NSViewRepresentable {
  let value: Value

  final class Coordinator {
    var last: Value?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ view: NSView, context: Context) {
    // The first pass only records the starting selection.
    guard let last = context.coordinator.last else {
      context.coordinator.last = value
      return
    }
    guard last != value else { return }
    context.coordinator.last = value
    DispatchQueue.main.async { [weak view] in
      guard let view, let window = view.window, window.isKeyWindow,
            let table = Self.nearestTable(above: view) else { return }
      if window.firstResponder !== table { window.makeFirstResponder(table) }
    }
  }

  /// The table view nearest above `view` that has one in its subtree.
  private static func nearestTable(above view: NSView) -> NSTableView? {
    func table(in view: NSView) -> NSTableView? {
      if let t = view as? NSTableView { return t }
      for sub in view.subviews { if let t = table(in: sub) { return t } }
      return nil
    }
    var ancestor = view.superview
    while let a = ancestor {
      if let t = table(in: a) { return t }
      ancestor = a.superview
    }
    return nil
  }
}

extension View {
  func focusListOnChange<Value: Equatable>(of value: Value) -> some View {
    modifier(FocusListOnChange(value: value))
  }
}
