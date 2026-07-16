# ══════════════════════════════════════════════════════════════════════
# v91 — TS/BD [PROGRAM] stream double-listing dedupe (PS1). Mirror bash.
#   Source-level pe av_encode.ps1 (Get-AudioTrackCountDedup + atSeen/eaSeen
#   in dialoguri) + av_check.ps1 (subSeen la count-ul de subtitrari) +
#   functional hermetic (sinteza .ts cu program → Get-AudioTrackCountDedup).
# ══════════════════════════════════════════════════════════════════════
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$proj = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$src  = Join-Path $proj 'src'
$enc  = Get-Content (Join-Path $src 'av_encode.ps1') -Raw
$chk  = Get-Content (Join-Path $src 'av_check.ps1')  -Raw

# ── 1. Source-level: helper + count sites (av_encode.ps1) ─────────────
Assert-Match $enc 'function Get-AudioTrackCountDedup'  "helper Get-AudioTrackCountDedup"
Assert-Match $enc 'Sort-Object -Unique'                "helper deduplica pe index (Sort-Object -Unique)"
Assert-Match $enc '\$audioTrackCount = Get-AudioTrackCountDedup' "flux principal foloseste helper-ul"
Assert-Match $enc '\$eaTrackCount = Get-AudioTrackCountDedup'    "audio-only foloseste helper-ul"
Assert-Match $enc '\$atSeen'   "atinfo flux principal deduplica pe index (atSeen)"
Assert-Match $enc '\$eaSeen'   "atinfo audio-only deduplica pe index (eaSeen)"

# ── 2. Source-level: subtitle dedupe (av_check.ps1) ───────────────────
Assert-Match $chk '\$subSeen'    "av_check.ps1 deduplica subtitrarile pe index (subSeen)"
Assert-Match $chk '\$subCurDup'  "av_check.ps1 marcheaza blocul dublat (subCurDup)"

# ── 2b. Get-FileSpatialLabel deduplica in AMBELE copii (av_encode via helper +
#        av_mux.ps1 standalone) — parity cu _file_spatial_label (bash) ──
Assert-Match $enc '(?s)function Get-FileSpatialLabel.*?Get-AudioTrackCountDedup' "av_encode Get-FileSpatialLabel deduplica (via helper)"
$muxPs = Get-Content (Join-Path $src 'av_mux.ps1') -Raw
Assert-Match $muxPs '(?s)function Get-FileSpatialLabel.*?Sort-Object -Unique' "av_mux Get-FileSpatialLabel deduplica inline (standalone)"

# ── 3. Functional hermetic (sinteza .ts cu [PROGRAM]) ─────────────────
$env:PATH = "$src;$env:PATH"
$haveFf = (Get-Command ffmpeg -EA SilentlyContinue) -and (Get-Command ffprobe -EA SilentlyContinue)
if ($haveFf) {
    Import-AvEncodeFunctions -Names @('Get-AudioTrackCountDedup') | Out-Null
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v91ts_" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force $tmp | Out-Null

    # raw count (fara dedupe) — dovada ca TS-ul chiar dubleaza
    function _RawCount([string]$f) {
        return @(& ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 $f 2>$null |
            Where-Object { $_ -match '^\d' }).Count
    }

    # .ts cu 1 audio → raw=2 (program), dedupe=1
    $a1 = Join-Path $tmp 'a1.ts'
    & ffmpeg -v error -y -f lavfi -i "testsrc=size=320x240:rate=10:duration=1" `
        -f lavfi -i "sine=frequency=440:duration=1" `
        -c:v libx264 -c:a aac -f mpegts $a1 2>$null
    if ((Test-Path $a1) -and (Get-Item $a1).Length -gt 0) {
        Assert-Eq "2" "$(_RawCount $a1)"                      "premisa: .ts 1-audio dubleaza la ffprobe (raw=2)"
        Assert-Eq "1" "$(Get-AudioTrackCountDedup -File $a1)" "dedupe .ts 1-audio → 1 (fara dialog fals)"
    } else {
        Write-Host "  (sinteza .ts esuata — libx264/aac lipsa?)" -ForegroundColor DarkGray
    }

    # .ts cu 2 audio → raw=4, dedupe=2
    $a2 = Join-Path $tmp 'a2.ts'
    & ffmpeg -v error -y -f lavfi -i "testsrc=size=320x240:rate=10:duration=1" `
        -f lavfi -i "sine=frequency=440:duration=1" `
        -f lavfi -i "sine=frequency=880:duration=1" `
        -map 0:v -map 1:a -map 2:a -c:v libx264 -c:a aac -f mpegts $a2 2>$null
    if ((Test-Path $a2) -and (Get-Item $a2).Length -gt 0) {
        Assert-Eq "4" "$(_RawCount $a2)"                      "premisa: .ts 2-audio → raw=4 (2×2 program)"
        Assert-Eq "2" "$(Get-AudioTrackCountDedup -File $a2)" "dedupe .ts 2-audio → 2 (piste reale)"
    }

    Remove-Item -Recurse -Force $tmp -EA SilentlyContinue
} else {
    Write-Host "  (functional sarit — ffmpeg/ffprobe lipsesc)" -ForegroundColor DarkGray
}

Invoke-TestSummary
