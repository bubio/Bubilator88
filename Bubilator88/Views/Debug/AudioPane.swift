import SwiftUI
import EmulatorCore

/// Audio debug pane — two-column HSplitView: Activity/Mute | Spectrum.
///
/// Each channel bar shows live activity and acts as a mute toggle:
/// - Unmuted + active  → green fill
/// - Unmuted + silent  → dim gray background
/// - Muted (any)       → red background, red label, no fill
struct AudioPane: View {
    @Bindable var session: DebugSession
    let viewModel: EmulatorViewModel

    // MARK: - Poll state

    @State private var fmKeyOn:     UInt8 = 0
    @State private var ssgVolume:   (UInt8, UInt8, UInt8) = (0, 0, 0)
    @State private var ssgMixer:    UInt8 = 0xFF
    @State private var rhythmKey:   UInt8 = 0
    @State private var adpcmActive: Bool  = false

    // MARK: - Mute state (ephemeral — resets to all-on when the debug window closes)

    @State private var muteMask: YM2608.DebugChannelMask = .all

    // MARK: - Spectrum state

    @State private var analyzer = SpectrumAnalyzer()
    @State private var spectrumBands: [Float] = Array(repeating: -60, count: 32)
    @State private var spectrumTask: Task<Void, Never>?
    @State private var pollTask:     Task<Void, Never>?

    // MARK: - Body

