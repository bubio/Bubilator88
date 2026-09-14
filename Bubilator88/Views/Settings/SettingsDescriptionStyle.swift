import SwiftUI

struct SettingsDescriptionStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(.subheadline)
      .foregroundStyle(.secondary)
  }
}

extension View {
  func settingsDescriptionStyle() -> some View {
    modifier(SettingsDescriptionStyle())
  }
}
