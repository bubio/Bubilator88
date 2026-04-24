import SwiftUI
import MetalKit
import EmulatorCore

/// ViewModel that drives the emulator and provides screen output to SwiftUI.
///
/// Machine runs on a dedicated serial queue. VRAM snapshots are rendered
/// on the emulation queue and the resulting CGImage is delivered to main.
@Observable
final class EmulatorViewModel {

    // MARK: - Boot Mode

    /// PC-8801 boot mode — determines ROM, clock speed, and DIP switch config.
    enum BootMode: String, CaseIterable {
        case n88v2  = "N88-BASIC V2"
        case n88v1h = "N88-BASIC V1H"
        case n88v1s = "N88-BASIC V1S"
        case n      = "N-BASIC"
        case custom = "Custom"

        /// Standard (non-custom) modes for menu display.
        static var standardCases: [BootMode] { [.n88v2, .n88v1h, .n88v1s, .n] }

        /// Short label for the status bar.
        var shortLabel: String {
            switch self {
            case .n88v2:  return "V2"
            case .n88v1h: return "V1H"
            case .n88v1s: return "V1S"
            case .n:      return "N"
            case .custom: return "Custom"
            }
        }

        /// Default clock speed for this mode
        var is8MHz: Bool {
            self == .n88v2
        }

        /// DIP SW1 value (bit 0: 1=N88, 0=N; bit 1: 1=BASIC, 0=Terminal)
        /// BubiC: (mode==N ? 0 : 1) | 0xC2
        var dipSw1: UInt8 {
            switch self {
            case .n:      return 0xC2
            case .custom: return Settings.shared.dipSw1
            default:      return 0xC3
            }
        }

        /// DIP SW2 value (bit7=V1, bit6=H, bit3: 0=FDD boot, 1=ROM boot)
        /// Base value 0x31 from QUASI88/BubiC + mode flags, FDD boot default
        var dipSw2: UInt8 {
            switch self {
            case .n88v2:  return 0x71  // 0x31 | H(0x40), FDD boot
            case .n88v1h: return 0xF1  // 0x31 | V1(0x80) | H(0x40), FDD boot
            case .n88v1s: return 0xB1  // 0x31 | V1(0x80), FDD boot
            case .n:      return 0xB1  // 0x31 | V1(0x80), FDD boot
            case .custom: return Settings.shared.dipSw2Base
            }
        }
    }

    // MARK: - CPU Speed

    enum CPUSpeed: String, CaseIterable {
        case x1 = "x1"
        case x2 = "x2"
        case x4 = "x4"
        case x8 = "x8"
        case x16 = "x16"

        var framesPerDraw: Int {
            switch self {
            case .x1: return 1
            case .x2: return 2
            case .x4: return 4
            case .x8: return 8
            case .x16: return 16
            }
        }

        var audioRate: Float {
            Float(framesPerDraw)
        }
    }

    var cpuSpeed: CPUSpeed = .x1 {
        didSet {
            audio.setRate(cpuSpeed.audioRate)
        }
    }

    /// Temporary turbo mode (x8 speed while held).
    var turboMode: Bool = false {
        didSet {
            guard turboMode != oldValue else { return }
            if turboMode {
                savedSpeed = cpuSpeed
                cpuSpeed = .x8
            } else {
                cpuSpeed = savedSpeed
            }
        }
    }
    private var savedSpeed: CPUSpeed = .x1

    // MARK: - Video Filter

    enum VideoFilter: String, CaseIterable {
        case none = "None"
        case linear = "Linear"
        case bicubic = "Bicubic"
        case crt = "CRT"
        case xbrz = "xBRZ"
        case enhanced = "Enhanced"
        case aiUpscaleFast = "AI Upscale (Fast)"
        case aiUpscaleBalanced = "AI Upscale (Balanced)"
        case aiUpscale = "AI Upscale (Quality)"

        var fragmentFunctionName: String {
            switch self {
            case .none: return "fragmentNearest"
            case .linear: return "fragmentLinear"
            case .bicubic: return "fragmentBicubic"
            case .crt: return "fragmentCRT"
            case .xbrz: return "fragmentXBRZ"
            case .enhanced: return "fragmentXBRZ"  // pass 2 uses xBRZ
            case .aiUpscaleFast: return "fragmentNearest"
            case .aiUpscaleBalanced: return "fragmentNearest"
            case .aiUpscale: return "fragmentNearest"  // AI texture is pre-upscaled
            }
        }

        var usesLinearSampler: Bool {
            self == .linear
        }

        var supportsScanlines: Bool {
            switch self {
            case .none, .linear, .bicubic: return true
            case .crt, .xbrz, .enhanced, .aiUpscaleFast, .aiUpscaleBalanced, .aiUpscale: return false
            }
        }

        var requiresAIUpscale: Bool {
            switch self {
            case .aiUpscaleFast, .aiUpscaleBalanced, .aiUpscale: return true
            default: return false
            }
        }

