# PC-8801 メモリマップ

PC-8801-FA のメインCPU / サブCPUのメモリマップ仕様。

---

## 1. メインCPU メモリマップ

### デフォルト配置 (N88-BASIC V2モード, ROM選択時)

```
0x0000 ┌─────────────────────┐
       │ N88-BASIC ROM (24KB)│  RMODE=0, MMODE=0
0x6000 ├─────────────────────┤
       │ N88-BASIC ROM /     │  Port 0x71 で Ext ROM バンク切替
       │ Ext ROM 0-3 (8KB)   │
0x8000 ├─────────────────────┤
       │ テキストウィンドウ   │  Port 0x70 オフセット付き (1KB)
0x8400 ├─────────────────────┤
       │ メイン RAM           │
0xC000 ├─────────────────────┤
       │ GVRAM (16KB)        │  Port 0x5C-0x5F でプレーン選択
       │ or メイン RAM        │  Port 0x5F で RAM に切替
0xF000 ├ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┤
       │ (高速TVRAM)          │  Port 0x32 bit4=0 で有効 (SR以降)
0xFFFF └─────────────────────┘
```

### 64K RAMモード (Port 0x31 MMODE=1)

```
0x0000 ┌─────────────────────┐
       │ メイン RAM (32KB)    │  ROM エリアが全て RAM に
0x8000 ├─────────────────────┤
       │ メイン RAM (32KB)    │  テキストウィンドウ無効
       │ ※0xC000以降は        │  GVRAM/TVRAM は引き続きアクセス可能
       │   GVRAM切替可能      │
0xFFFF └─────────────────────┘
```

### N-BASICモード (Port 0x31 RMODE=1, MMODE=0)

```
0x0000 ┌─────────────────────┐
       │ N-BASIC ROM (32KB)  │  N88 ROM の代わりに N-BASIC ROM
0x8000 ├─────────────────────┤
       │ メイン RAM           │  テキストウィンドウ無効
0xC000 ├─────────────────────┤
       │ GVRAM / RAM          │
0xFFFF └─────────────────────┘
```

---

## 2. バンク切替 I/Oポート

| メモリバンク | 関連ポート | 条件 |
|-------------|----------|------|
| N88-BASIC ROM | Port 0x31 bit2=0 (RMODE), bit1=0 (MMODE) | |
| N-BASIC ROM | Port 0x31 bit2=1 (RMODE), bit1=0 (MMODE) | |
| メインRAM (全域) | Port 0x31 bit1=1 (MMODE) | |
| Ext ROM (4th ROM) | Port 0x71 bit0=0 (IEROM, active low) | RMODE=0, MMODE=0 |
| Ext ROM バンク | Port 0x32 bit1:0 (EROMSL) = 0-3 | |
| GVRAM (独立) | Port 0x5C/0x5D/0x5E で選択 | |
| GVRAM (拡張) | Port 0x35 bit7=1 (GAM) | Port 0x32 bit6=1 (EVRAM) |
| メインRAM (0xC000+) | Port 0x5F で選択 | |
| 高速TVRAM | Port 0x32 bit4=0 (TMODE) | 0xF000-0xFFFF, V1H/V2のみ |
| 拡張RAM | Port 0xE2 bit0/4 (RDEN/WREN) | Port 0xE3 でカード/バンク |

### ROM 書き込み動作

0x0000-0x7FFF に ROM が選択されている場合でも、書き込みはメインRAM に対して行われる。

---

## 3. テキストウィンドウ

- **有効条件**: RMODE=0 (N88-BASIC) かつ MMODE=0 (ROM/RAMモード)
- **アドレス範囲**: 0x8000-0x83FF (1KB)
- **Port 0x70**: オフセットレジスタ (上位8ビット)
- **実アドレス計算**: `mainRAM[(textWindowOffset << 8) + (addr & 0x3FF)]`
- **Port 0x78**: オフセットを +1 インクリメント

テキストウィンドウが無効のとき (RMODE=1 または MMODE=1)、0x8000-0x83FF はメインRAM がそのまま見える。

---

## 4. GVRAM (グラフィックVRAM)

### 構造

3プレーン × 16KB = 48KB:

| プレーン | 色 | Port |
|---------|-----|------|
| 0 | 青 (Blue) | 0x5C |
| 1 | 赤 (Red) | 0x5D |
| 2 | 緑 (Green) | 0x5E |
| — | メインRAM | 0x5F |

### 独立アクセスモード (Port 0x32 EVRAM=0)

