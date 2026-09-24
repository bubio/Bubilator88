#Requires -Version 7.0
<#
.SYNOPSIS
    Bubilator88 Windows 版を単一 EXE と共有 WinUI ランタイム版の2種類にビルドする。

.DESCRIPTION
    1. Swift toolchain の所在と runtime DLL ディレクトリを検出
    2. (任意) unchecked で swift test を実行して Bubilator88Core の回帰を確認
    3. unchecked で swift build -c release --product Bubilator88C → native\Bubilator88C.dll に配置
    4. AI モデル (models/onnx/*.onnx) が Git LFS ポインタのままでないか確認
    5. dotnet publish (win-x64) でシェルを発行
    6. Bubilator88C.dll の依存クロージャに含まれる Swift runtime DLL だけを
       発行フォルダへバンドル (配布先に Swift toolchain は無い前提)
    6b. 未使用ファイルの prune (デバッグシンボル / 未使用 WindowsAppSDK 機能 /
       英語以外の *.mui ロケール)
    7. スモークテスト: Swift を PATH から外した状態で (a) Bubilator88C.dll が
       ロードできるか、(b) アプリが起動してメインウィンドウが出るかを検証
       (バンドル漏れ・prune しすぎの唯一の確実な検出方法 — objdump 静的解析は
       実行時にしか解決されない依存を見落とすため、実ロード/実起動で確認する)
    8. 発行フォルダを zip 化し、SHA256 を算出。既定では両方作成する

    CI (GitHub Actions) と手元ビルドの両方から呼べるよう、GITHUB_OUTPUT が
    設定されていれば single_*/shared_* をそこにも書き出す。

.PARAMETER Version
    パッケージ/アセンブリバージョン (例: "1.2.3" や "0.0.0-abcdef1")。
    dotnet publish に -p:Version として渡される。

.PARAMETER SwiftRuntimeBin
    Swift runtime DLL (swiftCore.dll 等) があるディレクトリ。省略時は
    `swift.exe` の場所から `Toolchains\<ver>\usr\bin` の兄弟である
    `Runtimes\<ver>\usr\bin` を自動検出する。CI 環境でこの兄弟関係が
    成り立たない場合に備えて明示上書きできる。

.EXAMPLE
    pwsh scripts/build-windows-package.ps1 -Version 1.2.3
#>
[CmdletBinding()]
param(
    [string]$Version = "0.0.0-dev",
    [string]$PackageName = "Bubilator88",
    [ValidateSet('Both', 'SingleFile', 'SharedRuntime')]
    [string]$Variant = 'Both',
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [string]$OutputDir,
    [switch]$RunCoreTests,
    [switch]$SkipCoreBuild,
    [switch]$SkipModelCheck,
    [switch]$SkipSmokeTest,
    [string]$SwiftRuntimeBin
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ローカル (日本語ロケール既定の cp932 コンソール) と CI (UTF-8) の両方で
# 日本語メッセージが文字化けしないよう、出力エンコーディングを明示する。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if ($Variant -eq 'Both') {
    $first = @{
        Version = $Version; PackageName = $PackageName; Variant = 'SingleFile'
        Configuration = $Configuration; RunCoreTests = $RunCoreTests
        SkipCoreBuild = $SkipCoreBuild; SkipModelCheck = $SkipModelCheck
        SkipSmokeTest = $SkipSmokeTest
    }
    if ($OutputDir) { $first.OutputDir = $OutputDir }
    if ($SwiftRuntimeBin) { $first.SwiftRuntimeBin = $SwiftRuntimeBin }
    & $PSCommandPath @first
    if ($LASTEXITCODE -ne 0) { throw 'SingleFile パッケージの作成に失敗しました。' }
    $first.Variant = 'SharedRuntime'
    $first.SkipCoreBuild = $true
    $first.RunCoreTests = $false
    & $PSCommandPath @first
    if ($LASTEXITCODE -ne 0) { throw 'SharedRuntime パッケージの作成に失敗しました。' }
    return
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# コアは別リポジトリ (bubio/Bubilator88Core)。既定ではこのリポジトリの隣に
# clone してある前提。BUBILATOR88_CORE_DIR で差し替えられる (CI はこちら)。
$CoreDir = if ($env:BUBILATOR88_CORE_DIR) { $env:BUBILATOR88_CORE_DIR } else { Join-Path $RepoRoot '..\Bubilator88Core' }
if (-not (Test-Path (Join-Path $CoreDir 'Package.swift'))) {
    throw "Bubilator88Core が '$CoreDir' に見つかりません。このリポジトリの隣に clone するか、BUBILATOR88_CORE_DIR を設定してください。"
}
$CoreDir = (Resolve-Path $CoreDir).Path
$ShellDir = Join-Path $RepoRoot 'windows\Bubilator88.Windows'
$NativeDir = Join-Path $ShellDir 'native'
if (-not $OutputDir) { $OutputDir = Join-Path $RepoRoot 'dist' }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 1. Swift toolchain / runtime DLL ディレクトリの検出
# ---------------------------------------------------------------------------
Step "Swift toolchain を確認"
$swiftCmd = Get-Command swift.exe -ErrorAction SilentlyContinue
if (-not $swiftCmd) {
    throw "swift.exe が見つかりません。Windows 版 Swift toolchain をインストールしてください (windows/README.md 参照)。"
}
& swift --version

if (-not $SwiftRuntimeBin) {
    # 標準レイアウト: <root>\Toolchains\<ver>\usr\bin\swift.exe の兄弟に
    # <root>\Runtimes\<ver>\usr\bin\swiftCore.dll 等が置かれる。
    $toolchainBin = Split-Path $swiftCmd.Source -Parent
    $toolchainVerDir = Split-Path $toolchainBin -Parent | Split-Path -Parent
    $toolchainsDir = Split-Path $toolchainVerDir -Parent
    $swiftInstallRoot = Split-Path $toolchainsDir -Parent
    $runtimesRoot = Join-Path $swiftInstallRoot 'Runtimes'

    $candidates = @()
    if (Test-Path $runtimesRoot) {
        $candidates = @(
            Get-ChildItem -Path $runtimesRoot -Directory |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName 'usr\bin' } |
                Where-Object { Test-Path (Join-Path $_ 'swiftCore.dll') }
        )
    }
    if ($candidates.Count -eq 0) {
        throw "Swift runtime (swiftCore.dll 等) のディレクトリを自動検出できませんでした。-SwiftRuntimeBin で明示してください。"
    }
    $SwiftRuntimeBin = $candidates[0]
}
if (-not (Test-Path (Join-Path $SwiftRuntimeBin 'swiftCore.dll'))) {
    throw "swiftCore.dll が '$SwiftRuntimeBin' に見つかりません。-SwiftRuntimeBin を確認してください。"
}
Write-Host "    Swift runtime bin: $SwiftRuntimeBin"

# ---------------------------------------------------------------------------
# 2. (任意) Bubilator88Core のユニットテスト
# ---------------------------------------------------------------------------
if ($RunCoreTests) {
    Step "swift test -Xswiftc -enforce-exclusivity=unchecked (Bubilator88Core)"
    Push-Location $CoreDir
    try {
        & swift test -Xswiftc -enforce-exclusivity=unchecked
        if ($LASTEXITCODE -ne 0) { throw "swift test が失敗しました (exit $LASTEXITCODE)。" }
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# 3. コア DLL のビルド
# ---------------------------------------------------------------------------
if (-not $SkipCoreBuild) {
    Step "swift build -c release --product Bubilator88C -Xswiftc -enforce-exclusivity=unchecked"
    Push-Location $CoreDir
    try {
        & swift build -c release --product Bubilator88C -Xswiftc -enforce-exclusivity=unchecked
        if ($LASTEXITCODE -ne 0) { throw "swift build が失敗しました (exit $LASTEXITCODE)。" }
    } finally {
        Pop-Location
    }
    $builtDll = Join-Path $CoreDir '.build\release\Bubilator88C.dll'
    if (-not (Test-Path $builtDll)) { throw "$builtDll が生成されませんでした。" }
    New-Item -ItemType Directory -Force -Path $NativeDir | Out-Null
    Copy-Item $builtDll (Join-Path $NativeDir 'Bubilator88C.dll') -Force
}
$nativeDll = Join-Path $NativeDir 'Bubilator88C.dll'
if (-not (Test-Path $nativeDll)) {
    throw "$nativeDll がありません。-SkipCoreBuild を外すか、事前に配置してください。"
}

# ---------------------------------------------------------------------------
# 4. AI モデル (Git LFS 実体化チェック)
# ---------------------------------------------------------------------------
if (-not $SkipModelCheck) {
    Step "AI モデル (ONNX) の実体を確認"
    $modelsDir = Join-Path $RepoRoot 'models\onnx'
    # LFS 未 pull のポインタファイルは ~130 バイトなので、実体化の目安に十分な閾値。
    $minRealSizeBytes = 4096
    foreach ($m in @('SRVGGNet_x2_lite.onnx', 'SRVGGNet_x2.onnx')) {
        $p = Join-Path $modelsDir $m
        if (-not (Test-Path $p)) {
            throw "$p が見つかりません。'git lfs pull' を実行してください (-SkipModelCheck で無視可)。"
        }
        $size = (Get-Item $p).Length
        if ($size -lt $minRealSizeBytes) {
            throw "$p は Git LFS ポインタのままです ($size bytes)。'git lfs pull' を実行してください (-SkipModelCheck で無視可)。"
        }
    }
}

# ---------------------------------------------------------------------------
# 5. dotnet publish (win-x64, self-contained)
#    Swift for Windows は x86_64-unknown-windows-msvc のみ提供 (arm64 toolchain
#    が無い) ため、v1 は win-x64 のみを対象とする。
# ---------------------------------------------------------------------------
$publishDir = Join-Path $OutputDir "publish-win-x64-$Variant"
if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }

Step "dotnet publish (win-x64, $Variant, Version=$Version)"
$csproj = Join-Path $ShellDir 'Bubilator88.Windows.csproj'
$winAppSdkSelfContained = if ($Variant -eq 'SingleFile') { 'true' } else { 'false' }
& dotnet publish $csproj `
    -c $Configuration -r win-x64 -p:Platform=x64 --self-contained true `
    -p:WindowsAppSDKSelfContained=$winAppSdkSelfContained `
    -p:PublishSingleFile=false `
    -p:Version=$Version `
    -o $publishDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish が失敗しました (exit $LASTEXITCODE)。" }

if (-not (Test-Path (Join-Path $publishDir 'Bubilator88C.dll'))) {
    throw "発行フォルダに Bubilator88C.dll がありません (csproj の Link 設定を確認)。"
}

# ---------------------------------------------------------------------------
# 6. Swift runtime DLL をバンドル (配布先マシンには Swift toolchain が無い前提)
#
#    Runtimes\...\usr\bin\*.dll を丸ごとコピーすると、使わない Foundation
#    モジュール (Networking / XML) やその依存 (ICU) まで同梱されてしまう。
#    Bubilator88C.dll の PE インポートテーブルを再帰的に辿り、実際に静的依存
#    している DLL だけをコピーする。漏れがあれば §7 のスモークテストが
#    ロード失敗として確実に検出する (Swift ランタイムは dlopen 相当の遅延
#    ロードを行わないため、静的クロージャで過不足なく足りる)。
# ---------------------------------------------------------------------------
Step "Swift runtime DLL をバンドル (依存クロージャのみ)"

# llvm-objdump は Swift toolchain の bin に同梱されている (swift.exe の隣)。
$toolchainBinDir = Split-Path $swiftCmd.Source -Parent
$objdump = Join-Path $toolchainBinDir 'llvm-objdump.exe'

function Get-PeImportNames {
    param([string]$Path)
    $out = & $objdump -p $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return @() }
    $out |
        Select-String -Pattern '^\s*DLL Name:\s*(.+)$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }
}

if (Test-Path $objdump) {
    $rootDll = Join-Path $publishDir 'Bubilator88C.dll'
    $visited = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $needed = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($rootDll)

    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if (-not $visited.Add([System.IO.Path]::GetFileName($cur))) { continue }
        foreach ($dep in (Get-PeImportNames -Path $cur)) {
            # Swift runtime ディレクトリに実体があるものだけが同梱対象。
            # 残り (kernel32 等の OS DLL) は配布先に必ず存在する。
            $depPath = Join-Path $SwiftRuntimeBin $dep
            if (Test-Path $depPath) {
                [void]$needed.Add((Get-Item $depPath).Name)
                $queue.Enqueue($depPath)
            }
        }
    }

    if ($needed.Count -eq 0) {
        throw "Bubilator88C.dll の Swift runtime 依存を 1 つも検出できませんでした (llvm-objdump の出力を確認してください)。"
    }
    foreach ($n in ($needed | Sort-Object)) {
        Copy-Item (Join-Path $SwiftRuntimeBin $n) -Destination $publishDir -Force
    }
    $allCount = (Get-ChildItem (Join-Path $SwiftRuntimeBin '*.dll')).Count
    Write-Host "    $($needed.Count) / $allCount 個をバンドル (残りは未使用)"
} else {
    Write-Warning "llvm-objdump.exe が見つからないため Swift runtime を全コピーします ($objdump)。"
    Copy-Item (Join-Path $SwiftRuntimeBin '*.dll') -Destination $publishDir -Force
}

# ---------------------------------------------------------------------------
# 6b. 未使用ファイルの削除 (prune)
#
#     self-contained な WindowsAppSDK は機能単位の on/off スイッチを持たない
#     ため、使っていないコンポーネントは発行後に削除するしかない。ここは
#     「消す理由」を明記した denylist にしておき、WindowsAppSDK / .NET を
#     bump したときに再監査できるようにする。
#
#     さらに、機能を後から足したときに黙って壊れないよう、WindowsAppSDK 機能の
#     グループにはシェルのソースを見る使用箇所ガードを付けてある
#     ($guardedPruneGroups)。起動スモークテスト (§7) は遅延活性化される機能を
#     カバーできないため、ここが実質的な最後の砦になる。
# ---------------------------------------------------------------------------
Step "未使用ファイルを削除"

$pruneFiles = [System.Collections.Generic.List[string]]@(
    # --- デバッグ用シンボル / 開発時専用 (実行には不要) ---
    #     アプリの機能とは無関係なので、無条件に削ってよい。
    '*.pdb'                                   # DirectML.pdb だけで 8.6MB
    'DirectML.Debug.dll'                      # DirectML のデバッグレイヤ
    'Microsoft.DiaSymReader.Native.amd64.dll' # PDB リーダ (シンボル無しなら不要)
    'createdump.exe'                          # クラッシュダンプ採取ツール
    'onnxruntime.lib'                         # C++ リンク用インポートライブラリ
    'skills-lock.json'                        # リポジトリのメタファイルが紛れ込む
)
$pruneDirs = [System.Collections.Generic.List[string]]@()

# --- 使っていない WindowsAppSDK 機能 (使用箇所ガード付き) ---
#
# WinRT のクラスは「実際に使う瞬間」に初めて DLL がロードされる (遅延活性化)
# ため、消しすぎても §7 の起動スモークテストでは捕まらない。例えば WebView2 で
# ヘルプ画面を出す機能を後から足すと、ビルドも起動も通るのに「その画面を開いた
# 瞬間だけ落ちる」ことになる。
#
# そこでシェルのソースを grep し、その機能を使い始めた形跡があれば prune を
# 取りやめる。安全側 (= 同梱する) に倒れ、警告で気づけるようにしてある。
$guardedPruneGroups = @(
    @{
        Name     = 'WebView2'
        Reason   = 'HTML ビューは使わない'
        Keywords = @('WebView2')
        Files    = @(
            'Microsoft.Web.WebView2.Core.dll'
            'Microsoft.Web.WebView2.Core.Projection.dll'
        )
        Dirs     = @('runtimes\win-x64\native')   # WebView2Loader.dll のみ
    }
    @{
        Name     = 'Widgets'
        Reason   = 'Windows ウィジェットボードへの提供機能は持たない'
        Keywords = @('Microsoft.Windows.Widgets', 'WidgetProvider')
        Files    = @(
            'Microsoft.Windows.Widgets.dll'
            'Microsoft.Windows.Widgets.Projection.dll'
            'Microsoft.Windows.Widgets.winmd'
        )
        Dirs     = @()
    }
    @{
        Name     = 'Notifications'
        Reason   = 'アプリ内トーストは自前実装で OS 通知は使わない'
        Keywords = @('AppNotification', 'PushNotification')
        Files    = @(
            'Microsoft.Windows.AppNotifications.dll'
            'Microsoft.Windows.AppNotifications.Projection.dll'
            'Microsoft.Windows.AppNotifications.winmd'
            'Microsoft.Windows.AppNotifications.Builder.Projection.dll'
            'Microsoft.Windows.AppNotifications.Builder.winmd'
            'Microsoft.Windows.PushNotifications.Projection.dll'
            'Microsoft.Windows.PushNotifications.winmd'
            'PushNotificationsLongRunningTask.ProxyStub.dll'
        )
        Dirs     = @()
    }
    @{
        Name     = 'MSIX Deployment'
        Reason   = 'unpackaged 配布なのでパッケージ配置 API は使わない'
        Keywords = @('Management.Deployment', 'PackageDeploymentManager', 'DeploymentManager')
        Files    = @(
            'Microsoft.Windows.Management.Deployment.Projection.dll'
            'Microsoft.Windows.Management.Deployment.winmd'
            'WindowsAppSdk.AppxDeploymentExtensions.Desktop.dll'
            'WindowsAppSdk.AppxDeploymentExtensions.Desktop-EventLog-Instrumentation.dll'
            'WindowsAppRuntime.DeploymentExtensions.OneCore.dll'
            'RestartAgent.exe'      # WindowsAppRuntime の更新時再起動エージェント
            'WindowsAppRuntime.png' # 上記エージェントのダイアログ用画像
        )
        Dirs     = @()
    }
)

# WinUIEdit.dll (3.4MB) はガード対象にせず常に残す: TextBox/RichEditBox を置いた
# 瞬間に遅延ロードされる。現状 XAML/コードとも TextBox 系は未使用だが、XAML の
# コントロールテンプレート経由で間接的に使われる可能性を grep では否定しきれない。

$shellSources = @(
    Get-ChildItem -Path $ShellDir -Recurse -File -Include '*.cs', '*.xaml' |
        Where-Object { $_.FullName -notmatch '\\(obj|bin)\\' }
)
if ($shellSources.Count -eq 0) {
    throw "シェルのソースが 1 つも見つかりません ($ShellDir)。prune の使用箇所ガードが機能しないため中断します。"
}

foreach ($g in $guardedPruneGroups) {
    # -SimpleMatch + -CaseSensitive: 識別子そのものの出現だけを見る
    # (コメント中の "error notification" のような散文には反応させない)。
    $hit = $shellSources |
        Select-String -Pattern $g.Keywords -SimpleMatch -CaseSensitive -List |
        Select-Object -First 1
    if ($hit) {
        Write-Warning ("{0} を使い始めた形跡があるため prune しません ({1}:{2})。不要なら `$guardedPruneGroups から外してください。" -f `
            $g.Name, (Resolve-Path -Relative $hit.Path), $hit.LineNumber)
        continue
    }
    foreach ($f in $g.Files) { $pruneFiles.Add($f) }
    foreach ($d in $g.Dirs) { $pruneDirs.Add($d) }
}

