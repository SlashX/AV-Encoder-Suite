#!/usr/bin/env bash
# v69 — HDR10+ pe APV: engine apv_hdr10plus.py + integrare suite.
#   Source-level: helperi av_common (_apv_hdr10plus_*), dispatch apv in
#   _check_hdr10plus_tool_for + extract_hdr10plus_metadata, probe in
#   detect_source_info, hook post-encode + reset defensiv in run_encode_loop,
#   dialog av_encoder_apv (env APV_HDR10PLUS_POLICY), av_check upgrade TYPE.
#   Functional (hermetic): encode liboapv sintetic → inject (JSON sintetic) →
#   probe/extract round-trip + CBS passthrough + idempotenta + count mismatch.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
APVENC="$(cat "$SCRIPT_DIR/av_encoder_apv.sh")"
CHECK="$(cat "$SCRIPT_DIR/av_check.sh")"

# ── 1. Engine prezent ───────────────────────────────────────────────
assert_file_exists "$SCRIPT_DIR/apv_hdr10plus.py" "engine apv_hdr10plus.py exista"
ENGINE="$(cat "$SCRIPT_DIR/apv_hdr10plus.py")"
assert_contains "$ENGINE" 'PBU_METADATA = 66'        "engine: PBU type 66 (metadata)"
assert_contains "$ENGINE" 'b5003c0001'               "engine: prefix T.35 HDR10+ (Samsung 0x003C)"
assert_contains "$ENGINE" 'def align_zero'            "engine: aliniere zero-padding (conventia quietvoid/grader oficial)"
assert_contains "$ENGINE" 'INAINTEA frame-ului'      "engine: metadata PBU inainte de frame (decoderul ffmpeg e secvential)"

# ── 2. Helperi av_common ────────────────────────────────────────────
assert_contains "$COMMON" '_apv_hdr10plus_probe() {'         "av_common: probe definit"
assert_contains "$COMMON" '_apv_hdr10plus_extract() {'       "av_common: extract definit"
assert_contains "$COMMON" '_apv_hdr10plus_inject_output() {' "av_common: inject_output definit"
assert_contains "$COMMON" 'apv) _apv_hdr10plus_engine_py'    "av_common: dispatch apv in _check_hdr10plus_tool_for"
assert_contains "$COMMON" '"$src_codec" == "apv"'            "av_common: ramura apv in extract_hdr10plus_metadata"
assert_contains "$COMMON" 'HDR_PLUS="HDR10+ (APV T.35)"'     "av_common: probe APV in detect_source_info"
assert_contains "$COMMON" '-frames:v 3 -f apv'               "av_common: probe usor (3 AU, nu demux complet)"
assert_contains "$COMMON" '-f apv -framerate "$fps" -i "$injected"' "av_common: re-mux cu -f apv fortat + -framerate explicit (probe-ul cere frame-first; raw APV fara timing)"

# ── 3. run_encode_loop: hook + reset defensiv ───────────────────────
assert_contains "$COMMON" '_apv_hdr10plus_inject_output "$output" "$APV_HDR10PLUS_JSON" "$file"' "run_encode_loop: hook post-encode"
assert_contains "$COMMON" 'APV_HDR10PLUS_JSON=""; APV_HDR10PLUS_INJECT=0' "run_encode_loop: reset defensiv state APV"

# ── 4. Encoder APV: dialog + env policy ─────────────────────────────
assert_contains "$APVENC" 'APV_HDR10PLUS_POLICY'             "av_encoder_apv: env bypass APV_HDR10PLUS_POLICY"
assert_contains "$APVENC" 'Pastreaza HDR10+ (T.35 in bitstream APV)' "av_encoder_apv: optiunea preserve in dialog"
assert_contains "$APVENC" 'APV_HDR10PLUS_JSON=$(extract_hdr10plus_metadata "$file")' "av_encoder_apv: extract la preserve"
assert_contains "$APVENC" 'stratul HDR10+ POATE fi pastrat'  "av_encoder_apv: hibrid DV+HDR10+ pastreaza HDR10+"

# ── 5. av_check: upgrade TYPE ───────────────────────────────────────
assert_contains "$CHECK" '_apv_hdr10plus_probe "$file"'      "av_check: probe APV"
assert_contains "$CHECK" '"$SRC_CODEC" == "apv"'             "av_check: gate pe codec apv"

