# v74: APV polish (mirror PS1 al test_v74_apv.sh) — (G3) av_check profil APV din campul
#   `profile` (numeric 33/44/55/66/77/88); + 4444_12 (yuva444p12le, profil 88) in encoder/
#   dialog/schema. Source-level + functional (guarded pe ffmpeg+liboapv).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT "src"
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$CHK = Get-Content (Join-Path $SRC "av_check.ps1") -Raw
$ENC = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw

# ── G3: av_check — profil APV din campul `profile` ──────────────────────
Assert-Match $CHK ([regex]::Escape('if ($codec -eq "apv")'))               "G3: profil probat pe apv (stream=profile)"
Assert-Match $CHK ([regex]::Escape('"33" { "Samsung APV 4:2:2 10-bit" }')) "G3: profil 33 -> 4:2:2 10-bit"
Assert-Match $CHK ([regex]::Escape('"55" { "Samsung APV 4:4:4 10-bit" }')) "G3: profil 55 -> 4:4:4 10-bit"
Assert-Match $CHK ([regex]::Escape('"88" { "Samsung APV 4:4:4:4 12-bit" }')) "G3: profil 88 -> 4:4:4:4 12-bit"

# ── 4444_12: encoder pixfmt + dialog + schema ───────────────────────────
Assert-Match $ENC ([regex]::Escape('"4444_12" { "yuva444p12le" }'))        "4444_12: pixfmt yuva444p12le"
Assert-Match $ENC ([regex]::Escape('"6" { "4444_12" }'))                   "4444_12: dialog optiune 6"
Assert-Match $ENC ([regex]::Escape('4444_10,4444_12'))                     "4444_12: schema PS1 include 4444_12"

# ── Functional (guarded): profile numbers + 4444_12 pix_fmt ─────────────
$hasApv = (Get-Command ffmpeg -ErrorAction SilentlyContinue) -and (Get-Command ffprobe -ErrorAction SilentlyContinue) `
          -and ((& ffmpeg -hide_banner -encoders 2>$null | Select-String "liboapv"))
if ($hasApv) {
    $td = Join-Path ([IO.Path]::GetTempPath()) ("v74apv_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $td | Out-Null
    & ffmpeg -y -v error -f lavfi -i "testsrc=size=320x240:rate=25" -t 1 -c:v liboapv -pix_fmt yuv422p10le "$td\a.mp4" 2>$null
    $p1 = (& ffprobe -v error -select_streams v:0 -show_entries stream=profile -of default=nw=1:nk=1 "$td\a.mp4" 2>$null | Select-Object -First 1)
    if ($p1) { $p1 = $p1.Trim() }
    Assert-Eq "33" $p1 "functional G3: 422-10 -> profile 33"
    & ffmpeg -y -v error -f lavfi -i "testsrc=size=320x240:rate=25" -t 1 -c:v liboapv -pix_fmt yuva444p12le "$td\f.mp4" 2>$null
    $p8 = (& ffprobe -v error -select_streams v:0 -show_entries stream=profile -of default=nw=1:nk=1 "$td\f.mp4" 2>$null | Select-Object -First 1)
    if ($p8) { $p8 = $p8.Trim() }
    $pf = (& ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$td\f.mp4" 2>$null | Select-Object -First 1)
    if ($pf) { $pf = $pf.Trim() }
    Assert-Eq "88" $p8 "functional: 4444_12 (yuva444p12le) -> profile 88"
    Assert-Eq "yuva444p12le" $pf "functional: 4444_12 -> pix_fmt yuva444p12le"
    Remove-Item -Recurse -Force $td -ErrorAction SilentlyContinue
} else {
    Write-Host "  (info: ffmpeg/liboapv indisponibil — sar functionalul)"
}

Invoke-TestSummary
