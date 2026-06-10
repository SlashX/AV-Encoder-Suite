# v66 — Audio re-encode FIX (mirror al test_v66_audio.sh).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$COMMON = Get-Content (Join-Path $SRC "av_common.sh") -Raw
$ENC    = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw

# ── 1. bash — ordine copy-first ───────────────────────────────────────
Assert-Match $COMMON ([regex]::Escape('-c:a copy -c:a:0 aac -b:a:0 $br'))     "bash: aac copy-first"
Assert-Match $COMMON ([regex]::Escape('-c:a copy -c:a:0 libopus -b:a:0 $br')) "bash: opus copy-first"
Assert-Match $COMMON ([regex]::Escape('-c:a copy -c:a:0 ac3 -b:a:0 $br'))     "bash: ac3 copy-first"
Assert-Eq $false ([bool]($COMMON -match ([regex]::Escape('-b:a:0 $br $downmix_flag -c:a copy')))) "bash: NU mai e vechea ordine"
Assert-Match $COMMON ([regex]::Escape('-filter:a:0 loudnorm=I=-24'))          "bash: loudnorm scopat la a:0"

# ── 2. PS1 — copy-first + loudnorm a:0 ────────────────────────────────
Assert-Match $ENC ([regex]::Escape('@("-c:a","copy","-c:a:0","aac","-b:a:0",$abr)'))     "PS1: aac copy-first"
Assert-Match $ENC ([regex]::Escape('@("-c:a","copy","-c:a:0","libopus","-b:a:0",$abr)')) "PS1: opus copy-first"
Assert-Match $ENC ([regex]::Escape('@("-c:a","copy","-c:a:0","ac3","-b:a:0",$abr)'))     "PS1: ac3 copy-first"
Assert-Match $ENC ([regex]::Escape('@("-filter:a:0","loudnorm=I=-24'))                   "PS1: loudnorm scopat la a:0"
Assert-Eq $false ([bool]($ENC -match ([regex]::Escape('@("-c:a:0","aac","-b:a:0",$abr) + $downmixFlag + @("-c:a","copy")')))) "PS1: NU mai e vechea ordine"
# ── 2b. PS1 — flux audio-only standalone ($eaAP, oglinda av_encoder_audio.sh) ──
#   E mirror-ul PS1 al av_encoder_audio.sh (meniu optiunea 2). Acelasi copy-first.
Assert-Match $ENC ([regex]::Escape('AUDIO-ONLY ENCODER (video copy)'))                          "PS1 standalone: header audio-only prezent"
Assert-Match $ENC ([regex]::Escape('"opus" { @("-c:a","copy","-c:a:0","libopus","-b:a:0",$abr)')) "PS1 standalone: opus copy-first"
Assert-Match $ENC ([regex]::Escape('"eac3" { @("-c:a","copy","-c:a:0","eac3","-b:a:0",$abr)'))   "PS1 standalone: eac3 copy-first"
Assert-Match $ENC ([regex]::Escape('"flac" { @("-c:a","copy","-c:a:0","flac","-compression_level",$eaFlvl)')) "PS1 standalone: flac copy-first"
Assert-Match $ENC ([regex]::Escape('"ac3"  { @("-c:a","copy","-c:a:0","ac3","-b:a:0",$abr)'))    "PS1 standalone: ac3 copy-first"

# ── 3. Functional — pattern-ul reordonat chiar produce codecul ales ───
if ((Get-Command ffmpeg -EA SilentlyContinue) -and (Get-Command ffprobe -EA SilentlyContinue)) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v66au_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $s2 = Join-Path $tmp "s2.mp4"
    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=240x160:rate=10" -f lavfi -i "sine=frequency=440:duration=1" `
        -c:v libx265 -pix_fmt yuv420p -preset ultrafast -x265-params "log-level=none" -c:a aac -shortest $s2 2>$null | Out-Null
    if (Test-Path $s2) {
        function _cn($f) { (& ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $f 2>$null | Select-Object -First 1) }
        # (a) copy-first → opus (sursa aac); ordinea veche ar fi dat aac
        $o = Join-Path $tmp "o.mkv"
        & ffmpeg -v error -y -i $s2 -map 0:v:0 -map 0:a:0 -c:v copy -c:a copy -c:a:0 libopus -b:a:0 128k $o 2>$null | Out-Null
        Assert-Eq "opus" (_cn $o) "functional: copy-first -c:a:0 libopus → OPUS (regresia)"
        # (b) ordinea VECHE (copy last) → aac (dovada de ce conteaza)
        $bad = Join-Path $tmp "bad.mkv"
        & ffmpeg -v error -y -i $s2 -map 0:v:0 -map 0:a:0 -c:v copy -c:a:0 libopus -b:a:0 128k -c:a copy $bad 2>$null | Out-Null
        Assert-Eq "aac" (_cn $bad) "functional: ordinea VECHE (copy last) → AAC (de ce era bug)"
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Invoke-TestSummary
