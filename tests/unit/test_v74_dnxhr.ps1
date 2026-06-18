# v74: DNxHR polish (mirror PS1 al test_v74_dnxhr.sh) — (F1) av_check profil din `profile`,
#   (F2) comentarii de culoare corectate (bt2020->unknown pe MOV, NU "bt709"; master-display
#   pastrat in loc de "MaxCLL pastrate"). Source-level + functional (guarded pe ffmpeg).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT "src"
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$CHK = Get-Content (Join-Path $SRC "av_check.ps1") -Raw
$ENC = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw

# ── F1: av_check — profil DNxHR din campul `profile` ────────────────────
Assert-Match $CHK ([regex]::Escape('if ($codec -eq "dnxhd")'))         "F1: profil probat pe dnxhd (stream=profile)"
Assert-Match $CHK ([regex]::Escape('"DNXHR LB"  { "Avid DNxHR LB" }'))  "F1: DNXHR LB"
Assert-Match $CHK ([regex]::Escape('"DNXHR HQ"  { "Avid DNxHR HQ" }'))  "F1: DNXHR HQ"
Assert-Match $CHK ([regex]::Escape('"DNXHR HQX" { "Avid DNxHR HQX" }')) "F1: DNXHR HQX"
Assert-Match $CHK ([regex]::Escape('"DNXHR 444" { "Avid DNxHR 444" }')) "F1: DNXHR 444"

# ── F2: comentarii de culoare corectate ─────────────────────────────────
Assert-Eq $false ([bool]($ENC -match 'bt2020 devine bt709')) "F2: claim gresit 'bt2020 devine bt709' ELIMINAT"
Assert-Match $ENC ([regex]::Escape('bt2020 -> unknown'))     "F2: forma corecta (bt2020 -> unknown)"
Assert-Match $ENC ([regex]::Escape('master-display pastrat')) "F2: 'master-display pastrat' (universal)"
Assert-Eq $false ([bool]($ENC -match 'MaxCLL pastrate'))     "F2: overstatement 'MaxCLL pastrate' ELIMINAT"

# ── Functional (guarded): `profile` expune profilul DNxHR + pix_fmt per profil ──
if ((Get-Command ffmpeg -ErrorAction SilentlyContinue) -and (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    $td = Join-Path ([IO.Path]::GetTempPath()) ("v74dnx_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $td | Out-Null
    & ffmpeg -y -v error -f lavfi -i "testsrc=size=640x360:rate=25" -t 1 -c:v dnxhd -profile:v dnxhr_hq -pix_fmt yuv422p -an "$td\hq.mxf" 2>$null
    $prof = (& ffprobe -v error -select_streams v:0 -show_entries stream=profile -of default=noprint_wrappers=1:nokey=1 "$td\hq.mxf" 2>$null | Select-Object -First 1)
    if ($prof) { $prof = $prof.Trim() }
    Assert-Eq "DNXHR HQ" $prof "functional F1: dnxhr_hq -> profile 'DNXHR HQ'"
    & ffmpeg -y -v error -f lavfi -i "testsrc=size=640x360:rate=25" -t 1 -c:v dnxhd -profile:v dnxhr_hqx -pix_fmt yuv422p10le -an "$td\hqx.mxf" 2>$null
    $pf = (& ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$td\hqx.mxf" 2>$null | Select-Object -First 1)
    if ($pf) { $pf = $pf.Trim() }
    Assert-Eq "yuv422p10le" $pf "functional: HQX -> 10-bit yuv422p10le"
    & ffmpeg -y -v error -f lavfi -i "testsrc=size=640x360:rate=25" -t 1 -c:v dnxhd -profile:v dnxhr_444 -pix_fmt yuv444p10le -an "$td\444.mxf" 2>$null
    $pf4 = (& ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$td\444.mxf" 2>$null | Select-Object -First 1)
    if ($pf4) { $pf4 = $pf4.Trim() }
    Assert-Eq "yuv444p10le" $pf4 "functional: 444 -> 10-bit yuv444p10le"
    Remove-Item -Recurse -Force $td -ErrorAction SilentlyContinue
} else {
    Write-Host "  (info: ffmpeg/ffprobe indisponibil — sar functionalul)"
}

Invoke-TestSummary
