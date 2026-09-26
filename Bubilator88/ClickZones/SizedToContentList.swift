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
