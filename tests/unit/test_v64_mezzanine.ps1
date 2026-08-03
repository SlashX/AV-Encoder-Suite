# v64 — DNxHR + ProRes corectitudine (mirror al test_v64_mezzanine.sh).
#   DNxHR LB/SQ/HQ = 8-bit yuv422p (10-bit respins); HQX = yuv422p10le.
#   ProRes: fara -bits_per_mb; XQ = profil 5 nativ (tag "XQ").
#   v94 (O4): + bsf-urile de culoare pentru ProRes/APV.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$DNX     = Get-Content (Join-Path $SRC "av_encoder_dnxhr.sh") -Raw
$PRO     = Get-Content (Join-Path $SRC "av_encoder_prores.sh") -Raw
$COMMON  = Get-Content (Join-Path $SRC "av_common.sh") -Raw
$ENC     = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
$LAUNCH  = Get-Content (Join-Path $SRC "av_launcher.sh") -Raw
$AVCHK   = Get-Content (Join-Path $SRC "av_check.sh") -Raw
$AVCHKP  = Get-Content (Join-Path $SRC "av_check.ps1") -Raw

# ── 1. DNxHR bash — pixfmt corect per profil ──────────────────────────
Assert-Match $DNX ([regex]::Escape('lb)  pixfmt="yuv422p";'))     "dnxhr: LB = 8-bit yuv422p"
Assert-Match $DNX ([regex]::Escape('sq)  pixfmt="yuv422p";'))     "dnxhr: SQ = 8-bit yuv422p"
Assert-Match $DNX ([regex]::Escape('hq)  pixfmt="yuv422p";'))     "dnxhr: HQ = 8-bit yuv422p"
Assert-Match $DNX ([regex]::Escape('hqx) pixfmt="yuv422p10le";')) "dnxhr: HQX = 10-bit yuv422p10le"
Assert-Eq $false ([bool]($DNX -match 'yuv422p12le'))             "dnxhr: NU mai foloseste 12le"

# ── 2. DNxHR PS1 — paritate pixfmt ────────────────────────────────────
Assert-Match $ENC ([regex]::Escape('"hqx" { "yuv422p10le" } "444" { "yuv444p10le" } default { "yuv422p" }')) "dnxhr PS1: pixfmt corect"

# ── 3. ProRes bash — fara bits_per_mb, XQ = profil 5 ──────────────────
Assert-Eq $false ([bool]($PRO -match 'bits_per_mb 8000'))        "prores: -bits_per_mb 8000 SCOS"
Assert-Eq $false ([bool]($PRO -match '-qscale:v 1'))             "prores: qscale hack SCOS"
Assert-Match $PRO ([regex]::Escape('xq|4444xq) profile_num=5'))  "prores: XQ = profil 5 nativ"

# ── 4. ProRes PS1 — paritate ──────────────────────────────────────────
Assert-Match $ENC ([regex]::Escape('"xq" { 5 } "4444xq" { 5 }')) "prores PS1: XQ = profil 5"
Assert-Eq $false ([bool]($ENC -match ([regex]::Escape('"-bits_per_mb","8000"')))) "prores PS1: bits_per_mb SCOS"
Assert-Eq $false ([bool]($ENC -match ([regex]::Escape('$xqFlag'))))                "prores PS1: xqFlag SCOS"

# ── 5. Launcher + scheme — token canonic xq ───────────────────────────
Assert-Match $LAUNCH ([regex]::Escape('6) PRORES_PROFILE="xq";'))                  "launcher: optiunea 6 = xq"
Assert-Match $COMMON ([regex]::Escape('enum:,proxy,lt,standard,hq,4444,xq,4444xq')) "schema bash: xq + 4444xq"
Assert-Match $ENC    ([regex]::Escape('enum:,proxy,lt,standard,hq,4444,xq,4444xq')) "schema PS1: xq + 4444xq"

