#!/usr/bin/env bash
# v64 — DNxHR + ProRes corectitudine (validat empiric cu ffmpeg real, prima testare functionala):
#   DNxHR LB/SQ/HQ cer 8-bit yuv422p (10-bit = "incompatible with DNxHR LB/SQ/HQ" → 0 output);
#                  HQX = yuv422p10le (build 10-bit max; 12le coboara tacut).
#   ProRes: FARA -bits_per_mb (8000=max umfla toate profilele egal, proxy ~16x peste nominal);
#           XQ = profil 5 nativ (tag "XQ"), NU profil 4 + qscale (acela scrie tag "4444").
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

DNX="$(cat "$SCRIPT_DIR/av_encoder_dnxhr.sh")"
PRO="$(cat "$SCRIPT_DIR/av_encoder_prores.sh")"
COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
ENC_PS1="$(cat "$SCRIPT_DIR/av_encode.ps1")"
LAUNCHER="$(cat "$SCRIPT_DIR/av_launcher.sh")"
AVCHK="$(cat "$SCRIPT_DIR/av_check.sh")"
AVCHK_PS1="$(cat "$SCRIPT_DIR/av_check.ps1")"

# ── 1. DNxHR bash — pixfmt corect per profil ──────────────────────────
assert_contains "$DNX" 'lb)  pixfmt="yuv422p";'      "dnxhr: LB = 8-bit yuv422p"
assert_contains "$DNX" 'sq)  pixfmt="yuv422p";'      "dnxhr: SQ = 8-bit yuv422p"
assert_contains "$DNX" 'hq)  pixfmt="yuv422p";'      "dnxhr: HQ = 8-bit yuv422p"
assert_contains "$DNX" 'hqx) pixfmt="yuv422p10le";'  "dnxhr: HQX = 10-bit yuv422p10le"
assert_contains "$DNX" '444) pixfmt="yuv444p10le";'  "dnxhr: 444 = 10-bit yuv444p10le"
assert_not_contains "$DNX" 'yuv422p12le'             "dnxhr: NU mai foloseste 12le (build 10-bit max)"
assert_not_contains "$DNX" 'lb)  pixfmt="yuv422p10le"' "dnxhr: LB NU mai e 10-bit (regresie rupta)"

# ── 2. DNxHR PS1 — paritate pixfmt ────────────────────────────────────
assert_contains "$ENC_PS1" '"hqx" { "yuv422p10le" } "444" { "yuv444p10le" } default { "yuv422p" }' "dnxhr PS1: pixfmt corect (default yuv422p, hqx 10le)"

# ── 3. ProRes bash — fara bits_per_mb, XQ = profil 5 ──────────────────
assert_not_contains "$PRO" 'bits_per_mb 8000'        "prores: -bits_per_mb 8000 SCOS"
assert_not_contains "$PRO" '-qscale:v 1'             "prores: qscale hack SCOS"
assert_contains "$PRO" 'xq|4444xq) profile_num=5'    "prores: XQ = profil 5 nativ (tag XQ)"
assert_contains "$PRO" '4444)      profile_num=4'    "prores: 4444 = profil 4"

# ── 4. ProRes PS1 — paritate (xq=5, fara bits_per_mb) ─────────────────
assert_contains "$ENC_PS1" '"xq" { 5 } "4444xq" { 5 }' "prores PS1: XQ = profil 5"
assert_not_contains "$ENC_PS1" '"-bits_per_mb","8000"'  "prores PS1: bits_per_mb SCOS"
assert_not_contains "$ENC_PS1" '$xqFlag'                "prores PS1: xqFlag SCOS"

# ── 5. Launcher + schema — token canonic xq ───────────────────────────
assert_contains "$LAUNCHER" '6) PRORES_PROFILE="xq";'   "launcher: optiunea 6 = xq (nu 4444xq → cadea pe HQ)"
assert_contains "$COMMON" 'enum:,proxy,lt,standard,hq,4444,xq,4444xq' "schema bash: accepta xq + 4444xq"
assert_contains "$ENC_PS1" "enum:,proxy,lt,standard,hq,4444,xq,4444xq" "schema PS1: accepta xq + 4444xq"

# ── 6. Avertismente DNxHR LOG/HDR pe profil 8-bit ─────────────────────
assert_contains "$DNX" "Recomandat pentru Log: profil HQX sau 444"  "dnxhr: warning LOG 8-bit -> HQX/444"
assert_contains "$DNX" '"$DNXHR_PROFILE" != "hqx" && "$DNXHR_PROFILE" != "444"' "dnxhr: HDR/HLG accepta si 444 (nu doar hqx)"
assert_not_contains "$DNX" "va converti la SDR range"               "dnxhr: mesaj gresit SDR-range scos"
assert_contains "$ENC_PS1" 'si.isHDR -or $si.isHLG'                 "dnxhr PS1: warning acopera si HLG (paritate)"
assert_contains "$ENC_PS1" "Recomandat pentru Log: profil HQX sau 444" "dnxhr PS1: warning LOG 8-bit"

