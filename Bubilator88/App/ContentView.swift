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
  static let m3u  = UTType(filenameExtension: "m3u")!
  static let m3u8 = UTType(filenameExtension: "m3u8")!
}

private let diskFileTypes: [UTType] = [
  .d88, .d77, .disk2d, .disk2hd,   // disk images
  .m3u, .m3u8,                     // multi-disk playlist
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
          onTurbo: { viewModel.turboMode = $0 },
          onRomajiKeyDown: { viewModel.handleRomajiKeyDown($0) },
          onMouseMove: { viewModel.injectMouseMovement(dx: $0, dy: $1) },
          onMouseButton: { viewModel.setMouseButton(left: $0, right: $1) },
          mouseCaptureEnabled: Settings.shared.mouseEnabled,
          mouseSensitivity: Settings.shared.mouseSensitivity,
          onCaptureChange: { viewModel.mouseCapturing = $0 }
        )
        .onChange(of: Settings.shared.mouseEnabled, initial: true) { _, newValue in
          viewModel.mouseModeEnabled = newValue
        }
        .onChange(of: Settings.shared.mouseJoyMode, initial: true) { _, newValue in
          viewModel.mouseJoyMode = newValue
        }
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
        if viewModel.isRewinding {
          VStack {
            Spacer()
            RewindStripView(viewModel: viewModel)
          }
          .animation(.easeInOut(duration: 0.15),
                     value: viewModel.rewindSnapshotCount)
        }
        if viewModel.romajiInputEnabled && !viewModel.romajiPending.isEmpty {
          VStack {
            Spacer()
            RomajiOverlayView(pending: viewModel.romajiPending)
              .padding(.bottom, 16)
          }
          .allowsHitTesting(false)
          .transition(.opacity)
        }
      }
      .frame(
        minWidth: viewModel.isFullScreen ? nil : CGFloat(640 * viewModel.windowScale),
        maxWidth: viewModel.isFullScreen ? .infinity : CGFloat(640 * viewModel.windowScale),
        minHeight: viewModel.isFullScreen ? nil : CGFloat(400 * viewModel.windowScale),
        maxHeight: viewModel.isFullScreen ? .infinity : CGFloat(400 * viewModel.windowScale)
      )
      .background(Color.black)
      .onDrop(of: [.fileURL], isTargeted: nil) { providers in
        handleDiskDrop(providers: providers)
      }

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
      // A `.b88script` double-clicked to launch the app is held until
      // here, so it plays only after ROMs + run loop are live.
      viewModel.consumePendingScript()
      // QUASI88 互換のコマンドライン引数 (`Bubilator88 -v2 game.d88 2`)。
      // 起動時に一度だけ評価する。`bubilator88://` URL より先に処理する
      // ので、両方与えられたときは URL 側が勝つ。
      viewModel.requestLaunchFromCommandLine()
      // Same deferral for a `bubilator88://boot` URL that arrived
      // before the run loop was ready (cold launch).
      viewModel.consumePendingLaunch()
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
    // sum type pickerContext を直接 bind することで、
    // 「どのピッカーが立っているか」と「内容」が常に整合する。
    // .sheet(item:) は item の id 変化でシートを再構築する。
    .sheet(item: Binding(
      get: { viewModel.pickerContext },
      set: { viewModel.pickerContext = $0 }
    )) { context in
      switch context {
      case .multiImageD88(let disks, _, _, _, _):
        DiskImagePickerView(
          images: disks,
          onSelect: { viewModel.mountSelectedImage(index: $0) },
          onCancel: { viewModel.pickerContext = nil }
        )
      case .archiveEntries(let entries, _, _, _):
        ArchiveFilePickerView(
          entries: entries,
          onSelect: { viewModel.mountSelectedArchiveEntry(index: $0) },
          onCancel: { viewModel.pickerContext = nil }
        )
      }
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

  private func handleDiskDrop(providers: [NSItemProvider]) -> Bool {
    guard providers.count == 1, let provider = providers.first else { return false }
    let acceptedExts: Set<String> = [
      "d88", "d77", "2d", "2hd",
      "m3u", "m3u8",
      "zip", "lzh", "lha", "cab", "rar"
    ]
    _ = provider.loadObject(ofClass: URL.self) { url, _ in
      guard let url, acceptedExts.contains(url.pathExtension.lowercased()) else { return }
      DispatchQueue.main.async {
        viewModel.mountDisk(url: url, drive: -1)
      }
    }
    return true
  }

  @ViewBuilder
  private var screenView: some View {
    ZStack {
      MetalScreenViewWrapper(viewModel: viewModel)
      if let session = viewModel.dissolveSession {
        GeometryReader { geo in
          // Match Metal view's aspect-fit (and integer scaling in
          // fullscreen) so the overlay aligns with the actual
          // displayed image and doesn't stretch into the letterbox.
          let displayW: CGFloat = 640
          let displayH: CGFloat = 400
          let scale: CGFloat = {
            if viewModel.isFullScreen,
               Settings.shared.fullscreenIntegerScaling {
              let s = max(1, min(Int(geo.size.width / displayW),
                                 Int(geo.size.height / displayH)))
              return CGFloat(s)
            }
            return min(geo.size.width / displayW,
                       geo.size.height / displayH)
          }()
          let w = displayW * scale
          let h = displayH * scale
          let x = (geo.size.width - w) / 2
          let y = (geo.size.height - h) / 2

          TimelineView(.animation) { ctx in
            let p = session.progress(at: ctx.date)
            ZStack {
              // Solid black behind the dissolving image so
              // (a) the frozen Metal view doesn't peek through
              // dispersed regions, and (b) when the dissolve
              // completes the screen reads as "fully gone"
              // instead of flashing back to the original.
              Color.black
              Image(nsImage: session.snapshot)
                .resizable()
                .interpolation(.none)
                .layerEffect(
                  ShaderLibrary.thanosDissolve(
                    .float2(Float(w), Float(h)),
                    .float(Float(p))
                  ),
                  maxSampleOffset: CGSize(width: 200, height: 200)
                )
            }
            .frame(width: w, height: h)
            .offset(x: x, y: y)
          }
        }
        .allowsHitTesting(false)
      }
    }
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

      // Mouse capture indicator (shown only while the host cursor is
      // captured for bus-mouse input). Control+Esc releases it.
      if viewModel.mouseCapturing {
        Image(systemName: "computermouse.fill")
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(Color.accentColor)
          .font(.system(size: 18))
          .help(NSLocalizedString("Mouse captured — press Control+Esc to release",
                                  comment: "Status bar mouse capture indicator tooltip"))
          .accessibilityLabel(Text(NSLocalizedString("Mouse captured",
                                                     comment: "Status bar mouse capture indicator accessibility label")))
      }

      // Script playback indicator (shown only while a timeline script is playing)
      if viewModel.isPlayingScript {
        Button {
          viewModel.cancelScriptPlayback()
        } label: {
          Image(systemName: "play.diamond")
            .symbolRenderingMode(.hierarchical)
            .symbolEffect(.wiggle.byLayer, options: .repeat(.periodic(delay: 1.0)))
            .foregroundStyle(.green)
            .font(.system(size: 20))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Stop script playback",
                                comment: "Status bar script playback button tooltip"))
      }

      // Operation-recording indicator (distinct from the red A/V record
      // dots and the green playback diamond: indigo "compose" glyph).
      if viewModel.isRecordingScript {
        Button {
          viewModel.stopScriptRecordingAndSave()
        } label: {
          Image(systemName: "square.and.pencil.circle.fill")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.indigo)
            .font(.system(size: 20))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Stop recording and save script",
                                comment: "Status bar operation-recording button tooltip"))
      }

      // Recording indicator (shown only while recording)
      if viewModel.audioRecorder.isRecording {
        Button {
          viewModel.stopRecording()
        } label: {
          Image(systemName: "record.circle.fill")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.red)
            .font(.system(size: 20))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Stop audio recording",
                                comment: "Status bar record button tooltip"))
      }

      if viewModel.videoRecorder.isRecording {
        Button {
          viewModel.stopVideoRecording()
        } label: {
          Image(systemName: "video.circle.fill")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.red)
            .font(.system(size: 20))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Stop video recording (CPU locked at 1×)",
                                comment: "Status bar video record button tooltip"))
      }

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
      .help(String(format: NSLocalizedString("Volume: %lld%%",
                                             comment: "Volume slider tooltip"),
                   viewModel.volumePercent))

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

      let wp = drive == 0 ? viewModel.drive0WriteProtected : viewModel.drive1WriteProtected
      Button(wp ? "Write Protect ✓" : "Write Protect") {
        viewModel.toggleWriteProtect(drive: drive)
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
    let loaded = viewModel.isTapeMounted
    Menu {
      Text(viewModel.tapeDisplayLabel).disabled(true)

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
    .help("Tape: \(viewModel.tapeDisplayLabel)")
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
