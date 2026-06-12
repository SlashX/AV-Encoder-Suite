# v69 — clasa "raw fara PTS → matroska" (mirror al test_v69_raw_mkv_class.sh).
#   CANAR: hevc+bframes → mkv trebuie sa esueze (daca un ffmpeg viitor o repara,
#   assert-ul pica → re-evalueaza guard-urile MP4-step din sectiunea H).
#   Plus: mp4-wrap OK, audio raw IMUN, APV -f apv -framerate → mkv OK.
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Write-Output "SKIP test_v69_raw_mkv_class — ffmpeg lipseste"; exit 77 }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("rawmkv_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null

function Get-Size([string]$p) { if (Test-Path $p) { (Get-Item $p).Length } else { 0 } }

& ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=128x128:rate=10" `
    -c:v libx265 -x265-params log-level=none:bframes=2 -preset ultrafast -f hevc "$tmp\t.hevc" 2>$null | Out-Null
& ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=1" -c:a aac -f adts "$tmp\t.aac" 2>$null | Out-Null

if ((Get-Size "$tmp\t.hevc") -eq 0) { Write-Output "SKIP test_v69_raw_mkv_class — x265 indisponibil"; exit 77 }

# 1. CANAR: hevc raw (bframes) → mkv = gol/esec
& ffmpeg -v error -y -i "$tmp\t.hevc" -c copy "$tmp\o1.mkv" 2>$null
Assert-Eq $true ((Get-Size "$tmp\o1.mkv") -lt 5000) "CANAR clasa: hevc raw (bframes) → mkv gol/esec ($(Get-Size "$tmp\o1.mkv")B; daca pica: ffmpeg a reparat clasa)"

# 2-3. mp4 OK + ruta wrap completa
& ffmpeg -v error -y -i "$tmp\t.hevc" -c copy -tag:v hvc1 "$tmp\o2.mp4" 2>$null
Assert-Eq $true ((Get-Size "$tmp\o2.mp4") -gt 5000) "hevc raw → mp4 functioneaza"
& ffmpeg -v error -y -i "$tmp\o2.mp4" -c copy "$tmp\o3.mkv" 2>$null
Assert-Eq $true ((Get-Size "$tmp\o3.mkv") -gt 5000) "ruta wrap (raw→mp4→mkv) functioneaza"

# 4. audio raw → mkv OK (fluxurile audio IMUNE)
& ffmpeg -v error -y -i "$tmp\t.aac" -c copy "$tmp\o4.mkv" 2>$null
Assert-Eq $true ((Get-Size "$tmp\o4.mkv") -gt 2000) "audio raw aac → mkv OK — audio imun (PTS din durata fixa)"

# 5. APV -f apv -framerate → mkv OK (premisa helper-ului inject)
if (& ffmpeg -hide_banner -encoders 2>$null | Select-String '\bliboapv\b') {
    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=0.5:size=160x128:rate=10" `
        -c:v liboapv -qp 45 -pix_fmt yuv422p10le -f apv "$tmp\t.apv" 2>$null | Out-Null
    & ffmpeg -v error -y -f apv -framerate 10 -i "$tmp\t.apv" -c copy "$tmp\o6.mkv" 2>$null
    Assert-Eq $true ((Get-Size "$tmp\o6.mkv") -gt 5000) "APV raw (-f apv -framerate) → mkv OK — intra-only, PTS generat"
} else {
    Write-Host "  (APV sarit: liboapv lipseste)" -ForegroundColor Yellow
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Invoke-TestSummary
