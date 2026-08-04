#!/usr/bin/env bash
# v51: 2-pass + VBV/Level + HDR10 static metadata
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

INPUT_DIR=/tmp/v51_in OUTPUT_DIR=/tmp/v51_out
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
source "$SCRIPT_DIR/av_common.sh"

# ══════════════════════════════════════════════════════════════════════
# Faza C: VBV / Level helpers
# ══════════════════════════════════════════════════════════════════════
# get_vbv_caps — HEVC Main vs High Tier
assert_eq "12000 12000"   "$(get_vbv_caps hevc 4.0 main)"  "HEVC 4.0 Main Tier"
assert_eq "30000 30000"   "$(get_vbv_caps hevc 4.0 high)"  "HEVC 4.0 High Tier"
assert_eq "20000 20000"   "$(get_vbv_caps hevc 4.1 main)"  "HEVC 4.1 Main"
assert_eq "50000 50000"   "$(get_vbv_caps hevc 4.1 high)"  "HEVC 4.1 High"
assert_eq "100000 100000" "$(get_vbv_caps hevc 5.0 high)"  "HEVC 5.0 High"
assert_eq "240000 240000" "$(get_vbv_caps hevc 5.2 high)"  "HEVC 5.2 High"

# get_vbv_caps — H.264
assert_eq "62500 62500"   "$(get_vbv_caps h264 4.1)" "H.264 4.1"
assert_eq "300000 300000" "$(get_vbv_caps h264 5.1)" "H.264 5.1"

# get_vbv_caps — AV1
assert_eq "30000 100000"  "$(get_vbv_caps av1 5.0)" "AV1 5.0"
assert_eq "60000 240000"  "$(get_vbv_caps av1 5.2)" "AV1 5.2"

# _min_level_for_res
assert_eq "4.0" "$(_min_level_for_res hevc 1920 1080 30)" "HEVC 1080p30 min level 4.0"
assert_eq "4.1" "$(_min_level_for_res hevc 1920 1080 60)" "HEVC 1080p60 min level 4.1"
assert_eq "5.0" "$(_min_level_for_res hevc 3840 2160 30)" "HEVC 4K30 min level 5.0"
assert_eq "5.1" "$(_min_level_for_res hevc 3840 2160 60)" "HEVC 4K60 min level 5.1"
assert_eq "4.1" "$(_min_level_for_res h264 1920 1080 30)" "H.264 1080p min level 4.1"

# v94 (B10b) — SANTINELA: level-ul se calculeaza din SAMPLES + RATA + latura maxima,
# NU din latime. Cazurile de mai jos ieseau subdimensionate pana in v93 si faceau x265
# sa refuze sa porneasca ("picture dimensions are out of range") → encode 0 octeti.
assert_eq "5.0" "$(_min_level_for_res hevc 2688 1512 60)" "B10b: HEVC 2.7K DJI (era 4.1 → esec)"
assert_eq "5.0" "$(_min_level_for_res hevc 2560 1440 30)" "B10b: HEVC 1440p (era 4.0 → esec)"
assert_eq "4.0" "$(_min_level_for_res hevc 1080 1920 30)" "B10b: HEVC portret 1080x1920 (era 3.0 → esec)"
assert_eq "5.0" "$(_min_level_for_res hevc 1440 2560 30)" "B10b: HEVC portret 1440x2560 (era 3.1 → esec)"
assert_eq "5.0" "$(_min_level_for_res av1  2688 1512 60)" "B10b: AV1 2.7K DJI (era 4.1)"
assert_eq "5.1" "$(_min_level_for_res h264 2688 1512 60)" "B10b: H.264 2.7K DJI 60fps (era 5.0, rata prea mare)"
assert_eq "4.1" "$(_min_level_for_res h264 1080 1920 30)" "B10b: H.264 portret (era 3.0)"

