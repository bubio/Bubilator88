import SwiftUI
import UniformTypeIdentifiers
import EmulatorCore
import Translation

extension UTType {
    static let d88  = UTType(filenameExtension: "d88")!
    static let d77  = UTType(filenameExtension: "d77")!
    static let disk2d  = UTType(filenameExtension: "2d")!
    static let disk2hd = UTType(filenameExtension: "2hd")!
    static let cmt  = UTType(filenameExtension: "cmt")!
    static let t88  = UTType(filenameExtension: "t88")!
    static let lzh  = UTType(filenameExtension: "lzh")!
    static let lha  = UTType(filenameExtension: "lha")!
    static let cab  = UTType(filenameExtension: "cab")!
    static let rar  = UTType(filenameExtension: "rar")!
}

private let diskFileTypes: [UTType] = [
    .d88, .d77, .disk2d, .disk2hd,   // disk images
    .zip, .lzh, .lha, .cab, .rar     // archives
]

private let tapeFileTypes: [UTType] = [
    .cmt, .t88,                      // tape images
    .zip, .lzh, .lha, .cab, .rar     // archives
]

// MARK: - ContentView

struct ContentView: View {
    let viewModel: EmulatorViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Screen area — 640×400 base, scaled by windowScale
            ZStack {
                screenView
                KeyEventView(
                    onKeyDown: { viewModel.keyDown($0) },
                    onKeyUp: { viewModel.keyUp($0) },
                    onTurbo: { viewModel.turboMode = $0 }
                )
                if viewModel.translationManager.isSessionActive {
                    TranslationOverlayView(
                        detectionRects: viewModel.translationManager.isOverlayVisible
                            ? viewModel.translationManager.ocrDetectionRects
                            : []
                    )
                    .opacity(viewModel.translationManager.isOverlayVisible ? 1 : 0)
                    .translationTask(viewModel.translationManager.configuration) { session in
                        viewModel.translationManager.setSession(session)
                    }
                }
            }
            .frame(
                minWidth: viewModel.isFullScreen ? nil : CGFloat(640 * viewModel.windowScale),
                maxWidth: viewModel.isFullScreen ? .infinity : CGFloat(640 * viewModel.windowScale),
                minHeight: viewModel.isFullScreen ? nil : CGFloat(400 * viewModel.windowScale),
                maxHeight: viewModel.isFullScreen ? .infinity : CGFloat(400 * viewModel.windowScale)
            )
            .background(Color.black)

