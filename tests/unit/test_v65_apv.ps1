# v65 — APV rework (mirror al test_v65_apv.sh).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$APV     = Get-Content (Join-Path $SRC "av_encoder_apv.sh") -Raw
$LAUNCH  = Get-Content (Join-Path $SRC "av_launcher.sh") -Raw
$COMMON  = Get-Content (Join-Path $SRC "av_common.sh") -Raw
$ENC     = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw

# ── 1. Encoder bash — nume auto-detect + pixfmt + preset/qp/extra ──────
Assert-Match $APV ([regex]::Escape('grep -qw "liboapv"'))        "apv: auto-detect liboapv"
Assert-Match $APV ([regex]::Escape('grep -qw "libopenapv"'))     "apv: fallback libopenapv"
Assert-Match $APV ([regex]::Escape('-c:v $APV_ENCODER -preset $APV_PRESET -qp $APV_QP')) "apv: comanda cu encoder detectat"
Assert-Match $APV ([regex]::Escape('422_10)  pixfmt="yuv422p10le"'))  "apv: 422_10 -> yuv422p10le"
Assert-Match $APV ([regex]::Escape('4444_10) pixfmt="yuva444p10le"')) "apv: 4444_10 -> yuva444p10le"
Assert-Eq $false ([bool]($APV -match ([regex]::Escape('-preset $APV_PROFILE')))) "apv: NU mai foloseste APV_PROFILE fictiv"
Assert-Eq $false ([bool]($APV -match 'preset light'))            "apv: NU mai are preset inventat 'light'"

# ── 2. Launcher — meniuri + container mkv (nu mxf) + dispatch ─────────
Assert-Match $LAUNCH ([regex]::Escape('profil / pixel format')) "launcher: meniu pixfmt"
Assert-Match $LAUNCH ([regex]::Escape('preset viteza'))         "launcher: meniu preset"
Assert-Match $LAUNCH 'placebo'                                  "launcher: preset placebo"
Assert-Match $LAUNCH ([regex]::Escape('"$APV_PIXFMT" "$APV_PRESET" "$APV_QP" "$APV_EXTRA"')) "launcher: dispatch arg-uri noi"
Assert-Match $LAUNCH ([regex]::Escape('Format container output (APV)')) "launcher: container APV"
Assert-Eq $false ([bool]($LAUNCH -match 'mxf — broadcast profesional')) "launcher: APV nu mai ofera mxf"

# ── 3. Schema bash ────────────────────────────────────────────────────
Assert-Match $COMMON ([regex]::Escape('APV_PIXFMT)           echo "enum:,422_10,422_12,444_10,444_12,4444_10,4444_12"')) "schema: APV_PIXFMT (v74 +4444_12)"
Assert-Match $COMMON ([regex]::Escape('APV_PRESET)           echo "enum:,fastest,fast,medium,slow,placebo"'))     "schema: APV_PRESET real"
Assert-Match $COMMON ([regex]::Escape('APV_QP)               echo "intrange:0,63"')) "schema: APV_QP intrange"
Assert-Eq $false ([bool]($COMMON -match 'APV_PROFILE\)'))       "schema: APV_PROFILE vechi scos"

# ── 4. PS1 paritate completa ──────────────────────────────────────────
Assert-Match $ENC ([regex]::Escape('$useAPV    = ($encChoice -eq "7")')) "PS1: APV optiunea 7"
Assert-Match $ENC ([regex]::Escape('$useAPV    = ($ENCODER -eq "apv")'))  "PS1: APV in profile-load"
Assert-Match $ENC ([regex]::Escape('profil / pixel format'))    "PS1: meniu pixfmt"
Assert-Match $ENC ([regex]::Escape('Container APV'))            "PS1: container APV"
Assert-Match $ENC ([regex]::Escape('@("-c:v",$apvEncoder,"-preset",$apvPreset,"-qp",$apvQp)')) "PS1: comanda encode APV"
Assert-Match $ENC ([regex]::Escape("'APV_PIXFMT'           { 'enum:,422_10,422_12,444_10,444_12,4444_10,4444_12'")) "PS1: schema APV_PIXFMT (v74 +4444_12)"
Assert-Match $ENC ([regex]::Escape('"APV_PIXFMT=$apvPixFmt"')) "PS1: save flow APV"
Assert-Match $ENC ([regex]::Escape("'\bliboapv\b'"))           "PS1: auto-detect liboapv"
Assert-Eq $false ([bool]($ENC -match "'APV_PROFILE'"))         "PS1: APV_PROFILE vechi scos"