# suggest_vbv_for_target — escaladare automata Main → High Tier
sug=$(suggest_vbv_for_target hevc 4000 1920 1080 30)
assert_eq "4.0 main 6000 8000" "$sug" "HEVC 4000kbps 1080p30 → 4.0 Main"

sug=$(suggest_vbv_for_target hevc 25000 3840 2160 30)
# 25000kbps × 1.5 = 37500 maxrate; HEVC 5.0 Main = 25000 (prea mic), escaladeaza la High = 100000
assert_eq "5.0 high 37500 50000" "$sug" "HEVC 25Mbps 4K30 → 5.0 High Tier"

sug=$(suggest_vbv_for_target h264 10000 1920 1080 30)
assert_eq "4.1 main 15000 20000" "$sug" "H.264 10Mbps 1080p30 → 4.1"

sug=$(suggest_vbv_for_target av1 8000 3840 2160 30)
assert_eq "5.0 main 12000 16000" "$sug" "AV1 8Mbps 4K30 → 5.0"

# parse_bitrate_kbps
assert_eq "4000" "$(parse_bitrate_kbps 4000k)" "4000k → 4000"
assert_eq "4000" "$(parse_bitrate_kbps 4M)"    "4M → 4000"
assert_eq "8000" "$(parse_bitrate_kbps 8000)"  "8000 → 8000"
assert_eq "0"    "$(parse_bitrate_kbps abc)"   "invalid → 0"
assert_eq "0"    "$(parse_bitrate_kbps '')"    "empty → 0"

# ══════════════════════════════════════════════════════════════════════
# Faza D: HDR10 static metadata
# ══════════════════════════════════════════════════════════════════════
# Defaults
hdr10_static_defaults
assert_eq "1" "$HDR10_STATIC_AVAILABLE" "defaults set HDR10_STATIC_AVAILABLE=1"
assert_contains "$HDR10_MASTER_DISPLAY_X265" "G(8500,39850)" "X265 defaults BT.2020 green"
assert_contains "$HDR10_MASTER_DISPLAY_X265" "L(10000000,1)" "X265 defaults 1000nit peak"
assert_contains "$HDR10_MASTER_DISPLAY_SVTAV1" "G(0.1700,0.7970)" "SVTAV1 defaults BT.2020 green float"
assert_contains "$HDR10_MASTER_DISPLAY_SVTAV1" "L(1000.0000,0.0001)" "SVTAV1 defaults 1000nit peak float"
assert_eq "1000,400" "$HDR10_MAX_CLL" "defaults MaxCLL 1000,400"

# Extract on missing file → fail clean
extract_hdr10_static_metadata /nonexistent/file.mp4
assert_eq "0" "$HDR10_STATIC_AVAILABLE" "missing file → AVAILABLE=0"

# Resolve: missing file → defaults
HDR10_STATIC_AVAILABLE=0
hdr10_static_resolve /nonexistent/file.mp4
assert_eq "1" "$HDR10_STATIC_AVAILABLE" "resolve fallback → AVAILABLE=1"
assert_eq "default-bt2020-1000nit" "$HDR10_STATIC_SOURCE" "resolve fallback source label"

# ══════════════════════════════════════════════════════════════════════
# Faza A: 2-pass infrastructure
# ══════════════════════════════════════════════════════════════════════
# init_2pass_state — sanity
init_2pass_state "/tmp/test video!@#.mp4"
assert_eq "1" "${USE_2PASS:-0}" "init_2pass_state sets USE_2PASS=1"
assert_dir_exists "$STATS_DIR" "STATS_DIR exists after init"
# Sanitization: special chars replaced
assert_match "$STATS_FILE" "^.+/test_video___\.passlog$" "STATS_FILE sanitized name (3 trailing _ from !@#)"

