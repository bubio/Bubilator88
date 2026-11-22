import AppKit
import Bubilator88Core
import QuickLookUI

/// The spacebar preview for `.vgm` / `.vgz` files with one YM2608: the
/// title from the GD3 tag and a player that synthesizes the file as it plays.
///
/// Playback waits for the Play button. Finder's preview pane shows the same
/// view as soon as a file is selected, and there is no telling the two
/// apart, so starting on our own would make a selection in Finder start
/// music. A file this player cannot play throws, which leaves it to Quick
/// Look's default preview.
final class VGMPreviewViewController: NSViewController, QLPreviewingController {
  /// Files larger than this, before or after `.vgz` expansion, are refused:
  /// every command becomes an event in memory, and real logs are far
  /// smaller.
  private static let maximumFileSize = 16 * 1024 * 1024

  /// A looped file repeats its loop once, then ends.
  private static let loops = 1

  private enum PreviewError: Error {
    case tooLarge
    case empty
  }

  private var file: VGMFile?
  private var rhythm: [(index: Int, samples: [Int16], sampleRate: Int)] = []
  private var stream: VGMStream?
  private var timer: Timer?

  private let titleLabel = NSTextField(labelWithString: "")
  private let detailLabel = NSTextField(labelWithString: "")
  private let playButton = NSButton()
  private let progress = NSProgressIndicator()
  private let timeLabel = NSTextField(labelWithString: "")

  override func loadView() {
    titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail
    detailLabel.font = .systemFont(ofSize: 13)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.lineBreakMode = .byTruncatingTail

    playButton.bezelStyle = .circular
    playButton.imagePosition = .imageOnly
    playButton.controlSize = .large
    playButton.target = self
    playButton.action = #selector(togglePlayback)

    progress.style = .bar
    progress.isIndeterminate = false
    progress.minValue = 0
    progress.maxValue = 1

    timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    timeLabel.textColor = .secondaryLabelColor

    let controls = NSStackView(views: [playButton, progress, timeLabel])
    controls.spacing = 10
    controls.alignment = .centerY
    let column = NSStackView(views: [titleLabel, detailLabel, controls])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 6
    column.setCustomSpacing(14, after: detailLabel)
    column.translatesAutoresizingMaskIntoConstraints = false

    // The system background, as the save-state preview uses, so the text
    // reads the same in light and dark mode rather than over Quick Look's
    // grey.
    let root = NSBox()
    root.boxType = .custom
    root.borderWidth = 0
    root.cornerRadius = 0
    root.fillColor = .windowBackgroundColor
    root.contentViewMargins = .zero
    root.addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
      column.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      controls.widthAnchor.constraint(equalTo: column.widthAnchor),
    ])
    view = root
    preferredContentSize = NSSize(width: 480, height: 140)
    showStopped()
  }

  func preparePreviewOfFile(at url: URL) async throws {
    stopPlayback()
    // Inflating and parsing can take a moment on a large file; keep it off
    // the main thread.
    let (file, rhythm) = try await Task.detached { try Self.load(url) }.value
    self.file = file
    self.rhythm = rhythm

    let tags = file.tags
    let title = [tags.track, tags.game].first { !$0.isEmpty } ?? url.lastPathComponent
    titleLabel.stringValue = title
    detailLabel.stringValue = [tags.game, tags.author, tags.system]
      .filter { !$0.isEmpty && $0 != title }
      .joined(separator: " · ")
    detailLabel.isHidden = detailLabel.stringValue.isEmpty
    showStopped()
  }

  private nonisolated static func load(_ url: URL) throws
    -> (VGMFile, [(index: Int, samples: [Int16], sampleRate: Int)]) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
    guard data.count <= maximumFileSize else { throw PreviewError.tooLarge }
    if Gzip.isGzip(data) {
      data = try Gzip.decompress(data, limit: maximumFileSize)
    }
    let file = try VGMFile(bytes: [UInt8](data))
    // Nothing to play; Quick Look's default preview says more.
    guard file.samples(loops: loops) > 0 else { throw PreviewError.empty }
    return (file, RhythmSamples.load(userDirectory: BIOSFiles.directory))
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    stopPlayback()
  }

  // MARK: - Playback

  @objc private func togglePlayback() {
    if let stream, timer != nil {
      stream.pause()
      timer?.invalidate()
      timer = nil
      setButton(playing: false)
      return
    }
    // A paused engine may have stopped on an output device change, and
    // playing a node on a stopped engine raises; start over instead.
    if let stream, !stream.isRunning {
      stream.stop()
      self.stream = nil
    }
    if stream == nil {
      guard let file, let player = try? VGMPlayer(file: file, loops: Self.loops) else { return }
      for sample in rhythm {
        try? player.loadRhythmSample(index: sample.index, samples: sample.samples,
                                     sampleRate: sample.sampleRate)
      }
      stream = try? VGMStream(player: player)
    }
    guard let stream else { return }
    stream.play()
    setButton(playing: true)
    timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  private func tick() {
    guard let stream else { return }
    // The engine stops by itself when the output device changes; start
    // over rather than sit on a stalled position.
    if stream.isFinished || !stream.isRunning {
      stopPlayback()
      return
    }
    showPosition(stream.playedFrames, of: stream.totalFrames)
  }

  /// Stop and go back to the start, ready to play again.
  private func stopPlayback() {
    timer?.invalidate()
    timer = nil
    stream?.stop()
    stream = nil
    showStopped()
  }

  // MARK: - Display

  private func showStopped() {
    setButton(playing: false)
    playButton.isEnabled = file != nil
    showPosition(0, of: file?.samples(loops: Self.loops) ?? 0)
  }

  private func showPosition(_ played: Int, of total: Int) {
    progress.doubleValue = total > 0 ? Double(played) / Double(total) : 0
    timeLabel.stringValue = "\(Self.time(played)) / \(Self.time(total))"
  }

  private func setButton(playing: Bool) {
    let label = playing
      ? String(localized: "Pause", comment: "VGM Quick Look preview: pause button")
      : String(localized: "Play", comment: "VGM Quick Look preview: play button")
    playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill",
                               accessibilityDescription: label)
    playButton.toolTip = label
  }

  /// `m:ss` for a frame count at 44.1kHz.
  private static func time(_ frames: Int) -> String {
    let seconds = frames / YM2608Renderer.sampleRate
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