# ── 6. Avertismente DNxHR LOG/HDR pe profil 8-bit ─────────────────────
Assert-Match $DNX ([regex]::Escape('Recomandat pentru Log: profil HQX sau 444'))            "dnxhr: warning LOG 8-bit"
Assert-Match $DNX ([regex]::Escape('"$DNXHR_PROFILE" != "hqx" && "$DNXHR_PROFILE" != "444"')) "dnxhr: HDR/HLG accepta si 444"
Assert-Eq $false ([bool]($DNX -match 'va converti la SDR range'))                            "dnxhr: mesaj SDR-range scos"
Assert-Match $ENC ([regex]::Escape('si.isHDR -or $si.isHLG'))                                "dnxhr PS1: warning acopera HLG"
Assert-Match $ENC ([regex]::Escape('Recomandat pentru Log: profil HQX sau 444'))            "dnxhr PS1: warning LOG 8-bit"

# ── 6b. Avertismente DV / HDR10+ (mezzanine nu pastreaza metadata dinamica) ──
Assert-Match $DNX ([regex]::Escape('DV + HDR10+ (hibrid) detectat'))   "dnxhr: warning hibrid DV+HDR10+"
Assert-Match $DNX ([regex]::Escape('DNxHR NU pastreaza RPU-ul DV'))    "dnxhr: warning DV"
Assert-Match $DNX ([regex]::Escape('metadata dinamica (SMPTE2094-40) NU se pastreaza')) "dnxhr: warning HDR10+"
Assert-Match $PRO ([regex]::Escape('ProRes NU pastreaza RPU-ul DV'))   "prores: warning DV"
Assert-Match $PRO ([regex]::Escape('DV + HDR10+ (hibrid) detectat'))   "prores: warning hibrid"
Assert-Match $ENC ([regex]::Escape('$logInfo.isDV -and $si.isHDRPlus')) "PS1: garda hibrid"
Assert-Match $ENC ([regex]::Escape('DNxHR NU pastreaza RPU-ul DV'))    "PS1 dnxhr: warning DV"
Assert-Match $ENC ([regex]::Escape('ProRes NU pastreaza RPU-ul DV'))   "PS1 prores: warning DV"

# ── 6c. av_check — eticheta prietenoasa DNxHR (paritate cu ProRes) ────
Assert-Match $AVCHK  ([regex]::Escape('"DNXHR HQ")  fmt="Avid DNxHR HQ"'))   "av_check.sh: dnxhd -> Avid DNxHR <profil> (v74)"
Assert-Match $AVCHKP ([regex]::Escape('"DNXHR HQ"  { "Avid DNxHR HQ" }'))    "av_check.ps1: dnxhd -> Avid DNxHR <profil> (v74)"

# ── 6d. MXF audio = PCM (AAC default + MXF ar pica) ───────────────────
Assert-Match $LAUNCH ([regex]::Escape('MXF suporta doar audio PCM'))                       "launcher: constrangere MXF audio PCM"
Assert-Match $LAUNCH ([regex]::Escape('CONTAINER" == "mxf" ]] && [[ "$AUDIO_CODEC_ARG" != pcm:*')) "launcher: garda MXF non-PCM"
Assert-Match $ENC    ([regex]::Escape('MXF suporta doar audio PCM'))                       "PS1: constrangere MXF audio PCM"
Assert-Match $ENC    ([regex]::Escape('container -eq "mxf" -and $audioCodec -ne "pcm"'))   "PS1: garda MXF non-PCM"

