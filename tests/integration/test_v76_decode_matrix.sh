#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# v76 — matrice DECODE-survival + fidelitate-exacta metadata (bash). Mirror PS1.
# COMPLEMENTAR fata de test_v75_metadata_matrix (structural: verify_dv_survived
# re-extract + dvcC + containere) si test_v72_dvcc_matrix (1 decode). Aici: DECODE
# dav1d real pe TOATA matricea AV1 (singura dovada ca av1_dv_t35_repair.py mode=dv/
# hdr10plus merge la decoder — re-extract e fals-pozitiv pe AV1, av1dovi tolereaza
# propriul output buggy) + scene-count HDR10+ EXACT (out==sursa, prinde frame-mismatch).
# Encode REAL (svtav1/x265/liboapv) pe clipuri 2s scalate. Auto-skip pe tools/sample.
# Nu foloseste mkvextract → ruleaza functional si pe MSYS (spre deosebire de P7).
# ══════════════════════════════════════════════════════════════════════
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

PY=""; for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done
[ -z "$PY" ] && skip_test "python lipsa"
T35="$SCRIPT_DIR/av1_dv_t35_repair.py"
APVENG="$SCRIPT_DIR/apv_hdr10plus.py"
for t in ffmpeg ffprobe dovi_tool hdr10plus_tool av1dovi_tool av1hdr10plus_tool; do
    command -v "$t" >/dev/null 2>&1 || skip_test "unealta lipsa: $t"
done
S_HEVC_HP="$SCRIPT_DIR/Upload_S02E01_HDR10Plus_40s_HEVC.mp4"
S_AV1_HP="$SCRIPT_DIR/Upload_S02E01_HDR10Plus_40s_AV1.mkv"
S_AV1_DV="$SCRIPT_DIR/Upload_S02E01_DV_40s_AV1.mkv"
for f in "$S_HEVC_HP" "$S_AV1_HP" "$S_AV1_DV"; do
    [ -f "$f" ] || skip_test "sample lipsa: $(basename "$f")"
done
SVT_APV=0; ffmpeg -hide_banner -encoders 2>/dev/null | grep -qw liboapv && SVT_APV=1

WS="$(mktemp -d)"
trap 'rm -rf "$WS"; _test_summary' EXIT

