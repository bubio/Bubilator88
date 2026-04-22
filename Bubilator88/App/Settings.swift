import Foundation

/// Centralized persistent settings backed by UserDefaults.
///
/// All user preferences that survive across sessions live here.
/// Access via `Settings.shared`.
@Observable
final class Settings {
    static let shared = Settings()

    /// CPU clock mode (true = 8 MHz, false = 4 MHz).
    var clock8MHz: Bool = false {
        didSet { UserDefaults.standard.set(clock8MHz, forKey: "clock8MHz") }
    }

    /// Master volume level (0.0–1.0).
    var volume: Float = 0.5 {
        didSet { UserDefaults.standard.set(volume, forKey: "volume") }
    }
 
    /// Pseudo-stereo: chorus effect on mono FM output for stereo widening.
    var pseudoStereo: Bool = false {
        didSet { UserDefaults.standard.set(pseudoStereo, forKey: "pseudoStereo") }
    }

    // MARK: - DIP Switches

    /// DIP switch 1 (port 0x30 read). Applied on reset.
    var dipSw1: UInt8 = 0xC3 {
        didSet { UserDefaults.standard.set(Int(dipSw1), forKey: "dipSw1") }
    }

    /// DIP switch 2 base value (port 0x31 read, excluding bit 3 which is dynamic).
    /// Applied on reset.
    var dipSw2Base: UInt8 = 0x71 {
        didSet { UserDefaults.standard.set(Int(dipSw2Base), forKey: "dipSw2Base") }
    }

    // MARK: - UI

    /// Show the DEBUG menu in the menu bar.
    var showDebugMenu: Bool = false {
        didSet { UserDefaults.standard.set(showDebugMenu, forKey: "showDebugMenu") }
    }

    // MARK: - Video Filter

    /// Video filter mode (raw value of VideoFilter enum).
    var videoFilter: String = "None" {
        didSet { UserDefaults.standard.set(videoFilter, forKey: "videoFilter") }
    }

    /// Scanline overlay enabled (only effective with None/Linear/Bicubic filters).
    var scanlineEnabled: Bool = false {
        didSet { UserDefaults.standard.set(scanlineEnabled, forKey: "scanlineEnabled") }
    }

    /// Window scale factor (1, 2, or 4).
    var windowScale: Int = 1 {
        didSet { UserDefaults.standard.set(windowScale, forKey: "windowScale") }
    }

    /// Fullscreen scaling mode: true = integer scaling (pixel-perfect), false = fit to screen.
    var fullscreenIntegerScaling: Bool = false {
        didSet { UserDefaults.standard.set(fullscreenIntegerScaling, forKey: "fullscreenIntegerScaling") }
    }

    /// Show cassette tape icon in the status bar.
    var showTapeInStatusBar: Bool = false {
        didSet { UserDefaults.standard.set(showTapeInStatusBar, forKey: "showTapeInStatusBar") }
    }

    /// Screenshot image format.
    var screenshotFormat: String = "png" {
        didSet { UserDefaults.standard.set(screenshotFormat, forKey: "screenshotFormat") }
    }

    /// Auto-save screenshots to a preset directory instead of showing
    /// NSSavePanel every time. Default is true (auto-save to ~/Pictures).
    var screenshotAutoSave: Bool = true {
        didSet { UserDefaults.standard.set(screenshotAutoSave, forKey: "screenshotAutoSave") }
    }

    /// Directory for auto-saved screenshots (absolute path). Nil means
    /// no directory has been chosen yet.
    var screenshotDirectory: String? = nil {
        didSet {
            if let dir = screenshotDirectory {
                UserDefaults.standard.set(dir, forKey: "screenshotDirectory")
            } else {
                UserDefaults.standard.removeObject(forKey: "screenshotDirectory")
            }
        }
    }

    // MARK: - Audio

    /// Audio ring buffer size in milliseconds (20–500).
    var audioBufferMs: Int = 100 {
        didSet { UserDefaults.standard.set(audioBufferMs, forKey: "audioBufferMs") }
    }

    /// Immersive audio: place YM2608 channels in 3D space (requires compatible headphones).
    var immersiveAudio: Bool = false {
        didSet { UserDefaults.standard.set(immersiveAudio, forKey: "spatialAudio") }
    }

    /// Immersive audio channel positions (x = L/R spread, z = front/back depth).
    var immersivePositions: ImmersiveAudioPositions = .defaults {
        didSet {
            if let data = try? JSONEncoder().encode(immersivePositions) {
                UserDefaults.standard.set(data, forKey: "immersivePositions")
            }
        }
    }

    /// FDD access sound (synthesized seek/read sounds).
    var fddSound: Bool = true {
        didSet { UserDefaults.standard.set(fddSound, forKey: "fddSound") }
    }

