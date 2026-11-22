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
  /// every command becomes an event in memory. The worst case, 16MB of
  /// nothing but register writes, peaks at about 300MB in the extension.
  private nonisolated static let maximumFileSize = 16 * 1024 * 1024

  /// A looped file repeats its loop once, then ends.
  private nonisolated static let loops = 1

  private enum PreviewError: Error {
    case tooLarge
    case empty
  }

  private var file: VGMFile?
  private var stream: VGMStream?
  private var timer: Timer?
  /// Counts `preparePreviewOfFile` calls, so a load that finishes after a
  /// later one has started is dropped.
  private var generation = 0
  private var rhythm: [RhythmSamples.Sample] = []

  private let titleLabel = NSTextField(labelWithString: "")
  private let detailLabel = NSTextField(labelWithString: "")
  private let playButton = NSButton()
  private let progress = ProgressBar()
  private let timeLabel = NSTextField(labelWithString: "")

  override func loadView() {
    titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail
    detailLabel.font = .systemFont(ofSize: 13)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.lineBreakMode = .byTruncatingTail

    // A bare symbol: the glass bar is the control's surface.
    playButton.isBordered = false
    playButton.imagePosition = .imageOnly
    playButton.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
    playButton.contentTintColor = .white
    playButton.target = self
    playButton.action = #selector(togglePlayback)

    timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    timeLabel.textColor = .secondaryLabelColor

    // Finder's preview pane is far narrower than the spacebar panel: the
    // labels truncate, the bar shrinks, and the time goes last.
    for label in [titleLabel, detailLabel] {
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    progress.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    progress.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let controls = NSStackView(views: [playButton, progress, timeLabel])
    controls.setVisibilityPriority(.detachOnlyIfNecessary, for: timeLabel)
    controls.spacing = 12
    controls.alignment = .centerY
    controls.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
    // The transport sits on a Liquid Glass capsule, as in the system's
    // audio preview.
    let bar = NSGlassEffectView()
    bar.contentView = controls
    bar.cornerRadius = 22
    // Dark glass with light contents in both modes, so the transport reads
    // on any background: Finder's preview pane is light in light mode.
    bar.appearance = NSAppearance(named: .darkAqua)
    bar.tintColor = NSColor.black.withAlphaComponent(0.15)
    let column = NSStackView(views: [titleLabel, detailLabel, bar])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 6
    column.setCustomSpacing(14, after: detailLabel)
    column.translatesAutoresizingMaskIntoConstraints = false

    // No background of its own: Quick Look's shows through, as it does
    // behind the system's audio preview.
    let root = NSView()
    root.addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      column.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      bar.widthAnchor.constraint(equalTo: column.widthAnchor),
      bar.heightAnchor.constraint(equalToConstant: 44),
    ])
    view = root
    preferredContentSize = NSSize(width: 480, height: 150)
    showStopped()
  }

  func preparePreviewOfFile(at url: URL) async throws {
    // Quick Look may reuse this controller: drop the previous file first,
    // which also disables Play while this one loads.
    generation += 1
    let current = generation
    file = nil
    stopPlayback()
    titleLabel.stringValue = url.lastPathComponent
    detailLabel.isHidden = true
    let (file, rhythm) = try await Self.load(url)
    guard current == generation else { throw CancellationError() }
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

  /// Read, expand and parse off the main thread; a large `.vgz` takes a
  /// moment.
  @concurrent private nonisolated static func load(_ url: URL) async throws
    -> (VGMFile, [RhythmSamples.Sample]) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
    guard data.count <= maximumFileSize else { throw PreviewError.tooLarge }
    if Gzip.isGzip(data) {
      try Task.checkCancellation()
      data = try Gzip.decompress(data, limit: maximumFileSize)
    }
    try Task.checkCancellation()
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
    if stream?.isRunning == false { stopPlayback() }
    // Without an output to play to there is no stream; the next press
    // tries again.
    guard let stream = stream ?? makeStream() else { return }
    self.stream = stream
    stream.play()
    setButton(playing: true)
    let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] timer in
      // Nothing else invalidates it if the controller goes without
      // `viewWillDisappear`.
      guard let self else { return timer.invalidate() }
      MainActor.assumeIsolated { self.tick() }
    }
    // Common modes, so the position keeps moving while the panel is resized.
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func makeStream() -> VGMStream? {
    guard let file, let player = try? VGMPlayer(file: file, loops: Self.loops) else { return nil }
    for sample in rhythm {
      try? player.loadRhythmSample(index: sample.index, samples: sample.samples,
                                   sampleRate: sample.sampleRate)
    }
    return try? VGMStream(player: player)
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
    progress.fraction = total > 0 ? Double(played) / Double(total) : 0
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
