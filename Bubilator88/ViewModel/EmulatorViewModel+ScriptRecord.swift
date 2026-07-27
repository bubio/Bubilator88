import AppKit
import UniformTypeIdentifiers
import EmulatorCore

// MARK: - Operation recording (real play → .b88script)
//
// docs/SCRIPTING.md の手順4 残件「操作の記録」。再生 (EmulatorViewModel+Script.swift)
// の対称。記録開始時に現在の boot/clock/ディスク構成で cold reset し、t=0 をリセット
// 直後に置く(= playScript と同じセマンティクス)。これで出力スクリプトの
// boot/clock/disk ヘッダで初期状態が完全に定まり、再生して同じ結果になる。
//
// 実ユーザ入力のみ記録: キーは keyDown/keyUp フックで拾う(ScriptPlayer/paste は
// machine.keyboard 直叩きで keyDown/keyUp を通らない)。コントローラは v1 非対象。
extension EmulatorViewModel {

    /// DEBUG メニュー「スクリプトを記録…」: cold reset して記録を開始する。
    func startScriptRecording() {
        guard scriptRecorder == nil else { return }
        if isPlayingScript {
            showAlert(title: NSLocalizedString("Cannot Record",
                                              comment: "Alert title: operation recording could not be started"),
                      message: NSLocalizedString("Recording cannot start while a script is playing.",
                                                 comment: "Alert message: script playback is in progress"))
            return
        }
        if audioRecorder.isRecording || videoRecorder.isRecording {
            showAlert(title: NSLocalizedString("Cannot Record",
                                              comment: "Alert title: operation recording could not be started"),
                      message: NSLocalizedString(
                        "Operation recording cannot start while audio or video is being recorded (starting a recording resets the machine).",
                        comment: "Alert message: an audio/video recording is in progress"))
            return
        }

        // 現在の構成から setup ヘッダを組み立てる(リセット後の初期状態を定義)。
        var setup = setupBootSteps()
        setup.append(.clock(mhz: clock8MHz ? 8 : 4))
        for drive in 0..<2 {
            if let info = (drive == 0 ? drive0Info : drive1Info), let path = info.sourceURL?.path {
                setup.append(.diskMount(drive: drive, path: path, image: info.currentImageIndex))
            }
        }

        // cold reset(playScript と同じ手順)。ディスクは reset を跨いで保持される。
        cancelPasteQueue()
        turboMode = false
        stop()
        let use8 = clock8MHz
        emuQueue.sync {
            machine.reset(preserveRAM: false)
            machine.applyBootStrap()      // 現ドライブ状態から bit3 を再確定(ディスク起動)
            machine.clock8MHz = use8
        }

        let recorder = ScriptRecorder(setup: setup)
        recorder.frameIndex = 0
        scriptRecorder = recorder
        isRecordingScript = true
        renderScreen()
        showToast(NSLocalizedString("Recording started",
                                   comment: "Toast shown when operation recording begins"))
        start()
    }

    /// 記録を確定し、`.b88script` として保存する。
    func stopScriptRecordingAndSave() {
        guard let recorder = scriptRecorder else { return }
        scriptRecorder = nil
        isRecordingScript = false
        let steps = recorder.finish()
        saveRecordedScript(ScriptWriter.write(steps))
    }

    /// 記録を破棄する(リセット / セーブステート読込で記録が中断されるとき)。
    func cancelScriptRecording() {
        guard scriptRecorder != nil else { return }
        scriptRecorder = nil
        isRecordingScript = false
        showToast(NSLocalizedString("Recording cancelled",
                                   comment: "Toast shown when operation recording is discarded by a reset or state load"))
    }

    /// アプリ終了時に記録中なら自動保存する(終了中は保存パネルを出せないので、
    /// 設定に関わらず保存先ディレクトリへ無言で書き出してデータ消失を防ぐ)。
    /// `AppDelegate.applicationWillTerminate` から呼ばれる。
    func flushScriptRecordingIfNeeded() {
        guard let recorder = scriptRecorder else { return }
        scriptRecorder = nil
        isRecordingScript = false
        let text = ScriptWriter.write(recorder.finish())
        let dir = Settings.shared.scriptRecordingDirectory ?? (NSHomeDirectory() + "/Documents")
        let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try? text.write(to: dirURL.appendingPathComponent(recordingDefaultName()),
                        atomically: true, encoding: .utf8)
    }

    /// ディスクをマウントしたとき(記録中のみ)`disk swap` を記録する。
    /// `EmulatorViewModel+Disk.swift` の各マウント終端から呼ばれる。
    func recordDiskMountIfNeeded(drive: Int) {
        guard let recorder = scriptRecorder else { return }
        let info = drive == 0 ? drive0Info : drive1Info
        guard let path = info?.sourceURL?.path else { return }   // データ由来(URL無)は記録不可
        recorder.diskSwap(drive: drive, path: path, image: info?.currentImageIndex ?? 0)
    }

    // MARK: - Setup header

    /// 現在のブートモードを setup ステップへ。n88 系3モードは `boot`(再生時に bit3 自動確定)、
    /// N-BASIC / Custom はアプリ独自の DIPSW 値を持つため生 `dipsw1/2` で出力する
    /// (EmulatorCore.BootMode とアプリ BootMode で N-BASIC の DIPSW2 が異なるため)。
    private func setupBootSteps() -> [ScriptStep] {
        switch bootMode {
        case .n88v2:  return [.boot(.n88v2)]
        case .n88v1h: return [.boot(.n88v1h)]
        case .n88v1s: return [.boot(.n88v1s)]
        case .n, .custom:
            return [.dipsw1(bootMode.dipSw1), .dipsw2(bootMode.dipSw2)]
        }
    }

    // MARK: - Save

    /// 記録ファイルの既定名。Drive 1 (= 内部 drive 0、ブートドライブ) の D88 ベース名を
    /// 含めてゲームを識別しやすくする。空ドライブなら素の "Bubilator88-<stamp>"。
    private func recordingDefaultName() -> String {
        let stamp = DateFormatter.stable(pattern: "yyyyMMdd-HHmmss").string(from: .now)
        if let disk = drive0Info?.fileName, !disk.isEmpty {
            let safe = disk.replacingOccurrences(of: "/", with: "-")
                           .replacingOccurrences(of: ":", with: "-")
            return "Bubilator88-\(safe)-\(stamp).b88script"
        }
        return "Bubilator88-\(stamp).b88script"
    }

    /// 記録テキストを保存先設定に従って書き出す(`saveScreenshot` と同じパターン)。
    private func saveRecordedScript(_ text: String) {
        let defaultName = recordingDefaultName()

        let url: URL
        if Settings.shared.scriptRecordingAutoSave {
            let dir = Settings.shared.scriptRecordingDirectory ?? (NSHomeDirectory() + "/Documents")
            let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            url = dirURL.appendingPathComponent(defaultName)
        } else {
            let panel = NSSavePanel()
            panel.title = NSLocalizedString("Save Script",
                                            comment: "Title of the save panel for a recorded .b88script")
            panel.nameFieldStringValue = defaultName
            if let type = UTType("com.bubio.bubilator88.timeline-script") {
                panel.allowedContentTypes = [type]
            }
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            showToast(NSLocalizedString("Script saved",
                                       comment: "Toast shown after a recorded .b88script is written to disk"))
        } catch {
            showAlert(title: NSLocalizedString("Save Failed",
                                              comment: "Alert title: writing the recorded .b88script failed"),
                      message: error.localizedDescription)
        }
    }
}
