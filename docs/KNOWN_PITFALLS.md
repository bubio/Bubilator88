# Known Pitfalls — PC-8801 Emulation

Bubilator88 開発で遭遇した落とし穴と教訓。デグレ防止のために記録する。

---

## 1. textVRAM と mainRAM の関係

**問題**: tvram 書き込みを mainRAM にも shadow (ミラーリング) すると、ハイドライド3 が起動しなくなる。

**原因**: テキストウィンドウ (0x8000-0x83FF) はオフセット付きで mainRAM にルーティングされる。tvram への書き込みを mainRAM に無条件ミラーすると、ゲームが想定しないアドレスのデータが変化する。

**教訓**: textVRAM と mainRAM は独立したアクセスパスを持つ。Phase 19 で独立バッファを廃止して mainRAM ベースに統合したが、tvram (高速テキストRAM) 経由の書き込みを mainRAM に伝播させるかは慎重に判断すること。

**追記 (commit 66a5cfc2)**: 反対方向 — テキストウィンドウ経由のアクセスが `0xF000+` に着地したとき tvram に divert する処理 — も同じ独立性原則を破る。BubiC 準拠で削除した。`tvram` と `mainRAM` の独立性は **両方向** で守ること (tvram→mainRAM のミラー、mainRAM→tvram の divert、いずれも NG)。

---

## 2. CRTC ステータスレジスタのビット配置

**問題**: dataReady を bit 0 に出力していたため、ROM の VRTC ハンドラが Light Pen 処理に入り、ブートが進まなくなった (Phase 21)。

**正しい配置**:
- bit 7: DR (data ready)
- bit 5: VRTC
- bit 4: VE (display enabled)
- bit 3: U (DMA underrun)
- bit 0: LP (light pen)

**教訓**: データシート上のビット配置と BubiC/QUASI88 の実装を必ず照合すること。1ビットのずれでブート不能になる。

---

## 3. DIP SW1 bit 1 (BASIC/Terminal mode)

**問題**: bit 1 = 0 だとターミナルモードになり、auto-key buffer が 0x20 で埋められ、起動に失敗する (Phase 21)。

**教訓**: DIP スイッチのデフォルト値 (0xC3) の各ビットの意味を把握すること。bit 1 は特に重要。

---

## 4. Port 0x31 のビット定義

**問題**: bit 0-2 の解釈を誤ると、200/400ライン、ROM/RAM、N88/N-BASIC の切り替えが壊れる (Phase 17)。

**正しい定義**:
- bit 0: GRPH_CTRL_200 (1=200line, 0=400line)
- bit 1: MMODE (0=ROM, 1=64K RAM) → `ramMode`
- bit 2: RMODE (0=N88-BASIC, 1=N-BASIC) → `romModeN88 = (val & 0x04) == 0`

**教訓**: QUASI88 のソースコードが最も信頼できるリファレンス。BubiC も参照するが、変数名が異なるので注意。

---

## 5. テキストウィンドウの条件分岐

**問題**: テキストウィンドウ (0x8000-0x83FF) のオフセット付きルーティングは `!ramMode && romModeN88` の場合のみ有効。この条件を間違えると N-BASIC ROM やゲームが誤動作する (Phase 17b)。

**教訓**: RMODE=1 (N-BASIC) や MMODE=1 (64K RAM) の場合はテキストウィンドウが無効になり、mainRAM[addr] にフォールスルーする。IM2 ベクタが 0x8000+ にある場合、この条件が重要。

---

## 6. InterruptController の acknowledge 動作

**問題**: acknowledge 時に levelThreshold を 0 にリセットしないと、割り込みが再発火してゲームがフリーズする (Phase 30)。

**QUASI88 準拠の動作**:
- acknowledge → levelThreshold = 0
- resolve: levelNum < threshold (not <=)

**教訓**: i8214 の仕様書だけでなく、QUASI88 の実装を参照すること。3件の致命的バグがこの箇所にあった。

---

## 7. スタートレーダーの GVRAM 色ずれ (解決済み)

**問題**: ダイアログの文字色が緑ではなく白になる。シナリオインタープリタが色コード 0x27 (緑) を正しく適用できない。

**原因**: 拡張アクセスモード (evramMode) 突入時に、独立アクセスモード用の GVRAM プレーン選択レジスタ (gvramPlane) をクリアしていなかった。古いプレーン選択が残ったまま ALU モードに遷移し、GVRAM の読み書き先がずれていた。

