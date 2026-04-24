import SwiftUI

@main
struct Bubilator88App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = EmulatorViewModel()
    @State private var showAbout = false

    var body: some Scene {
        Window("Bubilator88", id: "main") {
            ContentView(viewModel: viewModel)
                .onAppear { appDelegate.viewModel = viewModel }
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
    }
}

// MARK: - Emulator Menu

struct EmulatorCommands: Commands {
    let viewModel: EmulatorViewModel

    var body: some Commands {
        CommandMenu("Emulator") {
            Button {
                if viewModel.isRunning {
                    viewModel.pause()
                } else {
                    viewModel.resume()
                }
            } label: {
                Label(viewModel.isRunning ? "Pause" : "Resume",
                      systemImage: viewModel.isRunning ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut("r", modifiers: .command)

            Button {
                viewModel.reset()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .keyboardShortcut("e", modifiers: .command)

            Divider()

            Picker("Boot Mode", selection: Binding(
                get: { viewModel.bootMode },
                set: { viewModel.bootMode = $0 }
            )) {
                ForEach(EmulatorViewModel.BootMode.standardCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Picker("CPU Clock", selection: Binding(
                get: { viewModel.clock8MHz },
                set: { viewModel.clock8MHz = $0 }
            )) {
                Text("8 MHz").tag(true)
                Text("4 MHz").tag(false)
            }
            .pickerStyle(.inline)
        }
    }
}

// MARK: - Disk Menu

struct DiskCommands: Commands {
    let viewModel: EmulatorViewModel

    @ViewBuilder
    private func driveSubmenu(drive: Int) -> some View {
        let label = drive + 1
        let name = drive == 0 ? viewModel.drive0Name : viewModel.drive1Name
        let fileName = drive == 0 ? viewModel.drive0FileName : viewModel.drive1FileName
        let info = drive == 0 ? viewModel.drive0Info : viewModel.drive1Info
        let shortcut: KeyEquivalent = drive == 0 ? "1" : "2"

        Menu {
            Button {
                viewModel.diskPickerDrive = drive
                viewModel.showingDiskPicker = true
            } label: {
                Label("Mount...", systemImage: "opticaldiscdrive")
            }
            .keyboardShortcut(shortcut, modifiers: .command)

            Button {
                viewModel.ejectDisk(drive: drive)
            } label: {
                Label("Eject", systemImage: "eject")
            }
            .disabled(name == "Empty")

            let wp = drive == 0 ? viewModel.drive0WriteProtected : viewModel.drive1WriteProtected
            Button {
                viewModel.toggleWriteProtect(drive: drive)
            } label: {
                if wp {
                    Label("Write Protect ✓", systemImage: "lock.fill")
                } else {
                    Label("Write Protect", systemImage: "lock.open")
                }
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
            Label("Drive \(label)", image: "FloppyDisk")
        }
    }

    var body: some Commands {
        CommandMenu("Disk") {
            // Drive 1 submenu
            driveSubmenu(drive: 0)

            // Drive 2 submenu
            driveSubmenu(drive: 1)

            Divider()

            Menu {
                Button {
                    viewModel.diskPickerDrive = -1
                    viewModel.showingDiskPicker = true
                } label: {
                    Label("Mount...", systemImage: "opticaldiscdrive")
                }
                .keyboardShortcut("3", modifiers: .command)

                Button {
                    viewModel.ejectDisk(drive: 0)
                    viewModel.ejectDisk(drive: 1)
                } label: {
                    Label("Eject", systemImage: "eject")
                }
                .disabled(viewModel.drive0Name == "Empty" && viewModel.drive1Name == "Empty")
            } label: {
                Label("Drive 1&2", image: "FloppyDisk")
            }

            Divider()

            Button {
                viewModel.createBlankDisk()
            } label: {
                Label("Create Blank Disk...", systemImage: "plus.circle")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            // Recent Files submenu
            Menu("Recent Files") {
                if Settings.shared.recentDiskFiles.isEmpty {
                    Text("No Recent Files")
                } else {
                    ForEach(Settings.shared.recentDiskFiles) { entry in
                        Button("\(entry.displayName) — \(entry.displayDir)") {
                            viewModel.mountRecentFile(entry)
                        }
                    }
                    Divider()
                    Button {
                        Settings.shared.clearRecentFiles()
                    } label: {
                        Label("Clear Recent Files", systemImage: "trash")
                    }
                }
            }
        }

        CommandMenu("Tape") {
            Text(viewModel.tapeName).disabled(true)

            Divider()

            Button {
                viewModel.showingTapePicker = true
            } label: {
                Label {
                    Text("Open...")
                } icon: {
                    Image("Cassete")
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button {
                viewModel.rewindTape()
            } label: {
                Label("Rewind", systemImage: "backward.end")
            }
            .disabled(viewModel.tapeName == "Empty")

            Button {
                viewModel.ejectTape()
            } label: {
                Label("Eject", systemImage: "eject")
            }
            .disabled(viewModel.tapeName == "Empty")

            Divider()

            Menu("Recent Files") {
                if Settings.shared.recentTapeFiles.isEmpty {
                    Text("No Recent Files")
                } else {
                    ForEach(Settings.shared.recentTapeFiles) { entry in
                        Button("\(entry.displayName) — \(entry.displayDir)") {
                            viewModel.mountRecentTape(entry)
                        }
                    }
                    Divider()
                    Button {
                        Settings.shared.clearRecentTapeFiles()
                    } label: {
                        Label("Clear Recent Files", systemImage: "trash")
                    }
                }
            }
        }
    }
}

// MARK: - View Menu (appended to system View menu)

struct ViewCommands: Commands {
    let viewModel: EmulatorViewModel
    
    var body: some Commands {
        CommandGroup(after: .toolbar) {
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

            Toggle(isOn: Binding(
                get: { viewModel.scanlineEnabled },
                set: { viewModel.scanlineEnabled = $0 }
            )) {
                Label("Scanlines", systemImage: "line.3.horizontal")
            }
            .disabled(!viewModel.isScanlineAvailable)

            Divider()

            Picker("Video Filter", selection: Binding(
                get: { viewModel.videoFilter },
                set: { viewModel.videoFilter = $0 }
            )) {
                ForEach(EmulatorViewModel.VideoFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.inline)

            Divider()

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

// MARK: - Control Menu

struct ControlCommands: Commands {
    let viewModel: EmulatorViewModel

    var body: some Commands {
        CommandMenu("Control") {
            Button {
                viewModel.volumeUp()
            } label: {
                Label("Increase Volume", systemImage: "speaker.plus")
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button {
                viewModel.volumeDown()
            } label: {
                Label("Decrease Volume", systemImage: "speaker.minus")
            }
            .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            Picker("CPU Speed", selection: Binding(
                get: { viewModel.cpuSpeed },
                set: { viewModel.cpuSpeed = $0 }
            )) {
                ForEach(EmulatorViewModel.CPUSpeed.allCases, id: \.self) { speed in
                    Text(speed.rawValue).tag(speed)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button {
                viewModel.saveScreenshot()
            } label: {
                Label(
                    Settings.shared.screenshotAutoSave
                        ? "Save Screenshot"
                        : "Save Screenshot…",
                    systemImage: "camera"
                )
            }

            Button {
                viewModel.toggleRecording()
            } label: {
                if viewModel.audioRecorder.isRecording {
                    Label("Stop Audio Recording",
                          systemImage: "stop.circle")
                } else {
                    Label(
                        Settings.shared.recordingAutoSave
                            ? "Start Audio Recording"
                            : "Start Audio Recording…",
                        systemImage: "record.circle"
                    )
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Button {
                viewModel.quickSave()
            } label: {
                Label("Quick Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)

            Button {
                viewModel.quickLoad()
            } label: {
                Label("Quick Load", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!viewModel.hasQuickSave)

            if viewModel.hasQuickSave {
                Text(viewModel.quickSaveInfo)
                    .font(.caption)
            }

            Divider()

            Button {
                viewModel.saveStateSheetMode = .save
                viewModel.showingSaveStateSheet = true
            } label: {
                Label("Save State...", systemImage: "tray.and.arrow.down")
            }

            Button {
                viewModel.saveStateSheetMode = .load
                viewModel.showingSaveStateSheet = true
            } label: {
                Label("Load State...", systemImage: "tray.and.arrow.up")
            }
        }
    }
}

// MARK: - Debug Menu

struct DebugCommands: Commands {
    let viewModel: EmulatorViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("DEBUG") {
            Button("Debugger…") {
                openWindow(id: "debugger")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

        #if DEBUG
            Button("Dump Text DMA Snapshot") {
                viewModel.dumpTextDMASnapshotToDefaultPath()
            }
        #endif
            Button("Dump Memory…") {
                viewModel.dumpMemoryViaSavePanel()
            }

            Divider()

            Toggle("Show Text Layer", isOn: Binding(
                get: { viewModel.debugTextLayerEnabled },
                set: { viewModel.debugTextLayerEnabled = $0 }
            ))

            Divider()

            Toggle("FM", isOn: Binding(
                get: { viewModel.fmEnabled },
                set: { viewModel.fmEnabled = $0 }
            ))

            Toggle("SSG", isOn: Binding(
                get: { viewModel.ssgEnabled },
                set: { viewModel.ssgEnabled = $0 }
            ))

            Toggle("ADPCM", isOn: Binding(
                get: { viewModel.adpcmEnabled },
                set: { viewModel.adpcmEnabled = $0 }
            ))

            Toggle("Rhythm", isOn: Binding(
                get: { viewModel.rhythmEnabled },
                set: { viewModel.rhythmEnabled = $0 }
            ))

            Divider()

            Toggle("Force YM2203 (OPN)", isOn: Binding(
                get: { viewModel.forceOPNMode },
                set: { viewModel.forceOPNMode = $0 }
            ))

        }
    }
}