    var body: some View {
        HSplitView {
            // ── Left: Activity + Mute ────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Activity").font(.headline)
                        Spacer()
                        Button("All On") {
                            muteMask = .all
                            viewModel.applyDebugChannelMask(muteMask)
                        }
                        .controlSize(.mini)
                        .help("全チャンネルのミュートを解除")
                        Button("All Off") {
                            muteMask = YM2608.DebugChannelMask(fm: 0, ssg: 0, rhythm: 0, adpcm: false)
                            viewModel.applyDebugChannelMask(muteMask)
                        }
                        .controlSize(.mini)
                        .help("全チャンネルをミュート")
                    }

                    // Row 1: FM | SSG
                    HStack(alignment: .top, spacing: 6) {
                        GroupBox("FM") {
                            HStack(spacing: 4) {
                                ForEach(0..<6, id: \.self) { ch in
                                    let isOn  = (fmKeyOn >> ch) & 1 != 0
                                    let muted = (muteMask.fm >> ch) & 1 == 0
                                    channelBar(label: "\(ch+1)", isOn: isOn,
                                               fraction: isOn ? 1.0 : 0.0, muted: muted) {
                                        if muted { muteMask.fm |=  UInt8(1 << ch) }
                                        else     { muteMask.fm &= ~UInt8(1 << ch) }
                                        viewModel.applyDebugChannelMask(muteMask)
                                    }
                                    .help(muted ? "FM \(ch+1): ミュート中" : "FM \(ch+1): ミュート解除")
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        GroupBox("SSG") {
                            HStack(spacing: 4) {
                                ForEach(0..<3, id: \.self) { ch in
                                    let vol     = ch == 0 ? ssgVolume.0 : ch == 1 ? ssgVolume.1 : ssgVolume.2
                                    let toneOn  = (ssgMixer >> ch) & 1 == 0
                                    let noiseOn = (ssgMixer >> (ch + 3)) & 1 == 0
                                    let active  = (toneOn || noiseOn) && (vol & 0x1F) > 0
                                    let muted   = (muteMask.ssg >> ch) & 1 == 0
                                    let lbl     = ["A","B","C"][ch]
                                    channelBar(label: lbl, isOn: active,
                                               fraction: active ? Double(vol & 0x0F) / 15.0 : 0,
                                               muted: muted) {
                                        if muted { muteMask.ssg |=  UInt8(1 << ch) }
                                        else     { muteMask.ssg &= ~UInt8(1 << ch) }
                                        viewModel.applyDebugChannelMask(muteMask)
                                    }
                                    .help(muted ? "SSG \(lbl): ミュート中" : "SSG \(lbl): ミュート解除")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    // Row 2: Rhythm | ADPCM
                    HStack(alignment: .top, spacing: 6) {
                        GroupBox("Rhythm") {
                            HStack(spacing: 4) {
                                let names = ["BD","SD","TOP","HH","TOM","RIM"]
                                ForEach(0..<6, id: \.self) { i in
                                    let isOn  = (rhythmKey >> i) & 1 != 0
                                    let muted = (muteMask.rhythm >> i) & 1 == 0
                                    channelBar(label: names[i], isOn: isOn,
                                               fraction: isOn ? 1.0 : 0.0, muted: muted) {
                                        if muted { muteMask.rhythm |=  UInt8(1 << i) }
                                        else     { muteMask.rhythm &= ~UInt8(1 << i) }
                                        viewModel.applyDebugChannelMask(muteMask)
                                    }
                                    .help(muted ? "\(names[i]): ミュート中" : "\(names[i]): ミュート解除")
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        GroupBox("ADPCM") {
                            let muted = !muteMask.adpcm
                            channelBar(label: "ADC", isOn: adpcmActive,
                                       fraction: adpcmActive ? 1.0 : 0.0, muted: muted) {
                                muteMask.adpcm.toggle()
                                viewModel.applyDebugChannelMask(muteMask)
                            }
                            .help(muted ? "ADPCM: ミュート中" : "ADPCM: ミュート解除")
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(12)
            }
            .frame(minWidth: 180, idealWidth: 240)

            // ── Right: Spectrum ───────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("Spectrum")
                    .font(.headline)
                    .padding([.top, .horizontal], 12)

                Canvas { ctx, size in
                    let bands    = spectrumBands
                    guard !bands.isEmpty else { return }
                    let bw       = size.width / CGFloat(bands.count)
                    let minDB: Float = -60
                    let dbRange: Float = 60

                    for (i, db) in bands.enumerated() {
                        let frac  = CGFloat(max(0, (db - minDB) / dbRange))
                        let barH  = size.height * frac
                        let rect  = CGRect(x: CGFloat(i) * bw + 1,
                                           y: size.height - barH,
                                           width: max(1, bw - 2), height: barH)
                        let hue   = 0.33 - 0.33 * frac
                        ctx.fill(Path(rect), with: .color(
                            Color(hue: hue, saturation: 0.9, brightness: 0.85)))
                    }
                    for guidedB: Float in [-30, -60] {
                        let frac = CGFloat((guidedB - minDB) / dbRange)
                        let y    = size.height * (1 - frac)
                        let path = Path { p in
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        ctx.stroke(path, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.08))
                .cornerRadius(4)
                .padding(.horizontal, 12)

                HStack {
                    Text("20 Hz").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("22 kHz").font(.caption2).foregroundStyle(.secondary)
                }
                .padding([.bottom, .horizontal], 12)
            }
            .frame(minWidth: 160, idealWidth: 260)
        }
        .onAppear {
            viewModel.applyDebugChannelMask(muteMask)
            pollOnce()
            startPolling()
            installSpectrumTap()
            startSpectrumTask()
        }
        .onDisappear {
            pollTask?.cancel();     pollTask = nil
            spectrumTask?.cancel(); spectrumTask = nil
            viewModel.audio.removeSpectrumTap()
            analyzer.reset()
        }
    }

    // MARK: - Channel bar (activity + mute toggle)

    /// Compact vertical bar that shows activity and acts as a mute toggle.
    ///
    /// - Unmuted + active  → green fill
    /// - Unmuted + silent  → dim gray background, no fill
    /// - Muted             → red background, red label, no fill
    @ViewBuilder
    private func channelBar(
        label:    String,
        isOn:     Bool,
        fraction: Double,
        muted:    Bool,
        toggle:   @escaping () -> Void
    ) -> some View {
        Button(action: toggle) {
            VStack(spacing: 2) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(muted ? Color.red.opacity(0.25) : Color.secondary.opacity(0.15))
                        .frame(width: 22, height: 36)
                    if !muted && isOn {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.green)
                            .frame(width: 22, height: max(3, 36 * fraction))
                    }
                }
                Text(label)
                    .font(.system(size: 8, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(muted ? Color.red : (isOn ? Color.primary : Color.secondary))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Spectrum helpers

    private func installSpectrumTap() {
        let a = analyzer
        viewModel.audio.installSpectrumTap { [weak a] buf in a?.process(buffer: buf) }
    }

    private func startSpectrumTask() {
        spectrumTask?.cancel()
        spectrumTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled else { break }
                spectrumBands = analyzer.currentBands
            }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                pollOnce()
            }
        }
    }

    private func pollOnce() {
        let machine = viewModel.machine
        // Use DispatchQueue.main.async instead of Task { @MainActor } to avoid
        // per-poll Task allocation overhead at the 100 ms polling rate.
        viewModel.emuQueue.async {
            let fm    = machine.sound.fmKeyOnMask
            let vols  = (machine.sound.ssgVolume[0],
                         machine.sound.ssgVolume[1],
                         machine.sound.ssgVolume[2])
            let mixer = machine.sound.ssgMixer
            let rhy   = machine.sound.rhythmKeyOn
            let adc   = machine.sound.adpcmPlaying
            DispatchQueue.main.async {
                fmKeyOn     = fm
                ssgVolume   = vols
                ssgMixer    = mixer
                rhythmKey   = rhy
                adpcmActive = adc
            }
        }
    }
}
