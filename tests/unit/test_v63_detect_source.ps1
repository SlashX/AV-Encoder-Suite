# v63 — detect_source_info robustete (mirror PS1: Get-SourceInfo).
#   PS1 e imun la CRLF prin Get-FFprobeValue .Trim(); confirmam isHLG corect pe HLG/PQ/SDR.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$ENC    = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
$COMMON = Get-Content (Join-Path $SRC "av_common.sh") -Raw

# ── 1. Source-level — mecanismele CRLF-safe ──
Assert-Match $ENC ([regex]::Escape('([string]$v[0]).Trim()'))  "PS1 Get-FFprobeValue: .Trim() (CRLF-safe)"
Assert-Match $COMMON ([regex]::Escape("tr -d '\r'")) "bash detect_source_info: tr -d \r (CRLF-safe)"

# ── 2. Functional — PS1 Get-SourceInfo isHLG corect pe HLG / PQ / SDR ──
if ((Get-Command ffmpeg -EA SilentlyContinue) -and (Get-Command ffprobe -EA SilentlyContinue)) {
    Import-AvEncodeFunctions -Names @("Get-FFprobeValue","Get-SourceInfo")
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v63ds_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $hlg = Join-Path $tmp "hlg.mp4"; $pq = Join-Path $tmp "pq.mp4"; $sdr = Join-Path $tmp "sdr.mp4"
    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" `
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast `
        -x265-params "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:log-level=none" -an $hlg 2>$null | Out-Null
    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" `
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast `
        -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:log-level=none" -an $pq 2>$null | Out-Null
    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" `
        -c:v libx264 -pix_fmt yuv420p -preset ultrafast -an $sdr 2>$null | Out-Null

    if (Test-Path $hlg) {
        $h = Get-SourceInfo $hlg
        Assert-Eq $true $h.isHLG          "HLG (arib-std-b67) → isHLG=True"
        Assert-Eq "arib-std-b67" $h.transfer "HLG → transfer curat (Trim)"
    }
    if (Test-Path $pq) {
        $p = Get-SourceInfo $pq
        Assert-Eq $false $p.isHLG         "PQ (smpte2084) → isHLG=False"
    }
    if (Test-Path $sdr) {
        $s = Get-SourceInfo $sdr
        Assert-Eq $false $s.isHLG         "SDR → isHLG=False"
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Invoke-TestSummary