# ── 7. Functional — encodeaza real fiecare profil ─────────────────────
if ((Get-Command ffmpeg -EA SilentlyContinue) -and (Get-Command ffprobe -EA SilentlyContinue)) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v64mez_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $src = Join-Path $tmp "src.mp4"
    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" `
        -f lavfi -i "sine=frequency=440:duration=1" `
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast -x265-params "log-level=none" -c:a aac -shortest $src 2>$null | Out-Null
    if (Test-Path $src) {
        function _opf($f)   { (& ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 $f 2>$null | Select-Object -First 1) }
        function _oprof($f) { (& ffprobe -v error -select_streams v:0 -show_entries stream=profile -of default=noprint_wrappers=1:nokey=1 $f 2>$null | Select-Object -First 1) }

        # (a) DNxHR SQ + 8-bit yuv422p → OK
        $sq = Join-Path $tmp "sq.mov"
        & ffmpeg -v error -y -t 1 -i $src -an -c:v dnxhd -profile:v dnxhr_sq -pix_fmt yuv422p $sq 2>$null | Out-Null
        Assert-Eq $true (Test-Path $sq)        "functional: DNxHR SQ + yuv422p produce output"
        Assert-Eq "yuv422p" (_opf $sq)         "functional: DNxHR SQ out = yuv422p"

        # (b) DNxHR SQ + 10-bit (vechiul cod) → RESPINS (regresia critica)
        $sqBad = Join-Path $tmp "sq_bad.mov"
        & ffmpeg -v error -y -t 1 -i $src -an -c:v dnxhd -profile:v dnxhr_sq -pix_fmt yuv422p10le $sqBad 2>$null | Out-Null
        $bad = (Test-Path $sqBad) -and ((Get-Item $sqBad).Length -gt 0)
        Assert-Eq $false $bad                  "functional: DNxHR SQ + 10-bit RESPINS (de ce conteaza fix-ul)"

        # (c) DNxHR HQX + 444
        $hqx = Join-Path $tmp "hqx.mov"
        & ffmpeg -v error -y -t 1 -i $src -an -c:v dnxhd -profile:v dnxhr_hqx -pix_fmt yuv422p10le $hqx 2>$null | Out-Null
        Assert-Eq "yuv422p10le" (_opf $hqx)    "functional: DNxHR HQX out = yuv422p10le"
        $p444 = Join-Path $tmp "444.mov"
        & ffmpeg -v error -y -t 1 -i $src -an -c:v dnxhd -profile:v dnxhr_444 -pix_fmt yuv444p10le $p444 2>$null | Out-Null
        Assert-Eq "yuv444p10le" (_opf $p444)   "functional: DNxHR 444 out = yuv444p10le"

        # (d) ProRes XQ = profil 5 → tag "XQ"
        $xq = Join-Path $tmp "xq.mov"
        & ffmpeg -v error -y -t 1 -i $src -an -c:v prores_ks -profile:v 5 -pix_fmt yuva444p10le -vendor apl0 $xq 2>$null | Out-Null
        Assert-Eq "XQ" (_oprof $xq)            "functional: ProRes profil 5 → tag XQ"
        # (e) ProRes proxy = profil 0 → tag "Proxy"
        $px = Join-Path $tmp "proxy.mov"
        & ffmpeg -v error -y -t 1 -i $src -an -c:v prores_ks -profile:v 0 -pix_fmt yuv422p10le -vendor apl0 $px 2>$null | Out-Null
        Assert-Eq "Proxy" (_oprof $px)         "functional: ProRes profil 0 → tag Proxy"

        # (f) MXF: audio comprimat (AAC) esueaza (pcm_rechunk), PCM merge — de ce exista garda
        $mxfAac = Join-Path $tmp "mxf_aac.mxf"
        & ffmpeg -v error -y -t 1 -i $src -c:v dnxhd -profile:v dnxhr_hqx -pix_fmt yuv422p10le -c:a aac $mxfAac 2>$null | Out-Null
        $mxfAacOk = (Test-Path $mxfAac) -and ((Get-Item $mxfAac -EA SilentlyContinue).Length -gt 0)
        Assert-Eq $false $mxfAacOk             "functional: MXF + AAC esueaza (de ce garda PCM conteaza)"
        $mxfPcm = Join-Path $tmp "mxf_pcm.mxf"
        & ffmpeg -v error -y -t 1 -i $src -c:v dnxhd -profile:v dnxhr_hqx -pix_fmt yuv422p10le -c:a pcm_s16le $mxfPcm 2>$null | Out-Null
        Assert-Eq $true (Test-Path $mxfPcm)    "functional: MXF + PCM produce output"
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ── v94 (O4): ProRes si APV pierdeau semnalizarea de culoare a sursei ──
# Ambele isi scriu propriul atom/header si ignora `-color_*` (verificat) → sursa
# bt709/bt709/bt709 ieseа bt709/smpte170m/unknown. Reparat cu bsf-urile dedicate.
# DNxHR nu are bsf — acolo gamut-ul se pastreaza doar pe MXF (limitare v74).
# NB: $SRC a fost suprascris mai sus de $src (fisier video) — PowerShell e
# case-insensitive la variabile. Folosim $ENC, incarcat la inceputul testului.
$ENCO4 = $ENC
Assert-Match $ENCO4 'function Get-MezzColorBsf' "O4: helperul e definit"
Assert-Match $ENCO4 ([regex]::Escape("Get-MezzColorBsf -Kind 'prores' -File `$f.FullName")) "O4: cablat pe ProRes"
Assert-Match $ENCO4 ([regex]::Escape("Get-MezzColorBsf -Kind 'apv' -File `$f.FullName"))    "O4: cablat pe APV"
Assert-Match $ENCO4 ([regex]::Escape('+ $proresColorBsf')) "O4: bsf-ul intra in ffArgs (ProRes)"
Assert-Match $ENCO4 ([regex]::Escape('+ $apvColorBsf'))    "O4: bsf-ul intra in ffArgs (APV)"

