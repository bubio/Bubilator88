import SwiftUI

/// Confirms, runs and reports a one-time AI model download. Every exit goes
/// through the view model, which owns pausing and resuming emulation.
///
/// Reads the session from the view model on each render rather than taking it
/// as a value, so progress updates reach the sheet whatever `.sheet(item:)`
/// does with an item whose identity has not changed.
struct AIModelDownloadSheet: View {
  let viewModel: EmulatorViewModel

  var body: some View {
    if let session = viewModel.aiModelDownload {
      content(session)
    }
  }

  private func content(_ session: AIModelDownloadSession) -> some View {
    let totalSize = ByteCountFormatter.string(fromByteCount: session.model.byteCount, countStyle: .file)
    return VStack(alignment: .leading, spacing: 16) {
      Label("Download AI Model", systemImage: "arrow.down.circle")
        .font(.headline)

      switch session.phase {
      case .confirm:
        Text("“\(session.filter.rawValue)” needs an additional model (\(totalSize)). It is downloaded once and kept for later use.")
          .fixedSize(horizontal: false, vertical: true)
        Text("Emulation pauses while the model downloads.")
          .font(.caption)
          .foregroundStyle(.secondary)
        buttons {
          Button("Cancel", role: .cancel) { viewModel.cancelAIModelDownload() }
            .keyboardShortcut(.cancelAction)
          Button("Download") { viewModel.startAIModelDownload() }
            .keyboardShortcut(.defaultAction)
        }

      case .downloading(let received):
        ProgressView(value: Double(min(received, session.model.byteCount)),
                     total: Double(session.model.byteCount))
        Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(totalSize)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        buttons {
          Button("Cancel", role: .cancel) { viewModel.cancelAIModelDownload() }
            .keyboardShortcut(.cancelAction)
        }

      case .failed(let message):
        Text("The model could not be downloaded.")
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        buttons {
          Button("Close", role: .cancel) { viewModel.cancelAIModelDownload() }
            .keyboardShortcut(.cancelAction)
          Button("Retry") { viewModel.startAIModelDownload() }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
    .frame(width: 380)
    .interactiveDismissDisabled()
  }

  private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
    HStack {
      Spacer()
      content()
    }
  }
}
