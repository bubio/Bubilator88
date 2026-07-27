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
        // 独自 UTI (.b88script) を優先。互換のため素のテキストも選べるようにする。
        let scriptType = UTType("com.bubio.bubilator88.timeline-script")
        panel.allowedContentTypes = [scriptType, .plainText, .text].compactMap { $0 }
        panel.message = NSLocalizedString("Choose a timeline script to play",
                                          comment: "Prompt in the open panel for picking a .b88script file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        playScript(url: url)
    }

    /// AppDelegate (`.b88script` のダブルクリック/「このアプリで開く」) からの入口。
    /// エミュレータの描画ループが立ち上がってから再生しないと、`playScript` の
    /// `start()` が `metalView == nil` のまま `isRunning` を立て、後続の
    /// `ContentView.onAppear` の `start()` が `guard !isRunning` で no-op になり
    /// 描画ループが永久に始まらない (= ディスクは載るが起動しない)。
    /// 準備済み (描画ループ稼働中) なら即再生、まだなら保留して onAppear に委ねる。
    func requestScriptPlayback(url: URL) {
        if isRunning && metalView != nil {
            playScript(url: url)
        } else {
            pendingScriptURL = url
        }
    }

    /// `ContentView.onAppear` が `start()` の直後に呼ぶ。コールド起動オープンで
    /// 保留されたスクリプトを、UI が完全に準備できた状態で再生する。
    func consumePendingScript() {
        guard let url = pendingScriptURL else { return }
        pendingScriptURL = nil
        playScript(url: url)
    }

    /// スクリプトを解析し、機種を cold reset で構成してから live 再生を開始する。
    func playScript(url: URL) {
        // Finder からのダブルクリック起動では onAppear の loadROMs より先に
        // 来ることがある。ROM 未ロードのまま再生すると起動できないため保険。
        if !romLoaded { loadROMs() }

        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            showAlert(title: NSLocalizedString("Cannot Open Script",
                                              comment: "Alert title: a .b88script file could not be read"),
                      message: error.localizedDescription)
            return
        }

        let steps: [ScriptStep]
        do {
            steps = try ScriptParser.parse(text)
        } catch let e as ScriptError {
            showAlert(title: NSLocalizedString("Script Parse Error",
                                              comment: "Alert title: a .b88script file is malformed"),
                      message: String(format: NSLocalizedString(
                        "%1$@ line %2$ld: %3$@",
                        comment: "Script parse error detail. %1 file name, %2 line number, %3 parser message"),
                        url.lastPathComponent, e.line, e.message))
            return
        } catch {
            showAlert(title: NSLocalizedString("Script Parse Error",
                                              comment: "Alert title: a .b88script file is malformed"),
                      message: error.localizedDescription)
            return
        }

        // ディスクパスはスクリプトのあるディレクトリ基準で解決 (絶対パスはそのまま)。
        // loader はローカル `scriptDir` を捕捉する (self.scriptDir には依存しない)。
        let scriptDir = url.deletingLastPathComponent()
        let loader: ScriptPlayer.FileLoader = { [weak self] path in
            let fileURL = self?.resolveScriptDiskURL(path, scriptDir: scriptDir)
                ?? URL(fileURLWithPath: path)
            return [UInt8](try Data(contentsOf: fileURL))
        }

        // draw ループを止め (= machine への排他)、cold reset してセットアップを適用。
        // self.scriptDir の確定は cancelScriptPlayback() の後にする。さもないと
        // 前スクリプトの player を再構築する cancel 側が新ディレクトリで相対パスを
        // 誤解決してしまう。
        cancelScriptPlayback()
        stop()
        turboMode = false
        cancelPasteQueue()
        self.scriptDir = scriptDir

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
            showAlert(title: NSLocalizedString("Script Playback Error",
                                              comment: "Alert title: playing a .b88script failed"),
                      message: "\(setupError)")
            return
        }

        scriptPlayer = player
        isPlayingScript = true
        // スクリプトの boot/clock ヘッダをアプリの現在設定として採用し、
        // ステータスバー/メニュー表示を実機の構成に一致させる。
        adoptScriptSetup(steps)
        // セットアップ済みディスクを手動マウントと同じ情報で反映 (再生中も
        // ディスクメニューからイメージ選択できるようにする)。
        rebuildDriveInfoFromScript(player: player)
        showToast(NSLocalizedString("Script playback started",
                                   comment: "Toast shown when .b88script playback begins"))
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
                self?.showAlert(title: NSLocalizedString("Script Playback Error",
                                                        comment: "Alert title: playing a .b88script failed"),
                                message: "\(error)")
            }
            return
        }
        guard !ongoing else { return }
        // 自走完了。状態反映は main へ。`driveMount` 照会のため player を捕捉。
        scriptPlayer = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPlayingScript = false
            self.rebuildDriveInfoFromScript(player: player)
            self.showToast(NSLocalizedString("Script playback finished",
                                            comment: "Toast shown when .b88script playback ends"))
        }
    }

    /// 再生中のスクリプトを中断する (DEBUG メニュー停止 / リセット時)。
    func cancelScriptPlayback() {
        guard let player = scriptPlayer else { return }
        scriptPlayer = nil
        emuQueue.sync { player.cancelLive() }
        isPlayingScript = false
        // 中断時点でドライブに残ったディスクも手動と同じく選択できるよう、
        // マウント素性から driveXInfo を再構築する。
        rebuildDriveInfoFromScript(player: player)
    }

    /// スクリプトの setup (`boot` / `clock` / `dipsw1/2`) を、アプリの現在設定
    /// として採用する。機種は既に `beginLive` で構成済みなので、ここでは ViewModel
    /// の表示/設定状態だけを同期する (`applyBootMode` は呼ばない — 呼ぶと再リセット
    /// してスクリプトが構成した状態を壊す)。save-state ロードの `performLoad` と
    /// 同じ「機種は触らず ViewModel state だけ追従させる」方式。
    ///
    /// 起動モード/DIPSW は **`beginLive` 適用後の実機の実状態** (`machine.bus`) から
    /// 逆引きする。`Pc88Bus.reset` は DIPSW を保持するので、`boot` 行・生 `dipsw`・
    /// ヘッダ無しのいずれでも、ステータスバー表示・`Settings`・機種が必ず一致する
    /// (ヘッダ無し時は現状維持の no-op)。`performLoad` と同じ preset/custom 分岐。
    func adoptScriptSetup(_ steps: [ScriptStep]) {
        // クロックはスクリプトが明示した場合のみ永続化する (ヘッダ省略時に
        // ユーザのクロック設定を勝手に書き換えない)。表示は常に実機値で同期。
        clockScan: for step in steps {
            switch step {
            case .clock(let mhz):
                Settings.shared.clock8MHz = (mhz == 8)
                break clockScan
            case .boot, .dipsw1, .dipsw2, .diskMount:
                continue                 // setup ブロック内 — clock を探し続ける
            default:
                break clockScan          // timeline 開始 — clock 指定なし
            }
        }
        syncActiveClockFromMachine()

        // 起動モード: 実機 DIPSW をプリセットへ逆引き。一致すればその機種の正準
        // DIPSW を、一致しなければ Custom として生値を採用する (= performLoad と同型)。
        let sw1 = machine.bus.dipSw1
        let sw2 = machine.bus.dipSw2
        let preset = BootModePreset.from(dipSw1: sw1, dipSw2Base: sw2)
        if preset == .custom {
            _bootModeStorage = .custom
            Settings.shared.dipSw1 = sw1
            Settings.shared.dipSw2Base = sw2
        } else {
            let mode = BootMode(rawValue: preset.rawValue) ?? .custom
            _bootModeStorage = mode
            Settings.shared.dipSw1 = mode.dipSw1
            Settings.shared.dipSw2Base = mode.dipSw2
        }
    }

    /// スクリプト内のディスクパスを URL へ解決する (絶対パスはそのまま、相対は
    /// スクリプトのあるディレクトリ基準)。`playScript` の loader と同じ規則。
    func resolveScriptDiskURL(_ path: String, scriptDir: URL) -> URL {
        (path as NSString).isAbsolutePath
            ? URL(fileURLWithPath: path)
            : scriptDir.appendingPathComponent(path)
    }

    /// スクリプト再生後 (または中断時)、各ドライブのマウント素性から
    /// `MountedDiskInfo` を再構築する。スクリプトは `machine` を直接叩くため
    /// `driveXInfo` が埋まらず、手動マウント時と違ってディスクメニューから
    /// イメージ選択ができない。手動経路 (`mountDiskImage`) と同じ情報を組み立て、
    /// 再生後も多面 D88 のイメージ選択を可能にする。
    func rebuildDriveInfoFromScript(player: ScriptPlayer) {
        let scriptDir = self.scriptDir
        for drive in 0..<2 {
            // スクリプトがこのドライブにマウントした素性を最優先で使う。
            // disk swap/select の交換ディレイ中は machine.subSystem.drives[drive]
            // が一時的に nil になるが、pendingMount は必ず commit されるので、
            // 機種の瞬間状態ではなく driveMount の情報で再構築する。
            if let mount = player.driveMount(drive), let scriptDir {
                let url = resolveScriptDiskURL(mount.path, scriptDir: scriptDir)
                let fileName = url.deletingPathExtension().lastPathComponent
                let info = makeDirectDiskInfo(allImages: mount.images, fileName: fileName,
                                              imageIndex: mount.imageIndex, sourceURL: url)
                let index = info.currentImageIndex
                applyDriveState(
                    DriveState(name: info.imageNames[index], fileName: fileName, info: info,
                               writeProtected: mount.images[index].writeProtected),
                    drive: drive)
                continue
            }
            // スクリプトが触れていないドライブは機種の実状態に従う。
            if machine.subSystem.drives[drive] != nil {
                // 既存ディスク (手動マウント等): 名前だけ反映し driveXInfo は保持。
                let name = machine.subSystem.drives[drive]?.name ?? "Empty"
                if drive == 0 { drive0Name = name } else { drive1Name = name }
            } else {
                applyDriveState(.empty, drive: drive)
            }
        }
    }
}
