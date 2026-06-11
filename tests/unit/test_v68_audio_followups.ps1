# v68 — follow-up-uri audio (mirror al test_v68_audio_followups.sh) + #3 DRY (PS1-only).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$ENC = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw

# ── 1. source-level ───────────────────────────────────────────────────
# #1 compat helper + warning + apel in ambele fluxuri
Assert-Match $ENC ([regex]::Escape('function Get-AudioCopyCompat'))            "#1: Get-AudioCopyCompat definit"
Assert-Match $ENC ([regex]::Escape('function Show-IncompatAudioCopyWarnings')) "#1: Show-IncompatAudioCopyWarnings definit"
Assert-Match $ENC ([regex]::Escape('Show-IncompatAudioCopyWarnings -File $f.FullName -Container $container')) "#1: apelat in flux principal"
Assert-Match $ENC ([regex]::Escape('Show-IncompatAudioCopyWarnings -File $f.FullName -Container $eaContainer')) "#1: apelat in audio-only"
# #2 smart-copy wording
Assert-Match $ENC ([regex]::Escape('Copiaza video 1:1 + aplica audio ales'))  "#2: wording smart-copy clarificat"
Assert-Eq $false ([bool]($ENC -match ([regex]::Escape('Stream copy total in loc de re-encode')))) "#2: vechea formulare 'total' scoasa"
# #3 DRY builder partajat
Assert-Match $ENC ([regex]::Escape('function Build-AudioSelectionParams'))     "#3: builder partajat definit"
Assert-Match $ENC ([regex]::Escape('Build-AudioSelectionParams $sel $audioCodec'))  "#3: flux principal foloseste builder-ul"
Assert-Match $ENC ([regex]::Escape('Build-AudioSelectionParams $eaSel $eaCodec'))   "#3: audio-only foloseste builder-ul"
# #4 AV_AUDIO_DROP
Assert-Match $ENC ([regex]::Escape('$env:AV_AUDIO_DROP'))                       "#4: env AV_AUDIO_DROP suportat"

# ── 2. Functional — helpere via AST import ────────────────────────────
. "$PSScriptRoot\..\_helpers.ps1"
Import-AvEncodeFunctions -Names @('Get-AudioCopyCompat','Show-IncompatAudioCopyWarnings','Build-AudioSelectionParams','Get-TrackAudioArgs','Get-FFprobeValue') | Out-Null

# #1 matrice compat
Assert-Eq "drop" (Get-AudioCopyCompat eac3 mov)   "#1: eac3 + mov → drop (incompatibil)"
Assert-Eq "copy" (Get-AudioCopyCompat eac3 mp4)   "#1: eac3 + mp4 → copy (ok)"
Assert-Eq "copy" (Get-AudioCopyCompat aac mov)    "#1: aac + mov → copy"
Assert-Eq "drop" (Get-AudioCopyCompat truehd mp4) "#1: truehd + mp4 → drop"
Assert-Eq "copy" (Get-AudioCopyCompat dts mkv)    "#1: orice + mkv → copy"

# #3 builder DRY — selectie {0:E, 1:S, 2:E} pe sursa cu 3 piste
if ((Get-Command ffmpeg -EA SilentlyContinue) -and (Get-Command ffprobe -EA SilentlyContinue)) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v68_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $src = Join-Path $tmp 's.mkv'
    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=160x120:rate=10" `
        -f lavfi -i "sine=frequency=440:duration=1" -f lavfi -i "sine=frequency=660:duration=1" -f lavfi -i "sine=frequency=880:duration=1" `
        -map 0:v -map 1:a -map 2:a -map 3:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p `
        -filter:a:0 "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0" -c:a:0 aac -c:a:1 ac3 -c:a:2 aac -shortest $src 2>$null | Out-Null
    if (Test-Path $src) {
        $sel = @{ 0 = "E"; 1 = "S"; 2 = "E" }
        $r = Build-AudioSelectionParams $sel "opus" "128k" $src 3
        # a:0 E (5.1 → out0, 256k); a:1 S; a:2 E (out1 dupa skip)
        Assert-Eq "-c:a copy -c:a:0 libopus -b:a:0 256k -c:a:1 libopus -b:a:1 128k" ($r.AudioParams -join ' ') "#3: builder E/S/E → copy-first + index output corect"
        Assert-Eq "-map -0:a:1" ($r.SkipMaps -join ' ') "#3: builder → negative map pt skip"
        Assert-Eq "0 2" ($r.ReencInputs -join ' ') "#3: builder → ReencInputs corecti"
        Assert-Eq "1" ($r.SkipInputs -join ' ') "#3: builder → SkipInputs corecti"
        Assert-Eq 0 $r.LoudnormTrack "#3: builder → LoudnormTrack = prima pista E (out0)"
        # #1 warning functional
        $src2 = Join-Path $tmp 'e.mkv'
        & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=160x120:rate=10" -f lavfi -i "sine=frequency=440:duration=1" -f lavfi -i "sine=frequency=660:duration=1" -map 0:v -map 1:a -map 2:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a:0 aac -c:a:1 eac3 -shortest $src2 2>$null | Out-Null
        $warn = (Show-IncompatAudioCopyWarnings -File $src2 -Container "mov" -ReencInputs @(0) -SkipInputs @() 6>&1 | Out-String)
        Assert-Eq $true ($warn -match 'a:1.*eac3.*incompatibila') "#1: warning functional pe eac3 copiat in mov"
    }
    Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
}
Invoke-TestSummary