        /// Model name to load for this filter
        var aiModelName: String? {
            switch self {
            case .aiUpscaleFast: return "SRVGGNet_x2_lite"
            case .aiUpscaleBalanced: return "SRVGGNet_x2"
            case .aiUpscale: return "RealESRGAN_x2"
            default: return nil
            }
        }
    }

    var videoFilter: VideoFilter {
        get { VideoFilter(rawValue: Settings.shared.videoFilter) ?? .none }
        set {
            Settings.shared.videoFilter = newValue.rawValue
            metalView?.updateVideoFilter(newValue, scanlineEnabled: effectiveScanlineEnabled)
        }
    }

    var scanlineEnabled: Bool {
        get { Settings.shared.scanlineEnabled }
        set {
            Settings.shared.scanlineEnabled = newValue
            metalView?.updateVideoFilter(videoFilter, scanlineEnabled: effectiveScanlineEnabled)
        }
    }

    var isScanlineAvailable: Bool {
        videoFilter.supportsScanlines
    }

    var effectiveScanlineEnabled: Bool {
        isScanlineAvailable && scanlineEnabled
    }

    // MARK: - HQ Filter Debug Parameters

    var hqOffset: Float = 0.05
    var hqGradient: Float = 0.3
    var hqMaxBlend: Float = 0.3

    // MARK: - Published State (MainActor)

    /// Window scale factor (1, 2, or 4)
    var windowScale: Int {
        get { Settings.shared.windowScale }
        set { Settings.shared.windowScale = newValue }
    }

    /// Fullscreen mode
    var isFullScreen: Bool = false
    var showFullScreenOverlay: Bool = false

    /// Emulation running state
    var isRunning: Bool = false

    // MARK: - Notifications (toast + alert)

    /// Toast message shown briefly over the emulator screen, auto-dismissed
    /// after 2 seconds. Nil when hidden.
    var currentToast: String?

    /// Alert requiring user acknowledgement. Nil when dismissed.
    var currentAlert: (title: String, message: String)?

    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?