# ── helpers ───────────────────────────────────────────────────────────
seg()       { ffmpeg -y -v error -i "$1" -t 2 -map 0:v:0 -c copy "$WS/$2.${1##*.}" 2>/dev/null; echo "$WS/$2.${1##*.}"; }
raw_hevc()  { ffmpeg -y -v error -i "$1" -c copy -bsf:v hevc_mp4toannexb -f hevc "$WS/$2.hevc" 2>/dev/null; echo "$WS/$2.hevc"; }
raw_av1()   { ffmpeg -y -v error -i "$1" -c copy -f ivf "$WS/$2.ivf" 2>/dev/null; echo "$WS/$2.ivf"; }
enc_hevc()  { local c="$WS/$2.mp4"; ffmpeg -y -v error -i "$1" -c:v libx265 -preset ultrafast -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" -pix_fmt yuv420p10le "$c" 2>/dev/null; ffmpeg -y -v error -i "$c" -c copy -bsf:v hevc_mp4toannexb -f hevc "$WS/$2.hevc" 2>/dev/null; echo "$WS/$2.hevc"; }
enc_av1()   { local c="$WS/$2.mkv"; ffmpeg -y -v error -i "$1" -c:v libsvtav1 -preset 9 -crf 40 -pix_fmt yuv420p10le -svtav1-params "color-primaries=9:transfer-characteristics=16:matrix-coefficients=9" "$c" 2>/dev/null; ffmpeg -y -v error -i "$c" -c copy -f ivf "$WS/$2.ivf" 2>/dev/null; echo "$WS/$2.ivf"; }
scenes_hevc() { local j="$WS/s$RANDOM.json"; hdr10plus_tool extract "$1" -o "$j" >/dev/null 2>&1; [ -f "$j" ] && grep -c SceneFrameIndex "$j" 2>/dev/null || echo -1; }
scenes_av1()  { local j="$WS/s$RANDOM.json"; av1hdr10plus_tool extract "$1" -o "$j" >/dev/null 2>&1; [ -f "$j" ] && grep -c SceneFrameIndex "$j" 2>/dev/null || echo -1; }
json_hevc() { local j="$WS/jh$RANDOM.json"; hdr10plus_tool extract "$1" -o "$j" >/dev/null 2>&1; echo "$j"; }
json_av1()  { local j="$WS/ja$RANDOM.json"; av1hdr10plus_tool extract "$1" -o "$j" >/dev/null 2>&1; echo "$j"; }
inj_hp_hevc() { hdr10plus_tool inject -i "$1" -j "$2" -o "$3" >/dev/null 2>&1; }
inj_hp_av1()  { av1hdr10plus_tool inject -i "$1" -j "$2" -o "$3" >/dev/null 2>&1; "$PY" "$T35" "$3" "$3.f" hdr10plus >/dev/null 2>&1 && [ -s "$3.f" ] && mv -f "$3.f" "$3"; }
rpu_from()  { local r="$WS/rp$RANDOM.bin"; if [ "$2" = "av1" ]; then av1dovi_tool extract-rpu "$1" -o "$r" >/dev/null 2>&1; else dovi_tool extract-rpu "$1" -o "$r" >/dev/null 2>&1; fi; echo "$r"; }
inj_dv_av1() { av1dovi_tool inject-rpu -i "$1" --rpu-in "$2" -o "$3" >/dev/null 2>&1; "$PY" "$T35" "$3" "$3.f" dv >/dev/null 2>&1 && [ -s "$3.f" ] && mv -f "$3.f" "$3"; }
rpu_present_av1() { local r; r=$(rpu_from "$1" av1); [ -s "$r" ]; }
# DECODE dav1d — singura dovada reala ca T.35 e valid (re-extract e fals-pozitiv pe AV1)
dav1d_clean() { local e; e=$(ffmpeg -v error -i "$1" -f null - 2>&1 || true); echo "$e" | grep -qiE 'Malformed|T\.35' && return 1; return 0; }

# ── segmente + JSON-uri sursa ─────────────────────────────────────────
SEG_HEVC_HP=$(seg "$S_HEVC_HP" hevchp); SEG_AV1_HP=$(seg "$S_AV1_HP" av1hp); SEG_AV1_DV=$(seg "$S_AV1_DV" av1dv)
RAW_HEVC_HP=$(raw_hevc "$SEG_HEVC_HP" hevchpsrc); RAW_AV1_HP=$(raw_av1 "$SEG_AV1_HP" av1hpsrc); RAW_AV1_DV=$(raw_av1 "$SEG_AV1_DV" av1dvsrc)
N_HEVC=$(scenes_hevc "$RAW_HEVC_HP"); N_AV1=$(scenes_av1 "$RAW_AV1_HP")
J_HEVC=$(json_hevc "$RAW_HEVC_HP"); J_AV1=$(json_av1 "$RAW_AV1_HP")
echo "  (surse: HEVC HDR10+ $N_HEVC scene, AV1 HDR10+ $N_AV1 scene)"

# 1. AV1 HDR10+ -> AV1 : scene EXACT + DECODE (T.35 mode=hdr10plus)
BASE=$(enc_av1 "$SEG_AV1_HP" m1); O="$WS/m1_out.ivf"; inj_hp_av1 "$BASE" "$J_AV1" "$O"
assert_eq "$N_AV1" "$(scenes_av1 "$O")" "1. AV1 HDR10+ -> AV1: scene-count EXACT pastrat"
if dav1d_clean "$O"; then _pass; else _fail "1. AV1 HDR10+ -> AV1: DECODE dav1d (0 erori T.35, mode=hdr10plus)"; fi

# 2. AV1 DV -> AV1 : DECODE (T.35 mode=dv)
RPU=$(rpu_from "$RAW_AV1_DV" av1); BASE=$(enc_av1 "$SEG_AV1_DV" m2); O="$WS/m2_out.ivf"; inj_dv_av1 "$BASE" "$RPU" "$O"
if rpu_present_av1 "$O"; then _pass; else _fail "2. AV1 DV -> AV1: RPU prezent dupa inject"; fi
if dav1d_clean "$O"; then _pass; else _fail "2. AV1 DV -> AV1: DECODE dav1d (0 erori T.35, mode=dv)"; fi

# 3. AV1 hibrid (HDR10+ + DV, lant mode-specific) : ambele + DECODE
BASE=$(enc_av1 "$SEG_AV1_HP" m3); HP="$WS/m3_hp.ivf"; inj_hp_av1 "$BASE" "$J_AV1" "$HP"
GENCFG="$WS/m3_gen.json"; printf '%s' '{"length":0,"level6":{"max_display_mastering_luminance":1000,"min_display_mastering_luminance":1,"max_content_light_level":1000,"max_frame_average_light_level":200}}' > "$GENCFG"
RPUGEN="$WS/m3.rpu"; av1dovi_tool generate -j "$GENCFG" --hdr10plus-json "$J_AV1" -o "$RPUGEN" >/dev/null 2>&1
O="$WS/m3_out.ivf"; inj_dv_av1 "$HP" "$RPUGEN" "$O"
[ "$(scenes_av1 "$O")" -gt 0 ] && _pass || _fail "3. AV1 hibrid: HDR10+ pastrat dupa lantul HDR10++DV"
if rpu_present_av1 "$O"; then _pass; else _fail "3. AV1 hibrid: DV RPU pastrat (av1dovi paseaza OBU HDR10+ verbatim)"; fi
if dav1d_clean "$O"; then _pass; else _fail "3. AV1 hibrid: DECODE dav1d (ambele T.35 valide, repair mode-specific)"; fi

# 4. HEVC HDR10+ -> AV1 (cross) : scene>0 + DECODE
BASE=$(enc_av1 "$SEG_HEVC_HP" m4); O="$WS/m4_out.ivf"; inj_hp_av1 "$BASE" "$J_HEVC" "$O"
[ "$(scenes_av1 "$O")" -gt 0 ] && _pass || _fail "4. HEVC HDR10+ -> AV1 (cross): HDR10+ pastrat"
if dav1d_clean "$O"; then _pass; else _fail "4. HEVC HDR10+ -> AV1 (cross): DECODE dav1d"; fi

# 5. APV+ -> AV1 HDR10+ : encode APV, extract via engine, encode av1, inject + DECODE
if [ "$SVT_APV" = "1" ]; then
    APVC="$WS/m5.mp4"; ffmpeg -y -v error -i "$SEG_HEVC_HP" -c:v liboapv -qp 32 -pix_fmt yuv422p10le "$APVC" 2>/dev/null
    APVR="$WS/m5.apv"; ffmpeg -y -v error -i "$APVC" -c copy -f apv "$APVR" 2>/dev/null
    APVHP="$WS/m5_hp.apv"; "$PY" "$APVENG" inject -i "$APVR" -j "$J_HEVC" -o "$APVHP" >/dev/null 2>&1
    BACKJSON="$WS/m5_back.json"; "$PY" "$APVENG" extract -i "$APVHP" -o "$BACKJSON" >/dev/null 2>&1
    BASE="$WS/m5.mkv"; ffmpeg -y -v error -f apv -framerate 30 -i "$APVHP" -c:v libsvtav1 -preset 9 -crf 40 -pix_fmt yuv420p10le -svtav1-params "color-primaries=9:transfer-characteristics=16:matrix-coefficients=9" "$BASE" 2>/dev/null
    BASER="$WS/m5_base.ivf"; ffmpeg -y -v error -i "$BASE" -c copy -f ivf "$BASER" 2>/dev/null
    O="$WS/m5_out.ivf"; inj_hp_av1 "$BASER" "$BACKJSON" "$O"
    [ "$(scenes_av1 "$O")" -gt 0 ] && _pass || _fail "5. APV+ -> AV1 HDR10+: HDR10+ pastrat (engine APV extract)"
    if dav1d_clean "$O"; then _pass; else _fail "5. APV+ -> AV1 HDR10+: DECODE dav1d"; fi
else
    echo "  (5. APV sarit - liboapv indisponibil)"
fi

# 6. HEVC HDR10+ -> HEVC : scene-count EXACT (fidelitate)
BASE=$(enc_hevc "$SEG_HEVC_HP" m6); O="$WS/m6_out.hevc"; inj_hp_hevc "$BASE" "$J_HEVC" "$O"
assert_eq "$N_HEVC" "$(scenes_hevc "$O")" "6. HEVC HDR10+ -> HEVC: scene-count EXACT pastrat (fidelitate)"
