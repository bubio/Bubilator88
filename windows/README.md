# Bubilator88 — Windows ネイティブ版 (Vertical Slice)

macOS 版と**同一の Swift エミュレーションコア**を Windows ネイティブ DLL 化し、
C# + WinUI 3 のシェルから P/Invoke で駆動する移植の最初のマイルストーン。

> 全体方針・移植性監査は `../docs/WINDOWS_PORT.md` を参照。

## 構成

```
windows/Bubilator88.Windows/
├── NativeApi.cs      P/Invoke (Bubilator88C.dll の @_cdecl と 1:1)
├── EmulatorHost.cs   native ハンドル管理 + 再利用バッファ (毎フレーム alloc ゼロ)
├── KeyMapping.cs     VirtualKey → PC-8801 15行マトリクス
├── D3DScreen.cs      D3D11 + SwapChainPanel、nearest で 640×400 を提示
├── XAudioSink.cs     XAudio2 で 44.1kHz ステレオ float をストリーム
├── MainWindow.xaml(.cs)  UI + 60Hz フレームループ + 入力/ディスクマウント
├── App.xaml(.cs)
└── native/Bubilator88C.dll   ← swift build 成果物を手動配置
```

コア側の C ABI シムは `../Packages/EmulatorCore/Sources/CApi/CApi.swift`。

## 前提ツール

1. **Swift toolchain for Windows**(swift.org の Windows 版 + Visual Studio Build Tools の
   C++ ワークロード)。`swift --version` が通ること。
2. **Visual Studio 2022** + **Windows App SDK / .NET デスクトップ** ワークロード、**.NET 10 SDK**。
3. ROM 一式を `%LOCALAPPDATA%\Bubilator88\` に配置(`N88.ROM` 必須、`DISK.ROM` 等は任意)。
   macOS の `~/Library/Application Support/Bubilator88/` と同じ顔ぶれ(`../docs/PERSISTENCE.md`)。

## ビルド & 実行

### 1. コア DLL をビルド

```powershell
cd ..\Packages\EmulatorCore
swift build -c release --product Bubilator88C
# 成果物 (例): .build\release\Bubilator88C.dll を shell の native\ にコピー
Copy-Item .build\release\Bubilator88C.dll ..\..\windows\Bubilator88.Windows\native\
```

まずコア健全性を確認(macOS と同じ結果になるはず):

```powershell
swift test                          # 530+ ユニットテスト
swift run BootTester "C:\path\game.d88"   # テキストVRAMダンプ等
```

> **エクスポートに関する注意**: `@_cdecl` は C リンケージを付けるが Windows の
> `dllexport` は付けないため、`Sources/CApi/Bubilator88C.def` を linker に渡して
> シンボルを公開している(`Package.swift` の CApi target、Windows 限定 linkerSettings)。
> もし未エクスポートになる場合は `swift build` のログで `/DEF:` が渡っているか確認し、
> 代替として `-Xlinker /EXPORT:b88_create`(各シンボル)でも可。

### 2. シェルをビルド & 実行

```powershell
cd ..\..\windows\Bubilator88.Windows
dotnet run -c Release
```

> **ランタイム依存**: `Bubilator88C.dll` は Swift ランタイム DLL(`swiftCore.dll` 等)に依存する。
> 開発機では `...\Swift\Runtimes\6.3.2\usr\bin` が PATH 上なので `dotnet run` で解決するが、
> 単体配布する場合は同 bin の DLL 群を exe の隣に同梱すること。

## 完了条件(Vertical slice)

1. `swift test` グリーン(コアが Windows でも健全)。
2. アプリ起動 → ROM ロード → ディスク無しで **N88-BASIC 起動画面**が 640×400 で出る。
3. **Mount Disk…** で `.d88` を選ぶ → ゲームのタイトルがブートする。
4. キー入力がエミュ内に反映(BASIC で文字入力、ゲームでカーソル移動)。

## v1 の割り切り(後続フェーズ)

- 映像フィルタは nearest のみ(Linear/Bicubic/CRT/xBRZ は HLSL 移植が後続)。
- 音声は XAudio2 の素のストリーム(macOS の適応レート制御は未移植 — 不安定なら一旦切る)。
- ゲームコントローラ / マウスロック / セーブステート UI / アーカイブ展開 / AI / OCR は未実装。
- キーマップは US-ANSI 前提。JIS 記号は後続。