# ── 6b. Avertismente DV / HDR10+ (mezzanine nu pastreaza metadata dinamica) ──
assert_contains "$DNX" "DV + HDR10+ (hibrid) detectat"             "dnxhr: warning hibrid DV+HDR10+"
assert_contains "$DNX" "DNxHR NU pastreaza RPU-ul DV"              "dnxhr: warning DV (RPU pierdut)"
assert_contains "$DNX" "metadata dinamica (SMPTE2094-40) NU se pastreaza" "dnxhr: warning HDR10+"
assert_contains "$PRO" "ProRes NU pastreaza RPU-ul DV"            "prores: warning DV (RPU pierdut)"
assert_contains "$PRO" "DV + HDR10+ (hibrid) detectat"            "prores: warning hibrid"
assert_contains "$ENC_PS1" 'logInfo.isDV -and $si.isHDRPlus'      "PS1: garda hibrid DV+HDR10+"
assert_contains "$ENC_PS1" "DNxHR NU pastreaza RPU-ul DV"         "PS1 dnxhr: warning DV"
assert_contains "$ENC_PS1" "ProRes NU pastreaza RPU-ul DV"        "PS1 prores: warning DV"

# ── 6c. av_check — eticheta prietenoasa DNxHR (paritate cu ProRes) ────
assert_contains "$AVCHK"     '"DNXHR HQ")  fmt="Avid DNxHR HQ"'   "av_check.sh: dnxhd -> Avid DNxHR <profil> (v74)"
assert_contains "$AVCHK_PS1" '"DNXHR HQ"  { "Avid DNxHR HQ" }'    "av_check.ps1: dnxhd -> Avid DNxHR <profil> (v74)"

# ── 6d. MXF audio = PCM (AAC default + MXF ar pica) ───────────────────
assert_contains "$LAUNCHER" "MXF suporta doar audio PCM"           "launcher: constrangere MXF audio PCM"
assert_contains "$LAUNCHER" 'CONTAINER" == "mxf" ]] && [[ "$AUDIO_CODEC_ARG" != pcm:*' "launcher: garda MXF non-PCM"
assert_contains "$ENC_PS1"  "MXF suporta doar audio PCM"           "PS1: constrangere MXF audio PCM"
assert_contains "$ENC_PS1"  'container -eq "mxf" -and $audioCodec -ne "pcm"' "PS1: garda MXF non-PCM"

# ── 7. Functional — encodeaza real fiecare profil ─────────────────────
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    tmpd="$(mktemp -d)"
    trap 'rm -rf "$tmpd"; _test_summary' EXIT
    src="$tmpd/src.mp4"
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" \
        -f lavfi -i "sine=frequency=440:duration=1" \
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast \
        -x265-params "log-level=none" -c:a aac -shortest "$src" 2>/dev/null
    if [[ -s "$src" ]]; then
        opf() { ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -1; }
        oprof() { ffprobe -v error -select_streams v:0 -show_entries stream=profile -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -1; }

        # (a) DNxHR SQ cu 8-bit yuv422p → OK
        ffmpeg -v error -y -t 1 -i "$src" -an -c:v dnxhd -profile:v dnxhr_sq -pix_fmt yuv422p "$tmpd/sq.mov" 2>/dev/null
        assert_file_exists "$tmpd/sq.mov" "functional: DNxHR SQ + yuv422p produce output"
        assert_eq "yuv422p" "$(opf "$tmpd/sq.mov")" "functional: DNxHR SQ out = yuv422p"

        # (b) DNxHR SQ cu 10-bit (vechiul cod) → RESPINS, fara output (regresia critica)
        ffmpeg -v error -y -t 1 -i "$src" -an -c:v dnxhd -profile:v dnxhr_sq -pix_fmt yuv422p10le "$tmpd/sq_bad.mov" 2>/dev/null
        if [[ -s "$tmpd/sq_bad.mov" ]]; then bad=1; else bad=0; fi
        assert_eq "0" "$bad" "functional: DNxHR SQ + 10-bit RESPINS (dovedeste de ce fix-ul conteaza)"

        # (c) DNxHR HQX (10-bit) + 444 (10-bit 4:4:4) → OK
        ffmpeg -v error -y -t 1 -i "$src" -an -c:v dnxhd -profile:v dnxhr_hqx -pix_fmt yuv422p10le "$tmpd/hqx.mov" 2>/dev/null
        assert_eq "yuv422p10le" "$(opf "$tmpd/hqx.mov")" "functional: DNxHR HQX out = yuv422p10le"
        ffmpeg -v error -y -t 1 -i "$src" -an -c:v dnxhd -profile:v dnxhr_444 -pix_fmt yuv444p10le "$tmpd/444.mov" 2>/dev/null
        assert_eq "yuv444p10le" "$(opf "$tmpd/444.mov")" "functional: DNxHR 444 out = yuv444p10le"

        # (d) ProRes XQ = profil 5 → tag stream "XQ" (vechiul cod scria "4444")
        ffmpeg -v error -y -t 1 -i "$src" -an -c:v prores_ks -profile:v 5 -pix_fmt yuva444p10le -vendor apl0 "$tmpd/xq.mov" 2>/dev/null
        assert_eq "XQ" "$(oprof "$tmpd/xq.mov")" "functional: ProRes profil 5 → tag XQ"
        # (e) ProRes proxy = profil 0 → tag "Proxy"
        ffmpeg -v error -y -t 1 -i "$src" -an -c:v prores_ks -profile:v 0 -pix_fmt yuv422p10le -vendor apl0 "$tmpd/proxy.mov" 2>/dev/null
        assert_eq "Proxy" "$(oprof "$tmpd/proxy.mov")" "functional: ProRes profil 0 → tag Proxy"

        # (f) MXF: audio comprimat (AAC) esueaza (pcm_rechunk), PCM merge — de ce exista garda
        ffmpeg -v error -y -t 1 -i "$src" -c:v dnxhd -profile:v dnxhr_hqx -pix_fmt yuv422p10le -c:a aac "$tmpd/mxf_aac.mxf" 2>/dev/null
        if [[ -s "$tmpd/mxf_aac.mxf" ]]; then mxfaac=1; else mxfaac=0; fi
        assert_eq "0" "$mxfaac" "functional: MXF + AAC esueaza (de ce garda PCM conteaza)"
        ffmpeg -v error -y -t 1 -i "$src" -c:v dnxhd -profile:v dnxhr_hqx -pix_fmt yuv422p10le -c:a pcm_s16le "$tmpd/mxf_pcm.mxf" 2>/dev/null
        assert_file_exists "$tmpd/mxf_pcm.mxf" "functional: MXF + PCM produce output"
    fi