            if !viewModel.isFullScreen {
                statusBar
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: CGFloat(640 * viewModel.windowScale))
                    .background(.bar)
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.isFullScreen && viewModel.showFullScreenOverlay {
                statusBar
                    .frame(maxWidth: 1280)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.showFullScreenOverlay)
        .onAppear {
            viewModel.loadROMs()
            viewModel.renderScreen()
            viewModel.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            viewModel.isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            viewModel.showFullScreenOverlay = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            viewModel.isFullScreen = false
        }
        .fileImporter(
            isPresented: Binding(
                get: { viewModel.showingDiskPicker },
                set: { viewModel.showingDiskPicker = $0 }
            ),
            allowedContentTypes: diskFileTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewModel.mountDisk(url: url, drive: viewModel.diskPickerDrive)
            }
        }
        // SwiftUI silently drops all but the last .fileImporter attached
        // to the same view. The tape picker therefore lives on an
        // invisible sibling view via .background.
        .background(
            Color.clear.fileImporter(
                isPresented: Binding(
                    get: { viewModel.showingTapePicker },
                    set: { viewModel.showingTapePicker = $0 }
                ),
                allowedContentTypes: tapeFileTypes,
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    viewModel.mountTape(url: url)
                }
            }
        )
        .sheet(isPresented: Binding(
            get: { viewModel.showingImagePicker },
            set: { viewModel.showingImagePicker = $0 }
        )) {
            DiskImagePickerView(
                images: viewModel.pendingDiskImages,
                onSelect: { index in
                    viewModel.mountSelectedImage(index: index)
                },
                onCancel: {
                    viewModel.pendingDiskImages = []
                    viewModel.pendingDiskURL = nil
                    viewModel.showingImagePicker = false
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showingArchiveFilePicker },
            set: { viewModel.showingArchiveFilePicker = $0 }
        )) {
            ArchiveFilePickerView(
                entries: viewModel.pendingArchiveEntries,
                onSelect: { index in
                    viewModel.mountSelectedArchiveEntry(index: index)
                },
                onCancel: {
                    viewModel.pendingArchiveEntries = []
                    viewModel.showingArchiveFilePicker = false
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showingSaveStateSheet },
            set: { viewModel.showingSaveStateSheet = $0 }
        )) {
            SaveStateSheetView(viewModel: viewModel)
        }
        .alert(
            viewModel.alertTitle,
            isPresented: Binding(
                get: { viewModel.alertIsPresented },
                set: { viewModel.alertIsPresented = $0 }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.alertMessage)
        }
        .overlay(alignment: .bottom) {
            if let message = viewModel.currentToast {
                ToastView(message: message)
                    .padding(.bottom, viewModel.isFullScreen ? 60 : 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.currentToast != nil)
    }

    @ViewBuilder
    private var screenView: some View {
        MetalScreenViewWrapper(viewModel: viewModel)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            // Boot Mode + CPU Clock (grouped)
            HStack(spacing: 4) {
                Menu {
                    ForEach(EmulatorViewModel.BootMode.standardCases, id: \.self) { mode in
                        Button(mode.rawValue) { viewModel.bootMode = mode }
                    }
                } label: {
                    Text(viewModel.bootMode.shortLabel)
                        .bold()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    Button("8 MHz") { viewModel.clock8MHz = true }
                    Button("4 MHz") { viewModel.clock8MHz = false }
                } label: {
                    Text(viewModel.activeClock8MHz ? "8MHz" : "4MHz")
                        .monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Drive 2 + Drive 1 (real hardware order)
            HStack(spacing: 4) {
                driveLED(access: viewModel.drive1Access)
                driveMenu(drive: 1, name: viewModel.drive1Name, info: viewModel.drive1Info)
                driveLED(access: viewModel.drive0Access)
                driveMenu(drive: 0, name: viewModel.drive0Name, info: viewModel.drive0Info)
            }

            // Cassette tape (shown when enabled in Display settings)
            if Settings.shared.showTapeInStatusBar {
                tapeMenu
            }

            Spacer()

            // Volume slider (right-aligned, before translation icon)
            HStack(spacing: 4) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { viewModel.volume },
                        set: { viewModel.volume = $0 }
                    ),
                    in: 0...1
                )
                .frame(width: 60)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
            .help("Volume: \(viewModel.volumePercent)%")

            Button {
                viewModel.toggleTranslation(!viewModel.translationManager.isEnabled)
            } label: {
                Image(systemName: "translate")
                    .font(.system(size: 18))
                    .foregroundStyle(viewModel.translationManager.isEnabled ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Translation Overlay (⌘T)")

            HStack(spacing: 4) {
                Text(String(format: "%.0f fps", viewModel.fps))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
                Circle()
                    .fill(viewModel.turboMode ? Color.orange :
                          viewModel.isRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func driveMenu(drive: Int, name: String, info: MountedDiskInfo?) -> some View {
        let fileName = drive == 0 ? viewModel.drive0FileName : viewModel.drive1FileName

        return Menu {
            Text("Drive \(drive + 1)").disabled(true)
            Divider()
            Button("Mount...") {
                viewModel.diskPickerDrive = drive
                viewModel.showingDiskPicker = true
            }
            Button("Eject") {
                viewModel.ejectDisk(drive: drive)
            }
            .disabled(name == "Empty")

            if name != "Empty", let fileName {
                Divider()
                Text(fileName).disabled(true)
            }

            if let info {
                let multiGroup = info.imageGroups.count > 1
                ForEach(info.imageGroups, id: \.startIndex) { group in
                    if multiGroup {
                        Text(group.d88FileName).disabled(true)
                    }
                    ForEach(0..<group.count, id: \.self) { offset in
                        let index = group.startIndex + offset
                        Button {
                            viewModel.switchDiskImage(drive: drive, index: index)
                        } label: {
                            let imgName = info.imageNames[index]
                            if index == info.currentImageIndex {
                                Text(multiGroup ? "  \(imgName) ✓" : "\(imgName) ✓")
                            } else {
                                Text(multiGroup ? "  \(imgName)" : imgName)
                            }
                        }
                    }
                }
            }

        } label: {
            HStack(spacing: 3) {
                Image("FloppyDisk")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(name == "Empty" ? .tertiary : .secondary)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(name == "Empty" ? .tertiary : .secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .help("Drive \(drive + 1)")
    }

    @ViewBuilder
    private var tapeMenu: some View {
        let loaded = viewModel.tapeName != "Empty"
        Menu {
            Text(viewModel.tapeName).disabled(true)

            Divider()

            Button {
                viewModel.showingTapePicker = true
            } label: {
                Label("Open...", systemImage: "doc")
            }

            Button {
                viewModel.rewindTape()
            } label: {
                Label("Rewind", systemImage: "backward.end")
            }
            .disabled(!loaded)

            Button {
                viewModel.ejectTape()
            } label: {
                Label("Eject", systemImage: "eject")
            }
            .disabled(!loaded)
        } label: {
            Image("Cassete")
                .renderingMode(.template)
                .resizable()
                .frame(width: 12, height: 12)
        }
        .menuStyle(.borderlessButton)
        .help(loaded ? "Tape: \(viewModel.tapeName)" : "Tape: Empty")
    }

    private func driveLED(access: Bool) -> some View {
        Circle()
            .fill(access ? Color.red : Color.gray)
            .frame(width: 8, height: 8)
            .animation(access ? nil : .easeOut(duration: 0.2), value: access)
    }

}

// MARK: - Disk Image Picker

struct DiskImagePickerView: View {
    let images: [D88Disk]
    let onSelect: (Int) -> Void
    let onCancel: () -> Void

    private func diskTypeLabel(_ type: D88Disk.DiskType) -> String {
        switch type {
        case .twoD:  return "2D"
        case .twoDD: return "2DD"
        case .twoHD: return "2HD"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Select Disk Image")
                .font(.headline)
                .padding()

            List {
                ForEach(Array(images.enumerated()), id: \.offset) { index, disk in
                    Button {
                        onSelect(index)
                    } label: {
                        HStack {
                            Text("#\(index)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            Text(disk.name.isEmpty ? "(unnamed)" : disk.name)
                            Spacer()
                            Text(diskTypeLabel(disk.diskType))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if disk.writeProtected {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: 300, minHeight: 150)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
    }
}
