# v68 — paritate smart-copy + warning concat (mirror al test_v68_audio_parity.sh).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$ENC = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw

# ── 1. #1 — PS1 era DEJA corect (referinta pe care bash o aliniaza): smart-copy
#       paseaza $audioParams (per-pista) la Invoke-StreamCopy (video copy + audio onorat) ──
Assert-Match $ENC ([regex]::Escape('Invoke-StreamCopy $f $outFile $mapFlags $container $LogFile $audioParams')) "#1: PS1 smart-copy paseaza audioParams (referinta paritate)"
Assert-Match $ENC ([regex]::Escape('@("-c:v","copy") + $audioParams')) "#1: Invoke-StreamCopy = video copy + audio params"

# ── 2. #4 — warning compat in concat pe calea unde copy E posibil (demuxer/stream-copy).
#       v87 FIX: pe calea FILTER copy-ul audio nu exista (fallback aac obligatoriu —
#       "Filtering and streamcopy cannot be used together") → warn-ul de acolo a fost
#       scos ODATA CU optiunea; ramane doar pe demuxer, unde chiar se copiaza.
Assert-Match $ENC ([regex]::Escape('Show-IncompatAudioCopyWarnings -File $s.FullName -Container $container -ReencInputs @() -SkipInputs @()')) "#4: warning in concat (per sursa, calea demuxer)"
$cnt = ([regex]::Matches($ENC, [regex]::Escape('Show-IncompatAudioCopyWarnings -File $s.FullName -Container $container'))).Count
Assert-Eq 1 $cnt "#4: warning DOAR pe calea demuxer (v87: pe filter copy e imposibil → fallback aac)"
Assert-Match $ENC ([regex]::Escape('Audio copy nu functioneaza cu concat filter')) "#4/v87: calea filter are fallback-ul onest in loc de copy"

# ── 3. Functional — helper compat (mirror, reconfirmare) ──────────────
. "$PSScriptRoot\..\_helpers.ps1"
Import-AvEncodeFunctions -Names @('Get-AudioCopyCompat','Show-IncompatAudioCopyWarnings') | Out-Null
Assert-Eq "drop" (Get-AudioCopyCompat eac3 mov) "#4: eac3+mov → drop"
Assert-Eq "copy" (Get-AudioCopyCompat aac mp4)  "#4: aac+mp4 → copy"
if ((Get-Command ffmpeg -EA SilentlyContinue) -and (Get-Command ffprobe -EA SilentlyContinue)) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v68_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $src = Join-Path $tmp 'e.mkv'
    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=160x120:rate=10" -f lavfi -i "sine=frequency=440:duration=1" `
        -map 0:v -map 1:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a eac3 -shortest $src 2>$null | Out-Null
    if (Test-Path $src) {
        $w = (Show-IncompatAudioCopyWarnings -File $src -Container "mov" -ReencInputs @() -SkipInputs @() 6>&1 | Out-String)
        Assert-Eq $true ($w -match 'a:0.*eac3.*incompatibila') "#4 functional: concat-style eac3 copiat in mov → warning"
    }
    Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
}
Invoke-TestSummary