# cleanup_2pass_state
cleanup_2pass_state
assert_eq "0" "${USE_2PASS:-0}" "cleanup resets USE_2PASS"
assert_eq "" "$STATS_FILE" "cleanup clears STATS_FILE"
assert_eq "" "$STATS_DIR" "cleanup clears STATS_DIR"
assert_eq "" "$FFMPEG_CMD_PASS1" "cleanup clears FFMPEG_CMD_PASS1"
assert_eq "" "$FFMPEG_CMD_PASS2" "cleanup clears FFMPEG_CMD_PASS2"

# ── Gate-ul 2-pass × HW: politica VIE (v94/O11, inchis in v95) ──
# Pana in v94, aserţiunile de aici exercitau `hw_2pass_allowed()` — o functie pe care nimic
# n-o chema, ramasa cu politica de dinainte de v53 ("niciun backend HW nu suporta 2-pass") —
# si afirmau deci opusul codului viu, unde NVENC face 2-pass intern (`-multipass fullres`).
# v94 le-a re-tintit pe politica VIE (av_launcher.sh, oglindita in av_encode.ps1); v95 a
# STERS functia moarta. Un test care trece dar spune opusul comportamentului real e mai rau
# decat lipsa lui de acoperire — de-aia afirmam regula acolo unde e chiar aplicata.
LAUNCH_TXT="$(cat "$SCRIPT_DIR/av_launcher.sh")"
assert_contains "$LAUNCH_TXT" '[[ "${HW_BACKEND:-sw}" != "sw" ]] && _is_hw_active=1' \
    "gate viu: orice backend != sw = HW activ"
assert_contains "$LAUNCH_TXT" '[[ "${HW_BACKEND:-}" == "nvenc" ]] && _hw_supports_2pass=1' \
    "gate viu: NVENC SUPORTA 2-pass (v53, -multipass fullres)"
assert_contains "$LAUNCH_TXT" 'if [[ "$ENCODE_MODE" == "3" ]] && [ $_is_hw_active -eq 1 ] && [ $_hw_supports_2pass -eq 0 ]; then' \
    "gate viu: mode=3 respins doar pe HW care NU suporta 2-pass"
# aceeasi politica, replicata → contract explicit per backend
_live_2pass_ok() {
    local be="${1:-sw}" hw=0 sup=0
    [[ "$be" != "sw" ]] && hw=1
    [[ "$be" == "nvenc" ]] && sup=1
    [[ $hw -eq 0 || $sup -eq 1 ]]
}
for be in sw nvenc; do
    if _live_2pass_ok "$be"; then assert_eq "permis" "permis" "2-pass pe '$be': permis"
    else assert_eq "permis" "respins" "2-pass pe '$be': permis"; fi
done
for be in qsv vaapi videotoolbox amf mediacodec; do
    if _live_2pass_ok "$be"; then assert_eq "respins" "permis" "2-pass pe '$be': respins"
    else assert_eq "respins" "respins" "2-pass pe '$be': respins"; fi
done
# paritate: PS1 are acelasi gate (nvenc = singurul HW cu 2-pass)
assert_contains "$(cat "$SCRIPT_DIR/av_encode.ps1")" \
    '$hwSupports2Pass = ($useHWEnc -and ($hwEncCodec -match "nvenc"))' \
    "paritate PS1: acelasi gate 2-pass × HW"
# (O11 inchis in v95: `hw_2pass_allowed` si `get_null_output` au fost sterse din av_common.sh
# impreuna cu restul codului mort; garda permanenta e acum test_v95_dead_code.{sh,ps1}.)
HW_BACKEND=sw