# ── 5b. Validator OpenAPV: installer + hook soft (optional, tacut) ──
assert_file_exists "$SCRIPT_DIR/tools/openapv_validator.sh"  "tools: installer bash exista"
assert_file_exists "$SCRIPT_DIR/tools/openapv_validator.ps1" "tools: installer PS1 exista"
assert_contains "$COMMON" 'command -v "$AV_TOOL_OAPV_DEC"'   "av_common: hook soft decoder referinta (gate pe prezenta, prin variabila)"
# v69: nume binare/engine centralizate (env-overridable) — sursa unica sus
assert_contains "$COMMON" 'AV_TOOL_OAPV_DEC="${AV_TOOL_OAPV_DEC:-oapv_app_dec}"' "av_common: AV_TOOL_OAPV_DEC definit in blocul de config"
assert_contains "$COMMON" 'AV_ENGINE_APV_HDR10PLUS="${AV_ENGINE_APV_HDR10PLUS:-$SCRIPT_DIR/apv_hdr10plus.py}"' "av_common: calea engine-ului centralizata"
assert_contains "$COMMON" '"$py" "$AV_ENGINE_APV_HDR10PLUS" inject' "av_common: inject prin variabila engine"
assert_contains "$COMMON" 'acceptat si de decoderul de referinta OpenAPV' "av_common: mesaj decode-check referinta"