# ── 4b. FLAC — avertisment pe mov (nu mai scuteste mezzanine) ─────────
Assert-Match $LAUNCH ([regex]::Escape('flac:* ]] && [[ "$CONTAINER" == "mov" ]]')) "launcher: FLAC warning pe mov"
Assert-Eq $false ([bool]($LAUNCH -match ([regex]::Escape('"$ENCODER_NAME" != "apv"')))) "launcher: FLAC nu mai scuteste apv/prores/dnxhr"
Assert-Match $ENC ([regex]::Escape('audioCodec -eq "flac" -and $container -eq "mov"')) "PS1: FLAC warning pe mov (paritate)"

# ── 4c. Fix-uri adiacente: pcm in schema audio + eticheta progres ─────
Assert-Match $COMMON ([regex]::Escape('ac3:[0-9]+k|pcm:[0-9]+(le|be))?$')) "schema bash: AUDIO_CODEC_ARG pcm"
Assert-Match $ENC    ([regex]::Escape('ac3:[0-9]+k|pcm:[0-9]+(le|be))?'))  "schema PS1: AUDIO_CODEC_ARG pcm"
Assert-Match $COMMON ([regex]::Escape('ENCODER_NAME:-${ENCODER_TYPE:-FFmpeg}')) "progres: eticheta fallback ENCODER_TYPE"

# ── 5. Functional — encode real pe fiecare profil + mxf esueaza ───────
$apvEnc = ""
$encList = & ffmpeg -hide_banner -encoders 2>$null | Out-String
if     ($encList -match '\bliboapv\b')    { $apvEnc = "liboapv" }
elseif ($encList -match '\blibopenapv\b') { $apvEnc = "libopenapv" }
if ($apvEnc -and (Get-Command ffprobe -EA SilentlyContinue)) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v65apv_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $src = Join-Path $tmp "src.mp4"
    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=240x160:rate=5" `
        -f lavfi -i "sine=frequency=440:duration=1" `
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast -x265-params "log-level=none" -c:a aac -shortest $src 2>$null | Out-Null
    if (Test-Path $src) {
        function _prof($f) { (& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,profile -of default=noprint_wrappers=1:nokey=1 $f 2>$null | Select-Object -First 2) -join "/" }
        foreach ($combo in @("yuv422p10le:apv/33","yuv444p10le:apv/55","yuv444p12le:apv/66","yuva444p10le:apv/77")) {
            $pf = $combo.Split(":")[0]; $exp = $combo.Split(":")[1]
            $o = Join-Path $tmp "o.mp4"
            & ffmpeg -v error -y -t 1 -i $src -an -c:v $apvEnc -preset fast -qp 32 -pix_fmt $pf $o 2>$null | Out-Null
            Assert-Eq $exp (_prof $o) "functional: APV $pf -> $exp"
        }
        foreach ($ext in @("mp4","mov","mkv")) {
            $c = Join-Path $tmp "c.$ext"
            & ffmpeg -v error -y -t 1 -i $src -an -c:v $apvEnc -preset fast -qp 32 -pix_fmt yuv422p10le $c 2>$null | Out-Null
            Assert-Eq $true (Test-Path $c) "functional: APV in .$ext produce output"
        }
        $x = Join-Path $tmp "x.mxf"
        & ffmpeg -v error -y -t 1 -i $src -an -c:v $apvEnc -preset fast -qp 32 -pix_fmt yuv422p10le $x 2>$null | Out-Null
        $mxfOk = (Test-Path $x) -and ((Get-Item $x -EA SilentlyContinue).Length -gt 0)
        Assert-Eq $false $mxfOk "functional: APV + mxf esueaza (de ce l-am scos)"
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Invoke-TestSummary
