# PC-8801 拡張スロット

PC-8801 の拡張スロットのピン配置と信号仕様。

---

## ピン配置 (36ピン)

部品面から見て右側が1番ピン。SIDE A が半田面 (下側)、SIDE B が部品面 (上側)。

| SIDE A (半田面) | I/O | ピン番号 | I/O | SIDE B (部品面) |
|----------------|-----|---------|-----|----------------|
| GND | — | 1 | — | GND |
| GND | — | 2 | — | GND |
| +5V | — | 3 | — | +5V |
| +5V | — | 4 | — | +5V |
| AB0 | O | 5 | — | EXTRXRDY |
| AB1 | O | 6 | — | — |
| AB2 | O | 7 | I | MWAIT |
| AB3 | O | 8 | I | INT4 |
| AB4 | O | 9 | I | INT3 |
| AB5 | O | 10 | I | INT2 |
| AB6 | O | 11 | I | FDINT1 |
| AB7 | O | 12 | I | FDINT2 |
| AB8 | O | 13 | O | DB0 |
| AB9 | O | 14 | O | DB1 |
| AB10 | O | 15 | O | DB2 |
| AB11 | O | 16 | O | DB3 |
| AB12 | O | 17 | O | DB4 |
| AB13 | O | 18 | O | DB5 |
| AB14 | O | 19 | O | DB6 |
| AB15 | O | 20 | O | DB7 |
| RD | O | 21 | O | MEMR |
| WR | O | 22 | O | HIGH |
| MREQ | O | 23 | O | IOW |
| IORQ | O | 24 | O | IOR |
| MI | O | 25 | O | MEMW |
| RAS0 | O | 26 | ? | DMATC |
| RAS1 | O | 27 | ? | DMARDY |
| RFSH | O | 28 | I | DRQ1,2 |
| MUX | O | 29 | O | DACK1,2 |
| WE | O | 30 | O | 4CLK |
| ROMKILL | I | 31 | I | NMI |
| RESET | O | 32 | I | WAITRQ |
| SCLK | O | 33 | — | +12V |
| CLK | O | 34 | — | -12V |
| V1 | ? | 35 | ? | V1 |
| V2 | ? | 36 | ? | V2 |

※ DRQ2, DACK2 が拡張スロット最下段、DRQ1, DACK1 がそれ以外。

---

## 主要信号

| 信号 | 説明 |
|------|------|
| MWAIT | メモリリードサイクルに1ウェイト追加 (DIP SW と同等) |
| ROMKILL | 本体側デバイスが 0x0000-0x7FFF へのアクセスに応答するのを禁止 |
| 4CLK | 15.9744 MHz |
| SCLK | 76.8 kHz? |
| CLK | 3.9936 MHz |
| HIGH | +5V にプルアップ |
| INT2-INT4 | 割り込み入力 (i8214 レベル 2-4) |
| NMI | ノンマスカブル割り込み |

---

## ユーザ用 I/Oアドレス

ユーザに開放されている I/O アドレスは 0x80-0x8F のみ。

---

## 拡張ボードサイズ (参考)

実測 (サンハヤト MCC-151 基板):
- 全長: 219mm
- 基板幅: 84mm (コネクタ部: 68mm + 突出部: 11mm)