    func showToast(_ message: String) {
        toastDismissTask?.cancel()
        currentToast = message
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { self?.currentToast = nil }
        }
    }

    func showAlert(title: String, message: String) {
        currentAlert = (title, message)
    }

    var alertIsPresented: Bool {
        get { currentAlert != nil }
        set { if !newValue { currentAlert = nil } }
    }
    var alertTitle: String { currentAlert?.title ?? "" }
    var alertMessage: String { currentAlert?.message ?? "" }

    /// ROM loaded state
    var romLoaded: Bool = false

    /// Measured frames per second (updated every second while running)
    var fps: Double = 0.0

    /// Current boot mode (backing storage, also used for save state restore without reset)
    var _bootModeStorage: BootMode = .n88v2

    /// Current boot mode — triggers reset on change via UI.
    /// Setting a non-custom mode updates Settings.dipSw1/dipSw2Base.
    var bootMode: BootMode {
        get { _bootModeStorage }
        set {
            _bootModeStorage = newValue
            if newValue != .custom {
                Settings.shared.dipSw1 = newValue.dipSw1
                Settings.shared.dipSw2Base = newValue.dipSw2
            }
            applyBootMode()
        }
    }

    /// Effective boot mode derived from current DIP switch settings.
    var effectiveBootModePreset: BootModePreset {
        BootModePreset.from(dipSw1: Settings.shared.dipSw1, dipSw2Base: Settings.shared.dipSw2Base)
    }

    /// CPU clock mode — persisted via Settings.
    /// Applied on next reset, not immediately.
    var clock8MHz: Bool {
        get { Settings.shared.clock8MHz }
        set {
            Settings.shared.clock8MHz = newValue
            applyBootMode()
        }
    }

    /// Master volume (0.0–1.0) — persisted via Settings.
    var volume: Float {
        get { Settings.shared.volume }
        set {
            Settings.shared.volume = newValue
            applyVolume()
        }
    }

    /// Show/hide the DEBUG menu — persisted via Settings.
    var showDebugMenu: Bool {
        get { Settings.shared.showDebugMenu }
        set { Settings.shared.showDebugMenu = newValue }
    }

    /// Pseudo-stereo chorus effect on mono FM — persisted via Settings.
    var pseudoStereo: Bool {
        get { Settings.shared.pseudoStereo }
        set {
            Settings.shared.pseudoStereo = newValue
            machine.sound.pseudoStereoEnabled = newValue && !immersiveAudio
        }
    }

    /// Immersive audio: place YM2608 channels in 3D space — persisted via Settings.
    var immersiveAudio: Bool {
        get { Settings.shared.immersiveAudio }
        set {
            Settings.shared.immersiveAudio = newValue
            // Disable pseudo-stereo *first*, then enable immersive — avoids a
            // brief window where both flags are true and chorus-processed FM
            // leaks into the spatial buffer.
            machine.sound.pseudoStereoEnabled = pseudoStereo && !newValue
            machine.sound.immersiveOutputEnabled = newValue
            restartAudio()
        }
    }

    /// Update immersive audio 3D positions live (called when user drags channel dots).
    func updateImmersivePositions() {
        audio.updateSpatialPositions()
    }

    /// Volume as integer percentage for display.
    var volumePercent: Int {
        Int((volume * 100).rounded())
    }

    /// Increase volume by 10%.
    func volumeUp() {
        let step = Int((volume * 10).rounded())
        volume = Float(min(10, step + 1)) / 10.0
    }

    /// Decrease volume by 10%.
    func volumeDown() {
        let step = Int((volume * 10).rounded())
        volume = Float(max(0, step - 1)) / 10.0
    }

    /// Currently active clock mode (reflects what Machine is actually using)
    private(set) var activeClock8MHz: Bool = true

    /// Mounted disk names for UI display
    var drive0Name: String = "Empty"
    var drive1Name: String = "Empty"

    /// Original D88 file names (for save state display)
    var drive0FileName: String?
    var drive1FileName: String?

    /// Per-drive metadata for disk switching from menu
    var drive0Info: MountedDiskInfo?
    var drive1Info: MountedDiskInfo?

    /// Currently mounted cassette tape: display name ("Empty" when none),
    /// source URL (for save-state metadata / recent reload), and format.
    var tapeName: String = "Empty"
    var tapeSourceURL: URL?
    var tapeFormat: CassetteDeck.Format?

    /// Disk access LED indicators (true = active this frame)
    var drive0Access: Bool = false
    var drive1Access: Bool = false

    /// Sub-CPU debug info
    var subCpuInfo: String = ""

    /// File picker state (triggered from menu)
    var showingDiskPicker: Bool = false
    var diskPickerDrive: Int = 0

    /// Cassette-tape file picker state.
    var showingTapePicker: Bool = false

    /// Multi-image D88 selection state
    var pendingDiskImages: [D88Disk] = []
    var pendingDiskURL: URL? = nil
    var pendingArchiveEntryName: String? = nil
    var showingImagePicker: Bool = false

    /// Archive file selection state
    var pendingArchiveEntries: [ArchiveEntry] = []
    var pendingArchiveURL: URL? = nil
    var showingArchiveFilePicker: Bool = false

    /// Save state sheet
    var showingSaveStateSheet: Bool = false
    var saveStateSheetMode: SaveStateSheetMode = .save
    enum SaveStateSheetMode { case save, load }

    /// Debug audio source toggles
    var fmEnabled: Bool = true {
        didSet { applyDebugAudioMask() }
    }

    var ssgEnabled: Bool = true {
        didSet { applyDebugAudioMask() }
    }

    var adpcmEnabled: Bool = true {
        didSet { applyDebugAudioMask() }
    }

    /// Force YM2203 (OPN) mode — programs see register 0xFF as 0x00
    var forceOPNMode: Bool = false {
        didSet { machine.sound.forceOPNMode = forceOPNMode }
    }

    var rhythmEnabled: Bool = true {
        didSet { applyDebugAudioMask() }
    }

    // MARK: - Debugger

    /// Owned debugger instance — always present so breakpoints persist
    /// across Debug Window open/close cycles. Only attached to Machine
    /// while the window is visible, keeping the hot path fast otherwise.
    let debugger = Debugger()

    /// Attach the debugger to Machine. Call when opening the debug window.
    func attachDebugger() {
        emuQueue.async { [machine, debugger] in
            machine.debugger = debugger
        }
    }

    /// Detach the debugger from Machine. Call when closing the debug
    /// window so the hot path returns to full speed.
    func detachDebugger() {
        emuQueue.async { [machine] in
            machine.debugger = nil
        }
    }

    /// Debug-only experiment: suppress text layer overlay while keeping
    /// graphics and attribute-graphics rendering intact.
    var debugTextLayerEnabled: Bool = true {
        didSet {
            guard !isRunning else { return }
            renderScreen()
        }
    }

    // MARK: - Internal (shared across extension files)

    /// All Machine access is serialized on this queue.
    let emuQueue = DispatchQueue(label: "com.bubio.bubilator88.emu", qos: .userInteractive)

    let machine: Machine
    nonisolated(unsafe) let renderer = ScreenRenderer()
    @ObservationIgnored nonisolated(unsafe) var pixelBuffer: [UInt8]

    /// UI update throttle counter (render thread)
    @ObservationIgnored nonisolated(unsafe) var uiUpdateCounter: Int = 0

    /// Lock for keyboard state (written from main, read from emu queue).
    private let keyboardLock = NSLock()

    /// Paste queue that replays clipboard text as simulated keystrokes.
    @ObservationIgnored let pasteQueue = TextPasteQueue()
    @ObservationIgnored let pasteQueueLock = NSLock()

    /// Audio output for YM2608 SSG sound
    let audio = AudioOutput()

    /// Multichannel audio recorder (FM/SSG/ADPCM/Rhythm/Mix).
    let audioRecorder = AudioRecorder()

    /// FDD access sound effects
    let fddSound = FDDSound()
    let gameController = GameControllerManager()

    /// Translation overlay manager
    let translationManager = TranslationManager()

    /// Toggle translation overlay on/off.
    func toggleTranslation(_ enabled: Bool) {
        if enabled {
            if translationManager.isSessionActive {
                // Re-activation: just show cached results instantly
                translationManager.show()
            } else {
                // First activation: establish session and kick off OCR
                translationManager.isSessionActive = true
                translationManager.prepareTranslation()
                translationManager.show()
                triggerImmediateOCR()
            }
        } else {
            translationManager.hide()
        }
    }

    /// Trigger OCR immediately with current pixel buffer.
    func triggerImmediateOCR() {
        let buffer = emuQueue.sync { Array(pixelBuffer) }
        Task {
            await translationManager.processOCR(pixelBuffer: buffer, width: 640, height: 400)
        }
    }

