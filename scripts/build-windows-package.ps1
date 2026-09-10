#Requires -Version 7.0
<#
.SYNOPSIS
    Bubilator88 Windows 版を自己完結型の配布パッケージ (zip) にビルドする。

.DESCRIPTION
    1. Swift toolchain の所在と runtime DLL ディレクトリを検出
    2. (任意) swift test で EmulatorCore の回帰を確認
    3. swift build -c release --product Bubilator88C → native\Bubilator88C.dll に配置
    4. AI モデル (models/onnx/*.onnx) が Git LFS ポインタのままでないか確認
    5. dotnet publish (win-x64, self-contained) でシェルを発行
    6. Swift runtime DLL 一式を発行フォルダへバンドル (配布先に Swift toolchain は無い前提)
    7. スモークテスト: Swift を PATH から外した状態で Bubilator88C.dll がロードできるかを検証
       (バンドル漏れの唯一の確実な検出方法 — objdump 静的解析は実行時にしか
       解決されない依存を見落とすため、実ロードで確認する)
    8. 発行フォルダを zip 化し、SHA256 を算出

    CI (GitHub Actions) と手元ビルドの両方から呼べるよう、GITHUB_OUTPUT が
    設定されていれば zip_path/zip_name/sha256 をそこにも書き出す。

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

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$CoreDir = Join-Path $RepoRoot 'Packages\EmulatorCore'
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
# 2. (任意) EmulatorCore のユニットテスト
# ---------------------------------------------------------------------------
if ($RunCoreTests) {
    Step "swift test (EmulatorCore)"
    Push-Location $CoreDir
    try {
        & swift test
        if ($LASTEXITCODE -ne 0) { throw "swift test が失敗しました (exit $LASTEXITCODE)。" }
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# 3. コア DLL のビルド
# ---------------------------------------------------------------------------
if (-not $SkipCoreBuild) {
    Step "swift build -c release --product Bubilator88C"
    Push-Location $CoreDir
    try {
        & swift build -c release --product Bubilator88C
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
    foreach ($m in @('SRVGGNet_x2_lite.onnx', 'SRVGGNet_x2.onnx', 'RealESRGAN_x2.onnx')) {
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
$publishDir = Join-Path $OutputDir 'publish-win-x64'
if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }

Step "dotnet publish (win-x64, self-contained, Version=$Version)"
$csproj = Join-Path $ShellDir 'Bubilator88.Windows.csproj'
& dotnet publish $csproj `
    -c $Configuration -r win-x64 -p:Platform=x64 --self-contained true `
    -p:Version=$Version `
    -o $publishDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish が失敗しました (exit $LASTEXITCODE)。" }

if (-not (Test-Path (Join-Path $publishDir 'Bubilator88C.dll'))) {
    throw "発行フォルダに Bubilator88C.dll がありません (csproj の Link 設定を確認)。"
}

# ---------------------------------------------------------------------------
# 6. Swift runtime DLL をバンドル (配布先マシンには Swift toolchain が無い前提)
# ---------------------------------------------------------------------------
Step "Swift runtime DLL をバンドル"
Copy-Item (Join-Path $SwiftRuntimeBin '*.dll') -Destination $publishDir -Force

# ---------------------------------------------------------------------------
# 7. スモークテスト: Swift を PATH から外した状態で Bubilator88C.dll をロード
#    LoadLibraryEx を LOAD_WITH_ALTERED_SEARCH_PATH 付きで直接呼び、
#    「発行フォルダだけで依存関係が解決するか」を検証する。開発機は Swift が
#    PATH 上にあるため、素朴に exe を起動するだけではバンドル漏れを検出できない。
# ---------------------------------------------------------------------------
if (-not $SkipSmokeTest) {
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

    # "swift" という文字列を含むかだけでなく、実際に swiftCore.dll/swift.exe を
    # 含むディレクトリかどうかでも判定する — インストール先のパスに "swift" の
    # 文字列が含まれない CI 環境でも、ランタイムが PATH 上に残っていれば確実に除外する。
    $swiftToolchainBin = Split-Path $swiftCmd.Source -Parent
    $pathEntries = $env:PATH -split ';' | Where-Object {
        $_ -and
        -not $_.ToLower().Contains('swift') -and
        $_ -ne $SwiftRuntimeBin -and
        $_ -ne $swiftToolchainBin -and
        -not (Test-Path (Join-Path $_ 'swiftCore.dll') -ErrorAction SilentlyContinue)
    }
    $cleanPath = $pathEntries -join ';'

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

# ---------------------------------------------------------------------------
# 8. zip 化 + SHA256
# ---------------------------------------------------------------------------
$zipName = "$PackageName-Windows-x64-$Version.zip"
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
    Add-Content -Path $env:GITHUB_OUTPUT -Value "zip_path=$zipPath"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "zip_name=$zipName"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "sha256=$hash"
}