    /// FDD アクセス音の出力先デバイス UID。空文字列 = システムデフォルト。
    var fddSoundDeviceUID: String = "" {
        didSet { UserDefaults.standard.set(fddSoundDeviceUID, forKey: "fddSoundDeviceUID") }
    }

    /// FDD アクセス音の音量レベル。0=小(30%), 1=中(60%), 2=大(100%)。デフォルトは大。
    var fddSoundVolumeLevel: Int = 2 {
        didSet { UserDefaults.standard.set(fddSoundVolumeLevel, forKey: "fddSoundVolumeLevel") }
    }

    // MARK: - Game Controller

    /// Enable game controller input.
    var gameControllerEnabled: Bool = true {
        didSet { UserDefaults.standard.set(gameControllerEnabled, forKey: "gameControllerEnabled") }
    }

    /// Enable haptic feedback on game controller during disk access.
    var controllerHapticEnabled: Bool = true {
        didSet { UserDefaults.standard.set(controllerHapticEnabled, forKey: "controllerHapticEnabled") }
    }

    /// Per-controller-type button mappings (keyed by productCategory).
    var controllerMappings: [String: ControllerButtonMapping] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(controllerMappings) {
                UserDefaults.standard.set(data, forKey: "controllerMappings")
            }
        }
    }

    // MARK: - Keyboard

    /// Map arrow keys to numpad (↑→8, ↓→2, ←→4, →→6).
    var arrowKeysAsNumpad: Bool = false {
        didSet { UserDefaults.standard.set(arrowKeysAsNumpad, forKey: "arrowKeysAsNumpad") }
    }

    /// Map number row keys (1-0) to numpad (kp1-kp0).
    var numberRowAsNumpad: Bool = false {
        didSet { UserDefaults.standard.set(numberRowAsNumpad, forKey: "numberRowAsNumpad") }
    }

    /// Custom key assignments for PC-8801 special keys (STOP, COPY, etc.).
    /// Keys: PC88SpecialKey.rawValue, Values: macOS keyCode as Int.
    var specialKeyMapping: [String: Int] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(specialKeyMapping) {
                UserDefaults.standard.set(data, forKey: "specialKeyMapping")
            }
        }
    }

    // MARK: - Translation

    /// Target language for translation (maximal BCP 47 identifier, e.g. "en-Latn-US").
    var translationTargetLanguage: String = "en-Latn-US" {
        didSet { UserDefaults.standard.set(translationTargetLanguage, forKey: "translationTargetLanguage") }
    }

    /// Keyboard layout detection mode.
    var keyboardLayout: KeyboardLayout = .auto {
        didSet { UserDefaults.standard.set(keyboardLayout.rawValue, forKey: "keyboardLayout") }
    }

    /// Recently used disk files (max 10, newest first).
    var recentDiskFiles: [RecentDiskEntry] = []

    /// Recently used cassette-tape files (max 10, newest first). Stored
    /// in a separate list from disks so the two menus can be offered
    /// independently without mode cross-contamination.
    var recentTapeFiles: [RecentDiskEntry] = []

    /// Paths already in the recent list (for O(1) dedup).
    private var recentPaths: Set<String> = []
    private var recentTapePaths: Set<String> = []

    /// Add a file to the recent list (deduplicated, capped at 10).
    func addRecentFile(url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) else { return }
        let filePath = url.standardizedFileURL.path
        let displayName = url.lastPathComponent
        let displayDir = abbreviatedDir(url.deletingLastPathComponent().path)
        let entry = RecentDiskEntry(filePath: filePath, bookmark: bookmark,
                                     displayName: displayName, displayDir: displayDir)
        // Remove existing entry for same file
        if recentPaths.contains(filePath) {
            recentDiskFiles.removeAll { $0.filePath == filePath }
        }
        recentDiskFiles.insert(entry, at: 0)
        rebuildRecentPaths()
        if recentDiskFiles.count > 10 {
            recentDiskFiles = Array(recentDiskFiles.prefix(10))
            rebuildRecentPaths()
        }
        persistRecentFiles()
    }

    /// Remove a specific recent file entry.
    func removeRecentFile(_ entry: RecentDiskEntry) {
        recentDiskFiles.removeAll { $0.filePath == entry.filePath }
        rebuildRecentPaths()
        persistRecentFiles()
    }

    /// Clear all recent files.
    func clearRecentFiles() {
        recentDiskFiles = []
        recentPaths = []
        persistRecentFiles()
    }

    private func rebuildRecentPaths() {
        recentPaths = Set(recentDiskFiles.map(\.filePath))
    }

    private func persistRecentFiles() {
        if let data = try? JSONEncoder().encode(recentDiskFiles) {
            UserDefaults.standard.set(data, forKey: "recentDiskFiles")
        }
    }

    private func loadRecentFiles() {
        if let data = UserDefaults.standard.data(forKey: "recentDiskFiles"),
           let entries = try? JSONDecoder().decode([RecentDiskEntry].self, from: data) {
            recentDiskFiles = entries
            rebuildRecentPaths()
        }
        if let data = UserDefaults.standard.data(forKey: "recentTapeFiles"),
           let entries = try? JSONDecoder().decode([RecentDiskEntry].self, from: data) {
            recentTapeFiles = entries
            recentTapePaths = Set(entries.map(\.filePath))
        }
    }

    // MARK: - Recent tape files

    func addRecentTapeFile(url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) else { return }
        let filePath = url.standardizedFileURL.path
        let displayName = url.lastPathComponent
        let displayDir = abbreviatedDir(url.deletingLastPathComponent().path)
        let entry = RecentDiskEntry(filePath: filePath, bookmark: bookmark,
                                     displayName: displayName, displayDir: displayDir)
        if recentTapePaths.contains(filePath) {
            recentTapeFiles.removeAll { $0.filePath == filePath }
        }
        recentTapeFiles.insert(entry, at: 0)
        if recentTapeFiles.count > 10 {
            recentTapeFiles = Array(recentTapeFiles.prefix(10))
        }
        recentTapePaths = Set(recentTapeFiles.map(\.filePath))
        if let data = try? JSONEncoder().encode(recentTapeFiles) {
            UserDefaults.standard.set(data, forKey: "recentTapeFiles")
        }
    }

    func removeRecentTapeFile(_ entry: RecentDiskEntry) {
        recentTapeFiles.removeAll { $0.filePath == entry.filePath }
        recentTapePaths = Set(recentTapeFiles.map(\.filePath))
        if let data = try? JSONEncoder().encode(recentTapeFiles) {
            UserDefaults.standard.set(data, forKey: "recentTapeFiles")
        }
    }

    func clearRecentTapeFiles() {
        recentTapeFiles = []
        recentTapePaths = []
        UserDefaults.standard.removeObject(forKey: "recentTapeFiles")
    }

    /// Abbreviate home directory in path display.
    private func abbreviatedDir(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private init() {
        if let v = UserDefaults.standard.object(forKey: "clock8MHz") as? Bool {
            clock8MHz = v
        }
        if let v = UserDefaults.standard.object(forKey: "volume") {
            volume = min(1.0, max(0.0, (v as? NSNumber)?.floatValue ?? 0.5))
        }
        if let v = UserDefaults.standard.object(forKey: "pseudoStereo") as? Bool {
            pseudoStereo = v
        }
        if let v = UserDefaults.standard.object(forKey: "dipSw1") as? Int {
            dipSw1 = UInt8(v & 0xFF)
        }
        if let v = UserDefaults.standard.object(forKey: "dipSw2Base") as? Int {
            dipSw2Base = UInt8(v & 0xFF)
        }
        if let v = UserDefaults.standard.object(forKey: "showDebugMenu") as? Bool {
            showDebugMenu = v
        }
        if let v = UserDefaults.standard.object(forKey: "audioBufferMs") as? Int {
            audioBufferMs = max(20, min(500, v))
        }
        if let v = UserDefaults.standard.object(forKey: "spatialAudio") as? Bool {
            immersiveAudio = v
        }
        if let v = UserDefaults.standard.object(forKey: "fddSound") as? Bool {
            fddSound = v
        }
        if let v = UserDefaults.standard.string(forKey: "fddSoundDeviceUID") {
            fddSoundDeviceUID = v
        }
        if let v = UserDefaults.standard.object(forKey: "fddSoundVolumeLevel") as? Int {
            fddSoundVolumeLevel = v
        }
        if let data = UserDefaults.standard.data(forKey: "immersivePositions"),
           let pos = try? JSONDecoder().decode(ImmersiveAudioPositions.self, from: data) {
            immersivePositions = pos
        }
        if let v = UserDefaults.standard.object(forKey: "gameControllerEnabled") as? Bool {
            gameControllerEnabled = v
        }
        if let v = UserDefaults.standard.object(forKey: "controllerHapticEnabled") as? Bool {
            controllerHapticEnabled = v
        }
        if let data = UserDefaults.standard.data(forKey: "controllerMappings"),
           let m = try? JSONDecoder().decode([String: ControllerButtonMapping].self, from: data) {
            controllerMappings = m
        }
        if let v = UserDefaults.standard.object(forKey: "arrowKeysAsNumpad") as? Bool {
            arrowKeysAsNumpad = v
        }
        if let v = UserDefaults.standard.object(forKey: "numberRowAsNumpad") as? Bool {
            numberRowAsNumpad = v
        }
        if let data = UserDefaults.standard.data(forKey: "specialKeyMapping"),
           let m = try? JSONDecoder().decode([String: Int].self, from: data) {
            specialKeyMapping = m
        }
        if let v = UserDefaults.standard.string(forKey: "keyboardLayout"),
           let layout = KeyboardLayout(rawValue: v) {
            keyboardLayout = layout
        }
        if let v = UserDefaults.standard.object(forKey: "windowScale") as? Int, [1, 2, 4].contains(v) {
            windowScale = v
        }
        if let v = UserDefaults.standard.string(forKey: "screenshotFormat"),
           ["png", "jpeg", "heic"].contains(v) {
            screenshotFormat = v
        }
        if let v = UserDefaults.standard.object(forKey: "screenshotAutoSave") as? Bool {
            screenshotAutoSave = v
        }
        screenshotDirectory = UserDefaults.standard.string(forKey: "screenshotDirectory")
        if let v = UserDefaults.standard.object(forKey: "fullscreenIntegerScaling") as? Bool {
            fullscreenIntegerScaling = v
        }
        if let v = UserDefaults.standard.string(forKey: "videoFilter") {
            videoFilter = v
        }
        if let v = UserDefaults.standard.object(forKey: "scanlineEnabled") as? Bool {
            scanlineEnabled = v
        }
        if let v = UserDefaults.standard.object(forKey: "showTapeInStatusBar") as? Bool {
            showTapeInStatusBar = v
        }
        if let v = UserDefaults.standard.string(forKey: "translationTargetLanguage") {
            translationTargetLanguage = v
        }
        loadRecentFiles()
    }
}