$prunedBytes = 0
$prunedCount = 0
foreach ($pattern in $pruneFiles) {
    foreach ($f in (Get-ChildItem -Path $publishDir -Filter $pattern -File -ErrorAction SilentlyContinue)) {
        $prunedBytes += $f.Length; $prunedCount++
        Remove-Item $f.FullName -Force
    }
}
foreach ($d in $pruneDirs) {
    $p = Join-Path $publishDir $d
    if (Test-Path $p) {
        $dirFiles = @(Get-ChildItem $p -Recurse -File)
        if ($dirFiles.Count -gt 0) {
            $prunedBytes += ($dirFiles | Measure-Object Length -Sum).Sum
            $prunedCount += $dirFiles.Count
        }
        Remove-Item $p -Recurse -Force
    }
}

# WindowsAppSDK の *.mui (XAML 組み込み文字列のローカライズ) は 80 以上の
# ロケールフォルダとして展開され、フォルダ数の大半を占める。UI は英語のみ
# なので en-us だけ残す (フォールバック元が消えると MRM が解決に失敗する)。
$keepLocales = @('en-us')
foreach ($d in (Get-ChildItem -Path $publishDir -Directory)) {
    if ($keepLocales -contains $d.Name) { continue }
    # ロケールフォルダの見分け: 中身が *.mui だけのフォルダ
    $files = @(Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue)
    if ($files.Count -gt 0 -and -not ($files | Where-Object { $_.Extension -ne '.mui' })) {
        $prunedBytes += ($files | Measure-Object Length -Sum).Sum
        $prunedCount += $files.Count
        Remove-Item $d.FullName -Recurse -Force
    }
}