Port 0x5C-0x5F の書き込みでプレーンを切り替え、0xC000-0xFFFF で1プレーンずつ読み書きする。

### 拡張アクセスモード (Port 0x32 EVRAM=1)

Port 0x35 bit7 (GAM) を 1 にすると ALU を使った高速描画が可能。

**ALU 制御 (Port 0x34)** — ビットは非連続配置:

| Bit7 | Bit6 | Bit5 | Bit4 | Bit3 | Bit2 | Bit1 | Bit0 |
|------|------|------|------|------|------|------|------|
| — | ALU21 | ALU11 | ALU01 | — | ALU20 | ALU10 | ALU00 |

| マスク | プレーン | モード (上位bit:下位bit) |
|--------|---------|----------------------|
| 0x11 (bit4,0) | 青 (GVRAM0) | 00=AND NOT, 01=OR, 10=XOR, 11=NOP |
| 0x22 (bit5,1) | 赤 (GVRAM1) | 同上 |
| 0x44 (bit6,2) | 緑 (GVRAM2) | 同上 |

**マルチプレクサ制御 (Port 0x35 GDM bits 5:4)**:

| GDM | 書き込み動作 |
|-----|------------|
| 00 | ALU演算結果を3プレーン同時書込 |
| 01 | 直前のリードで読んだ値を3プレーン同時書込 |
| 10 | GVRAM1 の値を GVRAM0 にコピー |
| 11 | GVRAM0 の値を GVRAM1 にコピー |

**読み出し動作** (GAM=1):
- 3プレーン全てを内部レジスタに取り込み
- Port 0x35 bit2:0 (PLN) と比較した結果を返す

---

## 5. 高速TVRAM

- **アドレス**: 0xF000-0xFFFF (4KB)
- **制御**: Port 0x32 bit4 (TMODE) — 0=TVRAM有効, 1=メインRAM
- **対応機種**: SR以降
- **用途**: uPD3301 CRTC の DMA がテキスト表示のためにアクセスする

---

## 6. 拡張RAM

- **Port 0xE2**: bit0=リード有効 (RDEN), bit4=ライト有効 (WREN)
- **Port 0xE3**: bit7:6=カード選択 (0-3), bit1:0=バンク選択 (0-3)
- **容量**: 1カード = 4バンク × 32KB = 128KB, 最大4カード = 512KB
- **対応機種**: Mシリーズ以降 (MA/MA2/MC/MH/FH/FA)

拡張RAM が有効な場合、全アドレス空間 (0x0000-0xFFFF) に対して優先的にアクセスされる。

---

## 7. ROM 一覧

| ROM | サイズ | アクセス方式 |
|-----|--------|------------|
| N88-BASIC ROM | 32KB | メモリマップ (0x0000-0x7FFF) |
| N88 Ext ROM (4th ROM) 0-3 | 8KB × 4 = 32KB | メモリマップ (0x6000-0x7FFF) |
| N-BASIC ROM | 32KB | メモリマップ (0x0000-0x7FFF) |
| サブCPU ROM (DISK.ROM) | 8KB | サブCPU メモリ (0x0000-0x1FFF) |
| 漢字ROM 第一水準 | 128KB | I/O (Port 0xE8-0xEB) |
| 漢字ROM 第二水準 | 128KB | I/O (Port 0xEC-0xED) |
| フォントROM | 2KB | CRTC DMA 経由 |
| 辞書ROM | 最大512KB (32×16KB) | I/O (Port 0xF0-0xF1) |

---

## 8. サブCPU メモリマップ

```
0x0000 ┌─────────────────────┐
       │ DISK.ROM (8KB, R/O) │
0x2000 ├─────────────────────┤
       │ パターン初期化領域    │  読出し専用
0x4000 ├─────────────────────┤
       │ RAM (16KB, R/W)     │  ワークRAM
0x8000 ├─────────────────────┤
       │ (0x0000-0x7FFF の   │  アドレス折返し (addr & 0x7FFF)
       │  ミラー)             │
0xFFFF └─────────────────────┘
```

---

## 9. ウェイトステート

| アクセス対象 | 8MHz時 | 4MHz時 |
|------------|--------|--------|
| ROM/RAM (0x0000-0x7FFF) | +1T | なし |
| GVRAM (表示中, グラフィックON) | +5T | +2T |
| GVRAM (帰線中 or グラフィックOFF) | +3T | なし |
| 高速TVRAM リード | +2T | なし |
| 高速TVRAM ライト | +1T | なし |
