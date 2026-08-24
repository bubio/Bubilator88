import SwiftUI
import AppKit

@main
struct Bubilator88App: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var viewModel = EmulatorViewModel()
  @State private var showAbout = false

  var body: some Scene {
    Window("Bubilator88", id: "main") {
      ContentView(viewModel: viewModel)
        .onAppear { appDelegate.viewModel = viewModel }
        // `.b88script` double-click / "Open With" arrives here for both
        // cold-launch and warm (already-running) opens. requestScriptPlayback
        // plays immediately if the run loop is up, otherwise defers to
        // ContentView.onAppear's consumePendingScript() (cold launch may
        // fire onOpenURL before ROMs load). See AppDelegate for why this
        // lives in SwiftUI rather than application(_:open:).
        .onOpenURL { url in
          if url.scheme?.lowercased() == "bubilator88" {
            viewModel.requestLaunch(url: url)
          } else if url.pathExtension.lowercased() == "b88script" {
            viewModel.requestScriptPlayback(url: url)
          }
        }
        .windowResizeBehavior(.disabled)
        .windowFullScreenBehavior(.enabled)
        .sheet(isPresented: $showAbout) {
          AboutView()
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("OK") { showAbout = false }
                  .keyboardShortcut(.defaultAction)
              }
            }
        }
    }
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Bubilator88") {
          showAbout = true
        }
      }

      CommandGroup(replacing: .undoRedo) { }
      CommandGroup(replacing: .pasteboard) {
        Button("Copy Screen") { viewModel.copyScreenshotToClipboard() }
          .keyboardShortcut("c", modifiers: .command)
        Button("Copy Text") { viewModel.copyTextToPasteboard() }
          .keyboardShortcut("c", modifiers: [.command, .shift])
        Divider()
        Button("Paste Text") { viewModel.pasteTextFromPasteboard() }
          .keyboardShortcut("v", modifiers: .command)
      }
      CommandGroup(replacing: .textEditing) { }

      EmulatorCommands(viewModel: viewModel)
      ViewCommands(viewModel: viewModel)
      DiskCommands(viewModel: viewModel)
      ControlCommands(viewModel: viewModel)
      if viewModel.showDebugMenu {
        DebugCommands(viewModel: viewModel)
      }

      CommandGroup(replacing: .help) {
        Button("Bubilator88 Help") {
          if let bookName = Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String {
            NSHelpManager.shared.openHelpAnchor("bubilator88-help", inBook: bookName)
          }
        }
        .keyboardShortcut("?", modifiers: .command)
      }
    }

    SwiftUI.Settings {
      SettingsView(viewModel: viewModel)
        .environment(Settings.shared)
    }

    // Regular `Window` (not `UtilityWindow`) so the debugger can become
    // the key window — UtilityWindow uses an NSPanel with the
    // `.nonactivatingPanel` style mask, which leaves the title bar
    // perpetually dimmed because the panel never takes key status.
    Window("Debugger", id: "debugger") {
      DebugView(viewModel: viewModel)
    }
    .defaultSize(width: 960, height: 680)
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unifiedCompact)
    // The auto-generated "Debugger" menu entry in the standard
    // Window menu duplicates the one we already expose from the
    // Debug menu. Strip it.
    .commandsRemoved()

    // On-screen PC-8801 keyboard. Separate window so the emulation view
    // keeps driving frames; clicks feed the matrix via the ViewModel.
    Window("Software Keyboard", id: "software-keyboard") {
      SoftwareKeyboardView(viewModel: viewModel)
        .windowResizeBehavior(.disabled)
    }
    .windowResizability(.contentSize)
    .defaultPosition(.bottom)
    // The View menu already exposes "Software Keyboard"; drop the
    // auto-generated Window menu duplicate.
    .commandsRemoved()
  }
}