// MARK: - Keyboard Layout

enum KeyboardLayout: String, CaseIterable, Identifiable {
    case auto = "auto"
    case jis = "jis"
    case us = "us"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return NSLocalizedString("Auto-detect", comment: "Keyboard layout auto-detection")
        case .jis: return "JIS"
        case .us: return "US (ANSI)"
        }
    }
}

// MARK: - Immersive Audio Positions

/// Per-channel 3D positions for immersive audio.
/// x = L/R spread (0..1), z = front/back depth (-1..1, negative = front).
/// L channel at (-x, 0, z), R channel at (x, 0, z).
struct ImmersiveAudioPositions: Codable, Equatable {
    var fmX: Float = 0.5;     var fmZ: Float = -0.5
    var ssgX: Float = 0.5;    var ssgZ: Float = -0.5
    var adpcmX: Float = 0.3;  var adpcmZ: Float = -0.3
    var rhythmX: Float = 0.5; var rhythmZ: Float = 0.5

    static let defaults = ImmersiveAudioPositions()

    /// Channel labels and colors for UI.
    enum Channel: Int, CaseIterable {
        case fm, ssg, adpcm, rhythm

        var label: String {
            switch self {
            case .fm: return "FM"
            case .ssg: return "SSG"
            case .adpcm: return "ADPCM"
            case .rhythm: return "Rhythm"
            }
        }
    }

