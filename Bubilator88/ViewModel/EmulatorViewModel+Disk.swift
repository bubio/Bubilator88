import SwiftUI
import UniformTypeIdentifiers
import EmulatorCore

// MARK: - ROM Loading & Disk Operations

extension EmulatorViewModel {

    // MARK: - ROM Loading

    /// Load ROMs from Application Support directory.
    func loadROMs() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Bubilator88")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        // N88-BASIC ROM
        let n88Path = appSupport.appendingPathComponent("N88.ROM")
        if let data = try? Data(contentsOf: n88Path) {
            machine.loadN88BasicROM(Array(data))
            romLoaded = true
        } else {
            showAlert(
                title: NSLocalizedString("ROM Not Found", comment: ""),
                message: "N88.ROM not found in \(appSupport.path)"
            )
        }

        // N-BASIC ROM (optional — needed for N88-BASIC boot sequence)
        if let data = try? Data(contentsOf: appSupport.appendingPathComponent("N80.ROM")) {
            machine.loadNBasicROM(Array(data))
        }

        // Font ROM (optional — built-in ASCII font used as fallback)
        let fontPath = appSupport.appendingPathComponent("FONT.ROM")
        if let data = try? Data(contentsOf: fontPath) {
            machine.loadFontROM(Array(data))
        }

        // Kanji ROM Level 1 (optional)
        let kanji1Path = appSupport.appendingPathComponent("KANJI1.ROM")
        if let data = try? Data(contentsOf: kanji1Path) {
            machine.loadKanjiROM1(Array(data))
        }

        // Kanji ROM Level 2 (optional)
        let kanji2Path = appSupport.appendingPathComponent("KANJI2.ROM")
        if let data = try? Data(contentsOf: kanji2Path) {
            machine.loadKanjiROM2(Array(data))
        }

        // DISK.ROM (sub-CPU firmware, 8KB)
        let diskROMPath = appSupport.appendingPathComponent("DISK.ROM")
        if let data = try? Data(contentsOf: diskROMPath) {
            machine.loadDiskROM(Array(data))
        }

        // N88 Extended ROM banks (0-3, 8KB each)
        for bank in 0..<4 {
            let primary = appSupport.appendingPathComponent("N88_\(bank).ROM")
            let alt = appSupport.appendingPathComponent("N88EXT\(bank).ROM")
            if let data = try? Data(contentsOf: primary) {
                machine.loadN88ExtROM(bank: bank, data: Array(data))
            } else if let data = try? Data(contentsOf: alt) {
                machine.loadN88ExtROM(bank: bank, data: Array(data))
            }
        }

        // Install extended RAM (capacity from Settings; default 128KB).
        machine.installExtRAM(cards: Settings.shared.extramCards, banksPerCard: 4)