# ── 6. Functional (hermetic: liboapv + python necesare) ─────────────
if command -v ffmpeg >/dev/null 2>&1 && ffmpeg -hide_banner -encoders 2>/dev/null | grep -qw liboapv \
   && { command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; }; then
    tmpd="$(mktemp -d)"
    trap 'rm -rf "$tmpd"; _test_summary' EXIT
    PY=python3; command -v python3 >/dev/null 2>&1 || PY=python

    # sursa APV sintetica (2 frames) + JSON sintetic (2 entries)
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=0.2:size=160x128:rate=10" \
        -frames:v 2 -c:v liboapv -qp 40 -pix_fmt yuv422p10le "$tmpd/src.mp4" 2>/dev/null
    cat > "$tmpd/meta.json" <<'EOF'
{"SceneInfo":[
{"BezierCurveData":{"Anchors":[102,205,307],"KneePointX":10,"KneePointY":20},"LuminanceParameters":{"AverageRGB":500,"LuminanceDistributions":{"DistributionIndex":[1,5,10,25,50,75,90,95,99],"DistributionValues":[1,2,3,4,5,6,7,8,9]},"MaxScl":[1000,1100,1200]},"NumberOfWindows":1,"TargetedSystemDisplayMaximumLuminance":400},
{"BezierCurveData":{"Anchors":[110,210,310],"KneePointX":11,"KneePointY":21},"LuminanceParameters":{"AverageRGB":600,"LuminanceDistributions":{"DistributionIndex":[1,5,10,25,50,75,90,95,99],"DistributionValues":[9,8,7,6,5,4,3,2,1]},"MaxScl":[2000,2100,2200]},"NumberOfWindows":1,"TargetedSystemDisplayMaximumLuminance":450}
]}
EOF

    if [[ -s "$tmpd/src.mp4" ]]; then
        source "$SCRIPT_DIR/av_common.sh" 2>/dev/null
        LOG_FILE="$tmpd/test.log"; CONTAINER=mp4

        # inject post-encode in-place (cu MDCV/CLL din defaults — sursa e SDR sintetic)
        cp -f "$tmpd/src.mp4" "$tmpd/out.mp4"
        _apv_hdr10plus_inject_output "$tmpd/out.mp4" "$tmpd/meta.json" "$tmpd/src.mp4" >/dev/null 2>&1
        assert_zero $? "functional: inject_output rc=0 (cu verificare probe interna)"
        assert_eq "hdr10plus" "$(_apv_hdr10plus_probe "$tmpd/out.mp4")" "functional: probe → hdr10plus"
        assert_eq "none" "$(_apv_hdr10plus_probe "$tmpd/src.mp4")" "functional: sursa ne-injectata → none"

        # detect_source_info vede HDR10+ pe APV
        detect_source_info "$tmpd/out.mp4" >/dev/null 2>&1
        assert_eq "HDR10+ (APV T.35)" "$HDR_PLUS" "functional: detect_source_info → HDR_PLUS setat"

        # extract round-trip: valorile JSON supravietuiesc
        ej=$(_apv_hdr10plus_extract "$tmpd/out.mp4")
        assert_eq "1" "$([[ -n "$ej" && -s "$ej" ]] && echo 1 || echo 0)" "functional: extract intoarce JSON ne-gol"
        # caile ca sys.argv (MSYS le converteste pe argumente, NU in stringul -c)
        rt=$("$PY" -c "
import json, sys
a=json.load(open(sys.argv[1]))['SceneInfo']
b=json.load(open(sys.argv[2]))['SceneInfo']
ok=(len(a)==len(b)==2
    and b[0]['LuminanceParameters']['AverageRGB']==500
    and b[1]['LuminanceParameters']['AverageRGB']==600
    and b[0]['BezierCurveData']['Anchors']==[102,205,307]
    and b[1]['TargetedSystemDisplayMaximumLuminance']==450
    and b[1]['LuminanceParameters']['MaxScl']==[2000,2100,2200])
print('OK' if ok else 'FAIL')" "$tmpd/meta.json" "$ej" 2>/dev/null)
        assert_eq "OK" "$rt" "functional: extract round-trip — toate valorile identice"
        rm -f "$ej"

        # CBS passthrough (al doilea parser independent) accepta bitstream-ul injectat
        ffmpeg -v error -y -i "$tmpd/out.mp4" -c:v copy -bsf:v apv_metadata -f apv "$tmpd/cbs.apv" 2>/dev/null
        assert_zero $? "functional: CBS apv_metadata passthrough exit 0"

        # MDCV/CLL din bitstream vizibile in ffprobe (metadata INAINTE de frame)
        sd=$(ffprobe -v error -select_streams v:0 -show_entries frame_side_data=side_data_type \
            -read_intervals "%+#1" -of compact "$tmpd/out.mp4" 2>/dev/null | tr -d '\r')
        assert_contains "$sd" "Mastering display" "functional: MDCV din bitstream vizibil in ffprobe"

        # idempotenta: inject de 2 ori → tot 1 payload HDR10+ per AU (curata vechiul)
        _apv_hdr10plus_inject_output "$tmpd/out.mp4" "$tmpd/meta.json" "$tmpd/src.mp4" >/dev/null 2>&1
        raw2="$tmpd/recheck.apv"
        ffmpeg -v error -y -i "$tmpd/out.mp4" -map 0:v:0 -c:v copy -f apv "$raw2" 2>/dev/null
        pr=$("$PY" "$SCRIPT_DIR/apv_hdr10plus.py" probe -i "$raw2" 2>/dev/null)
        assert_eq "hdr10plus frames=2 hdr10plus=2 mdcv=2 cll=2" "$pr" "functional: idempotent — 1 set metadata per AU dupa dublu inject"

        # count mismatch → eroare onesta (JSON 1 entry vs 2 AU)
        cat > "$tmpd/meta1.json" <<'EOF'
{"SceneInfo":[{"LuminanceParameters":{"AverageRGB":500,"LuminanceDistributions":{"DistributionIndex":[1,50,99],"DistributionValues":[1,5,9]},"MaxScl":[1000,1100,1200]},"NumberOfWindows":1,"TargetedSystemDisplayMaximumLuminance":400}]}
EOF
        ffmpeg -v error -y -i "$tmpd/src.mp4" -map 0:v:0 -c:v copy -f apv "$tmpd/raw.apv" 2>/dev/null
        if "$PY" "$SCRIPT_DIR/apv_hdr10plus.py" inject -i "$tmpd/raw.apv" -j "$tmpd/meta1.json" -o "$tmpd/bad.apv" 2>/dev/null; then
            assert_eq "fail" "ok" "functional: count mismatch trebuia sa esueze"
        else
            assert_eq 1 1 "functional: count mismatch (1 JSON vs 2 AU) → eroare onesta"
        fi
    else
        skip_test "liboapv nu a produs fisierul sintetic"
    fi
else
    echo "  (functional sarit: ffmpeg cu liboapv sau python lipsesc)"
fi
true
