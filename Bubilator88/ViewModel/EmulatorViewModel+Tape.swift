import SwiftUI
import UniformTypeIdentifiers
import EmulatorCore

// MARK: - Cassette Tape Operations

extension EmulatorViewModel {

    /// Mount a cassette-tape image (`.cmt` / `.t88`, or an archive
    /// containing one). Multi-entry archives mount the first hit — PC-88
    /// tape ZIPs in the wild are almost always single-file so a picker
    /// isn't justified here.
    func mountTape(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            showAlert(
                title: NSLocalizedString("Tape Load Error", comment: ""),
                message: "Could not read \(url.lastPathComponent)"
            )
            return
        }
        // Unwrap archive if present.
        var tapeData = data
        if let entries = ArchiveExtractor.extractTapeImages(data) {
            guard let first = entries.first else {
                showAlert(
                    title: NSLocalizedString("Tape Load Error", comment: ""),
                    message: "No .cmt or .t88 found in \(url.lastPathComponent)"
                )
                return
            }
            tapeData = first.data
        }

        let format: CassetteDeck.Format = emuQueue.sync {
            machine.mountTape(data: tapeData)
        }
        Settings.shared.addRecentTapeFile(url: url)
        tapeName = url.deletingPathExtension().lastPathComponent
        tapeSourceURL = url
        tapeFormat = format
    }

    /// Mount a previously-remembered tape via its security-scoped bookmark.
    func mountRecentTape(_ entry: RecentDiskEntry) {
        guard let url = entry.resolveBookmark() else {
            Settings.shared.removeRecentTapeFile(entry)
            showAlert(
                title: NSLocalizedString("Tape Load Error", comment: ""),
                message: "Could not resolve \(entry.displayName)"
            )
            return
        }
        mountTape(url: url)
    }

    /// Rewind tape to the beginning (keep it loaded).
    func rewindTape() {
        emuQueue.sync {
            machine.rewindTape()
        }
        tapeProgress = 0
    }

    /// Eject the currently-loaded tape.
    func ejectTape() {
        emuQueue.sync {
            machine.ejectTape()
        }
        tapeName = "Empty"
        tapeSourceURL = nil
        tapeFormat = nil
        tapeProgress = 0
    }
}
