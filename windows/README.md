# Bubilator88 — Windows ネイティブ版

macOS 版と**同一の Swift エミュレーションコア**を Windows ネイティブ DLL 化し、
C# + WinUI 3 のシェルから P/Invoke で駆動する移植版。描画は D3D11、音声は XAudio2、
AI アップスケールは ONNX Runtime + DirectML。

> 全体方針・移植性監査・実装進捗は `../docs/WINDOWS_PORT.md` を参照。
> このファイルは**ビルドと実行の手順書**。

## 構成

```
windows/Bubilator88.Windows/
├── NativeApi.cs              P/Invoke (Bubilator88C.dll の @_cdecl と 1:1)
├── EmulatorHost.cs           native ハンドル管理 + 再利用バッファ (毎フレーム alloc ゼロ)
├── KeyMapping.cs             VirtualKey → PC-8801 15行マトリクス (US/JIS + テンキー擬似)
├── D3DScreen.cs              D3D11 + SwapChainPanel。フィルタ + スキャンライン + レターボックス
├── AiUpscaler.cs             ONNX Runtime + DirectML で AI x2 (3モデル切替、非同期ダブルバッファ)
├── PixelMath.cs              無依存の画素演算ヘルパ (単体テスト対象)
├── XAudioSink.cs             XAudio2 で 44.1kHz ステレオ float をストリーム (適応レート制御)
├── ImageCodec.cs             スクリーンショット PNG/JPEG/HEIC エンコード
├── WinSaveState.cs           セーブステート/メタ/サムネイルのファイル入出力
├── MainWindow.xaml(.cs)      UI + 60Hz フレームループ + 入力/ディスク/メニュー
├── MainWindow.SettingsDialog.cs  設定ダイアログ (General/Display/Audio/Keyboard)
├── App.xaml(.cs)
└── native/
    └── Bubilator88C.dll      ← swift build 成果物を手動配置 (git 管理外)

windows/Bubilator88.Windows.Tests/   シェルの純ロジック xUnit テスト (KeyMapping / PixelMath)

AI モデル (3種) は全 OS 共有の `../../models/onnx/*.onnx` から csproj が出力直下へコピーする:
  SRVGGNet_x2_lite.onnx (Fast) / SRVGGNet_x2.onnx (Balanced) / RealESRGAN_x2.onnx (Quality)
いずれも Git LFS 管理。source-of-truth と再生成は `../../models/PROVENANCE.md`。
```

コア側の C ABI シムは `../Packages/EmulatorCore/Sources/CApi/CApi.swift`。

## 前提ツール

1. **Swift toolchain for Windows**(swift.org の Windows 版 + Visual Studio Build Tools の
   C++ ワークロード)。`swift --version` が通ること。
2. **Visual Studio 2022** + **Windows App SDK / .NET デスクトップ** ワークロード、**.NET 10 SDK**。
3. **Git LFS**(`git lfs version` が通ること)。AI モデルが LFS 管理のため。
4. ROM 一式を `%LOCALAPPDATA%\Bubilator88\` に配置(`N88.ROM` 必須、`DISK.ROM` 等は任意)。
   macOS の `~/Library/Application Support/Bubilator88/` と同じ顔ぶれ(`../docs/PERSISTENCE.md`)。

## チェックアウト

```powershell
git lfs install            # マシンごとに一度 (LFS フックを有効化)
git clone git@github.com:bubio/Bubilator88.git
cd Bubilator88
git lfs pull               # AI モデル実体 (models/onnx/*.onnx, 計 ~67MB) を取得
```

> **LFS 注意**: AI モデルは `models/onnx/*.onnx`(Git LFS 管理)。`git lfs pull` 前は
> ~133 バイトの**ポインタ**なので、そのままビルドするとモデルが壊れたまま同梱される。
> `git lfs pull` で実体に展開すること。特に **Fast/Balanced(SRVGGNet)は自前学習で
> 公開重みが無い**ため、pull しないと再生成もできない(Quality は公開重みから再生成可)。
> モデルが無くても(または AI を使わなくても)ビルド・起動は可能で、その AI フィルタは
> Bicubic にフォールバックする(`AiUpscaler` の state=unavailable)。

## ビルド & 実行

### 1. コア DLL をビルド

```powershell
cd Packages\EmulatorCore
swift build -c release --product Bubilator88C
# 成果物 (例): .build\release\Bubilator88C.dll を shell の native\ にコピー
Copy-Item .build\release\Bubilator88C.dll ..\..\windows\Bubilator88.Windows\native\
```

まずコア健全性を確認(macOS と同じ結果になるはず):

```powershell
swift test                                  # 760+ ユニットテスト
swift run BootTester "C:\path\game.d88"     # テキストVRAMダンプ等
```

> **エクスポートに関する注意**: `@_cdecl` は C リンケージを付けるが Windows の
> `dllexport` は付けないため、`Sources/CApi/Bubilator88C.def` を linker に渡して
> シンボルを公開している(`Package.swift` の CApi target、Windows 限定 linkerSettings)。
> もし未エクスポートになる場合は `swift build` のログで `/DEF:` が渡っているか確認し、
> 代替として `-Xlinker /EXPORT:b88_create`(各シンボル)でも可。

### 2. AI モデル (ONNX) を用意 — 任意

`git lfs pull` で `models/onnx/*.onnx` を取得済みならスキップ可。自分で生成する場合:

```powershell
pip install torch onnx onnxruntime
python scripts\convert_srvggnet_onnx.py       # models\*.pth → SRVGGNet_x2*.onnx (Fast/Balanced)
python scripts\convert_realesrgan_onnx.py     # RealESRGAN_x2plus.pth を自動DL → RealESRGAN_x2.onnx (Quality)
```

- 出力はすべて `models\onnx\` 直下。3 モデルとも macOS の CoreML 版と**同一重み**で、
  ONNX↔CoreML の出力一致は `scripts\verify_onnx_coreml.py` で検証済(fp16 精度、
  max|diff| < 0.003)。入出力は float[0,1] RGB CHW、正規化(/255)と RGBA8 化はホスト
  (`AiUpscaler.cs`)が行う。
- Fast/Balanced(SRVGGNet)は公開重みが無いため `.pth`・`.onnx` とも LFS 必須。詳細と
  再生成手順は `..\..\models\PROVENANCE.md`(Balanced はコンパイル済 `.mlmodelc` から復元)。
- csproj は `models\onnx\*.onnx` を出力直下へコピーする(欠けているモデルはそのフィルタが
  Bicubic フォールバック)。

### 3. シェルをビルド & 実行

```powershell
cd windows\Bubilator88.Windows
dotnet run -c Release -r win-x64
```

> **ランタイム依存**: `Bubilator88C.dll` は Swift ランタイム DLL(`swiftCore.dll` 等)に依存する。
> 開発機では `...\Swift\Runtimes\6.3.2\usr\bin` が PATH 上なので `dotnet run` で解決するが、
> 単体配布する場合は同 bin の DLL 群を exe の隣に同梱すること(配布同梱は未対応)。
>
> **DLL 配置**: `None Include="native\..."` を `<Link>Bubilator88C.dll</Link>` で**出力直下**に
> 置かないと P/Invoke が `ERROR_MOD_NOT_FOUND (0x8007007E)` で落ちる(native\ サブフォルダは
> 探索対象外)。`models\onnx\*.onnx` も同様に出力直下へ Link コピーされる。

### 4. シェルの単体テスト

```powershell
dotnet test windows\Bubilator88.Windows.Tests\Bubilator88.Windows.Tests.csproj
```

> self-contained な WinUI exe を ProjectReference するとテストホストに WinUI ランタイムが
> 載って失敗するため、テストプロジェクトは UI 非依存の純ロジックファイル
> (`KeyMapping.cs` / `PixelMath.cs`)を**ソースリンク**してヘッドレスに検証する。
> 対象を増やすときは `.csproj` の `<Compile Include=…>` に純ロジックファイルを足す。

## 実装済み機能

- **コア**: Swift→DLL を P/Invoke。`runFrame`/`render_rgba`/キー入力/ディスクマウント。挙動精度は macOS と同一。
- **映像**: D3D11。None/Linear/Bicubic/CRT/xBRZ/Enhanced/**AI (Fast/Balanced/Quality)** の
  フィルタ + スキャンライン。ウィンドウ ×1/×2/×4(固定・永続)、フルスクリーン(整数スケーリング切替)、レターボックス。
- **AI アップスケール**: ONNX Runtime + DirectML で 3 モデル(Fast=SRVGGNet_x2_lite /
  Balanced=SRVGGNet_x2 / Quality=RealESRGAN_x2)を切替(640×400→1280×800)。フィルタ選択で
  モデルを載せ替え。非同期ダブルバッファ、未準備/欠落時は Bicubic フォールバック(macOS パリティ)。
- **音声**: XAudio2 リングバッファ + 適応レート制御。YM2608 リズム音源サンプル読込。音量・バッファ長設定。
  **FDD アクセス音**(シーク/リード音を合成、ドライブ別ステレオ定位、ステータスバーの赤アクセスランプ)は
  メイン音声とは別の専用 XAudio2 エンジンで再生し、出力デバイスを個別に選択可能
  (`NAudio.CoreAudioApi.MMDeviceEnumerator` でデバイス列挙、macOS の `fddSoundDeviceUID` と同じ設計)。
- **ディスク**: マルチイメージ D88、Drive 1/2/1&2、ライトプロテクト、Recent Files、イメージ選択ダイアログ。
- **入力**: VirtualKey→マトリクス(US/JIS 記号、矢印/数字行/WASD のテンキー擬似)、
  メニューのキーボードショートカット(Ctrl+R/E/S/L、Ctrl+Shift+C、Ctrl+1/2/3、F11)。
  **ゲームコントローラ**(`Windows.Gaming.Input.Gamepad` ポーリング、Dpad/ABXY/ショルダー/
  トリガー/スティックをPC-88キーまたはホストコマンドにマッピング、設定ダイアログの
  Controller タブで「キーを押してバインド」/デフォルト復帰が可能)。
- **状態保存**: セーブステート(スロット/クイック、メタ・サムネイル)、スクリーンショット(PNG/JPEG/HEIC)、CPU 早送り(×1〜×16)。
- **設定**: General/Display/Audio/Keyboard/Controller タブ(`settings.json` に即時永続化)。
- **テスト基盤**: シェル純ロジックの xUnit プロジェクト。

## 未実装(後続 / 別実装枠)

- 触覚フィードバック(SSGノイズ検出→振動。EmulatorCore の CApi 拡張が必要なため別PRで対応予定)
- コントローラーのモデル別マッピング / ブランド別アイコン表示(`Windows.Gaming.Input.Gamepad` は
  製品識別情報を提供しないため、v1 は単一のグローバルマッピング)
- マウスロック(`ClipCursor` + RAWINPUT 相対デルタ)
- OCR 翻訳オーバーレイ(Windows.Media.Ocr)
- 空間オーディオ / ヘッドトラッキング、操作スクリプト記録
- Swift ランタイム DLL の配布同梱
