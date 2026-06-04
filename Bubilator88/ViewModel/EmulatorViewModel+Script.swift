import AppKit
import UniformTypeIdentifiers
import EmulatorCore

// MARK: - Timeline script playback (live mode)
//
// docs/SCRIPTING.md の手順4 (アプリ統合)。スクリプトを解析し機種を構成してから、
// 自走 60Hz ループに乗せて live (実時間) 再生する。再生の駆動は
// `runFrameForMetal()` から毎フレーム呼ばれる `tickScriptPlayer()` が行う。
//
// 非サンドボックス (entitlements 空) なのでディスクは任意パスを直接読める。
extension EmulatorViewModel {

    /// DEBUG メニューから: タイムラインスクリプト (.txt) を選んで live 再生する。
    func openAndPlayScript() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text, .data]
        panel.message = NSLocalizedString("再生するタイムラインスクリプトを選択",
                                          comment: "Script open panel prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        playScript(url: url)
    }

    /// スクリプトを解析し、機種を cold reset で構成してから live 再生を開始する。
    func playScript(url: URL) {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            showAlert(title: NSLocalizedString("スクリプトを開けません", comment: ""),
                      message: error.localizedDescription)
            return
        }

        let steps: [ScriptStep]
        do {
            steps = try ScriptParser.parse(text)
        } catch let e as ScriptError {
            showAlert(title: NSLocalizedString("スクリプト解析エラー", comment: ""),
                      message: "\(url.lastPathComponent) \(e.line) 行目: \(e.message)")
            return
        } catch {
            showAlert(title: NSLocalizedString("スクリプト解析エラー", comment: ""),
                      message: error.localizedDescription)
            return
        }

        // ディスクパスはスクリプトのあるディレクトリ基準で解決 (絶対パスはそのまま)。
        let scriptDir = url.deletingLastPathComponent()
        let loader: ScriptPlayer.FileLoader = { path in
            let fileURL = (path as NSString).isAbsolutePath
                ? URL(fileURLWithPath: path)
                : scriptDir.appendingPathComponent(path)
            return [UInt8](try Data(contentsOf: fileURL))
        }

        // draw ループを止め (= machine への排他)、cold reset してセットアップを適用。
        cancelScriptPlayback()
        stop()
        turboMode = false
        cancelPasteQueue()

        let player = ScriptPlayer(machine: machine, loader: loader)
        var setupError: Error?
        emuQueue.sync {
            machine.reset(preserveRAM: false)
            do {
                try player.beginLive(steps)
            } catch {
                setupError = error
            }
        }

        if let setupError {
            emuQueue.sync { player.cancelLive() }
            renderScreen()
            showAlert(title: NSLocalizedString("スクリプト再生エラー", comment: ""),
                      message: "\(setupError)")
            return
        }

        scriptPlayer = player
        isPlayingScript = true
        refreshDriveLabelsFromMachine()
        showToast(NSLocalizedString("スクリプト再生開始", comment: ""))
        start()
    }

    /// 毎フレーム、`runFrameForMetal` の `machine.runFrame()` **直前** に呼ぶ。
    /// draw スレッド上で実行され、`machine` を直接触る (`tickPasteQueue` と同じ)。
    func tickScriptPlayer() {
        guard let player = scriptPlayer else { return }
        let ongoing: Bool
        do {
            ongoing = try player.liveTick()
        } catch {
            scriptPlayer = nil
            DispatchQueue.main.async { [weak self] in
                self?.isPlayingScript = false
                self?.showAlert(title: NSLocalizedString("スクリプト再生エラー", comment: ""),
                                message: "\(error)")
            }
            return
        }
        guard !ongoing else { return }
        // 自走完了。状態反映は main へ。
        scriptPlayer = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPlayingScript = false
            self.refreshDriveLabelsFromMachine()
            self.showToast(NSLocalizedString("スクリプト再生終了", comment: ""))
        }
    }

    /// 再生中のスクリプトを中断する (DEBUG メニュー停止 / リセット時)。
    func cancelScriptPlayback() {
        guard let player = scriptPlayer else { return }
        scriptPlayer = nil
        emuQueue.sync { player.cancelLive() }
        isPlayingScript = false
    }

    /// 機種のドライブ状態からステータスバーのラベルを更新する。
    func refreshDriveLabelsFromMachine() {
        drive0Name = machine.subSystem.drives[0]?.name ?? "Empty"
        drive1Name = machine.subSystem.drives[1]?.name ?? "Empty"
    }
}
