# カセットテープ (CMT) インタフェース

PC-8801 のカセットテープ I/O と、ソフトウェア流通フォーマット (T88 / CMT)
の仕様。Bubilator88 の CassetteDeck / I8251 実装の参照。

参照: `docs/SPECS/IO_PORT_MAP.md` のポート 0x20/0x21/0x30/0x40、BubiC-8801MA
(`src/vm/pc8801/pc88.cpp`, `src/vm/i8251.cpp`) の実装。

---

## 1. ハードウェア構成

### 関与する LSI

| デバイス | 役割 |
|---------|------|
| μPD8251AFC (I8251 USART) | シリアル送受信。CMT と RS-232C で兼用 |
| システム制御 PIO 相当 | モータ ON/OFF、CMT/RS-232C 切替、クロック分周 |
| アナログ FSK 回路 | 1200/2400Hz の変調・復調 (エミュでは再現不要) |

FSK 変調部はアナログ回路なので、エミュレーションではデジタル結果 (bit /
byte 列) を I8251 の Rx に直接注入するだけで足りる。

### 変調方式 / ボーレート

- **FSK (Kansas City Standard 系)**: 0 = 1200Hz, 1 = 2400Hz
- **600 baud** (低速) / **1200 baud** (高速) の 2 段階
- BASIC 命令で指定: `CLOAD?` / `CSAVE "NAME",,H` の `H` パラメタで高速
- ハード分周とソフト設定を組み合わせて実レートを決定
- エミュ実装では実ボーレートに縛られず、T-state 間隔でバイトを供給する

---

## 2. I/O ポート

### 0x20 / 0x21: I8251 USART

| Port | R/W | 機能 |
|------|-----|------|
| 0x20 | R | 受信データ (Rx) |
| 0x20 | W | 送信データ (Tx) |
| 0x21 | R | ステータス |
| 0x21 | W | Mode byte または Command byte |

**Status (0x21 R)**

| Bit | 信号 | 意味 |
|-----|------|------|
| 7 | DSR | Data Set Ready |
| 6 | SYNDET / BD | 同期検出 |
| 5 | FE | Framing Error |
| 4 | OE | Overrun Error |
| 3 | PE | Parity Error |
| 2 | TxE | Transmitter Empty |
| 1 | RxRDY | 受信レディ (1 = readRx 可能) |
| 0 | TxRDY | 送信レディ (1 = writeTx 可能) |

**Mode byte (0x21 W, リセット直後の最初の書き込み)**

| Bit | 意味 |
|-----|------|
| 7-6 | Stop bits (00=invalid, 01=1, 10=1.5, 11=2) |
| 5-4 | Parity (00=none, 01=odd, 10=none, 11=even) |
| 3-2 | Character length (00=5, 01=6, 10=7, 11=8) |
| 1-0 | Baud factor (00=sync, 01=x1, 10=x16, 11=x64) |

**Command byte (0x21 W, Mode 書き込み以降)**

| Bit | 意味 |
|-----|------|
| 7 | EH (Hunt mode, sync 時のみ) |
| 6 | IR (Internal Reset; 1 で Mode 待ちに戻る) |
| 5 | RTS |
| 4 | ER (Error Reset) |
| 3 | SBRK (Send Break) |
| 2 | RxE (Receiver Enable) |
| 1 | DTR |
| 0 | TxEN (Transmitter Enable) |

N88-BASIC のカセットロード経路では、Mode = 0x4E (1 stop / no parity / 8 bit /
x16) → Command = 0x27 (RxE + ER + DTR + TxEN) のような初期化をする。

### 0x30 (Write): システムコントロール

| Bit | 信号 | 用途 |
|-----|------|------|
| 5-4 | BS | USART チャネル選択 (00=CMT600, 01=CMT1200, 10/11=RS-232C) |
| 3 | MTON | カセットモータ ON/OFF (1=ON) |

ビット 5 が `0` のとき CMT 側にルーティング。`1` で RS-232C 側。
Bubilator88 実装では `cmtSelected = !(port30w & 0x20)` で判別。

### 0x40 (Read): システムステータス

| Bit | 信号 | 用途 |
|-----|------|------|
| 2 | DCD | データキャリア検出 (1 = キャリア有) |

I8251 内部の DSR/DCD ピンではなく、本体 I/O ラッチとして見える。
CassetteDeck 側が `dcd` 状態を管理し、Pc88Bus が Port 0x40 読み出し時に
OR する。

---

## 3. BASIC からのアクセスシーケンス

### CLOAD の典型フロー

1. `OUT &H30, ...` (MTON=1, BS=00 = CMT600) → モータ ON + CMT 選択
2. `OUT &H21, mode` → I8251 を Mode 設定に
3. `OUT &H21, command` → Command で RxE 有効
4. Port 0x40 bit 2 (DCD) をポーリングしてキャリア検出を待つ
5. Port 0x21 bit 1 (RxRDY) をポーリング → Port 0x20 で 1 バイト読み
6. 同期パターン (`D3 D3 D3 ...` または `9C 9C ...`) を検出
7. ヘッダ部 (6B: ファイル名 + 属性) を読む
8. キャリア再確認 → 本体データ読み
9. 終端判定 → `MOTOR OFF` (Port 0x30 bit 3 = 0)

### CSAVE (参考; Bubilator88 ではサポート外)

Tx 側で Port 0x20 に書き込み → I8251 が TxEmpty で出力 → アナログ FSK
変調回路 → カセットに記録。Bubilator88 のスコープでは実装しない。

---

## 4. ファイルフォーマット

### 4.1 CMT (raw)

