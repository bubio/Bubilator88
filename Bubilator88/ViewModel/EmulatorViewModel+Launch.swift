import AppKit
import EmulatorCore

// MARK: - 起動引数 (URL スキーム / CLI, QUASI88 互換)
//
// docs/URL_SCHEME.md の実装。`bubilator88://boot?arg=...` および起動時の
// コマンドライン引数を単一インスタンスへ配送し、ディスク/機種/クロックを
// 差し替えて cold boot する。引数書式は QUASI88 と同じ (`LaunchRequest`)。
// `.b88script` の `pendingScriptURL` と同型の deferral
// (`pendingLaunchRequest`) を使うが、transport と消費者が別なので専用に保つ。
extension EmulatorViewModel {

    /// `.onOpenURL` からの入口。パースに失敗した時点でアラートを出し、
    /// machine には一切触れない。
    func requestLaunch(url: URL) {
        do {
            requestLaunch(request: try LaunchRequest.parse(url))
        } catch {
            showAlert(title: NSLocalizedString("起動 URL エラー", comment: ""),
                      message: "\(url.absoluteString): \(errorMessage(error))")
        }
    }

    /// 起動時コマンドライン引数からの入口 (`AppDelegate` が一度だけ呼ぶ)。
    /// 引数が無ければ何もしない (Finder からの通常起動)。
    func requestLaunchFromCommandLine() {
        guard !didConsumeCommandLine else { return }
        didConsumeCommandLine = true
        do {
            guard let request = try LaunchRequest.fromCommandLine() else { return }
            requestLaunch(request: request)
        } catch {
            showAlert(title: NSLocalizedString("起動引数エラー", comment: ""),
                      message: errorMessage(error))
        }
    }

    /// 準備済み (描画ループ稼働中) なら即実行、まだなら保留して
    /// `ContentView.onAppear` の `consumePendingLaunch()` に委ねる。
    func requestLaunch(request: LaunchRequest) {
        if isRunning && metalView != nil {
            performLaunch(request)
        } else {
            pendingLaunchRequest = request
        }
    }

    /// `ContentView.onAppear` が `start()` の直後に呼ぶ。コールド起動で
    /// 保留された起動リクエストを、UI が完全に準備できた状態で処理する。
    func consumePendingLaunch() {
        guard let request = pendingLaunchRequest else { return }
        pendingLaunchRequest = nil
        performLaunch(request)
    }

