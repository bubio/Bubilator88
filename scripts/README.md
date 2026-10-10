# scripts/

開発・検証・リリース用の補助スクリプト。AI 学習系の入出力パスの多くは作者環境
(`/Volumes/CrucialX6/...`) 固定なので、再利用時は引数・定数を読み替える。

## 日常の開発

| スクリプト | 用途 |
| --- | --- |
| `format_all.sh` | SwiftFormat をアプリとコア両方に適用 (`--check` で検証のみ) |
| `lint.sh` | SwiftLint をアプリとコア両方に実行 |
| `build_macos.sh` | Swift 排他チェックの有無を指定してアプリをローカルビルド |
| `extract_loc_keys.py` | ビルドで抽出されたローカライズキーの一覧と、カタログ未登録キーの検出 |
| `strings_to_xcstrings.py` | 旧 `.lproj/*.strings` を String Catalog に変換 |

## 回帰・検証

| スクリプト | 用途 |
| --- | --- |
| `regression_compare.py` | 15 シナリオを再実行し参照スクリーンショットとピクセル比較 (`/regression`) |
| `capture_reference_screenshots.py` | 回帰テストの参照スクリーンショットを撮り直す |
| `rom_sweep.py` | D88 を一括起動し、起動失敗 (黒画面・BASIC プロンプト等) を分類 |
| `pbios_check.py` | 回帰シナリオを代替 BIOS (pbios) で走らせ、到達画面を比較 |
| `capi_trace_compare.py` | 2 つの C ABI DLL に同じ入力を与え、出力 (映像・音・FDD・保存) を比較 |
| `tstate_diff.py` | BubiC と命令単位の T-state を比較 (入力は `patches/bubic-cpu-trace.patch` で作る) |
| `ppm_contact_sheet.py` | BootTester の PPM を 1 枚の PNG に並べて目視確認 |
| `gvram_to_png.py` | メモリダンプの `gvram_{b,r,g}.bin` を PNG 化 |
| `disasm-roms.sh` | BIOS ROM を z80dasm で逆アセンブル (出力はリポジトリ外) |
| `patches/` | 比較対象エミュレータに当てるローカルパッチ ([README](patches/README.md)) |
| `tests/` | `check_exclusivity.py` のゲートのテスト (CI で実行) |

## 排他チェック・性能

| スクリプト | 用途 |
| --- | --- |
| `check_exclusivity.py` | Swift コンパイルが要求した排他チェック設定で行われたかを検査 (release.yml が使用) |
| `test_pinned_core.py` | アプリがピン留めしたコアを checked / unchecked で個別にテスト (CI が使用) |
| `build_checked_benchmarks.py` | checked 性能実験のバリアントをビルド |
| `benchmark_release.py` | ビルド済み BootTester を同一入力で計測 |
| `parse_exclusivity_profile.py` | `sample` 出力から動的排他チェックの呼び出し元を集計 |
| `bench_accelerate.swift` | AIUpscaler 変換ループの Accelerate 化マイクロベンチ (評価済み、再現用) |
| `tsan_ui_soak.sh` | TSan ビルドで `ThreadSoakUITests` を実行 |
| `tsan_manual_soak.sh` | 手動ソーク用に TSan ビルドを準備・起動し、終了後に検出有無を報告 |

## AI アップスケーラ (モデル作成)

学習データ作成 → 学習 → 変換 → 検証の順。手順は `docs/develop/AI_TRAINING.md`、
由来は `models/PROVENANCE.md`。

| スクリプト | 用途 |
| --- | --- |
| `extract_archives.sh` | cab/lzh/zip/rar から D88 を展開 |
| `collect_screenshots.sh` | D88 を起動して学習用スクリーンショットを収集 |
| `filter_screenshots.py` | 空画面・重複を除いて PNG 化 |
| `generate_targets.py` | Real-ESRGAN で正解画像を生成 |
| `train_srvggnet.py` | SRVGGNet x2 を知識蒸留で学習 |
| `compare_srvggnet.py` | 学習済みモデルと正解画像を並べて目視比較 |
| `convert_realesrgan.py` | Real-ESRGAN → CoreML |
| `convert_srvggnet_coreml.py` | SRVGGNet `.pth` → CoreML (`.mlmodelc`) |
| `convert_realesrgan_onnx.py` | Real-ESRGAN → ONNX (Windows) |
| `convert_srvggnet_onnx.py` | SRVGGNet `.pth` → ONNX (Windows) |
| `recover_srvggnet_from_mlmodelc.py` | 同梱 `.mlmodelc` から `.pth` を復元 (元の学習結果が失われているため) |
| `verify_onnx_coreml.py` | ONNX と CoreML の出力一致を検証 |
| `package_ai_model.sh` | CoreML モデルを配布用 zip にし、`AIModelStore` 用の SHA-256 を出力 |

## Windows・その他

| スクリプト | 用途 |
| --- | --- |
| `build-windows-package.ps1` | Windows 版を単一 EXE と共有ランタイム版の 2 種でビルド |
| `convert-png-to-ico.ps1` | 正方形 PNG からマルチ解像度 `.ico` を生成 |
| `par_list_to_presets.py` | 88PAR コードリストをチートプリセット JSON に変換 |