**修正**: evramMode 有効時に gvramPlane を -1 (mainRAM) にリセット。QUASI88 の main_memory_vram_mapping() と同じ動作。

**教訓**: VRAM アクセスモードの遷移時には、前のモードのステートを適切にクリアすること。描画の色ずれが CPU 命令の問題に見えても、実際には VRAM アクセス制御レジスタの状態管理が原因であり得る。

---

## 8. FDC d88Track 計算 (LUXSOR 修正)

**問題**: LUXSOR の Disk B で FDC が d88Track を chrn.c ベースで計算すると、EOT < R の場合に誤ったトラックを読む。

**修正**: EOT < R の場合は pcn[us] ベースで d88Track を計算する。resolveReadSequence() でマルチセクタ読取を統一処理。

**教訓**: D88 フォーマットのトラック番号と FDC の物理シリンダ番号は常に一致するとは限らない。特にコピープロテクトやイレギュラーなディスクフォーマットに注意。

---

## 9. 200ライン倍化とフィルタ処理

**問題**: 640x400 バッファ (200ライン倍化済み) をそのままフィルタに渡すと、xBRZ 等のエッジ検出が倍化行で誤動作する。

**正しい方法**: 200ラインモードでは偶数行のみ抽出した 640x200 テクスチャをフィルタに渡す。XM8 も同じ方式。

**教訓**: フィルタ/スケーラは実コンテンツ解像度で処理すること。倍化はフィルタ後の表示段階で行う。

---

## 10. GPU シェーダでの浮動小数点比較

**問題**: xBRZ の GPU 移植で `v[i] == v[j]` (packed float の完全一致比較) が 8-bit テクスチャの精度誤差で失敗し、エッジ検出が機能しない。

**対策**: `reduce()` に `round()` を追加して丸め誤差を除去するか、閾値付き比較 (`xbrz_IsPixEqual`) を使用する。ただし閾値を緩くしすぎるとエッジ検出がスキップされるケースが増える。

**教訓**: CPU (整数演算) → GPU (浮動小数点) の移植では、等値比較のセマンティクスが変わる。

---

## 11. Port 0x53 プレーン非表示とカラーモード

**問題**: Port 0x53 bits 1-3 で GVRAM プレーンを個別に非表示にできるが、カラーモード時はこれらのビットを無視しなければならない (BubiC 確認)。

---

## 12. Z80 DAA の減算側フラグ

**問題**: `DAA` を単純な「補正後の A だけ」から再計算すると、減算側 (`N=1`) の `C/H/PV` が参照実装と食い違う。

**教訓**: PC-88 タイトル互換では、`DAA` は x88/QUASI88 相当の挙動に合わせること。特に減算側は、補正前の `C/H` と補正条件を使って `C/H` を決める。

**教訓**: モノ/アトリビュートモード時のみ個別プレーン非表示が有効。カラーモード時に適用すると表示が壊れる。

---

## 12. @Observable + didSet の再帰ループ

**問題**: Swift の `@Observable` マクロ付きクラスで、`didSet` 内でプロパティを再代入すると無限再帰 → ハングアップ。

```swift
// NG: 無限ループ
var value: Float = 0.5 {
    didSet { value = max(0, min(1, value)) }
}
```

**対策**: クランプは代入側 (ボタンハンドラ等) で行う。

**教訓**: `@Observable` のプロパティ観測メカニズムは `didSet` 内の再代入をトリガーとして再度 `didSet` を呼ぶ。

---

## 13. FDC Seek 完了割り込みが ReadData を破壊

**問題**: 「あたしのぱぴぷぺぽ」でアニメーション画面が表示されず、ADPCM 音量も不安定。PIO データ転送が 1 バイトずれていた。

**原因**: FDC の `tick()` で、ReadData 実行フェーズ中に別ドライブの Seek 完了が `interruptPending = true` を設定。サブ CPU が HALT→INI バイト読み取りループで、バイト準備前にスプリアス割り込みで覚醒し、`readData()` が 0xFF を返した。この 0xFF がバッファに挿入され、以降の全データが 1 バイトシフト。

**修正**: `tick()` の Seek 完了処理で、`phase == .execution` の間は `interruptPending` 設定と `onInterrupt()` 呼び出しを抑制。`seekState = .interrupt` は記録されるため、次の `SenseIntStatus` で正常に報告される。

