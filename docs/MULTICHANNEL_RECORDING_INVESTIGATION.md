# 8ch (separated) 録音の再生問題 — 調査結果

調査日: 2026-08-03 / 対象: `Bubilator88/Audio/AudioRecorder.swift` の separated モード

## 症状

separated モードで録音した 8ch WAV を再生すると、曲の途中で音量が上下して聞こえる。
QuickTime Player / `afplay` / `ffplay` のいずれでも同様。

## 結論

**録音ファイル自体は正しい。壊しているのは再生側（プレイヤのチャンネル推測）。**

WAV に書き出す際に discrete-8 のチャンネルレイアウトが失われるため、プレイヤが
チャンネル数だけを見て「7.1 サラウンド」と誤って解釈し、独自の downmix を適用する。

## 検証方法

`AudioRecorder` の separated 書き出し経路（settings / `AVChannelLayoutKey` /
`makeInputFormat` / `AVAudioPCMBuffer` への interleave / `AVAudioFile.write`）を
そのまま複製したスタンドアロンの Swift ハーネスを作り、既知の信号を書いて読み戻した。

### 検証 1: ラウンドトリップの正確性 — 合格

ch0/1=440Hz@0.5、ch2/3=220Hz@0.25、ch4/5=110Hz@0.125、ch6/7=DC 0.0625 を
4 秒書き出して読み戻した結果:

```
ch0: rms=0.3536 peak=0.5000     ch4: rms=0.0884 peak=0.1250
ch1: rms=0.3536 peak=0.5000     ch5: rms=0.0884 peak=0.1250
ch2: rms=0.1768 peak=0.2500     ch6: rms=0.0000 peak=0.0625 (DC)
ch3: rms=0.1768 peak=0.2500     ch7: rms=0.0000 peak=0.0625 (DC)
ch0 の 100ms 窓 RMS: min 0.35355365 / max 0.35355365  (完全に一定)
```

ヘッダ、data チャンクサイズ、サンプル値すべてビット完全。`file.processingFormat`
と `makeInputFormat(channels: 8)` も `==` で一致しており、フォーマット不整合もない。

### 検証 2: オーバーレンジ時のクリップ挙動 — 無害

`YM2608.swift:653-656` の immersive FM ステムは、`saturate16` した後に `beepSample`
を加算して `/ scale` しており、再クランプがない。つまり ±1.0 を超え得る
（ステレオミックス経路は `mixOutputFrame` が全加算を `storeSample16` 経由にしているため
超えない）。この非対称性が 8ch ファイルだけに出る不具合を作っていないか確認した。

−1.6 〜 +1.6 のランプを書き出して読み戻した結果:

```
in -1.6000 -> -32768      in +0.9998 -> +32762
in -1.1999 -> -32768      in +1.1999 -> +32767
in -0.9998 -> -32762      in +1.6000 -> +32767
```

`AVAudioFile` の Float32→Int16 変換は**飽和のみでラップしない**。ラップによる
全振幅の符号反転は起きていない。単なる歪みであり、音量変動の原因ではない。

### 検証 3: プレイヤ側の downmix — これが原因

書き出した 8ch WAV を `afinfo` で見ると:

```
Data format:     8 ch,  44100 Hz, Int16, interleaved
                 no channel layout.        ← レイアウトが消えている
```

ヘッダは素の `WAVE_FORMAT_PCM`（fmt チャンク 16 バイト、format tag = 1）。
`AVChannelLayoutKey` に `kAudioChannelLayoutTag_DiscreteInOrder | 8` を渡しても、
AVAudioFile の WAV ライタはそれを WAVE_FORMAT_EXTENSIBLE として書き出さず、破棄する。

各チャンネルに異なる周波数の同振幅トーン（440/660/880/1100/1320/1540/1760/1980 Hz）を
入れたプローブファイルを作り、ステレオへ落として FFT で各成分の残存量を実測した:

| プレイヤ | 実測結果 |
|---|---|
| **CoreAudio 系**<br>(QuickTime / afplay / afconvert) | **ch0/ch1 = FM ステムのみ 0 dB で通過。**<br>SSG・ADPCM・Rhythm は完全に消える |
| **ffmpeg / ffplay** | 8ch を 7.1 と誤解して downmix。<br>FM: −9.9 dB / SSG・ADPCM・Rhythm: −12.9 dB。<br>**ch3 (SSG_R) は LFE 扱いで完全に破棄**、<br>ch2 (SSG_L) はセンター→L/R 両方へモノで潰れる |

つまり QuickTime / afplay では **FM しか鳴っていない**。メロディが SSG やリズムに
移る場面で音がごっそり消えるため、曲の途中で音量が上下しているように聞こえる。
これが報告された症状の正体。

### 検証 4: ALAC / CAF は WAV より悪い

`.alac`（CAF コンテナ）も `supportsSeparated == true` なので同じ内容を書き出して確認した:

```
Data format:    8 ch, 44100 Hz, alac, 4096 frames/packet
Channel layout: 7.1 (C Lc Rc L R Ls Rs LFE)     ← 勝手に書き換えられている
```

