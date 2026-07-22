import AppKit
import EmulatorCore

// MARK: - URL scheme launch (FlipDisk 連携, xm8 CLI 相当)
//
// docs/URL_SCHEME_LAUNCH_PLAN.md の実装。`bubilator88://boot?...` を単一
// インスタンスへ配送し、ディスク/機種/クロックを差し替えて cold boot する。
// `.b88script` の `pendingScriptURL` と同型の deferral (`pendingLaunchURL`)
// を使うが、transport (kAEGetURL) と消費者が別なので専用に保つ。
extension EmulatorViewModel {

    /// `.onOpenURL` からの入口。準備済み (描画ループ稼働中) なら即実行、
    /// まだなら保留して `ContentView.onAppear` の `consumePendingLaunch()` に委ねる。
    func requestLaunch(url: URL) {
        if isRunning && metalView != nil {
            performLaunch(url: url)
        } else {
            pendingLaunchURL = url
        }
    }

    /// `ContentView.onAppear` が `start()` の直後に呼ぶ。コールド起動オープンで
    /// 保留された起動 URL を、UI が完全に準備できた状態で処理する。
    func consumePendingLaunch() {
        guard let url = pendingLaunchURL else { return }
        pendingLaunchURL = nil
        performLaunch(url: url)
    }

    /// URL をパースし、全ディスクを検証してから単一インスタンスを差し替える。
    /// xm8 と同じセマンティクス: 1件でも検証・mount 失敗なら現状を一切変えない。
    func performLaunch(url: URL) {
        let req: LaunchRequest
        do {
            req = try LaunchRequest.parse(url)
        } catch {
            showAlert(title: NSLocalizedString("起動 URL エラー", comment: ""),
                      message: "\(url.absoluteString): \(error)")
            return
        }

        if !romLoaded { loadROMs() }

        // MARK: 検証フェーズ — machine を一切触らない。
        // 1件でも失敗したら return し、現在の状態を保つ (xm8 semantics)。
        let disk0Result = validateLaunchDisk(req.disk0)
        let disk0Disks: [D88Disk]
        switch disk0Result {
        case .failure(let message):
            showAlert(title: NSLocalizedString("ディスクを読み込めません", comment: ""), message: message)
            return
        case .success(let disks):
            disk0Disks = disks
        }

        var disk1Disks: [D88Disk]?
        if let disk1 = req.disk1 {
            switch validateLaunchDisk(disk1) {
            case .failure(let message):
                showAlert(title: NSLocalizedString("ディスクを読み込めません", comment: ""), message: message)
                return
            case .success(let disks):
                disk1Disks = disks
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

        let disk0URL = URL(fileURLWithPath: req.disk0.path)
        mountDiskExplicit(disks: disk0Disks, imageIndex: req.disk0.bank, url: disk0URL, drive: 0)
        if let disk1 = req.disk1, let disk1Disks {
            let disk1URL = URL(fileURLWithPath: disk1.path)
            mountDiskExplicit(disks: disk1Disks, imageIndex: disk1.bank, url: disk1URL, drive: 1)
        } else {
            ejectDisk(drive: 1)
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
        emuQueue.sync {
            machine.bus.dipSw1 = sw1
            machine.reset(preserveRAM: true)
            machine.applyBootStrap(base: sw2Base)
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

    /// 1 ディスクの検証: 読める & D88 としてパースできる & bank が範囲内。
    /// machine には触れない (validation のみ)。丸め込み禁止 (xm8 semantics) —
    /// `mountDiskImage` 側のクランプはあくまで安全側のフォールバックで、
    /// 「存在しない bank はエラー」の判定はここで行う。
    private func validateLaunchDisk(_ disk: LaunchRequest.Disk) -> LaunchDiskValidationResult {
        let url = URL(fileURLWithPath: disk.path)
        guard let data = try? Data(contentsOf: url) else {
            return .failure(String(format: NSLocalizedString(
                "\"%@\" を読み込めません。ファイルが存在しないか、アクセスできません。", comment: ""),
                disk.path))
        }
        let disks = D88Disk.parseAll(data: Array(data))
        guard !disks.isEmpty else {
            return .failure(String(format: NSLocalizedString(
                "\"%@\" は有効な D88 ディスクイメージではありません。", comment: ""), disk.path))
        }
        guard disk.bank < disks.count else {
            return .failure(String(format: NSLocalizedString(
                "\"%@\" に bank %d は存在しません (全 %d 面)。", comment: ""),
                disk.path, disk.bank, disks.count))
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