**教訓**: FDC は Seek/Recalibrate（非同期）と ReadData/WriteData（同期）を並行処理できる。共有の `interruptPending` フラグを使う場合、実行フェーズ中の Seek 完了割り込みを抑制しないと、サブ CPU のバイト読み取りタイミングが崩れる。

---

## 14. Z80 実装の信頼性 (疑う前に読むこと)

**状況**: 起動しないタイトルを調査するとき、**Z80 CPU のバグを最初に疑うのは避ける**。過去に網羅的な監査を行い、BubiC と実質的に等価であることが確認されている。

**監査済項目** (2026-04-20, BubiC `z80.cpp` と突合):

- **符号処理**: `JR`/`DJNZ`/`IX+d`/`IY+d` の変位は `Int8(bitPattern:) → Int16 → UInt16(bitPattern:)` で正しく符号拡張。Swift の型安全性と wrapping 演算子 (`&+`/`&-`) により C 言語式の `int` 事故は起こり得ない。15 ゲーム regression + 639 unit tests で負オフセット (`JR -3`, `DJNZ -2` 等) も検証済。
- **フラグ計算**: ADD/ADC/SUB/SBC/CP/INC/DEC/AND/OR/XOR/ADC HL/SBC HL/LDI/LDIR/LDD/LDDR/CPI/CPD/INI/INIR/IND/INDR/OUTI/OTIR/OUTD/OTDR/RLA/RRA/RLCA/RRCA/DAA の **S/Z/H/PV/N/C/F5/F3 計算**を BubiC の SZHVC_add/SZHVC_sub テーブル、SZP テーブルと対比 → すべて数学的に等価 (例: half-carry の `(a & 0x0F) + (value & 0x0F) > 0x0F` と `(newA & 0x0F) < (a & 0x0F)` は同値)。
- **命令 T-states**: 通常命令 0x00-0xFF (CB/DD/ED/FD 除く) 256 個すべて BubiC の `cc_op[]` と一致。条件分岐の取らない/取る (JR cc 7/12、CALL cc 10/17、RET cc 5/11、DJNZ 8/13) も一致。LDIR の iteration 中 21/完了時 16 も一致。
- **DAA 減算側**: 本ファイル §12 で既に x88/QUASI88 相当に調整済。
- **ED 未定義命令**: 各 NOP 扱いだが、`ED 08` のみ「あたしのぱぴぷぺぽ」PIO handshake (0x08A2) のため `EX AF,AF'` として扱う (BubiC 互換の意図的例外)。

**残っている軽微な既知差**:

- **BIT (HL) / BIT (IX+d) の F5/F3**: Bubilator88 は未設定 (コメント "simplified")。BubiC は `WZ_H` (memptr) や `(ea >> 8)` から取る。**通常ソフトへの影響はほぼない** (undocumented bit のため) が、zexall 系の網羅テストは通らない。WZ/Memptr レジスタを導入しない限り修正不可。

**疑うべき別の層** (Z80 ではなく):

起動問題は経験的に以下の層に起因することが多い:
1. **FDC の挙動差** (保護セクタ処理、N 不一致、回転タイミング)
2. **PIO 8255 main-sub ハンドシェイク** のタイミング
3. **メモリマップ/ROM バンク切替** (port 0x31/0x32 bit 解釈)
4. **CRTC / DMA / 割込み制御** の state machine
5. **V1H/V2/V1S モード** によるゲーム側分岐 (ここは emulator の V1S memory wait `Pc88Bus.swift:215` が関連)

**教訓**: 「起動しない → Z80 がおかしい」と飛びつかない。Z80 にバグが入り込む確率は現状**極めて低い**。まず FDC コマンドログ、PIO flow diff、ポート書き込みトレースを取って、**どの層で分岐しているか**を特定してから Z80 を疑うこと。もし Z80 精度を疑うなら、先に **BIT (HL) の F5/F3** 以外の具体的な症状・バイト列を示せる状態にしてから着手する。

**参照**: `memory/project_ng_games_investigation.md` の TOKYOナンパストリート / F2 / T.D.F の調査履歴。これらは**すべて Z80 以外**の層 (ROM の JP 先計算差、PIO ハンドシェイク、V1H メモリ wait) が真因だった。
