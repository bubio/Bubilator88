import AppKit
import Bubilator88Core
import UniformTypeIdentifiers

// 88PAR cheat codes. A `.pat` file is imported into `CheatStore` for the
// mounted disks; the set for the disk in drive 1 (else drive 2) is active, and
// its enabled groups run once per frame, before the frame, from the loop
// thread. See docs/develop/PAR_CHEAT_CODES.md.
extension EmulatorViewModel {

  /// File names of the mounted disks, drive 1 first.
  var cheatDiskFiles: [String?] {
    [drive0Info, drive1Info].map { $0.map { ClickZoneDiskKey(info: $0).fileName } }
  }

  var activeCheatSet: CheatSet? {
    CheatStore.shared.set(for: cheatDiskFiles)
  }

  /// From the Disk menu: choose a `.pat` file to import.
  func openCheatFile() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [UTType(filenameExtension: "pat"), .plainText, .data].compactMap { $0 }
    panel.message = String(localized: "Choose a cheat file (.pat) for the mounted disks",
                           comment: "Prompt in the open panel for importing an 88PAR .pat file")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    importCheatFile(url: url)
  }

  /// Import a `.pat` file for every mounted disk file. Its groups start off.
  func importCheatFile(url: URL) {
    guard let diskFiles = cheatTargetDiskFiles() else { return }
    let text: String
    do {
      text = PATFile.decodeText(try Data(contentsOf: url))
    } catch {
      showAlert(title: String(localized: "Cannot Import Cheat File"), message: error.localizedDescription)
      return
    }
    guard PATFile.parse(text).contains(where: { !$0.codes.isEmpty }) else {
      showAlert(title: String(localized: "Cannot Import Cheat File"),
                message: String(localized: "The file contains no cheat codes."))
      return
    }
    CheatStore.shared.importSet(name: url.lastPathComponent, text: text, for: diskFiles)
    syncActiveCheats()
    showToast(String(localized: "Cheat file imported: \(url.lastPathComponent)"))
  }

  /// Use a bundled preset for every mounted disk file. Its groups start off.
  func useCheatPreset(_ preset: CheatPreset) {
    guard let diskFiles = cheatTargetDiskFiles() else { return }
    CheatStore.shared.importSet(name: preset.title, text: preset.text, for: diskFiles)
    syncActiveCheats()
    showToast(String(localized: "Cheats set for the mounted disks: \(preset.title)"))
  }

  /// The mounted disk files, each once, or nil after explaining that a disk
  /// must be mounted first.
  private func cheatTargetDiskFiles() -> [String]? {
    let diskFiles = cheatDiskFiles.compactMap { $0 }
      .reduce(into: [String]()) { files, file in
        if !files.contains(where: { CheatSet.sameFile($0, file) }) { files.append(file) }
      }
    guard !diskFiles.isEmpty else {
      showAlert(title: String(localized: "Cannot Import Cheat File"),
                message: String(localized: "Mount the game's disk first. Cheat codes are kept for the mounted disks."))
      return nil
    }
    return diskFiles
  }

  func isCheatGroupEnabled(_ index: Int) -> Bool {
    activeCheatSet?.enabledGroups.contains(index) ?? false
  }

  func setCheatGroup(_ index: Int, enabled: Bool) {
    guard let set = activeCheatSet else { return }
    CheatStore.shared.setGroup(index, enabled: enabled, in: set.id)
    syncActiveCheats()
  }

  func disableAllCheats() {
    guard let set = activeCheatSet else { return }
    CheatStore.shared.disableAll(in: set.id)
    syncActiveCheats()
  }

  func removeActiveCheatSet() {
    guard let set = activeCheatSet else { return }
    CheatStore.shared.remove(set.id)
    syncActiveCheats()
  }

  /// Hand the loop the codes it should run. Main thread only; call it
  /// whenever the mounted disks or the store change.
  func syncActiveCheats() {
    let codes = activeCheatSet.map { CheatStore.shared.enabledCodes(of: $0) } ?? []
    emuQueue.sync { activeCheatCodes = codes }
  }

  /// Run the enabled groups once. On `emuQueue`, between frames.
  nonisolated func applyCheats() {
    for group in activeCheatCodes {
      pc88.runPATCodes(group)
    }
  }
}