fi

# ── v94 (O4): ProRes si APV pierdeau semnalizarea de culoare a sursei ──
# Ambele isi scriu propriul atom/header si ignora `-color_*` (verificat) → sursa
# bt709/bt709/bt709 ieseа bt709/smpte170m/unknown. Reparat cu bsf-urile dedicate.
# DNxHR nu are bsf — acolo gamut-ul se pastreaza doar pe MXF (limitare v74).
PR_SRC="$(cat "$SCRIPT_DIR/av_encoder_prores.sh")"
APV_SRC="$(cat "$SCRIPT_DIR/av_encoder_apv.sh")"
assert_contains "$PR_SRC"  '_mezz_color_bsf prores' "O4: ProRes cere bsf-ul de culoare"
assert_contains "$PR_SRC"  '$_pr_color_bsf'         "O4: ProRes il injecteaza in comanda"
assert_contains "$APV_SRC" '_mezz_color_bsf apv'    "O4: APV cere bsf-ul de culoare"
assert_contains "$APV_SRC" '$_apv_color_bsf'        "O4: APV il injecteaza in comanda"

if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    source "$SCRIPT_DIR/av_common.sh" 2>/dev/null
    tmpo="$(mktemp -d)"
    # sursa cu culoare COMPLETA (via -x264-params: `-color_*` nu propaga in VUI, regula v62)
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=256x256:rate=10" \
        -c:v libx264 -preset ultrafast -x264-params "colorprim=bt709:transfer=bt709:colormatrix=bt709" \
        "$tmpo/full.mp4" 2>/dev/null
    bsf_pr=$(_mezz_color_bsf prores "$tmpo/full.mp4")
    bsf_apv=$(_mezz_color_bsf apv "$tmpo/full.mp4")
    assert_contains "$bsf_pr"  "prores_metadata=color_primaries=bt709:color_trc=bt709:colorspace=bt709" \
        "O4: ProRes → bsf cu numele culorii sursei"
    assert_contains "$bsf_apv" "apv_metadata=color_primaries=1:transfer_characteristics=1:matrix_coefficients=1" \
        "O4: APV → bsf cu coduri H.273"
    # sursa care NU declara culoarea → GOL (nu inventam)
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=256x256:rate=10" \
        -c:v libx264 -preset ultrafast "$tmpo/plain.mp4" 2>/dev/null
    assert_eq "" "$(_mezz_color_bsf prores "$tmpo/plain.mp4")" "O4: sursa fara culoare → bsf gol (ProRes)"
    assert_eq "" "$(_mezz_color_bsf apv    "$tmpo/plain.mp4")" "O4: sursa fara culoare → bsf gol (APV)"
    assert_eq "" "$(_mezz_color_bsf prores)"                   "O4: fara fisier → bsf gol"
    # functional: bsf-ul chiar produce eticheta corecta prin eval (calea reala de encode)
    # shellcheck disable=SC2086
    eval "ffmpeg -v error -y -t 1 -i \"$tmpo/full.mp4\" -an -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le $bsf_pr \"$tmpo/pr.mov\"" 2>/dev/null
    trc=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 "$tmpo/pr.mov" 2>/dev/null | tr -d '\r')
    assert_eq "bt709" "$trc" "O4 functional: ProRes + bsf prin eval → transfer=bt709"
    rm -rf "$tmpo"
fi
true
