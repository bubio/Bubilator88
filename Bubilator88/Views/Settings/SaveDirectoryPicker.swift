import SwiftUI

struct SaveDirectoryPicker: View {
  let directory: String
  let setDirectory: (String) -> Void

  var body: some View {
    HStack {
      Text(directory)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.head)
      Spacer()
      Button("Choose...", action: chooseDirectory)
    }
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Select"
    if panel.runModal() == .OK, let url = panel.url {
      setDirectory(url.path)
    }
  }
}