- ヘッダなし。ファイル全体がそのまま I8251 Rx に流し込まれる生データ列
- 先頭 23 バイトが `"PC-8801 Tape Image(T88)"` でなければ CMT と判定
- Data carrier (同期) 検出は buffer を走査してパターンで特定する
  (後述 Data Carrier 検出規則)

### 4.2 T88 (PC-88 コミュニティ標準)

**ファイル構造**

```
+0     "PC-8801 Tape Image(T88)" + 0x1A      (24 バイト、ASCII シグネチャ)
+24    Tag ブロック列
       [tag (u16 LE)] [len (u16 LE)] [payload (len bytes)]
       ...
       [0x0000] [0x0000]                      EOF タグ
```

**主要タグ**

| Tag (LE) | 名前 | payload 説明 |
|----------|------|--------------|
| 0x0000 | EOF | len=0。ファイル終端 |
| 0x0101 | Data | **先頭 12 バイトはメタ情報 (スキップ)**、残り `len-12` バイトをバッファに追記 |
| 0x0102 | Data Carrier | 低速キャリア開始マーカー。現在のバッファ位置を記録 |
| 0x0103 | Data Carrier (高速) | 1200bps 側のキャリア開始マーカー |

タイミング情報 (周波数遷移テーブル) が含まれることもあるが、BubiC/XM8 と
同様に無視し、バイト列のみ抽出して一定間隔で送る。

### 4.3 Data Carrier 検出規則

Data carrier は「これから有意データが始まる」の手がかり。BASIC のロード
ルーチンは carrier を検出してからデータを読み始める。パターン:

- **`0xD3` を 10 回以上連続** → BASIC ヘッダ前の同期
- **`0x9C` を 6 回以上連続** → マシン語 (BSAVE) ヘッダ前の同期

CassetteDeck はロード時にバッファ全体を走査してこれらの開始位置を
`dataCarriers: [Int]` に記録。現在の `bufPtr` がこれら開始位置の
近傍にあるとき `dcd = true` を返す。

T88 の場合は tag 0x0102 / 0x0103 の時点のバッファ位置をそのまま使う
(走査不要)。

---

## 5. タイミング

### バイト間隔

- 実機 1200bps = 1 バイト約 8333 T-state @ 8MHz (理論値)
- BubiC/XM8 は **5000 T-state/バイト** で固定駆動 (~1.7 倍速)
- Bubilator88 も初期実装は 5000 T-state/バイトで出発
- 可能ならもっと詰める余地はあるが、N88-BASIC ROM の同期検出ループが
  壊れない範囲に留める

### DCD 遷移

- モータ ON → 次の data carrier 位置到達まで DCD=0
- Data carrier 区間に入ると DCD=1 (1,000,000 T-state 程度の遅延を BubiC
  が挿入するが、Bubilator88 は即時遷移で開始 → 互換問題が出たら遅延追加)

### モータ OFF 時の DCD

- BubiC は一部タイトル (ジャッキー・チェンのスパルタンX) 互換のため
  MOTOR OFF 後も DCD=true を残す実装がある
- Bubilator88 は OFF で DCD=0 にクリアで出発 → 互換問題が出たら同調整

---

## 6. テープロード手順

### 基本ロード (BASIC プログラム)

N88-BASIC V2 / V1H / V1S で使用可能 (N-BASIC は不可):

1. Tape メニューから Open... でテープイメージ (.cmt / .t88) を開く
2. BASIC プロンプトで `LOAD "CAS:` + Enter
3. `Found:<ファイル名>` が表示されロード完了 → `Ok.` が出たら `RUN`

> **注**: N-BASIC では `CLOAD` を使用するが、現在 N-BASIC の cold boot
> 自体に未解決の問題がある (PIO Port C bits 1,2 待ちでハング)。

### 高速ロード (Hudson タイトル)

アルフォス等のハドソン初期タイトルは BASIC ローダ + 機械語本体で構成され、
`RUN` 実行時に BASIC ローダがモニタ経由で `OUT 0,0` を発行する。これが
QUASI88 互換の高速テープロードをトリガーし、機械語本体がテープから直接
メモリにコピーされる。ユーザ側の追加操作は不要。

参照: QUASI88 `sio_tape_highspeed_load()` (pc88main.c:2502-2585)、
X88000M `WriteIO_00_Ex` (PC88Z80Main.cpp:2256-2310)

### ブートモード自動切替

リセット時にドライブ 0 の状態を自動判定:
- ディスクマウント済 → DIP SW2 bit 3 = 0 (DISK boot: IPL 自動起動)
- ドライブ空 → DIP SW2 bit 3 = 1 (ROM boot: 即 BASIC プロンプト)

テープ使用時は ~30 秒の IPL タイムアウト待ちが不要になる。

---

## 7. SaveState 統合

`.b88s` 内の FourCC `CMT ` セクションに I8251 + CassetteDeck 状態を保存する。

- I8251: version / writeExpect / mode / command / status / rxBuf (6 バイト)
- CassetteDeck v2: version / motorOn / cmtSelected / phase /
  bytePeriodTStates / primeDelayTStates / bufPtr / tickAccum /
  buffer 全体 / dataCarriers 配列

テープ非マウント時は CMT セクション自体が書き込まれず、ロード側は
自動で eject 相当の状態になる。v1 フォーマットからの読み込みも後方互換。

---

## 8. 参考: 対応可能タイトル数

- PC-8801 初期 (mk2 以前) の商用カセットタイトル: ~200 本程度
- 書籍付録 / I/O 掲載プログラム: 数百 ~ 数千 (保存価値高)
- 現代のアーカイブでは T88 形式が主流、CMT raw は一部の古いコレクション
  で残存
- 有名タイトル: ジャッキー・チェンのスパルタンX、BLACK ONYX (CMT 版)、
  アルフォス、ドアドア、パックマン など
