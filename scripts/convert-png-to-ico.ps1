#Requires -Version 7.0
<#
.SYNOPSIS
    正方形の PNG (推奨: 1024x1024 以上、アルファ有り) から Windows 用マルチ解像度 .ico を生成する。

.DESCRIPTION
    System.Drawing (GDI+) で各サイズにリサイズし、PNG 圧縮フレームとして
    ICO コンテナに埋め込む (Windows Vista 以降が対応する PNG-in-ICO 形式)。
    外部ツール (ImageMagick 等) 不要、Windows 同梱の System.Drawing.Common のみで完結する。

.PARAMETER SourcePng
    元となる正方形 PNG のパス。

.PARAMETER OutputIco
    出力する .ico のパス。

.PARAMETER Sizes
    埋め込む正方形サイズ (px) のリスト。既定は Windows 標準の一式。

.EXAMPLE
    pwsh scripts/convert-png-to-ico.ps1 -SourcePng docs/AppIcon.png -OutputIco windows/Bubilator88.Windows/Assets/AppIcon.ico
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePng,

    [Parameter(Mandatory = $true)]
    [string]$OutputIco,

    [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Drawing

$SourcePng = (Resolve-Path $SourcePng).Path
$srcBitmap = [System.Drawing.Bitmap]::FromFile($SourcePng)

try {
    $entries = foreach ($size in ($Sizes | Sort-Object)) {
        $resized = New-Object System.Drawing.Bitmap($size, $size)
        $g = [System.Drawing.Graphics]::FromImage($resized)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.DrawImage($srcBitmap, 0, 0, $size, $size)
        } finally {
            $g.Dispose()
        }

        $ms = New-Object System.IO.MemoryStream
        $resized.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $resized.Dispose()
        [PSCustomObject]@{ Size = $size; Bytes = $ms.ToArray() }
    }
} finally {
    $srcBitmap.Dispose()
}

# ICO container: ICONDIR (6B) + ICONDIRENTRY[N] (16B each) + PNG payloads.
$headerSize = 6
$dirEntrySize = 16
$offset = $headerSize + ($dirEntrySize * $entries.Count)

$outStream = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($outStream)

$bw.Write([UInt16]0)          # reserved
$bw.Write([UInt16]1)          # type = icon
$bw.Write([UInt16]$entries.Count)

foreach ($e in $entries) {
    $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }  # 0 means 256px per ICO spec
    $bw.Write([byte]$dim)     # width
    $bw.Write([byte]$dim)     # height
    $bw.Write([byte]0)        # color count (0 = no palette)
    $bw.Write([byte]0)        # reserved
    $bw.Write([UInt16]1)      # color planes
    $bw.Write([UInt16]32)     # bits per pixel
    $bw.Write([UInt32]$e.Bytes.Length)
    $bw.Write([UInt32]$offset)
    $offset += $e.Bytes.Length
}

foreach ($e in $entries) {
    $bw.Write($e.Bytes)
}

$bw.Flush()
[System.IO.File]::WriteAllBytes($OutputIco, $outStream.ToArray())
$bw.Dispose()
$outStream.Dispose()

Write-Host "Wrote $OutputIco ($(($Sizes | Sort-Object) -join ', ') px, $([math]::Round((Get-Item $OutputIco).Length / 1KB, 1)) KB)"