    private func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// 全ディスクを検証してから単一インスタンスを差し替える。
    /// xm8 と同じセマンティクス: 1件でも検証・mount 失敗なら現状を一切変えない。
    func performLaunch(_ req: LaunchRequest) {
        if !romLoaded { loadROMs() }

        // MARK: 検証フェーズ — machine を一切触らない。
        // 1件でも失敗したら return し、現在の状態を保つ (xm8 semantics)。
        //
        // イメージ番号省略時のドライブ割り当ては実イメージ数に依存する
        // (QUASI88: 複数面ファイルを 1 個だけ指定 → drive 1 に 2 面目) ため、
        // まず全ファイルを読んで面数を確定させてから `resolveMounts` に渡す。
        var parsed: [String: [D88Disk]] = [:]
        for spec in req.disks where parsed[spec.path] == nil {
            switch validateLaunchDisk(spec.path) {
            case .failure(let message):
                showAlert(title: NSLocalizedString("ディスクを読み込めません", comment: ""), message: message)
                return
            case .success(let disks):
                parsed[spec.path] = disks
            }
        }

        let mounts = LaunchRequest.resolveMounts(req.disks) { parsed[req.disks[$0].path]?.count ?? 0 }

        // 明示指定されたイメージ番号が実在するかを、適用前に全件チェック。
        // 丸め込み禁止 (xm8 semantics) — `mountDiskImage` 側のクランプはあくまで
        // 安全側のフォールバック。
        for mount in mounts {
            let images = parsed[mount.path] ?? []
            guard mount.imageIndex < images.count else {
                showAlert(title: NSLocalizedString("ディスクを読み込めません", comment: ""),
                          message: String(format: NSLocalizedString(
                            "\"%@\" にイメージ %d は存在しません (全 %d 面)。", comment: ""),
                            mount.path, mount.imageIndex + 1, images.count))
                return
            }
        }

        // MARK: 適用フェーズ — ここから状態変更。
        cancelScriptPlayback()
        cancelScriptRecording()
        stop()
        cancelPasteQueue()

        if let system = req.system {
            _bootModeStorage = system
            Settings.shared.dipSw1 = system.dipSw1
            Settings.shared.dipSw2Base = system.dipSw2
        }
        if let clock = req.clock8MHz {
            Settings.shared.clock8MHz = clock
        }

        for drive in 0..<LaunchRequest.driveCount {
            if let mount = mounts.first(where: { $0.drive == drive }), let images = parsed[mount.path] {
                mountDiskExplicit(disks: images, imageIndex: mount.imageIndex,
                                  url: URL(fileURLWithPath: mount.path), drive: drive)
            } else {
                ejectDisk(drive: drive)
            }
        }

        // 単発リセット: 現在の `_bootModeStorage`/Settings から DIP SW を
        // 適用し、drive 0 のマウント状態を見て FDD/ROM boot を自動判定する。
        // `preserveRAM: true` を使う — 手動マウント+Cmd+E リセットでディスク
        // ブートする既存の動作確認済みパスと完全に一致させる (`preserveRAM:
        // false` はこの組合せで未検証だったため不採用)。
        //
        // **`reset()` を `applyBootStrap()` より先に呼ぶ** (`performReset` とは
        // 逆順、意図的な変更): ディスク差し替え直後は `SubSystem` の
        // `pendingMount` (400,000 T-state の交換ディレイ) が未コミットで
        // `subSystem.drives[0]` がまだ nil ということがあり、これは
        // `SubSystem.reset()` が明示的に flush する既知の設計 (同ファイルの
        // コメント「リセット直後にディスク交換窓が残るとロード失敗の原因」)。
        // 通常の手動マウント→Cmd+E は間に人間の反応時間が入るため自然に
        // ディレイが解消されるが、`performLaunch` は直前に `stop()` で
        // サブCPU時計を止めてしまうため 400,000 T-state が永遠に経過せず、
        // `applyBootStrap` を先に呼ぶと「ディスクなし」に誤判定して ROM boot
        // ビットが立ってしまう (→ BASIC に落ちて FDD 読み込みが始まらない、
        // 実機テストで再現した症状そのもの)。`reset()` を先にして
        // `pendingMount` を確定させてから判定する。
        let mode = _bootModeStorage
        let sw1 = mode.dipSw1
        let sw2Base = mode.dipSw2
        let use8MHz = clock8MHz
        // `-romboot` / `-diskboot` は自動判定を上書きする (QUASI88 同様、
        // 省略時はディスクの有無による自動判定)。
        let forcedBootStrap = req.bootStrap
        emuQueue.sync {
            machine.bus.dipSw1 = sw1
            machine.reset(preserveRAM: true)
            switch forcedBootStrap {
            case .rom:
                machine.bus.dipSw2 = Machine.resolvedBootStrap(base: sw2Base, hasDiskInDrive0: false)
            case .disk:
                machine.bus.dipSw2 = Machine.resolvedBootStrap(base: sw2Base, hasDiskInDrive0: true)
            case nil:
                machine.applyBootStrap(base: sw2Base)
            }
            machine.clock8MHz = use8MHz
            machine.cpuOverclock = cpuOverclock
        }
        syncActiveClockFromMachine()
        if romLoaded { loadROMs() }
        clearRewindBuffer()
        renderScreen()
        // `EmulatorMetalView.updateDrawLoop()` は `window.occlusionState`
        // (visible) を見て draw ループを一時停止する省エネ設計。FlipDisk など
        // 外部ランチャーからの起動時は、Bubilator88 のウィンドウが最前面でない
        // (= occluded 判定) ことがあり、そのまま `start()` すると draw ループが
        // 再開されず CPU がリセットベクタから一切進まない (mount/reset はここまでに
        // 完了しているのに「読み込みが始まらない」ように見える)。URL 起動は
        // ユーザがそのゲームを見るために呼んでいる操作なので、明示的にアプリを
        // 前面化してから start() する。
        NSApp.activate(ignoringOtherApps: true)
        metalView?.window?.makeKeyAndOrderFront(nil)
        start()
        showToast("\(NSLocalizedString("起動", comment: "")): \(drive0Name)")
    }

    /// 1 ディスクの検証: 読める & D88 としてパースできる。
    /// machine には触れない (validation のみ)。イメージ番号の範囲チェックは
    /// 自動割り当ての解決後 (`resolveMounts` の出力) に呼び出し側で行う。
    private func validateLaunchDisk(_ path: String) -> LaunchDiskValidationResult {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            return .failure(String(format: NSLocalizedString(
                "\"%@\" を読み込めません。ファイルが存在しないか、アクセスできません。", comment: ""),
                path))
        }
        let disks = D88Disk.parseAll(data: Array(data))
        guard !disks.isEmpty else {
            return .failure(String(format: NSLocalizedString(
                "\"%@\" は有効な D88 ディスクイメージではありません。", comment: ""), path))
        }
        return .success(disks)
    }
}

/// `validateLaunchDisk` の戻り値。エラーはユーザ表示用メッセージそのもの
/// (Error 適合が不要な内部用途) なので `Result<_, Error>` ではなく専用列挙にする。
private enum LaunchDiskValidationResult {
    case success([D88Disk])
    case failure(String)
}
