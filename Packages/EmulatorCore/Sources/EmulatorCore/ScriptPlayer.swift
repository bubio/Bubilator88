// ScriptPlayer.swift — [ScriptStep] を Machine 上で再生する。
//
// docs/SCRIPTING.md の drive モード (スクリプトが時計を所有) に相当。
// ファイルシステムには触れず、ディスクパス → バイト列の解決は呼び出し側が
// 渡す `FileLoader` クロージャに委ねる (純粋・テスト容易・サンドボックス対応)。

import Foundation

public final class ScriptPlayer {

    /// ディスクパス文字列を D88 のバイト列へ解決するクロージャ。
    public typealias FileLoader = (_ path: String) throws -> [UInt8]

    /// 再生時エラー (ディスク読み込み失敗・範囲外イメージ等)。
    public struct RuntimeError: Error, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    private let machine: Machine
    private let loader: FileLoader

    /// ドライブごとにマウント済みファイルの全イメージを保持 (disk select 用)。
    private var loadedImages: [[D88Disk]] = [[], []]

    /// tap の自動リリース予約。残りフレーム数。
    private var pendingReleases: [Keyboard.Key: Int] = [:]

    /// setup → timeline 遷移時の確定処理を済ませたか (reset で再武装)。
    private var setupFinalized = false

    /// `boot` で設定したときのみ ROM/ディスク起動 (DIPSW2 bit3) を自動解決する。
    /// `dipsw2` を生値で指定したらユーザに従い自動解決しない。
    private var resolveDiskBoot = true

    /// `clock` で明示されたクロック。`Machine.reset()` は clock8MHz を true に
    /// 戻すため、reset 後に再適用してスクリプトの意図を保つ (nil = 未指定)。
    private var desiredClock8MHz: Bool?

    public init(machine: Machine, loader: @escaping FileLoader) {
        self.machine = machine
        self.loader = loader
    }

    /// スクリプト全体を再生する。
    public func run(_ steps: [ScriptStep]) throws {
        for step in steps {
            try execute(step)
        }
        finish()
    }

    // MARK: - Step execution

    private func execute(_ step: ScriptStep) throws {
        switch step {
        case .boot(let mode):
            machine.bus.dipSw1 = mode.dipSw1
            machine.bus.dipSw2 = mode.dipSw2
            resolveDiskBoot = true

        case .clock(let mhz):
            let want = (mhz == 8)
            machine.clock8MHz = want
            desiredClock8MHz = want

        case .dipsw1(let v):
            machine.bus.dipSw1 = v

        case .dipsw2(let v):
            machine.bus.dipSw2 = v
            resolveDiskBoot = false

        case .diskMount(let drive, let path, let image):
            try mountFile(drive: drive, path: path, image: image)

        case .wait(let frames):
            advance(frames)

        case .key(let key, let action):
            applyKey(key, action)

        case .diskSwap(let drive, let path, let image):
            try mountFile(drive: drive, path: path, image: image)

        case .diskSelect(let drive, let image):
            try selectImage(drive: drive, image: image)

        case .diskEject(let drive):
            machine.ejectDisk(drive: drive)
            loadedImages[drive] = []

        case .reset(let preserveRAM):
            machine.reset(preserveRAM: preserveRAM)
            // reset は clock8MHz を true に戻し、キーマトリクスを全解放する。
            // スクリプトで明示したクロックは再適用して意図を保つ
            // (dipSw1/2 は reset で保持される)。
            if let c = desiredClock8MHz { machine.clock8MHz = c }
            pendingReleases.removeAll()
            setupFinalized = false          // 次の advance 前に bit3 を再確定
        }
    }

    // MARK: - Time advancement

    func advance(_ frames: Int) {           // internal: タイミングのユニットテスト用
        guard frames > 0 else { return }    // wait 0 は時間も起動確定も進めない
        finalizeSetupIfNeeded()
        for _ in 0..<frames {
            machine.runFrame()
            tickPendingReleases()
        }
    }

    /// 各フレーム後に呼び、予約された tap リリースを発火する。
    private func tickPendingReleases() {
        guard !pendingReleases.isEmpty else { return }
        // キーのスナップショットを反復し、辞書本体は中身だけ更新する。
        for key in Array(pendingReleases.keys) {
            guard let remaining = pendingReleases[key] else { continue }
            let next = remaining - 1
            if next <= 0 {
                machine.keyboard.releaseKey(row: key.row, bit: key.bit)
                pendingReleases[key] = nil
            } else {
                pendingReleases[key] = next
            }
        }
    }

    /// 最初の時間進行 (および reset 後) の一度だけ、ROM/ディスク起動を確定する。
    private func finalizeSetupIfNeeded() {
        guard !setupFinalized else { return }
        setupFinalized = true
        if resolveDiskBoot {
            // ドライブ 0 の占有状態から起動ストラップ (bit3) を確定 (Machine 共有ヘルパ)。
            machine.applyBootStrap()
        }
    }

    // MARK: - Keyboard

    func applyKey(_ key: Keyboard.Key, _ action: KeyAction) {   // internal: タイミングのユニットテスト用
        switch action {
        case .down:
            machine.keyboard.pressKey(row: key.row, bit: key.bit)
            pendingReleases[key] = nil
        case .up:
            machine.keyboard.releaseKey(row: key.row, bit: key.bit)
            pendingReleases[key] = nil
        case .tap(let hold):
            // 保持中の同キーは先に解放してから押し直す (pressKey で上書き)。
            // §6 の「必ず 1 フレーム以上保持」保証のため hold は 1 未満を 1 に丸める。
            machine.keyboard.pressKey(row: key.row, bit: key.bit)
            pendingReleases[key] = max(1, hold)
        }
    }

    // MARK: - Disk

    private func mountFile(drive: Int, path: String, image: Int) throws {
        let data = try loader(path)
        let disks = D88Disk.parseAll(data: data)
        guard !disks.isEmpty else {
            throw RuntimeError("D88 として解釈できません: \(path)")
        }
        guard image >= 0 && image < disks.count else {
            throw RuntimeError("イメージ番号 \(image) が範囲外 (\(path) は \(disks.count) 面)")
        }
        loadedImages[drive] = disks
        machine.mountDisk(drive: drive, disk: disks[image])
    }

    private func selectImage(drive: Int, image: Int) throws {
        let disks = loadedImages[drive]
        guard !disks.isEmpty else {
            throw RuntimeError("ドライブ \(drive) にマウント済みファイルがありません (disk select)")
        }
        guard image >= 0 && image < disks.count else {
            throw RuntimeError("イメージ番号 \(image) が範囲外 (ドライブ \(drive) は \(disks.count) 面)")
        }
        machine.mountDisk(drive: drive, disk: disks[image])
    }

    // MARK: - Finish

    /// 再生終了時、未リリースの tap 予約を解放する。
    private func finish() {
        for key in pendingReleases.keys {
            machine.keyboard.releaseKey(row: key.row, bit: key.bit)
        }
        pendingReleases.removeAll()
    }
}
