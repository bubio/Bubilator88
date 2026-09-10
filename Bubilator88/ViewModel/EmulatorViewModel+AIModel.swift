import Foundation

// MARK: - AI Model Download

/// One pass through the download sheet, from the confirmation prompt to the
/// installed model (or the user giving up).
struct AIModelDownloadSession: Identifiable {
  enum Phase: Equatable {
    /// Asking before a download the user may not have expected.
    case confirm
    /// Transfer in flight; `receivedBytes` is for the progress bar.
    case downloading(receivedBytes: Int64)
    /// The last attempt failed; the sheet offers a retry.
    case failed(message: String)
  }

  let id = UUID()
  /// The filter to switch to once the model is installed.
  let filter: EmulatorViewModel.VideoFilter
  let model: DownloadableAIModel
  var phase: Phase = .confirm
  /// Whether emulation was running when the download started, so it can
  /// resume afterwards. Only meaningful once a download has been started.
  var resumeAfterwards = false
}

extension EmulatorViewModel {

  /// Opens the download sheet for `filter`'s model. Called by the
  /// `videoFilter` setter instead of switching to a filter it cannot show yet.
  func requestAIModelDownload(for filter: VideoFilter) {
    guard aiModelDownload == nil, let model = filter.downloadableModel else { return }
    aiModelDownload = AIModelDownloadSession(filter: filter, model: model)
  }

  /// Starts (or retries) the transfer. Emulation is paused for the duration
  /// and the displayed filter is left as it was until the model is installed.
  func startAIModelDownload() {
    guard var session = aiModelDownload else { return }
    if case .downloading = session.phase { return }
    // A retry keeps the flag from the first attempt: emulation is already
    // paused by then, and was left paused on purpose.
    if case .confirm = session.phase {
      session.resumeAfterwards = isRunning
      pause()
    }
    session.phase = .downloading(receivedBytes: 0)
    aiModelDownload = session

    let model = session.model
    let sessionID = session.id
    aiModelDownloadTask = Task { [weak self] in
      do {
        try await AIModelStore.shared.download(model) { bytes in
          Task { @MainActor in self?.updateAIModelDownloadProgress(bytes, sessionID: sessionID) }
        }
        self?.finishAIModelDownload(sessionID: sessionID)
      } catch is CancellationError {
        // `cancelAIModelDownload()` has already closed the sheet.
      } catch let error as URLError where error.code == .cancelled {
        // Same, surfaced by URLSession rather than the task.
      } catch {
        self?.failAIModelDownload(error, sessionID: sessionID)
      }
    }
  }

  /// Abandons the download (or the prompt) and closes the sheet. The filter
  /// stays where it was; emulation resumes if the download had paused it.
  func cancelAIModelDownload() {
    aiModelDownloadTask?.cancel()
    aiModelDownloadTask = nil
    guard let session = aiModelDownload else { return }
    aiModelDownload = nil
    if session.resumeAfterwards { resume() }
  }

  private func updateAIModelDownloadProgress(_ bytes: Int64, sessionID: UUID) {
    guard var session = aiModelDownload, session.id == sessionID,
          case .downloading = session.phase else { return }
    session.phase = .downloading(receivedBytes: bytes)
    aiModelDownload = session
  }

  private func finishAIModelDownload(sessionID: UUID) {
    guard let session = aiModelDownload, session.id == sessionID else { return }
    aiModelDownloadTask = nil
    aiModelDownload = nil
    aiModelStoreRevision += 1
    videoFilter = session.filter
    if session.resumeAfterwards { resume() }
  }

  private func failAIModelDownload(_ error: Error, sessionID: UUID) {
    guard var session = aiModelDownload, session.id == sessionID else { return }
    aiModelDownloadTask = nil
    session.phase = .failed(message: error.localizedDescription)
    aiModelDownload = session
  }

  // MARK: - Installed Models

  func isAIModelInstalled(_ model: DownloadableAIModel) -> Bool {
    _ = aiModelStoreRevision
    return AIModelStore.shared.isInstalled(model)
  }

  /// Deletes a downloaded model at the user's request. A filter that was
  /// using it falls back to None, since it can no longer be shown.
  func deleteAIModel(_ model: DownloadableAIModel) {
    if videoFilter.downloadableModel == model {
      videoFilter = .none
    }
    do {
      try AIModelStore.shared.remove(model)
    } catch {
      showAlert(title: String(localized: "Could Not Delete Model", comment: "Alert title"),
                message: error.localizedDescription)
    }
    aiModelStoreRevision += 1
  }
}