# ══════════════════════════════════════════════════════════════════════
# Faza B: per-encoder integration — markers in encoder files
# ══════════════════════════════════════════════════════════════════════
# x265: 2-pass branch + level inject + HDR10 static helper
x265_src=$(cat "$SCRIPT_DIR/av_encoder_x265.sh")
assert_contains "$x265_src" 'ENCODE_MODE" == "3"' "x265 has ENCODE_MODE=3 branch"
assert_contains "$x265_src" 'init_2pass_state'    "x265 calls init_2pass_state"
assert_contains "$x265_src" 'pass=1:stats='       "x265 inline pass=1:stats syntax"
assert_contains "$x265_src" 'pass=2:stats='       "x265 inline pass=2:stats syntax"
assert_contains "$x265_src" 'X265_LEVEL_PARAMS'   "x265 has level params global"
assert_contains "$x265_src" 'X265_HDR10_STATIC_PARAMS' "x265 has HDR10 static global"
assert_contains "$x265_src" '_set_x265_hdr10_static' "x265 has HDR10 static helper"
assert_contains "$x265_src" 'high-tier='          "x265 sets high-tier"
assert_contains "$x265_src" 'hrd=1'               "x265 sets hrd=1 on VBR"
assert_contains "$x265_src" 'hdr10_static_resolve' "x265 calls hdr10_static_resolve"

# x264: 2-pass via -pass + -passlogfile + nal-hrd=vbr
x264_src=$(cat "$SCRIPT_DIR/av_encoder_x264.sh")
assert_contains "$x264_src" 'ENCODE_MODE" == "3"' "x264 has ENCODE_MODE=3 branch"
assert_contains "$x264_src" '-pass 1 -passlogfile' "x264 pass 1 flag"
assert_contains "$x264_src" '-pass 2 -passlogfile' "x264 pass 2 flag"
assert_contains "$x264_src" 'nal-hrd=vbr'          "x264 nal-hrd=vbr on VBR"
assert_contains "$x264_src" 'suggest_vbv_for_target h264' "x264 uses VBV suggest"

# AV1: 2-pass via svtav1-params inline + libaom -pass + -level
av1_src=$(cat "$SCRIPT_DIR/av_encoder_av1.sh")
assert_contains "$av1_src" 'ENCODE_MODE" == "3"'   "AV1 has ENCODE_MODE=3 branch"
assert_contains "$av1_src" '_check_svtav1_2pass_caps' "AV1 checks SVT-AV1 caps"
assert_contains "$av1_src" 'pass=1:stats='          "AV1 SVT inline pass=1"
assert_contains "$av1_src" 'pass=2:stats='          "AV1 SVT inline pass=2"
assert_contains "$av1_src" 'suggest_vbv_for_target av1' "AV1 uses VBV suggest"
assert_contains "$av1_src" '_set_av1_hdr10_static'  "AV1 has HDR10 static helper"
assert_contains "$av1_src" 'mastering-display='     "AV1 inject mastering-display"
assert_contains "$av1_src" 'content-light='         "AV1 inject content-light"

# ══════════════════════════════════════════════════════════════════════
# Faza E: launcher gate — meniu mode + HW fallback
# ══════════════════════════════════════════════════════════════════════
launcher_src=$(cat "$SCRIPT_DIR/av_launcher.sh")
assert_contains "$launcher_src" 'VBR 2-pass'             "launcher menu has 2-pass option"
assert_contains "$launcher_src" '_is_hw_active'          "launcher HW gate flag"
assert_contains "$launcher_src" 'fallback la VBR 1-pass' "launcher HW fallback message"
assert_contains "$launcher_src" 'ENCODE_MODE=2'          "launcher fallback resets to 2"

# Common: schema + smart-copy skip
common_src=$(cat "$SCRIPT_DIR/av_common.sh")
assert_contains "$common_src" 'enum:1,2,3'          "schema ENCODE_MODE enum=1,2,3"
assert_contains "$common_src" 'USE_2PASS:-0}" == "1"' "run_encode_loop branches on USE_2PASS"
assert_contains "$common_src" '"${ENCODE_MODE:-1}" != "3"' "smart-copy guard skips mode=3"
assert_contains "$common_src" 'cleanup_2pass_state' "defensive reset includes cleanup_2pass_state"

exit 0
