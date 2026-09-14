# ローカルのmacOSビルド

普段は `dev`（Debug・排他チェック有効）を使う。最適化後の挙動確認は
`release-checked`、配布時の速度確認は `release-unchecked` を使う。
unchecked は動的排他チェックだけを外し、静的診断は維持する。

いずれも既定では `Bubilator88Dev.xcworkspace` と隣の `../Bubilator88Core` を
使うため、未コミットのコア変更もアプリへ反映される。コアmainのDebug最適化も
そのまま使う。Xcodeの設定ファイルやコアのPackage.swiftは書き換えない。

## CMakeから使う

macOS、Xcode（Metal Toolchainを含む）、CMake 3.21以降が必要。
リポジトリ直下で実行する。

```sh
# 通常の開発
cmake --preset dev
cmake --build --preset dev

# Releaseの最適化＋排他チェック有効
cmake --preset release-checked
cmake --build --preset release-checked

# 配布時の速度確認：動的排他チェック無効
cmake --preset release-unchecked
cmake --build --preset release-unchecked
```

configureは初回や設定変更時に実行すればよい。ソース編集後は `cmake --build`
だけで増分ビルドされる。CMakeは既存のXcodeビルドを呼び出す入口であり、
Swiftのコンパイルやリソース処理はXcodeが担当する。
実装はCMakeの [`add_custom_target`](https://cmake.org/cmake/help/latest/command/add_custom_target.html)
を使用している。

成功時に `.app` のパスと起動コマンドが表示される。devの場合は次の場所。

```sh
open build/cmake/dev/outputs/local/debug-checked/DerivedData/Build/Products/Debug/Bubilator88.app
```

設定ごとに出力先が分かれ、各出力先の `build.log` に直近のログを保存する。
ローカル用のad-hoc署名なので開発チームの指定は不要。アプリの起動は手動。
シェルを実行しているアーキテクチャ（通常Apple Siliconではarm64）だけをビルドする。
Xcodeを直接使う場合も、通常どおり開発workspaceを開けばよい。

## スクリプトだけで使う

CMakeを使わず同じビルドを実行できる。

```sh
bash scripts/build_macos.sh
bash scripts/build_macos.sh --configuration Release
bash scripts/build_macos.sh --configuration Release --exclusivity unchecked
```

出力先は `build/macos/local/<構成>-<排他設定>/`。
`--build-root /path/to/output` で変更でき、`--dry-run` は実行コマンドだけを表示する。

隣の開発コアではなくアプリがpinしたコアを使う場合は、次のように明示する。

```sh
bash scripts/build_macos.sh --core pinned --configuration Release --exclusivity unchecked
```

CMakeでは専用ディレクトリを指定する。

```sh
cmake -S . -B build/cmake/pinned -DB88_CORE=pinned \
  -DB88_CONFIGURATION=Release -DB88_EXCLUSIVITY=unchecked
cmake --build build/cmake/pinned
```

## テストとの使い分け

この入口はアプリのビルド用で、テストは自動実行しない。
コアを変更したら、開発コアでcheckedのテストを行う。

```sh
cd ../Bubilator88Core
swift test -Xswiftc -enforce-exclusivity=checked
swift test -c release -Xswiftc -enforce-exclusivity=checked
```

コアSourcesの変更は従来どおりゲーム回帰検証も必要。
ローカルでのuncheckedビルド成功は配布判定の代わりにはならない。
配布前の両設定でのテスト、固定SHA・コンパイラ引数の検証は
[Release exclusivity policy](RELEASE_EXCLUSIVITY.md)のCIが担当する。

2026-09-14、Apple Silicon / Xcode 26.6で3プリセットの実ビルドが成功。
隣のコアが選択され、アプリ・コア・Loggingの計7モジュールに指定どおりの
排他設定が渡っていることをコンパイラ引数で確認した。