#if DEBUG
    /// Debug-only text DMA snapshot auto-dump request, written once after launch.
    @ObservationIgnored nonisolated let textDMASnapshotAutoDumpRequested: Bool = {
        ProcessInfo.processInfo.environment["BUBILATOR88_TEXT_DMA_SNAPSHOT"] != nil
    }()

    @ObservationIgnored nonisolated let textDMASnapshotDumpPath: String = {
        ProcessInfo.processInfo.environment["BUBILATOR88_TEXT_DMA_SNAPSHOT_PATH"]
            ?? "/tmp/bubilator88-text-dma-snapshot.txt"
    }()

    @ObservationIgnored nonisolated let textDMASnapshotTriggerPath: String = {
        ProcessInfo.processInfo.environment["BUBILATOR88_TEXT_DMA_TRIGGER_PATH"]
            ?? "/tmp/bubilator88-text-dma-trigger"
    }()

    @ObservationIgnored nonisolated(unsafe) var textDMASnapshotAutoDumped = false

#endif

    // MARK: - Init

    init() {
        self.machine = Machine()
        self.pixelBuffer = Array(repeating: 0, count: ScreenRenderer.bufferSize400)
        activeClock8MHz = clock8MHz
        machine.bus.dipSw1 = _bootModeStorage.dipSw1
        // Drive 0 is always empty at init → ROM boot (bit 3 = 1)
        machine.bus.dipSw2 = _bootModeStorage.dipSw2 | 0x08
        machine.reset()
        machine.clock8MHz = clock8MHz
        machine.sound.immersiveOutputEnabled = Settings.shared.immersiveAudio
        machine.sound.pseudoStereoEnabled = pseudoStereo && !immersiveAudio
        audio.sound = machine.sound
        audio.recorder = audioRecorder

        // FDD sound callbacks (wrap existing SubSystem callbacks)
        let originalOnSeekStep = machine.subSystem.fdc.onSeekStep
        machine.subSystem.fdc.onSeekStep = { [weak self] drive, track in
            originalOnSeekStep?(drive, track)
            self?.fddSound.playSeekStep(drive: drive)
        }
        let originalOnDiskAccess = machine.subSystem.fdc.onDiskAccess
        machine.subSystem.fdc.onDiskAccess = { [weak self] drive in
            originalOnDiskAccess?(drive)
            self?.fddSound.playReadAccess(drive: drive)
        }
    }

    // MARK: - Execution Control

    /// Metal view reference for start/stop control
    weak var metalView: EmulatorMetalView?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        showToast("Running")

        audio.start(spatial: Settings.shared.immersiveAudio)
        applyVolume()
        audio.setRate(cpuSpeed.audioRate)
        if Settings.shared.fddSound {
            fddSound.volume = FDDSound.volume(for: Settings.shared.fddSoundVolumeLevel)
            fddSound.start(outputDeviceUID: Settings.shared.fddSoundDeviceUID)
        }
        if Settings.shared.gameControllerEnabled {
            gameController.start(viewModel: self)
        }

        // Metal path: MTKView drives frame timing via draw(in:)
        metalView?.startEmulation()
    }

    /// Restart audio engine to apply new settings (buffer size, spatial mode).
    func restartAudio() {
        guard isRunning else { return }
        audio.stop()
        audio.start(spatial: Settings.shared.immersiveAudio)
        applyVolume()
        audio.setRate(cpuSpeed.audioRate)
    }

    /// Internal tear-down of the run loop. Stops Metal, audio, FDD
    /// sound, and game controller, but preserves all emulator state
    /// (CPU registers, memory, CRTC, YM2608) so the next `start()`
    /// resumes from exactly where we left off. Callers that need
    /// user-visible "pause" semantics should go through `pause()`
    /// instead, which also handles translation OCR and the toast.
    func stop() {
        metalView?.stopEmulation()
        audio.stop()
        fddSound.stop()
        gameController.stop()

        isRunning = false
        fps = 0.0
    }

    /// User-facing pause. Same preserved-state semantics as `stop()`
    /// but with the UX polish: guards against double-pause, surfaces
    /// a "Paused" toast, and when the translation overlay is active
    /// runs one fresh OCR pass on the now-frozen frame so the
    /// overlay reflects the exact moment the user froze — important
    /// during auto-scrolling dialogue where the stale OCR would
    /// otherwise show whatever line was captured up to 3 seconds
    /// earlier. Called from both the Emulator menu Pause button and
    /// the Debug Window's Pause button; they are the same operation.
    ///
    /// Internal callers that need to tear the run loop down as part
    /// of a larger operation (reset, save-state load/save) should
    /// still call `stop()` directly to skip the toast and OCR.
    func pause() {
        guard isRunning else { return }
        stop()
        showToast("Paused")
        if translationManager.isSessionActive {
            triggerImmediateOCR()
        }
    }

    /// User-facing resume from a paused state. Guards against
    /// double-resume and surfaces a "Running" toast. Called from
    /// both the Emulator menu Resume button and the Debug Window's
    /// Run button.
    func resume() {
        guard !isRunning else { return }
        start()
    }

    /// Render one frame synchronously into the pixel buffer and
    /// force the Metal view to upload + draw it once, even while
    /// `isRunning == false`. Used by the debugger's Step button so
    /// the visual effect of executing a single instruction (e.g., a
    /// write to VRAM) becomes visible without resuming the render
    /// loop. No effect when Metal is still running — the normal
    /// draw cycle will pick up the change.
    func renderSingleFrame() {
        renderCurrentFrame(into: &pixelBuffer, blinkCursor: false)
        metalView?.draw()
    }

    func reset() {
        performReset(resetTranslation: true)
    }

    private func applyBootMode() {
        performReset(resetTranslation: false)
    }

    /// Shared reset core. Uses the current `bootMode` (the status-bar
    /// backing storage) as the single source of truth for DIP switch
    /// values, so the UI label and the actual ROM-visible mode can never
    /// drift — even if Settings.dipSw1/dipSw2Base were left stale by a
    /// previous save-state load or another unusual path.
    private func performReset(resetTranslation: Bool) {
        let wasRunning = isRunning
        stop()
        cancelPasteQueue()
        let mode = _bootModeStorage
        let sw1 = mode.dipSw1
        let sw2Base = mode.dipSw2
        // Keep Settings in sync so a user toggling back to the same mode
        // through the UI still sees a consistent stored state.
        if mode != .custom {
            if Settings.shared.dipSw1 != sw1 { Settings.shared.dipSw1 = sw1 }
            if Settings.shared.dipSw2Base != sw2Base { Settings.shared.dipSw2Base = sw2Base }
        }
        let use8MHz = clock8MHz
        emuQueue.sync {
            // Auto-select ROM/DISK boot: if drive 0 is empty, set DIP SW2
            // bit 3 to skip the ~30s disk-boot timeout and go straight to
            // BASIC. When a disk is mounted, clear bit 3 for normal IPL boot.
            let hasDisk = machine.subSystem.drives[0] != nil
            let sw2 = hasDisk ? (sw2Base & ~UInt8(0x08)) : (sw2Base | 0x08)
            machine.bus.dipSw1 = sw1
            machine.bus.dipSw2 = sw2
            machine.reset()
            machine.clock8MHz = use8MHz
        }
        activeClock8MHz = use8MHz
        if romLoaded { loadROMs() }
        if resetTranslation { translationManager.hardReset() }
        renderScreen()
        if wasRunning { start() }
    }

    // MARK: - Save State

    private static let saveStateDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Bubilator88/SaveStates", isDirectory: true)
    }()

    private func saveStatePath(slot: Int) -> URL {
        Self.saveStateDir.appendingPathComponent("slot_\(slot).b88s")
    }

    /// Public accessor for sheet view.
    func saveStatePath(forSlot slot: Int) -> URL {
        saveStatePath(slot: slot)
    }

    private var quickSavePath: URL {
        Self.saveStateDir.appendingPathComponent("quicksave.b88s")
    }

    /// App-level metadata saved alongside the machine state.
    struct SaveMeta: Codable {
        var bootMode: String
        var clock8MHz: Bool
        var disk0: String?
        var disk1: String?
        var drive0Name: String?
        var drive1Name: String?
        var drive0FileName: String?
        var drive1FileName: String?
        var drive0SourceURL: String?
        var drive1SourceURL: String?
        var drive0ImageIndex: Int?
        var drive1ImageIndex: Int?
        var drive0ArchiveEntry: String?
        var drive1ArchiveEntry: String?
    }

    private func metaPath(for statePath: URL) -> URL {
        statePath.deletingPathExtension().appendingPathExtension("meta.json")
    }

    private func thumbnailPath(for statePath: URL) -> URL {
        statePath.deletingPathExtension().appendingPathExtension("thumb.png")
    }

    private func captureThumbnail() -> Data? {
        let srcWidth = 640
        let srcHeight = 400
        // Create full-size CGImage from pixelBuffer (RGBA)
        let dataProvider = CGDataProvider(data: Data(pixelBuffer) as CFData)!
        guard let fullImage = CGImage(
            width: srcWidth, height: srcHeight,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: srcWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: dataProvider,
            decode: nil, shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        // Draw scaled down to 320x200
        let thumbWidth = 320
        let thumbHeight = 200
        guard let ctx = CGContext(
            data: nil, width: thumbWidth, height: thumbHeight,
            bitsPerComponent: 8, bytesPerRow: thumbWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(fullImage, in: CGRect(x: 0, y: 0, width: thumbWidth, height: thumbHeight))
        guard let thumbImage = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: thumbImage)
        return rep.representation(using: .png, properties: [:])
    }

    private func performSave(to path: URL) {
        let wasRunning = isRunning
        if wasRunning { stop() }
        // Capture thumbnail on main thread (pixelBuffer access)
        let thumbData = captureThumbnail()
        emuQueue.sync {
            let data = machine.createSaveState()
            try? FileManager.default.createDirectory(at: Self.saveStateDir, withIntermediateDirectories: true)
            try? Data(data).write(to: path, options: .atomic)
            let meta = SaveMeta(
                bootMode: bootMode.rawValue,
                clock8MHz: clock8MHz,
                disk0: machine.subSystem.drives[0]?.name,
                disk1: machine.subSystem.drives[1]?.name,
                drive0Name: self.drive0Name == "Empty" ? nil : self.drive0Name,
                drive1Name: self.drive1Name == "Empty" ? nil : self.drive1Name,
                drive0FileName: self.drive0FileName,
                drive1FileName: self.drive1FileName,
                drive0SourceURL: self.drive0Info?.sourceURL?.absoluteString,
                drive1SourceURL: self.drive1Info?.sourceURL?.absoluteString,
                drive0ImageIndex: self.drive0Info?.currentImageIndex,
                drive1ImageIndex: self.drive1Info?.currentImageIndex,
                drive0ArchiveEntry: self.drive0Info?.archiveEntryName,
                drive1ArchiveEntry: self.drive1Info?.archiveEntryName
            )
            try? JSONEncoder().encode(meta).write(to: metaPath(for: path), options: .atomic)
        }
        if let thumbData {
            try? thumbData.write(to: thumbnailPath(for: path), options: .atomic)
        }
        saveStateRevision += 1
        if wasRunning { start() }
        showToast(NSLocalizedString("State saved", comment: ""))
    }

    private func performLoad(from path: URL) {
        guard let fileData = try? Data(contentsOf: path) else {
            showToast(NSLocalizedString("Save state not found", comment: ""))
            return
        }
        let wasRunning = isRunning
        if wasRunning { stop() }
        var loadError: Error?
        emuQueue.sync {
            do {
                try machine.loadSaveState(Array(fileData))
            } catch {
                loadError = error
            }
        }
        if let loadError {
            if wasRunning { start() }
            showToast(saveStateLoadErrorMessage(loadError))
            return
        }
        let meta: SaveMeta? = {
            guard let metaData = try? Data(contentsOf: metaPath(for: path)) else { return nil }
            return try? JSONDecoder().decode(SaveMeta.self, from: metaData)
        }()
        if let meta {
            if let mode = BootMode(rawValue: meta.bootMode) {
                _bootModeStorage = mode
                // Keep Settings.dipSw{1,2}Base in sync with the restored boot
                // mode. The save state doesn't serialize DIP switches, so on
                // the next Reset the ViewModel would otherwise re-apply the
                // previously-selected user mode's DIP values to the bus —
                // making the status bar disagree with the actual mode the
                // ROM boots into (e.g. UI says V2 but the game behaves as V1).
                if mode != .custom {
                    Settings.shared.dipSw1 = mode.dipSw1
                    Settings.shared.dipSw2Base = mode.dipSw2
                    let sw1 = mode.dipSw1
                    let sw2 = mode.dipSw2
                    emuQueue.sync {
                        machine.bus.dipSw1 = sw1
                        machine.bus.dipSw2 = sw2
                    }
                }
            }
            Settings.shared.clock8MHz = meta.clock8MHz
            drive0Name = meta.drive0Name ?? machine.subSystem.drives[0]?.name ?? "Empty"
            drive1Name = meta.drive1Name ?? machine.subSystem.drives[1]?.name ?? "Empty"
            drive0FileName = meta.drive0FileName
            drive1FileName = meta.drive1FileName
        } else {
            drive0Name = machine.subSystem.drives[0]?.name ?? "Empty"
            drive1Name = machine.subSystem.drives[1]?.name ?? "Empty"
            drive0FileName = nil
            drive1FileName = nil
        }
        // Reconstruct MountedDiskInfo from saved source URL or restored disk
        drive0Info = reconstructDiskInfo(drive: 0, meta: meta)
        drive1Info = reconstructDiskInfo(drive: 1, meta: meta)
        activeClock8MHz = machine.clock8MHz
        renderScreen()
        if wasRunning { start() }
        showToast(NSLocalizedString("State loaded", comment: ""))
    }

    private func saveStateLoadErrorMessage(_ error: Error) -> String {
        if let err = error as? SaveStateError {
            switch err {
            case .invalidMagic:
                return NSLocalizedString("Load failed: not a save state file", comment: "")
            case .unsupportedVersion(let v):
                let fmt = NSLocalizedString("Load failed: incompatible save state (v%u)", comment: "")
                return String(format: fmt, v)
            case .missingSections, .sectionTooSmall, .invalidData, .endOfData:
                return NSLocalizedString("Load failed: save state is corrupt", comment: "")
            }
        }
        return NSLocalizedString("Load failed", comment: "")
    }

    /// Reconstruct MountedDiskInfo for a drive after loading a save state.
    /// If the original source file is available, re-parse it for multi-image support.
    /// For archives, re-extract the relevant entry from the archive.
    /// Otherwise, build minimal info from the restored single disk.
    private func reconstructDiskInfo(drive: Int, meta: SaveMeta?) -> MountedDiskInfo? {
        guard let disk = machine.subSystem.drives[drive] else { return nil }
        let fileName = (drive == 0 ? drive0FileName : drive1FileName) ?? "Disk"
        let savedURLString = drive == 0 ? meta?.drive0SourceURL : meta?.drive1SourceURL
        let savedImageIndex = drive == 0 ? meta?.drive0ImageIndex : meta?.drive1ImageIndex
        let archiveEntry = drive == 0 ? meta?.drive0ArchiveEntry : meta?.drive1ArchiveEntry

        if let urlString = savedURLString, let url = URL(string: urlString),
           let data = try? Data(contentsOf: url) {

            // Check if source is an archive
            if let archiveEntries = ArchiveExtractor.extractDiskImages(data) {
                if let entryName = archiveEntry {
                    // Specific entry within archive
                    if let entry = archiveEntries.first(where: { $0.filename == entryName }) {
                        let allImages = D88Disk.parseAll(data: Array(entry.data))
                        if !allImages.isEmpty {
                            let d88Name = (entryName as NSString).deletingPathExtension
                            let imageNames = allImages.enumerated().map { i, d in
                                d.name.isEmpty ? (allImages.count > 1 ? "\(d88Name) #\(i)" : d88Name) : d.name
                            }
                            let groups = [DiskImageGroup(d88FileName: d88Name,
                                                         startIndex: 0, count: allImages.count)]
                            let index = min(savedImageIndex ?? 0, allImages.count - 1)
                            return MountedDiskInfo(sourceURL: url, archiveEntryName: entryName,
                                                   allImages: allImages, imageNames: imageNames,
                                                   currentImageIndex: index, fileName: fileName,
                                                   imageGroups: groups)
                        }
                    }
                } else {
                    // Mount 0&1 mode: flatten all entries
                    var allDisks: [(disk: D88Disk, name: String)] = []
                    var groups: [DiskImageGroup] = []
                    for entry in archiveEntries {
                        let disks = D88Disk.parseAll(data: Array(entry.data))
                        let baseName = (entry.filename as NSString).deletingPathExtension
                        groups.append(DiskImageGroup(d88FileName: baseName,
                                                     startIndex: allDisks.count, count: disks.count))
                        for d in disks {
                            allDisks.append((d, d.name.isEmpty ? baseName : d.name))
                        }
                    }
                    if !allDisks.isEmpty {
                        let index = min(savedImageIndex ?? 0, allDisks.count - 1)
                        return MountedDiskInfo(sourceURL: url, archiveEntryName: nil,
                                               allImages: allDisks.map(\.disk),
                                               imageNames: allDisks.map(\.name),
                                               currentImageIndex: index, fileName: fileName,
                                               imageGroups: groups)
                    }
                }
            } else {
                // Direct D88 file (existing logic)
                let allImages = D88Disk.parseAll(data: [UInt8](data))
                if !allImages.isEmpty {
                    let imageNames = allImages.enumerated().map { i, d in
                        d.name.isEmpty ? (allImages.count > 1 ? "\(fileName) #\(i)" : fileName) : d.name
                    }
                    let groups = [DiskImageGroup(d88FileName: fileName,
                                                 startIndex: 0, count: allImages.count)]
                    let index = min(savedImageIndex ?? 0, allImages.count - 1)
                    return MountedDiskInfo(sourceURL: url, archiveEntryName: nil,
                                           allImages: allImages, imageNames: imageNames,
                                           currentImageIndex: index, fileName: fileName,
                                           imageGroups: groups)
                }
            }
        }

        // Fallback: single disk from restored state
        let name = disk.name.isEmpty ? fileName : disk.name
        return MountedDiskInfo(sourceURL: nil, archiveEntryName: nil,
                               allImages: [disk], imageNames: [name],
                               currentImageIndex: 0, fileName: fileName,
                               imageGroups: [DiskImageGroup(d88FileName: fileName,
                                                            startIndex: 0, count: 1)])
    }

    func quickSave() { performSave(to: quickSavePath) }
    func quickLoad() { performLoad(from: quickSavePath) }
    func saveState(slot: Int) { performSave(to: saveStatePath(slot: slot)) }
    func loadState(slot: Int) { performLoad(from: saveStatePath(slot: slot)) }

    func hasState(slot: Int) -> Bool {
        FileManager.default.fileExists(atPath: saveStatePath(slot: slot).path)
    }

    var hasQuickSave: Bool {
        _ = saveStateRevision
        return FileManager.default.fileExists(atPath: quickSavePath.path)
    }

    /// Short info line shown below Quick Load in the menu.
    /// Incremented after each quick save to trigger SwiftUI menu refresh.
    var saveStateRevision: Int = 0

    var quickSaveInfo: String {
        _ = saveStateRevision  // observe to trigger refresh
        guard hasQuickSave,
              let attrs = try? FileManager.default.attributesOfItem(atPath: quickSavePath.path),
              let date = attrs[.modificationDate] as? Date else { return "" }
        let fmt = DateFormatter.stable(pattern: "MM/dd HH:mm")
        var parts = [fmt.string(from: date)]
        if let metaData = try? Data(contentsOf: metaPath(for: quickSavePath)),
           let meta = try? JSONDecoder().decode(SaveMeta.self, from: metaData) {
            let name0: String? = meta.drive0FileName ?? meta.drive0Name
            let name1: String? = meta.drive1FileName ?? meta.drive1Name
            var names: [String] = []
            if let n = name0, !n.isEmpty { names.append(n) }
            if let n = name1, !n.isEmpty, n != name0 { names.append(n) }
            parts.append(contentsOf: names)
        }
        return parts.joined(separator: " — ")
    }

    var quickSaveLabel: String {
        guard hasQuickSave,
              let attrs = try? FileManager.default.attributesOfItem(atPath: quickSavePath.path),
              let date = attrs[.modificationDate] as? Date else {
            return "Quick Load"
        }
        let fmt = DateFormatter.stable(pattern: "MM/dd HH:mm")
        var label = "Quick Load — \(fmt.string(from: date))"
        if let metaData = try? Data(contentsOf: metaPath(for: quickSavePath)),
           let meta = try? JSONDecoder().decode(SaveMeta.self, from: metaData) {
            let disks = [meta.disk0, meta.disk1].compactMap { $0 }.filter { !$0.isEmpty }
            if !disks.isEmpty {
                label += " — \(disks.joined(separator: ", "))"
            }
        }
        return label
    }

    var quickSaveThumbnail: NSImage? {
        guard let data = try? Data(contentsOf: thumbnailPath(for: quickSavePath)) else { return nil }
        return NSImage(data: data)
    }

    func loadSlotMeta(_ slot: Int) -> SaveMeta? {
        guard let data = try? Data(contentsOf: metaPath(for: saveStatePath(slot: slot))) else { return nil }
        return try? JSONDecoder().decode(SaveMeta.self, from: data)
    }

    func slotThumbnail(_ slot: Int) -> NSImage? {
        let path = thumbnailPath(for: saveStatePath(slot: slot))
        guard let data = try? Data(contentsOf: path) else { return nil }
        return NSImage(data: data)
    }

    func slotLabel(_ slot: Int) -> String {
        let path = saveStatePath(slot: slot)
        guard FileManager.default.fileExists(atPath: path.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let date = attrs[.modificationDate] as? Date else {
            return "Slot \(slot) — Empty"
        }
        let fmt = DateFormatter.stable(pattern: "MM/dd HH:mm")
        var label = "Slot \(slot) — \(fmt.string(from: date))"
        if let meta = loadSlotMeta(slot) {
            let disks = [meta.disk0, meta.disk1].compactMap { $0 }.filter { !$0.isEmpty }
            if !disks.isEmpty {
                label += " — \(disks.joined(separator: ", "))"
            }
        }
        return label
    }

    // MARK: - Keyboard

    /// Handle key down event. Maps macOS keyCode to PC-8801 keyboard matrix.
    func keyDown(_ keyCode: UInt16) {
        // ESC during an in-flight clipboard paste cancels the paste and is
        // swallowed, matching X88000M. Otherwise ESC reaches the emulator
        // normally (Keyboard.esc at row 9 / bit 7).
        if keyCode == 0x35 && !pasteQueue.isEmpty {
            cancelPasteQueue()
            return
        }
        guard let key = KeyMapping.pc88Key(for: keyCode) else { return }
        keyboardLock.lock()
        machine.keyboard.pressKey(row: key.row, bit: key.bit)
        keyboardLock.unlock()
    }

    func keyUp(_ keyCode: UInt16) {
        guard let key = KeyMapping.pc88Key(for: keyCode) else { return }
        keyboardLock.lock()
        machine.keyboard.releaseKey(row: key.row, bit: key.bit)
        keyboardLock.unlock()
    }

    /// Press a PC-8801 key directly (used by game controller).
    func pressKey(_ key: Keyboard.Key) {
        keyboardLock.lock()
        machine.keyboard.pressKey(row: key.row, bit: key.bit)
        keyboardLock.unlock()
    }

    /// Release a PC-8801 key directly (used by game controller).
    func releaseKey(_ key: Keyboard.Key) {
        keyboardLock.lock()
        machine.keyboard.releaseKey(row: key.row, bit: key.bit)
        keyboardLock.unlock()
    }
}

// MARK: - Mounted Disk Info

/// A group of disk images originating from a single D88 file.
struct DiskImageGroup {
    let d88FileName: String
    let startIndex: Int
    let count: Int
}

/// Metadata about a mounted disk source for menu-based disk switching.
struct MountedDiskInfo {
    let sourceURL: URL?
    let archiveEntryName: String?
    let allImages: [D88Disk]
    let imageNames: [String]
    var currentImageIndex: Int
    let fileName: String
    let imageGroups: [DiskImageGroup]
}