    /// Get position for a channel.
    func position(for ch: Channel) -> (x: Float, z: Float) {
        switch ch {
        case .fm:     return (fmX, fmZ)
        case .ssg:    return (ssgX, ssgZ)
        case .adpcm:  return (adpcmX, adpcmZ)
        case .rhythm: return (rhythmX, rhythmZ)
        }
    }

    /// Set position for a channel.
    mutating func setPosition(for ch: Channel, x: Float, z: Float) {
        let cx = min(1, max(0, x))
        let cz = min(1, max(-1, z))
        switch ch {
        case .fm:     fmX = cx; fmZ = cz
        case .ssg:    ssgX = cx; ssgZ = cz
        case .adpcm:  adpcmX = cx; adpcmZ = cz
        case .rhythm: rhythmX = cx; rhythmZ = cz
        }
    }

    /// Convert to AVAudio3DPoint array (8 elements: L/R pairs for FM, SSG, ADPCM, Rhythm).
    var spatialPoints: [(x: Float, y: Float, z: Float)] {
        var points: [(x: Float, y: Float, z: Float)] = []
        for ch in Channel.allCases {
            let p = position(for: ch)
            points.append((x: -p.x, y: 0, z: p.z))  // L
            points.append((x:  p.x, y: 0, z: p.z))  // R
        }
        return points
    }
}

// MARK: - Recent Disk Entry

struct RecentDiskEntry: Codable, Identifiable, Hashable {
    let filePath: String
    let bookmark: Data
    let displayName: String
    let displayDir: String

    var id: String { filePath }

    func hash(into hasher: inout Hasher) { hasher.combine(filePath) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.filePath == rhs.filePath }

    /// Resolve the bookmark back to a URL, granting sandbox access.
    func resolveBookmark() -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) else { return nil }
        if stale { return nil }
        return url
    }
}