if ((Get-Command ffmpeg -EA SilentlyContinue) -and (Get-Command ffprobe -EA SilentlyContinue)) {
    Import-AvEncodeFunctions -Names @('Get-MezzColorBsf','Get-H273Code')
    $tmpO = Join-Path ([System.IO.Path]::GetTempPath()) ("mezzo4_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmpO | Out-Null
    try {
        # culoarea se pune prin -x264-params (regula v62 — `-color_*` nu propaga in VUI)
        $full = Join-Path $tmpO "full.mp4"
        & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=256x256:rate=10" `
            -c:v libx264 -preset ultrafast -x264-params "colorprim=bt709:transfer=bt709:colormatrix=bt709" `
            $full 2>$null | Out-Null
        $bp = Get-MezzColorBsf -Kind 'prores' -File $full
        $ba = Get-MezzColorBsf -Kind 'apv'    -File $full
        Assert-Match $bp[1] ([regex]::Escape("prores_metadata=color_primaries=bt709:color_trc=bt709:colorspace=bt709")) `
            "O4: ProRes → bsf cu numele culorii sursei"
        Assert-Match $ba[1] ([regex]::Escape("apv_metadata=color_primaries=1:transfer_characteristics=1:matrix_coefficients=1")) `
            "O4: APV → bsf cu coduri H.273"
        # sursa care NU declara culoarea → gol (nu inventam)
        $plain = Join-Path $tmpO "plain.mp4"
        & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=256x256:rate=10" `
            -c:v libx264 -preset ultrafast $plain 2>$null | Out-Null
        Assert-Eq 0 (Get-MezzColorBsf -Kind 'prores' -File $plain).Count "O4: sursa fara culoare → gol (ProRes)"
        Assert-Eq 0 (Get-MezzColorBsf -Kind 'apv'    -File $plain).Count "O4: sursa fara culoare → gol (APV)"
        Assert-Eq 0 (Get-MezzColorBsf -Kind 'prores' -File "").Count     "O4: fara fisier → gol"
        # functional: bsf-ul produce eticheta corecta
        $prOut = Join-Path $tmpO "pr.mov"
        & ffmpeg -v error -y -t 1 -i $full -an -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le @bp $prOut 2>$null | Out-Null
        $trcO4 = (& ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 $prOut 2>$null | Select-Object -First 1)
        Assert-Eq "bt709" "$trcO4".Trim() "O4 functional: ProRes + bsf → transfer=bt709"
    } finally { Remove-Item $tmpO -Recurse -Force -EA SilentlyContinue }
}

Invoke-TestSummary