# 中身が空になったフォルダ (runtimes\ 等) も畳む。
foreach ($d in (Get-ChildItem -Path $publishDir -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending)) {
    if (@(Get-ChildItem $d.FullName -Force).Count -eq 0) { Remove-Item $d.FullName -Force }
}

Write-Host ("    {0} ファイル / {1:N1} MB を削除" -f $prunedCount, ($prunedBytes / 1MB))

if ($Variant -eq 'SingleFile') {
    # The first publish supplies the exact Swift import closure. Stage those DLLs
    # as project Content so the second publish includes them in the bundle.
    $stageDir = Join-Path $ShellDir 'singlefile-runtime'
    if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
    New-Item -ItemType Directory -Path $stageDir | Out-Null
    try {
        foreach ($dll in (Get-ChildItem $SwiftRuntimeBin -Filter '*.dll' -File)) {
            $bundled = Join-Path $publishDir $dll.Name
            if (Test-Path $bundled) { Copy-Item $bundled $stageDir }
        }
        if (@(Get-ChildItem $stageDir -Filter '*.dll').Count -eq 0) {
            throw '単一ファイルに組み込む Swift runtime DLL がありません。'
        }
        $singleDir = Join-Path $OutputDir 'publish-win-x64-SingleFile-final'
        if (Test-Path $singleDir) { Remove-Item $singleDir -Recurse -Force }
        Step 'dotnet publish (single-file, Swift runtime 同梱)'
        & dotnet publish $csproj `
            -c $Configuration -r win-x64 -p:Platform=x64 --self-contained true `
            -p:WindowsAppSDKSelfContained=true `
            -p:PublishSingleFile=true -p:IncludeAllContentForSelfExtract=true `
            -p:Version=$Version -o $singleDir
        if ($LASTEXITCODE -ne 0) { throw "単一ファイル publish が失敗しました (exit $LASTEXITCODE)。" }
        foreach ($sidecar in (Get-ChildItem $singleDir -File | Where-Object { $_.Name -ne 'Bubilator88.Windows.exe' })) {
            if ($sidecar.Extension -eq '.pdb') { Remove-Item $sidecar.FullName -Force }
            else { throw "単一ファイル publish に予期しない sidecar: $($sidecar.Name)" }
        }
        if (@(Get-ChildItem $singleDir -Recurse -File).Count -ne 1) {
            throw '単一 EXE 以外のファイルが publish に残っています。'
        }
        $publishDir = $singleDir
    } finally {
        Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    @"
Bubilator88 for Windows $Version — Shared Windows App SDK runtime edition

Install Windows App SDK runtime 2.5.1 (x64) before starting Bubilator88.Windows.exe:
https://aka.ms/windowsappsdk/2.5/2.5.1/windowsappruntimeinstall-x64.exe

Microsoft Visual C++ Redistributable (x64) is also required:
https://aka.ms/vc14/vc_redist.x64.exe

This ZIP includes the .NET 10 runtime and Swift runtime. Install the Windows
App SDK runtime once per PC; already installed compatible 2.5.x runtimes can
be shared by this and other apps. ROM files are not included.
"@ | Set-Content -Path (Join-Path $publishDir 'INSTALL-RUNTIME.txt') -Encoding utf8
}

# ---------------------------------------------------------------------------
# 7. スモークテスト: Swift を PATH から外した状態で Bubilator88C.dll をロード
#    LoadLibraryEx を LOAD_WITH_ALTERED_SEARCH_PATH 付きで直接呼び、
#    「発行フォルダだけで依存関係が解決するか」を検証する。開発機は Swift が
#    PATH 上にあるため、素朴に exe を起動するだけではバンドル漏れを検出できない。
# ---------------------------------------------------------------------------
if (-not $SkipSmokeTest) {
    # Swift toolchain/runtime を PATH から除外し、バンドルした依存だけで起動する。
    $swiftToolchainBin = Split-Path $swiftCmd.Source -Parent
    $pathEntries = $env:PATH -split ';' | Where-Object {
        $_ -and
        -not $_.ToLower().Contains('swift') -and
        $_ -ne $SwiftRuntimeBin -and
        $_ -ne $swiftToolchainBin -and
        -not (Test-Path (Join-Path $_ 'swiftCore.dll') -ErrorAction SilentlyContinue)
    }
    $cleanPath = $pathEntries -join ';'
    if ($Variant -ne 'SingleFile') {
    Step "スモークテスト: Swift を PATH から外して Bubilator88C.dll のロードを確認"

    $loaderScript = Join-Path $OutputDir '_smoketest_loader.ps1'
    $resultPath = Join-Path $OutputDir '_smoketest_result.txt'
    if (Test-Path $resultPath) { Remove-Item $resultPath -Force }

    @'
param([string]$DllPath, [string]$ResultPath)
Add-Type -Name Win32 -Namespace SmokeTestNative -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern IntPtr LoadLibraryEx(string lpFileName, IntPtr hFile, uint dwFlags);
"@
$LOAD_WITH_ALTERED_SEARCH_PATH = 0x00000008
$h = [SmokeTestNative.Win32]::LoadLibraryEx($DllPath, [IntPtr]::Zero, $LOAD_WITH_ALTERED_SEARCH_PATH)
if ($h -eq [IntPtr]::Zero) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Set-Content -Path $ResultPath -Value "FAIL:$err"
} else {
    Set-Content -Path $ResultPath -Value "PASS"
}
'@ | Set-Content -Path $loaderScript

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command pwsh).Source
    $dllPathForLoader = Join-Path $publishDir 'Bubilator88C.dll'
    $psi.Arguments = "-NoProfile -NonInteractive -File `"$loaderScript`" -DllPath `"$dllPathForLoader`" -ResultPath `"$resultPath`""
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables["PATH"] = $cleanPath
    $proc = [System.Diagnostics.Process]::Start($psi)

    # dispatch/Foundation の初期化がバックグラウンドスレッドを起こし、プロセスが
    # 自然終了しないことがあるため、結果ファイルが書かれ次第 forced kill する。
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path $resultPath) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
    }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

    if (-not (Test-Path $resultPath)) {
        throw "スモークテストがタイムアウトしました (結果ファイルが書かれませんでした)。"
    }
    $result = Get-Content $resultPath -Raw
    Remove-Item $loaderScript, $resultPath -Force -ErrorAction SilentlyContinue

    if ($result -notmatch '^PASS') {
        throw "スモークテスト失敗: $result (発行フォルダに Bubilator88C.dll の依存 DLL が不足しています)"
    }
    Write-Host "    Swift runtime を PATH から外した状態でもロード成功"
    }

    # -----------------------------------------------------------------------
    # 7b. アプリ本体の起動スモークテスト
    #     §6b の prune で WindowsAppSDK / .NET 側を消しすぎていないかは、
    #     DLL 単体ロードでは検出できない (XAML の型解決や MRM のリソース解決は
    #     アプリを起動して初めて走る)。実際に exe を起動し、数秒生存して
    #     ウィンドウが出ることを確認する。
    # -----------------------------------------------------------------------
    Step "スモークテスト: アプリを起動してウィンドウ生成を確認"

    $exePath = Join-Path $publishDir 'Bubilator88.Windows.exe'
    $psi2 = New-Object System.Diagnostics.ProcessStartInfo
    $psi2.FileName = $exePath
    $psi2.WorkingDirectory = $publishDir
    $psi2.UseShellExecute = $false
    $psi2.EnvironmentVariables["PATH"] = $cleanPath
    $app = [System.Diagnostics.Process]::Start($psi2)

    # 生存し続けていること自体が本命の判定。XAML の型解決も MRM のリソース
    # 解決も失敗すれば未処理例外でプロセスが即死するため、prune のやりすぎは
    # 「起動直後に exit」として必ず現れる (ROM 未配置でも起動はする — ROM が
    # 無い状態でも title 'Bubilator88' のウィンドウが出ることを確認済み)。
    $appDeadline = (Get-Date).AddSeconds(30)
    $windowTitle = $null
    while ((Get-Date) -lt $appDeadline) {
        Start-Sleep -Milliseconds 500
        if ($app.HasExited) { break }
        $app.Refresh()
        if ($app.MainWindowHandle -ne [IntPtr]::Zero -and $app.MainWindowTitle) {
            $windowTitle = $app.MainWindowTitle
            break
        }
    }
    if ($app.HasExited) {
        throw "アプリ起動スモークテスト失敗: 起動直後に終了しました (exit $($app.ExitCode))。§6b の prune で必要なファイルまで削っていないか確認してください。"
    }
    # WinUI がウィンドウを作った直後でも、エミュレータ初期化と Swift DLL の
    # ロードは続いている。スナップショット一回だけでは起動順に左右される。
    $requiredModules = @('Bubilator88C.dll', 'swiftCore.dll', 'Microsoft.UI.Xaml.dll')
    $moduleDeadline = (Get-Date).AddSeconds(30)
    $missingModules = $requiredModules
    do {
        $app.Refresh()
        if ($app.HasExited) {
            throw "アプリ起動スモークテスト失敗: DLL ロード待機中に終了しました (exit $($app.ExitCode))。"
        }
        $loadedModules = @($app.Modules)
        $loadedNames = @($loadedModules | ForEach-Object { $_.ModuleName })
        $missingModules = @($requiredModules | Where-Object { $loadedNames -notcontains $_ })
        if ($missingModules.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $moduleDeadline)
    if ($missingModules.Count -ne 0) {
        Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
        throw "アプリ起動スモークテスト失敗: $($missingModules -join ', ') がロードされていません (検出済み: $($loadedNames -join ', '))。"
    }
    $coreModule = $loadedModules | Where-Object ModuleName -eq 'Bubilator88C.dll' | Select-Object -First 1
    $contentDir = Split-Path $coreModule.FileName -Parent
    foreach ($relative in @('SRVGGNet_x2_lite.onnx', 'SRVGGNet_x2.onnx', 'Assets\AppIcon.ico')) {
        if (-not (Test-Path (Join-Path $contentDir $relative))) {
            Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
            throw "アプリ起動スモークテスト失敗: $relative がコア DLL と同じ展開先にありません。"
        }
    }
    Write-Host '    WinUI / Swift コアの実ロードを確認'
    Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue

    # ウィンドウの有無は「デスクトップセッションがあるか」に左右されるため、
    # CI (headless に近いランナー) で release を落とさないよう warning 止まりに
    # する。プロセスが生存している時点で活性化・リソース解決は通っている。
    if ($windowTitle -eq 'Bubilator88') {
        Write-Host "    メインウィンドウ ('$windowTitle') の生成を確認"
    } elseif ($windowTitle) {
        Write-Warning "起動はしたがウィンドウタイトルが想定外です: '$windowTitle' (モーダルダイアログの可能性)。"
    } else {
        Write-Warning "30 秒以内にウィンドウを検出できませんでした (プロセスは生存)。デスクトップセッションの無い環境では正常。"
    }
}

# ---------------------------------------------------------------------------
# 8. zip 化 + SHA256
# ---------------------------------------------------------------------------
$zipName = "$PackageName-Windows-x64-$Version-$Variant.zip"
$zipPath = Join-Path $OutputDir $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Step "zip 作成: $zipName"
Compress-Archive -Path (Join-Path $publishDir '*') -DestinationPath $zipPath -CompressionLevel Optimal

$hash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()
$sizeMb = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)

Step "完了"
Write-Host "  Path:   $zipPath"
Write-Host "  Size:   $sizeMb MB"
Write-Host "  SHA256: $hash"

if ($env:GITHUB_OUTPUT) {
    $prefix = if ($Variant -eq 'SingleFile') { 'single' } else { 'shared' }
    Add-Content -Path $env:GITHUB_OUTPUT -Value "${prefix}_zip_path=$zipPath"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "${prefix}_zip_name=$zipName"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "${prefix}_sha256=$hash"
}
