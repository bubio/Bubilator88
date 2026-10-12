import SwiftUI
import Bubilator88Core

// MARK: - Memory Image (.n80)

extension EmulatorViewModel {

  /// Open a `.n80` memory image: a PC-8001 RAM dump. Resets into N-BASIC with
  /// the drives empty; ``MemoryImageBoot`` then restores the image once
  /// N-BASIC is at its prompt and types `RUN` if the image needs it. The mode
  /// stays N-BASIC afterwards.
  @discardableResult
  func loadMemoryImage(url: URL) -> Bool {
    // Drag and drop reaches here without the menu's check.
    guard checkAllowed(.state) else { return false }
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url) else {
      showAlert(
        title: String(localized: "Memory Image Load Error", comment: ""),
        message: String(localized: "Could not read \"\(url.lastPathComponent)\".", comment: "")
      )
      return false
    }
    guard data.count == PC88.memoryImageSize else {
      showAlert(
        title: String(localized: "Memory Image Load Error", comment: ""),
        message: String(
          localized: "\"\(url.lastPathComponent)\" is not a PC-8001 memory image.", comment: "")
      )
      return false
    }
    ejectDisk(drive: 0)
    ejectDisk(drive: 1)
    // Resets the machine, and the reset cancels anything in flight, so the
    // sequencer is started only afterwards.
    bootMode = .n
    pasteQueueLock.lock()
    memoryImageBoot.start(image: Array(data))
    pasteQueueLock.unlock()
    // The sequencer is ticked by the frame loop, so a machine that is paused,
    // or has not been started yet, has to run for it to get anywhere.
    resume()
    return true
  }

  /// Whether a memory image is still being loaded.
  var isMemoryImageBootActive: Bool {
    pasteQueueLock.lock()
    defer { pasteQueueLock.unlock() }
    return memoryImageBoot.isActive
  }

  /// Advance the memory-image load by one frame. Called from the frame loop
  /// right after `tickTapeAutoBoot()`, on the emulation thread, so the machine
  /// is touched directly rather than through `emuQueue`.
  nonisolated func tickMemoryImageBoot() {
    pasteQueueLock.lock()
    guard memoryImageBoot.isActive else {
      pasteQueueLock.unlock()
      return
    }
    switch memoryImageBoot.tick(
      typingIdle: pasteQueue.isEmpty,
      screen: { pc88.copyTextAsUnicode() }
    ) {
    case .restore(let image):
      pc88.restoreMemoryImage(image)
    case .type(let text):
      pasteQueue.enqueue(text)
    case nil:
      break
    }
    let failed = memoryImageBoot.phase == .failed
    pasteQueueLock.unlock()

    if failed {
      DispatchQueue.main.async { [weak self] in
        self?.showToast(String(localized: "Memory image load stopped", comment: "Toast"))
      }
    }
  }
}
