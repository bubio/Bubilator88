import SwiftUI

/// View Menu (appended to system View menu)
struct ViewCommands: Commands {
  @Bindable var viewModel: EmulatorViewModel
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Divider()

      Button {
        openWindow(id: "software-keyboard")
      } label: {
        Text("Software Keyboard")
      }
      .keyboardShortcut("k", modifiers: [.command, .shift])

      Divider()

      Button {
        withAnimation(.easeOut(duration: 0.35)) {
          viewModel.windowScale = 1
        }
      } label: {
        Text("Actual Size (x1)")
      }
      .keyboardShortcut("1", modifiers: [.command, .control])
      .disabled(viewModel.isFullScreen)

      Button {
        withAnimation(.easeOut(duration: 0.35)) {
          viewModel.windowScale = 2
        }
      } label: {
        Text("Double Size (x2)")
      }
      .keyboardShortcut("2", modifiers: [.command, .control])
      .disabled(viewModel.isFullScreen)

      Button {
        withAnimation(.easeOut(duration: 0.35)) {
          viewModel.windowScale = 4
        }
      } label: {
        Text("Quad Size (x4)")
      }
      .keyboardShortcut("4", modifiers: [.command, .control])
      .disabled(viewModel.isFullScreen)

      Divider()

      Toggle(isOn: $viewModel.scanlineEnabled) {
        Label("Scanlines", systemImage: "line.3.horizontal")
      }
      .disabled(!viewModel.isScanlineAvailable)

      Divider()

      // Toggles rather than an inline Picker: the menu items SwiftUI builds
      // from an inline Picker ignore `.disabled`, on the Picker and on its
      // items alike, and the filter must be frozen while the AI model
      // download sheet is up.
      Section("Video Filter") {
        ForEach(EmulatorViewModel.VideoFilter.allCases, id: \.self) { filter in
          Toggle(filter.rawValue, isOn: Binding(
            get: { viewModel.videoFilter == filter },
            set: { if $0 { viewModel.videoFilter = filter } }
          ))
          .disabled(viewModel.aiModelDownload != nil)
        }
      }

      Divider()

      // Not a pass-through: the getter reads the manager's own flag while the
      // setter goes through `toggleTranslation`, which tears the session up or
      // down. `@Bindable` cannot express that.
      Toggle(isOn: Binding(
        get: { viewModel.translationManager.isEnabled },
        set: { viewModel.toggleTranslation($0) }
      )) {
        Label("Translation Overlay", systemImage: "translate")
      }
      .keyboardShortcut("t", modifiers: .command)

      Divider()
    }
  }
}