ALAC エンコーダが discrete-8 を破棄して 7.1 レイアウトを**明示的にタグ付けする**ため、
CoreAudio の downmix が ch3/ch4（＝ SSG_R と ADPCM_L）を L/R として拾う。
チャンネルが完全に入れ替わる。WAV より状況が悪い。

## 棄却した仮説

- **drain 経路のレース / `min()` 切り捨てによるステム間ドリフト**
  `writeSeparated` (`AudioRecorder.swift:266`) は 4 本のバッファを
  `min(...)/2` に切り詰めるため、長さが揃わないと余剰サンプルが恒久的に失われる。
  → **起きない。** `drainSamples` は `EmulatorViewModel+Rendering.swift:230` の
  単一スレッドから呼ばれ、`YM2608.swift:657-682` は 4 本を必ず同一ブロックで
  lockstep に append する。エミュレータ側と drain 側の並行実行は発生しない。

- **CD Mix (PR #93) の回帰**
  immersive 経路の `shaped()` は `cdMixEnabled` のときだけ動くが、そこを通らない
  場合も症状は同じ。原因は downmix 側なので CD Mix の有無に依存しない。

## 付随して判明した既存ドキュメントの誤り

`AudioRecorder.swift:9-10` のコメント:

> QuickTime and most media players will only play ch0/ch1.

これは半分間違い。ch0/ch1 だけを取るのは **CoreAudio 系だけ**で、ffmpeg 系は
8ch 全部を 7.1 として混ぜる（SSG_R を捨てて）。どちらの修正案を採るにせよ、
このコメントは実測値に基づいて直すべき。

## 対応方針: 案 C を採用（2026-08-04 決定）

コンテナ側でこれを直す手段は AVAudioFile の範囲にはない。設計変更が要るが、
今回は挙動を変えず、**ドキュメントを実測どおりに直してユーザに明示する**方針とした。
実施した変更:

- `AudioRecorder.swift` の型ドキュメントを実測値に差し替え（本ドキュメントへの参照付き）
- 設定画面の説明文を簡潔に修正
  （「メディアプレーヤーでは正しく再生できないため、試聴にはステレオを使ってください」）
- ヘルプブック (en/ja) の `pgs/audio.html` — 技術的詳細は書かず、分離 (8ch) の項に
  「QuickTime Player などのメディアプレーヤーでは正しく再生できない場合があります。
  聴くだけならステレオ (2ch) を使ってください」の一文を追加。
  フォーマット表の ALAC 行に「分離 (8ch) では WAV を推奨」を追記

  （プレーヤーごとの downmix の実挙動など技術的な背景は本ドキュメントと
  `AudioRecorder.swift` のコメント側に置き、ヘルプには載せない方針）

以下の案 A / B は将来の選択肢として残す。

### 検討したが採用しなかった案

### 案 A: ステムごとに 4 ファイル（推奨）

```
スキーム-2026-08-03-230025/
  ├ 1-FM.wav      (2ch)
  ├ 2-SSG.wav     (2ch)
  ├ 3-ADPCM.wav   (2ch)
  └ 4-Rhythm.wav  (2ch)
```

- どのプレイヤでも正しく再生できる
- DAW へのインポートも標準的（4 トラックとしてドラッグ＆ドロップ）
- AAC / ALAC でもそのまま使える → `supportsSeparated` の制約自体が不要になる
- 難点: ファイルが 4 つに増える。`lastOutputURL` など UI 側の扱いを見直す必要あり

### 案 B: 1 ファイル 10ch（ch0/1 にミックス）

```
ch0/1 = ステレオミックス (完全な曲)
ch2/3 = FM       ch4/5 = SSG
ch6/7 = ADPCM    ch8/9 = Rhythm
```

- QuickTime / afplay は ch0/1 を拾うので**正しいミックスが鳴る**
- ffplay は 10ch を推測 downmix するため**依然として崩れる**
- 1 ファイルで完結する点は利点

### 案 C: 現状維持＋ドキュメント修正

- 8ch WAV のまま。コメントと UI 説明を実測どおりに直し、
  「DAW 専用。汎用プレイヤでは正しく鳴らない」旨をユーザに明示する
- コード変更は最小だが、症状そのものは解消しない

## 再現用ハーネス

セッションのスクラッチパッドに置いた（永続化はしていない）。再現手順:

1. `AudioRecorder.swift` の `discrete8Layout` / `discrete8LayoutData` /
   `makeInputFormat` / `RecordingFormat.settings` をそのままコピーした
   単一ファイルの Swift プログラムを作る
2. `AVAudioFile` を**必ずスコープを抜けて解放する**（トップレベル `let` のまま
   プロセス終了すると deinit が走らず、data チャンクサイズが 0 のまま残る。
   アプリ本体は `stop()` の `writeQueue.sync { self.file = nil }` で解放しているので
   通常経路では問題ないが、録音中にアプリを強制終了した場合は同じ壊れ方をするはず）
3. `swiftc -O` でビルドして実行し、`afinfo` と Python (`wave` + `numpy`) で解析
