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
            showAlert(title: NSLocalizedString("Launch URL Error",
                                              comment: "Alert title: a bubilator88:// URL could not be parsed"),
                      message: "\(url.absoluteString): \(error.localizedDescription)")
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
            showAlert(title: NSLocalizedString("Launch Argument Error",
                                              comment: "Alert title: the command-line arguments could not be parsed"),
                      message: error.localizedDescription)
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

    /// 全ディスクを検証してから単一インスタンスを差し替える。
    /// xm8 と同じセマンティクス: 1件でも検証・mount 失敗なら現状を一切変えない。
    func performLaunch(_ req: LaunchRequest) {
        if !romLoaded { loadROMs() }

        // MARK: 検証フェーズ — machine を一切触らない。
        // 1件でも失敗したら return し、現在の状態を保つ (xm8 semantics)。
        let resolved: [ResolvedLaunchMount]
        switch resolveLaunchMounts(req) {
        case .failure(let message):
            showAlert(title: NSLocalizedString("Cannot Load Disk",
                                              comment: "Alert title: a disk named in the launch arguments could not be mounted"),
                      message: message)
            return
        case .success(let mounts):
            resolved = mounts
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
            if let mount = resolved.first(where: { $0.drive == drive }) {
                mountDiskExplicit(disks: mount.images, imageIndex: mount.imageIndex,
                                  url: mount.url, drive: drive)
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
        showToast("\(NSLocalizedString("Launched", comment: "Toast shown after a URL/command-line launch; followed by the drive 0 disk name")): \(drive0Name)")
    }

    /// 起動リクエストを「どのドライブに、どのファイルの何面目を載せるか」まで
    /// 確定させる。ファイル読込と D88 パースを伴うが、`machine` には触れない。
    ///
    /// イメージ番号省略時の割り当ては**実イメージ数に依存する** (QUASI88:
    /// 複数面ファイルを 1 個だけ指定 → drive 1 に 2 面目) ため、先に面数を
    /// 確定させてから `LaunchRequest.resolveMounts` に渡す。プレイリスト
    /// 指定時は「面数 = エントリ数」として同じ規則を適用する。
    private func resolveLaunchMounts(_ req: LaunchRequest)
        -> LaunchMountResolution {
        guard !req.disks.isEmpty else { return .success([]) }

        if req.isPlaylistLaunch {
            return resolvePlaylistMounts(req)
        }

        var parsed: [String: [D88Disk]] = [:]
        for spec in req.disks where parsed[spec.path] == nil {
            switch validateLaunchDisk(URL(fileURLWithPath: spec.path)) {
            case .failure(let message): return .failure(message)
            case .success(let disks): parsed[spec.path] = disks
            }
        }

        let mounts = LaunchRequest.resolveMounts(req.disks) { parsed[req.disks[$0].path]?.count ?? 0 }

        // 明示指定されたイメージ番号が実在するかを、適用前に全件チェック。
        // 丸め込み禁止 (xm8 semantics) — `mountDiskImage` 側のクランプはあくまで
        // 安全側のフォールバック。
        var resolved: [ResolvedLaunchMount] = []
        for mount in mounts {
            let images = parsed[mount.path] ?? []
            guard mount.imageIndex < images.count else {
                return .failure(String(format: NSLocalizedString(
                    "\"%1$@\" has no image %2$ld (it contains %3$ld image(s)).",
                    comment: "Error: the image number given in the launch arguments is past the end of the D88 file. %1 file path, %2 requested 1-based image number, %3 number of images in the file"),
                    mount.path, mount.imageIndex + 1, images.count))
            }
            resolved.append(ResolvedLaunchMount(drive: mount.drive,
                                                url: URL(fileURLWithPath: mount.path),
                                                images: images,
                                                imageIndex: mount.imageIndex))
        }
        return .success(resolved)
    }

    /// `.m3u` / `.m3u8` 指定の解決。プレイリストの**エントリ**を d88 の「面」と
    /// 同じものとして扱う (イメージ番号 = エントリ番号, 1 始まり):
    ///
    /// - `p.m3u` → エントリ1 を drive 0、エントリ2 を drive 1 (2 件以上あれば)
    /// - `p.m3u 3` → エントリ3 を drive 0、drive 1 は空
    /// - `p.m3u 2 4` → エントリ2 を drive 0、エントリ4 を drive 1
    ///
    /// 各エントリは**独立したソースファイル**として、その 1 面目をマウントする
    /// (GUI の `mountM3U` と同じ規則)。ディスク書き戻しがエントリ自身のファイルに
    /// 向くようにするため、複数面をフラット化した共有イメージリストにはしない。
    private func resolvePlaylistMounts(_ req: LaunchRequest)
        -> LaunchMountResolution {
        let playlistPath = req.disks[0].path
        let playlistURL = URL(fileURLWithPath: playlistPath)
        guard let entries = M3UPlaylist.entryURLs(contentsOf: playlistURL) else {
            return .failure(String(format: NSLocalizedString(
                "Cannot read \"%@\". The file does not exist or is not accessible.",
                comment: "Error: a file named in the launch arguments could not be read. %@ is the file path"),
                playlistPath))
        }
        guard !entries.isEmpty else {
            return .failure(String(format: NSLocalizedString(
                "\"%@\" contains no disk image entries.",
                comment: "Error: an m3u/m3u8 playlist has only blank or comment lines. %@ is the playlist path"),
                playlistPath))
        }

        let mounts = LaunchRequest.resolveMounts(req.disks) { _ in entries.count }
        var resolved: [ResolvedLaunchMount] = []
        for mount in mounts {
            guard mount.imageIndex < entries.count else {
                return .failure(String(format: NSLocalizedString(
                    "\"%1$@\" has no entry %2$ld (it contains %3$ld entries).",
                    comment: "Error: the entry number given in the launch arguments is past the end of the playlist. %1 playlist path, %2 requested 1-based entry number, %3 number of entries"),
                    playlistPath, mount.imageIndex + 1, entries.count))
            }
            let entryURL = entries[mount.imageIndex]
            switch validateLaunchDisk(entryURL) {
            case .failure(let message): return .failure(message)
            case .success(let images):
                resolved.append(ResolvedLaunchMount(drive: mount.drive, url: entryURL,
                                                    images: images, imageIndex: 0))
            }
        }
        return .success(resolved)
    }

    /// 1 ディスクの検証: 読める & D88 としてパースできる。
    /// machine には触れない (validation のみ)。イメージ番号の範囲チェックは
    /// 自動割り当ての解決後 (`resolveMounts` の出力) に呼び出し側で行う。
    private func validateLaunchDisk(_ url: URL) -> LaunchDiskValidationResult {
        guard let data = try? Data(contentsOf: url) else {
            return .failure(String(format: NSLocalizedString(
                "Cannot read \"%@\". The file does not exist or is not accessible.",
                comment: "Error: a file named in the launch arguments could not be read. %@ is the file path"),
                url.path))
        }
        let disks = D88Disk.parseAll(data: Array(data))
        guard !disks.isEmpty else {
            return .failure(String(format: NSLocalizedString(
                "\"%@\" is not a valid D88 disk image.",
                comment: "Error: a file named in the launch arguments is readable but is not a D88 image. %@ is the file path"),
                url.path))
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

/// `resolveLaunchMounts` の戻り値。`LaunchDiskValidationResult` と同じく、
/// エラーはユーザ表示用メッセージそのもの (`String` は `Error` 非適合なので
/// `Result` は使えない)。
private enum LaunchMountResolution {
    case success([ResolvedLaunchMount])
    case failure(String)
}

/// 検証済みの 1 ドライブ分のマウント指示。d88 直接指定なら `url` はその d88、
/// プレイリスト指定なら `url` は**エントリのファイル**を指す (プレイリスト
/// 自身ではない) — 書き戻し先を実ファイルに向けるため。
private struct ResolvedLaunchMount {
    let drive: Int
    let url: URL
    let images: [D88Disk]
    let imageIndex: Int
}