        // YM2608 rhythm WAV samples (fmgen format: signed 16-bit PCM)
        let rhythmFiles = ["2608_BD.WAV", "2608_SD.WAV", "2608_TOP.WAV",
                           "2608_HH.WAV", "2608_TOM.WAV", "2608_RIM.WAV"]
        for (index, filename) in rhythmFiles.enumerated() {
            let path = appSupport.appendingPathComponent(filename)
            if let wavData = try? Data(contentsOf: path),
               let (samples, sampleRate) = parseWAV(wavData) {
                machine.loadRhythmSample(index: index, data: samples, sampleRate: sampleRate)
            }
        }
    }

    /// Parse a WAV file and extract signed 16-bit PCM samples.
    private func parseWAV(_ data: Data) -> (samples: [Int16], sampleRate: Int)? {
        guard data.count > 44 else { return nil }
        // Verify RIFF header
        guard data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46 else { return nil }
        // Verify WAVE format
        guard data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45 else { return nil }

        // Find "fmt " and "data" chunks
        var sampleRate = 44100
        var bitsPerSample = 16
        var numChannels = 1
        var dataOffset = 0
        var dataSize = 0

        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let chunkSize = Int(data[offset+4]) | Int(data[offset+5]) << 8 |
                            Int(data[offset+6]) << 16 | Int(data[offset+7]) << 24
            if chunkID == "fmt " {
                numChannels = Int(data[offset+10]) | Int(data[offset+11]) << 8
                sampleRate = Int(data[offset+12]) | Int(data[offset+13]) << 8 |
                             Int(data[offset+14]) << 16 | Int(data[offset+15]) << 24
                bitsPerSample = Int(data[offset+22]) | Int(data[offset+23]) << 8
            } else if chunkID == "data" {
                dataOffset = offset + 8
                dataSize = chunkSize
                break
            }
            offset += 8 + chunkSize
            if chunkSize & 1 != 0 { offset += 1 }  // Word-align
        }

        guard dataOffset > 0, bitsPerSample == 16 else { return nil }
        let sampleCount = min(dataSize, data.count - dataOffset) / (2 * numChannels)
        var samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let byteOffset = dataOffset + i * 2 * numChannels
            samples[i] = Int16(bitPattern: UInt16(data[byteOffset]) | UInt16(data[byteOffset+1]) << 8)
        }
        return (samples, sampleRate)
    }

    // MARK: - Disk Operations

    /// Open a D88 disk image file (or archive containing D88 files) and mount it.
    /// Multi-image D88 files trigger an image selection sheet.
    /// Archives with multiple D88 files trigger an archive file picker.
    /// drive == -1 triggers "Mount 0&1" mode.
    func mountDisk(url: URL, drive: Int) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            presentDiskLoadErrorAlert(
                fileName: url.lastPathComponent,
                reason: .unreadable
            )
            return
        }

        // Record in recent files
        Settings.shared.addRecentFile(url: url)

        // Check for archive formats (ZIP, LZH, CAB, RAR)
        if let entries = ArchiveExtractor.extractDiskImages(data) {
            if entries.isEmpty {
                presentDiskLoadErrorAlert(
                    fileName: url.lastPathComponent,
                    reason: .emptyArchive
                )
                return
            }
            // アーカイブを展開キャッシュへ書き出す (初回のみ実体書込)。
            // 書き戻し先 sourceURL はキャッシュ内ファイル URL に切り替える。
            let cacheDir = DiskCacheManager.ensureCached(archiveURL: url,
                                                          archiveData: data,
                                                          entries: entries)
            if drive == -1 {
                // Mount 0&1: collect all D88 images across archive entries
                var allDisks: [(disk: D88Disk, name: String, entryName: String)] = []
                var groups: [DiskImageGroup] = []
                for entry in entries {
                    let disks = D88Disk.parseAll(data: Array(entry.data))
                    let baseName = (entry.filename as NSString).deletingPathExtension
                    groups.append(DiskImageGroup(d88FileName: baseName,
                                                 startIndex: allDisks.count, count: disks.count))
                    for disk in disks {
                        allDisks.append((disk,
                                         disk.name.isEmpty ? baseName : disk.name,
                                         entry.filename))
                    }
                }
                let allImages = allDisks.map(\.disk)
                let allNames = allDisks.map(\.name)
                let fileName = url.deletingPathExtension().lastPathComponent
                if let first = allDisks.first {
                    let entryURL = cacheDir.flatMap {
                        DiskCacheManager.cachedEntryURL(in: $0, entryName: first.entryName)
                    }
                    mountDiskImageDirect(first.disk, name: first.name, drive: 0,
                                         allImages: allImages, imageNames: allNames, imageIndex: 0,
                                         sourceURL: entryURL,
                                         archiveEntryName: first.entryName,
                                         originArchiveURL: url,
                                         fileName: fileName,
                                         imageGroups: groups)
                }
                if allDisks.count >= 2 {
                    let second = allDisks[1]
                    let entryURL = cacheDir.flatMap {
                        DiskCacheManager.cachedEntryURL(in: $0, entryName: second.entryName)
                    }
                    mountDiskImageDirect(second.disk, name: second.name, drive: 1,
                                         allImages: allImages, imageNames: allNames, imageIndex: 1,
                                         sourceURL: entryURL,
                                         archiveEntryName: second.entryName,
                                         originArchiveURL: url,
                                         fileName: fileName,
                                         imageGroups: groups)
                } else {
                    ejectDisk(drive: 1)
                }
                return
            }
            if entries.count == 1 {
                let entryURL = cacheDir.flatMap {
                    DiskCacheManager.cachedEntryURL(in: $0, entryName: entries[0].filename)
                }
                mountDiskData(Array(entries[0].data), name: entries[0].filename, drive: drive,
                              sourceURL: entryURL, archiveEntryName: entries[0].filename,
                              originArchiveURL: url)
                return
            }
            // Multiple D88 files in archive → show archive file picker
            pendingArchiveEntries = entries
            pendingArchiveURL = url
            pendingArchiveCacheDir = cacheDir
            diskPickerDrive = drive
            showingArchiveFilePicker = true
            return
        }

        // Direct D88 file
        let disks = D88Disk.parseAll(data: Array(data))
        guard !disks.isEmpty else {
            presentDiskLoadErrorAlert(
                fileName: url.lastPathComponent,
                reason: classifyDiskLoadFailure(data: Array(data))
            )
            return
        }

        if drive == -1 {
            mountDiskImage(disks[0], allImages: disks, imageIndex: 0, url: url, drive: 0)
            if disks.count >= 2 {
                mountDiskImage(disks[1], allImages: disks, imageIndex: 1, url: url, drive: 1)
            } else {
                ejectDisk(drive: 1)
            }
            return
        }

        if disks.count == 1 {
            mountDiskImage(disks[0], allImages: disks, imageIndex: 0, url: url, drive: drive)
        } else {
            pendingDiskImages = disks
            pendingDiskURL = url
            showingImagePicker = true
        }
    }

    /// Mount a D88 from raw bytes (extracted from archive).
    /// `drive` must be 0 or 1 (not -1; Mount 0&1 is handled by the caller).
    private func mountDiskData(_ data: [UInt8], name: String, drive: Int,
                               sourceURL: URL?, archiveEntryName: String? = nil,
                               originArchiveURL: URL? = nil) {
        let disks = D88Disk.parseAll(data: data)
        guard !disks.isEmpty else {
            presentDiskLoadErrorAlert(
                fileName: name,
                reason: classifyDiskLoadFailure(data: data)
            )
            return
        }
        if disks.count == 1 {
            let disk = disks[0]
            let fileName = (name as NSString).deletingPathExtension
            let imageNames = disks.map { $0.name.isEmpty ? fileName : $0.name }
            let groups = [DiskImageGroup(d88FileName: fileName, startIndex: 0, count: disks.count)]
            mountDiskImageDirect(disk, name: imageNames[0], drive: drive,
                                 allImages: disks, imageNames: imageNames, imageIndex: 0,
                                 sourceURL: sourceURL, archiveEntryName: archiveEntryName,
                                 originArchiveURL: originArchiveURL,
                                 fileName: fileName, imageGroups: groups)
        } else {
            // Multi-image D88 inside archive → show image picker
            pendingDiskImages = disks
            pendingDiskURL = sourceURL
            pendingArchiveEntryName = archiveEntryName
            pendingOriginArchiveURL = originArchiveURL
            diskPickerDrive = drive
            showingImagePicker = true
        }
    }

    /// Mount a parsed D88Disk directly to a specific drive with full metadata.
    private func mountDiskImageDirect(_ disk: D88Disk, name: String, drive: Int,
                                       allImages: [D88Disk], imageNames: [String], imageIndex: Int,
                                       sourceURL: URL?, archiveEntryName: String? = nil,
                                       originArchiveURL: URL? = nil,
                                       fileName: String, imageGroups: [DiskImageGroup]) {
        diskWriteBackScheduler.flushNow(drive: drive)
        emuQueue.sync {
            machine.mountDisk(drive: drive, disk: disk)
        }
        clearRewindBuffer()
        let info = MountedDiskInfo(sourceURL: sourceURL, archiveEntryName: archiveEntryName,
                                    originArchiveURL: originArchiveURL,
                                    allImages: allImages, imageNames: imageNames,
                                    currentImageIndex: imageIndex, fileName: fileName,
                                    imageGroups: imageGroups)
        if drive == 0 {
            drive0Name = name; drive0FileName = fileName; drive0Info = info
            drive0WriteProtected = disk.writeProtected
        } else {
            drive1Name = name; drive1FileName = fileName; drive1Info = info
            drive1WriteProtected = disk.writeProtected
        }
        // (mount confirmation not shown — no user-facing toast needed)
    }

    /// Mount the selected file from an archive.
    func mountSelectedArchiveEntry(index: Int) {
        guard index >= 0, index < pendingArchiveEntries.count else { return }
        let entry = pendingArchiveEntries[index]
        let entryURL = pendingArchiveCacheDir.flatMap {
            DiskCacheManager.cachedEntryURL(in: $0, entryName: entry.filename)
        }
        mountDiskData(Array(entry.data), name: entry.filename, drive: diskPickerDrive,
                      sourceURL: entryURL, archiveEntryName: entry.filename,
                      originArchiveURL: pendingArchiveURL)
        pendingArchiveEntries = []
        pendingArchiveURL = nil
        pendingArchiveCacheDir = nil
        showingArchiveFilePicker = false
    }

    /// Mount the selected image from a multi-image D88 file.
    func mountSelectedImage(index: Int) {
        guard index >= 0 && index < pendingDiskImages.count else { return }
        let disk = pendingDiskImages[index]
        let url = pendingDiskURL
        let allImages = pendingDiskImages
        let entryName = pendingArchiveEntryName
        let originArchive = pendingOriginArchiveURL
        mountDiskImage(disk, allImages: allImages, imageIndex: index, url: url,
                       drive: diskPickerDrive, archiveEntryName: entryName,
                       originArchiveURL: originArchive)
        pendingDiskImages = []
        pendingDiskURL = nil
        pendingArchiveEntryName = nil
        pendingOriginArchiveURL = nil
        showingImagePicker = false
    }

    private func mountDiskImage(_ disk: D88Disk, allImages: [D88Disk], imageIndex: Int,
                                 url: URL?, drive: Int, archiveEntryName: String? = nil,
                                 originArchiveURL: URL? = nil) {
        // For non-archive paths, use the source URL as the display name.
        // For archive-derived paths, prefer the original archive name (cache dir
        // names like "abc123-456" are not user-friendly).
        let fileName: String = {
            if let archiveURL = originArchiveURL {
                return archiveURL.deletingPathExtension().lastPathComponent
            }
            return url?.deletingPathExtension().lastPathComponent ?? "Disk"
        }()
        let imageNames = allImages.enumerated().map { i, d in
            d.name.isEmpty ? (allImages.count > 1 ? "\(fileName) #\(i)" : fileName) : d.name
        }
        let groups = [DiskImageGroup(d88FileName: fileName, startIndex: 0, count: allImages.count)]
        let displayName = imageNames[imageIndex]
        diskWriteBackScheduler.flushNow(drive: drive)
        emuQueue.sync {
            machine.mountDisk(drive: drive, disk: disk)
        }
        clearRewindBuffer()
        let info = MountedDiskInfo(sourceURL: url, archiveEntryName: archiveEntryName,
                                    originArchiveURL: originArchiveURL,
                                    allImages: allImages, imageNames: imageNames,
                                    currentImageIndex: imageIndex, fileName: fileName,
                                    imageGroups: groups)
        if drive == 0 {
            drive0Name = displayName; drive0FileName = fileName; drive0Info = info
            drive0WriteProtected = disk.writeProtected
        } else {
            drive1Name = displayName; drive1FileName = fileName; drive1Info = info
            drive1WriteProtected = disk.writeProtected
        }
        // (mount confirmation not shown)
    }

    /// Switch to a different disk image within the same source file.
    func switchDiskImage(drive: Int, index: Int) {
        guard let info = (drive == 0 ? drive0Info : drive1Info),
              index >= 0, index < info.allImages.count else { return }
        diskWriteBackScheduler.flushNow(drive: drive)
        let disk = info.allImages[index]
        emuQueue.sync {
            machine.mountDisk(drive: drive, disk: disk)
        }
        clearRewindBuffer()
        var updated = info
        updated.currentImageIndex = index
        let displayName = info.imageNames[index]
        if drive == 0 {
            drive0Info = updated; drive0Name = displayName
            drive0WriteProtected = disk.writeProtected
        } else {
            drive1Info = updated; drive1Name = displayName
            drive1WriteProtected = disk.writeProtected
        }
        // (switch confirmation not shown)
    }

    /// Toggle the write-protect flag on the disk mounted in the specified drive.
    /// No-op when the drive is empty.
    func toggleWriteProtect(drive: Int) {
        let name = drive == 0 ? drive0Name : drive1Name
        guard name != "Empty" else { return }
        let newValue = !(drive == 0 ? drive0WriteProtected : drive1WriteProtected)
        emuQueue.sync {
            machine.setWriteProtect(drive: drive, protected: newValue)
        }
        if drive == 0 {
            drive0WriteProtected = newValue
        } else {
            drive1WriteProtected = newValue
        }
    }

    func ejectDisk(drive: Int) {
        diskWriteBackScheduler.flushNow(drive: drive)
        emuQueue.sync {
            machine.ejectDisk(drive: drive)
        }
        clearRewindBuffer()
        if drive == 0 {
            drive0Name = "Empty"
            drive0FileName = nil
            drive0Info = nil
            drive0WriteProtected = false
        } else {
            drive1Name = "Empty"
            drive1FileName = nil
            drive1Info = nil
            drive1WriteProtected = false
        }
        // FDD boot is always the default; no need to revert to ROM boot
        // (eject confirmation not shown)
    }

    /// Mount a disk from a recent file entry (resolves bookmark, mounts as 0&1).
    func mountRecentFile(_ entry: RecentDiskEntry, drive: Int = -1) {
        guard let url = entry.resolveBookmark() else {
            Settings.shared.removeRecentFile(entry)
            showAlert(
                title: NSLocalizedString("File Error", comment: ""),
                message: NSLocalizedString("File no longer accessible", comment: "")
            )
            return
        }
        mountDisk(url: url, drive: drive)
    }

    // MARK: - Blank Disk Creation

    /// Show save panel and create a formatted blank D88 disk image.
    func createBlankDisk() {
        let panel = NSSavePanel()
        panel.title = NSLocalizedString("Create Blank Disk", comment: "Save panel title")
        panel.nameFieldStringValue = "Blank.d88"
        panel.allowedContentTypes = [.init(filenameExtension: "d88")!]

        // Disk type picker as accessory view
        let typePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        typePopup.addItems(withTitles: ["2D (320KB)", "2DD (640KB)", "2HD (1.2MB)"])
        typePopup.selectItem(at: 1)  // default: 2DD

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 36))
        let label = NSTextField(labelWithString: NSLocalizedString("Disk Type:", comment: "Blank disk type label"))
        label.sizeToFit()
        let labelWidth = max(70, label.frame.width)
        label.frame = NSRect(x: 4, y: 6, width: labelWidth, height: 20)
        typePopup.frame = NSRect(x: labelWidth + 8, y: 4, width: 200, height: 26)
        container.addSubview(label)
        container.addSubview(typePopup)
        panel.accessoryView = container

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let diskType: D88Disk.DiskType
            switch typePopup.indexOfSelectedItem {
            case 0:  diskType = .twoD
            case 2:  diskType = .twoHD
            default: diskType = .twoDD
            }
            let diskName = url.deletingPathExtension().lastPathComponent
            let disk = D88Disk.createFormatted(type: diskType, name: diskName)
            guard let data = disk.serialize() else {
                self?.showAlert(
                    title: NSLocalizedString("Disk Error", comment: ""),
                    message: NSLocalizedString("Failed to create blank disk", comment: "")
                )
                return
            }
            do {
                try Data(data).write(to: url)
                // (blank disk creation confirmation not shown)
                self?.mountDisk(url: url, drive: 0)
            } catch {
                self?.showAlert(
                    title: NSLocalizedString("Disk Error", comment: ""),
                    message: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Disk Load Failure Reporting

    /// Why a disk image could not be loaded. Used to pick a user-facing
    /// explanation for the disk-load error alert.
    enum DiskLoadFailureReason {
        case unreadable         // File could not be read from disk at all.
        case emptyArchive       // Archive extracted but contains no D88 images.
        case t88TapeImage       // File is actually a T88 PC-8801 tape image.
        case notD88             // File is not a D88 and not a recognized archive.
    }

    /// Inspect the raw bytes of a file the user tried to mount to classify
    /// *why* D88 parsing failed, so the alert can give a specific hint
    /// rather than a generic "can't load" message.
    private func classifyDiskLoadFailure(data: [UInt8]) -> DiskLoadFailureReason {
        // Common foot-gun #1: a PC-8801 tape image renamed to .d88. The T88
        // file format starts with the literal "PC-8801 Tape Image(T88)"
        // string in ASCII, so sniff that first — T88 headers can otherwise
        // incidentally pass the D88-header heuristic below because the NUL
        // after "T88)" lands at offset 0x17.
        let t88Signature: [UInt8] = Array("PC-8801 Tape Image(T88)".utf8)
        if data.count >= t88Signature.count &&
            Array(data.prefix(t88Signature.count)) == t88Signature {
            return .t88TapeImage
        }

        return .notD88
    }

    /// Show a disk-load failure alert via the unified notification system.
    private func presentDiskLoadErrorAlert(fileName: String, reason: DiskLoadFailureReason) {
        let title = NSLocalizedString("Can't Load Disk Image", comment: "Disk load failure alert title")
        let bodyFormat: String
        switch reason {
        case .unreadable:
            bodyFormat = NSLocalizedString(
                "\"%@\" could not be read. The file may be missing, unreadable, or on a disconnected volume.",
                comment: "Disk load failure: file unreadable"
            )
        case .emptyArchive:
            bodyFormat = NSLocalizedString(
                "\"%@\" is an archive, but it does not contain any D88 disk images.",
                comment: "Disk load failure: archive contains no D88"
            )
        case .t88TapeImage:
            bodyFormat = NSLocalizedString(
                "\"%@\" is a PC-8801 tape image (T88), not a D88 disk image. Bubilator88 does not support T88 files.",
                comment: "Disk load failure: file is a T88 tape image"
            )
        case .notD88:
            bodyFormat = NSLocalizedString(
                "\"%@\" is not a valid D88 disk image. The header is missing or the file is corrupted.",
                comment: "Disk load failure: file is not a D88"
            )
        }
        showAlert(title: title, message: String(format: bodyFormat, fileName))
    }
}

// MARK: - Disk Write-Back (Phase 1: 単独 .d88 のライトスルー)

extension EmulatorViewModel {

    /// `SubSystem.onDiskWritten` から呼ばれるエントリポイント。
    /// emulation thread から呼ばれるためメインスレッドへホップしてから
    /// scheduler を叩く。
    func diskDirtyNotification(drive: Int) {
        if Thread.isMainThread {
            diskWriteBackScheduler.schedule(drive: drive)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.diskWriteBackScheduler.schedule(drive: drive)
            }
        }
    }

    /// scheduler から呼ばれる実書込関数。メインスレッド前提。
    func performDiskWriteBack(drive: Int) {
        // 現在の D88 バイト列を emu thread でスナップショット
        let snapshot: [UInt8]? = emuQueue.sync {
            machine.subSystem.drives[drive]?.serialize()
        }
        guard let bankBytes = snapshot else { return }

        // dirty が true でも writeProtected な場合は no-op
        let dirty = emuQueue.sync { machine.subSystem.drives[drive]?.dirty ?? false }
        guard dirty else { return }

        let info = (drive == 0 ? drive0Info : drive1Info)
        let sourceURL = info?.sourceURL
        let imageIndex = info?.currentImageIndex ?? 0

        // 書き戻し先 URL の決定。
        // Phase 2 以降、アーカイブ由来でも sourceURL はキャッシュ内 .d88 を
        // 指すので分け隔てなくそのまま書ける。
        // - sourceURL があればそこへ
        // - 無ければリカバリディレクトリへフォールバック
        guard let writeURL = sourceURL else {
            writeBackToRecovery(drive: drive, bankBytes: bankBytes,
                                 fileName: info?.fileName ?? "disk\(drive)")
            return
        }

        do {
            try writeBankToFile(bankBytes: bankBytes, imageIndex: imageIndex, url: writeURL)
            // 成功時 dirty クリア (emu thread 経由)
            emuQueue.sync {
                machine.subSystem.drives[drive]?.dirty = false
            }
        } catch {
            // 書込失敗 → リカバリディレクトリへフォールバック
            writeBackToRecovery(drive: drive, bankBytes: bankBytes,
                                 fileName: info?.fileName ?? "disk\(drive)")
            showAlert(
                title: NSLocalizedString("Disk Write Failed", comment: ""),
                message: error.localizedDescription
            )
        }
    }

    /// 指定 imageIndex のバンクを `url` の D88 ファイル内に splice 書込する。
    /// 単一バンク (file の総バイトが bank0 と一致) なら丸ごと上書き。
    /// マルチバンクなら前後のバンクバイト列を保持して中央のみ差し替え。
    private func writeBankToFile(bankBytes: [UInt8], imageIndex: Int, url: URL) throws {
        let originalData: Data
        do {
            originalData = try Data(contentsOf: url)
        } catch {
            // 元ファイルが読めない → 単一バンク扱いで上書き
            try Data(bankBytes).write(to: url, options: .atomic)
            return
        }

        // 元ファイル内のバンク offset を header (offset 0x1C のバンクサイズ)
        // を辿って算出する。
        var bankStart = 0
        for _ in 0..<imageIndex {
            guard bankStart + 0x20 <= originalData.count else {
                throw NSError(domain: "DiskWriteBack", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Bank header out of range"])
            }
            let size = Int(readUInt32LE(originalData, offset: bankStart + 0x1C))
            guard size > 0 else {
                throw NSError(domain: "DiskWriteBack", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid bank size"])
            }
            bankStart += size
        }
        guard bankStart + 0x20 <= originalData.count else {
            throw NSError(domain: "DiskWriteBack", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Bank offset beyond file"])
        }
        let originalBankSize = Int(readUInt32LE(originalData, offset: bankStart + 0x1C))
        let bankEnd = bankStart + originalBankSize
        guard bankEnd <= originalData.count else {
            throw NSError(domain: "DiskWriteBack", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Bank end beyond file"])
        }

        var merged = Data(capacity: originalData.count - originalBankSize + bankBytes.count)
        merged.append(originalData.prefix(bankStart))
        merged.append(contentsOf: bankBytes)
        merged.append(originalData.suffix(from: bankEnd))
        try merged.write(to: url, options: .atomic)
    }

    /// 通常の書込先が無い / 書込失敗時のフォールバック保存先。
    private func writeBackToRecovery(drive: Int, bankBytes: [UInt8], fileName: String) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Bubilator88/ModifiedDisks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sanitized = fileName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let url = dir.appendingPathComponent("\(sanitized)-drive\(drive)-\(stamp).d88")
        do {
            try Data(bankBytes).write(to: url, options: .atomic)
            // 成功時 dirty クリア
            emuQueue.sync { machine.subSystem.drives[drive]?.dirty = false }
        } catch {
            // ここは諦める。次回 dirty 検出時に再試行される。
        }
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        return UInt32(data[offset])
             | (UInt32(data[offset + 1]) << 8)
             | (UInt32(data[offset + 2]) << 16)
             | (UInt32(data[offset + 3]) << 24)
    }
}
