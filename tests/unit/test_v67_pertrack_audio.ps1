# v67 — Selectie audio per-pista (mirror al test_v67_pertrack_audio.sh).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$ENC = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw

# ── 1. PS1 source-level — helper + builder DRY (v68) + ambele fluxuri ──
Assert-Match $ENC ([regex]::Escape('function Get-TrackAudioArgs'))                 "PS1: helper Get-TrackAudioArgs definit"
# v68 DRY: builder partajat Build-AudioSelectionParams (mirror al buclei bash); ambele fluxuri il apeleaza
Assert-Match $ENC ([regex]::Escape('function Build-AudioSelectionParams'))         "PS1: builder partajat Build-AudioSelectionParams definit"
Assert-Match $ENC ([regex]::Escape('Build-AudioSelectionParams $sel $audioCodec'))    "PS1 main: foloseste builder-ul partajat"
Assert-Match $ENC ([regex]::Escape('Build-AudioSelectionParams $eaSel $eaCodec'))     "PS1 audio-only: foloseste builder-ul partajat"
Assert-Match $ENC ([regex]::Escape('Get-TrackAudioArgs $Codec $outIdx $tchN $BaseBr')) "PS1 builder: helper folosit cu scaling per-pista"
Assert-Match $ENC ([regex]::Escape('$outIdx = $ai - $skipsBefore'))                "PS1 builder: index output recalculat dupa skip (fix bug v33)"
Assert-Match $ENC ([regex]::Escape('$audioLoudnormTrack = $r.LoudnormTrack'))      "PS1 main: loudnorm pe prima pista re-encodata"
Assert-Match $ENC ([regex]::Escape('-filter:a:$audioLoudnormTrack'))               "PS1 main: loudnorm scopat dinamic"
Assert-Match $ENC ([regex]::Escape('$env:AV_AUDIO_TRACKS'))                         "PS1: bypass non-interactiv AV_AUDIO_TRACKS"
Assert-Match $ENC ([regex]::Escape('$eaSkipMaps'))                                 "PS1 audio-only: negative skip maps"

# ── 2. Get-TrackAudioArgs functional (AST import) ─────────────────────
. "$PSScriptRoot\..\_helpers.ps1"
Import-AvEncodeFunctions -Names @('Get-TrackAudioArgs') | Out-Null
function _j($a) { ($a -join ' ') }
Assert-Eq "-c:a:1 libopus -b:a:1 256k"        (_j (Get-TrackAudioArgs opus 1 6 128k)) "helper: opus 5.1 → 256k @ idx1"
Assert-Eq "-c:a:0 aac -b:a:0 768k"            (_j (Get-TrackAudioArgs aac 0 8 192k))  "helper: aac 7.1 → 768k @ idx0"
Assert-Eq "-c:a:2 ac3 -b:a:2 448k -ac:a:2 6"  (_j (Get-TrackAudioArgs ac3 2 8 224k))  "helper: ac3 7.1 → 448k + downmix 5.1"
Assert-Eq "-c:a:0 pcm_s24le"                  (_j (Get-TrackAudioArgs pcm 0 2 24le))  "helper: pcm s24le"
$env:AV_DOWNMIX_STEREO = "1"
Assert-Eq "-c:a:1 aac -b:a:1 192k -ac:a:1 2"  (_j (Get-TrackAudioArgs aac 1 6 192k))  "helper: AV_DOWNMIX → -ac:a:1 2"
$env:AV_DOWNMIX_STEREO = $null

# ── 3. Functional end-to-end — flux audio-only PS1 per-pista via env ──
if ((Get-Command ffmpeg -EA SilentlyContinue) -and (Get-Command ffprobe -EA SilentlyContinue)) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v67_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    Copy-Item (Join-Path $SRC 'av_encode.ps1') (Join-Path $tmp 'av_encode.ps1')
    $src = Join-Path $tmp 'clip.mkv'
    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=160x120:rate=10" `
        -f lavfi -i "sine=frequency=440:duration=1" -f lavfi -i "sine=frequency=660:duration=1" -f lavfi -i "sine=frequency=880:duration=1" `
        -map 0:v -map 1:a -map 2:a -map 3:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p `
        -c:a:0 aac -c:a:1 ac3 -c:a:2 aac -shortest $src 2>$null | Out-Null
    if (Test-Path $src) {
        # meniu 2 (audio-only) → container mkv (2) → audio opus (3); AV_AUDIO_TRACKS=0,2
        $env:AV_AUDIO_TRACKS = "0,2"
        "2`n2`n3`n`n`n" | pwsh -NoProfile -File (Join-Path $tmp 'av_encode.ps1') *>$null
        $env:AV_AUDIO_TRACKS = $null
        $out = Join-Path $tmp 'output\clip_audio.mkv'
        if (Test-Path $out) {
            $oc = ((& ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 $out) -join ' ').Trim()
            Assert-Eq "opus ac3 opus" $oc "end-to-end audio-only 0,2: a:0+a:2 opus, a:1 copy ac3"
        } else {
            Assert-Eq "output" "lipsa" "end-to-end audio-only: output generat"
        }
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Invoke-TestSummary
