# v63 — HDR10 → HLG (mirror al test_v63_hdr10_to_hlg.sh).
#   Optiune noua in Show-SourceDialog (hdr10_to_hlg); PQ → HLG (arib-std-b67), metadata-free.
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
# ffmpeg: global (PATH) sau bundle-uit in src/ (Windows testing)
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$ENC    = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
$COMMON = Get-Content (Join-Path $SRC "av_common.sh") -Raw
$X265   = Get-Content (Join-Path $SRC "av_encoder_x265.sh") -Raw
$AV1    = Get-Content (Join-Path $SRC "av_encoder_av1.sh") -Raw

# ── 1. PS1 — Show-SourceDialog ofera + consuma hdr10_to_hlg ──
Assert-Match $ENC 'return "hdr10_to_hlg"'         "PS1 Show-SourceDialog: returneaza hdr10_to_hlg"
Assert-Match $ENC '"hdr10_to_hlg" \{'             "PS1: cazul hdr10_to_hlg consumat (switch)"
Assert-Match $ENC 'Converteste la HLG'            "PS1 dialog: ofera optiunea HLG"
Assert-Match $ENC 'transfer=arib-std-b67'         "PS1 x265: HLG VUI derivat (arib)"
Assert-Match $ENC 'transfer-characteristics=18'   "PS1 av1: HLG VUI (transfer-characteristics=18)"

# ── 2. Paritate bash (mode + cazuri encodere) ──
Assert-Match $COMMON 'SRC_DIALOG_MODE="hdr10_to_hlg"'                                  "bash dialog: mode hdr10_to_hlg"
Assert-Match $X265   'hdr10_to_hlg\)'                                                  "bash x265: cazul hdr10_to_hlg"
Assert-Match $X265   'colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc'     "bash x265: HLG params (fara hdr10=1)"
Assert-Match $AV1    'hdr10_to_hlg\)'                                                  "bash av1: cazul hdr10_to_hlg"

# ── 3. Functional — PQ (smpte2084) → HLG (arib-std-b67) ──
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v63h_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $pq = Join-Path $tmp "pq.mp4"; $hlg = Join-Path $tmp "hlg.mp4"
    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=30" `
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast `
        -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:log-level=none" -an $pq 2>$null | Out-Null
    if ((Test-Path $pq) -and (Get-Item $pq).Length -gt 0) {
        & ffmpeg -v error -y -i $pq `
            -vf "zscale=t=linear:npl=1000,zscale=t=arib-std-b67:p=bt2020:m=bt2020nc:r=tv,format=yuv420p10le" `
            -c:v libx265 -preset ultrafast `
            -x265-params "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:log-level=none" -an $hlg 2>$null | Out-Null
        $trc = (& ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer `
            -of default=noprint_wrappers=1:nokey=1 $hlg 2>$null | Select-Object -First 1)
        Assert-Eq "arib-std-b67" "$trc".Trim() "functional: PQ -> HLG produce arib-std-b67"
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Invoke-TestSummary
