#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# v72 — MATRICE dvcC de container (integrare, bash). Mirror al .ps1.
#   Validare end-to-end a semnalizarii DV de container pe matricea
#   codec × container × unealta (cu/fara MP4Box+mkvmerge): dvcC scris +
#   RPU byte-identic + HDR10+ co-existenta + cross-codec (profil fortat 10)
#   + cross-container (ffmpeg -c copy) + passthrough + transform + LANT
#   ENCODE REAL (svtav1 → inject → T.35 → dvcC).
#   Scenariile MP4Box se sar pe MSYS (MP4Box.exe nu accepta cai /tmp) →
#   pe git-bash ruleaza partea MKV/mkvmerge; pe Linux/macOS ruleaza TOT.
#   Auto-skip cand uneltele/sample-urile lipsesc. Nascut din auditul v72.
# ══════════════════════════════════════════════════════════════════════
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
export AV_HDR_DV_TEST_MODE=1
source "$SCRIPT_DIR/av_common.sh"
source "$SCRIPT_DIR/av_hdr_dv_tools.sh"

MP4BOX="${AV_TOOL_MP4BOX:-mp4box}"
MKVM="${AV_TOOL_MKVMERGE:-mkvmerge}"
DOVI="${AV_TOOL_DOVI:-dovi_tool}"
AV1DOVI="${AV_TOOL_AV1DOVI:-av1dovi_tool}"
for t in ffmpeg ffprobe "$MKVM" "$DOVI" "$AV1DOVI"; do
    command -v "$t" >/dev/null 2>&1 || skip_test "unealta lipsa: $t"
done
SM_AV1DV="$(ls "$SCRIPT_DIR"/*_DV_*AV1.mkv 2>/dev/null | grep -v HDR10Plus | head -1)"
SM_AV1HYB="$(ls "$SCRIPT_DIR"/*DV_HDR10Plus*AV1.mkv 2>/dev/null | head -1)"
SM_HEVCHP="$(ls "$SCRIPT_DIR"/*HDR10Plus*HEVC.mp4 2>/dev/null | head -1)"
[ -n "$SM_AV1DV" ] && [ -n "$SM_AV1HYB" ] && [ -n "$SM_HEVCHP" ] || skip_test "sample-uri AV1 DV / AV1 hibrid / HEVC HDR10+ lipsesc"

# MP4Box gating: MSYS (cai /tmp + :dvp/:fps) sau unealta absenta → scenariile MP4 se sar
_is_msys=0; case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) _is_msys=1 ;; esac
HAVE_MP4BOX=0
[ "$_is_msys" = "0" ] && command -v "$MP4BOX" >/dev/null 2>&1 && HAVE_MP4BOX=1

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; _test_summary' EXIT

has_dvcc(){ ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type -of default=nw=1:nk=1 "$1" 2>/dev/null | grep -qi "DOVI configuration record" && echo 1 || echo 0; }
dv_prof(){ local p c; p=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_profile -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1 | tr -d '\r'); c=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_bl_signal_compatibility_id -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1 | tr -d '\r'); echo "${p}.${c}"; }
has_hdr10p(){ ffprobe -v error -select_streams v:0 -read_intervals '%+#6' -show_entries frame_side_data=side_data_type -of default=nw=1:nk=1 "$1" 2>/dev/null | grep -qi "SMPTE2094-40" && echo 1 || echo 0; }
rpu_av1(){ "$AV1DOVI" extract-rpu -i "$1" -o "$1.rpu" >/dev/null 2>&1 || true; [ -s "$1.rpu" ] && md5sum "$1.rpu" | cut -d' ' -f1 || echo NORPU; }
rpu_hevc(){ "$DOVI" extract-rpu -i "$1" -o "$1.rpu" >/dev/null 2>&1 || true; [ -s "$1.rpu" ] && md5sum "$1.rpu" | cut -d' ' -f1 || echo NORPU; }
to_ivf(){ ffmpeg -y -loglevel error -i "$1" -map 0:v:0 -c copy -f ivf "$2" 2>/dev/null; }

# ── PREP — stream-uri brute + RPU-uri (mereu) ─────────────────────────
ffmpeg -y -loglevel error -i "$SM_AV1DV" -map 0:v:0 -c copy -f ivf "$TMP/av1dv.ivf" 2>/dev/null
ffmpeg -y -loglevel error -i "$TMP/av1dv.ivf" -f lavfi -i "sine=r=48000:d=2" -map 0:v -map 1:a -c copy -c:a aac -shortest "$TMP/av1dv_o.mp4" 2>/dev/null
RPU_AV1DV="$(rpu_av1 "$TMP/av1dv.ivf")"
ffmpeg -y -loglevel error -i "$SM_AV1HYB" -map 0:v:0 -c copy -f ivf "$TMP/av1hyb.ivf" 2>/dev/null
ffmpeg -y -loglevel error -i "$TMP/av1hyb.ivf" -f lavfi -i "sine=r=48000:d=2" -map 0:v -map 1:a -c copy -c:a aac -shortest "$TMP/av1hyb_o.mp4" 2>/dev/null
RPU_AV1HYB="$(rpu_av1 "$TMP/av1hyb.ivf")"
# HEVC DV 8.1 (din HEVC HDR10+ + inject) — fara MP4Box (dovi generate/inject)
ffmpeg -y -loglevel error -i "$SM_HEVCHP" -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb "$TMP/h.hevc" 2>/dev/null
printf '%s' '{ "cm_version":"V40","length":48,"level6":{"max_display_mastering_luminance":1000,"min_display_mastering_luminance":1,"max_content_light_level":1000,"max_frame_average_light_level":400} }' > "$TMP/cfg.json"
"$DOVI" generate -j "$TMP/cfg.json" -o "$TMP/h_rpu.bin" >/dev/null 2>&1 || true
"$DOVI" inject-rpu -i "$TMP/h.hevc" --rpu-in "$TMP/h_rpu.bin" -o "$TMP/hevcdv.hevc" >/dev/null 2>&1 || true
ffmpeg -y -loglevel error -i "$SM_HEVCHP" -f lavfi -i "sine=r=48000:d=2" -map 0:v -map 1:a -c copy -c:a aac -shortest "$TMP/hevcdv_o.mp4" 2>/dev/null
RPU_HEVCDV="$(rpu_hevc "$TMP/hevcdv.hevc")"

# ════ SCENARIILE MKV (mereu, mkvmerge merge si pe git-bash) ════
# 2. AV1 DV → MKV
_mux_dv_mkv "$TMP/av1dv.ivf" "$TMP/av1dv_o.mp4" "$TMP/2.mkv" >/dev/null 2>&1 || true
to_ivf "$TMP/2.mkv" "$TMP/2.ivf"
assert_eq "1" "$(has_dvcc "$TMP/2.mkv")" "av1 DV -> MKV: dvcC scris"
assert_eq "$RPU_AV1DV" "$(rpu_av1 "$TMP/2.ivf")" "av1 DV -> MKV: RPU byte-identic"
# 4-MKV. AV1 hibrid → MKV (dvcC + HDR10+)
_mux_dv_mkv "$TMP/av1hyb.ivf" "$TMP/av1hyb_o.mp4" "$TMP/4.mkv" >/dev/null 2>&1 || true
assert_eq "1" "$(has_dvcc "$TMP/4.mkv")" "av1 hibrid -> MKV: dvcC scris"
assert_eq "1" "$(has_hdr10p "$TMP/4.mkv")" "av1 hibrid -> MKV: HDR10+ pastrat"
# 6-MKV. HEVC DV → MKV
_mux_dv_mkv "$TMP/hevcdv.hevc" "$TMP/hevcdv_o.mp4" "$TMP/6.mkv" >/dev/null 2>&1 || true
assert_eq "1" "$(has_dvcc "$TMP/6.mkv")" "hevc DV -> MKV: dvcC scris"
# 7. CROSS-CONTAINER: ffmpeg -c copy PASTREAZA →MKV, PIERDE →MP4
ffmpeg -y -loglevel error -i "$SM_AV1DV" -map 0:v:0 -c copy "$TMP/cc.mkv" 2>/dev/null
ffmpeg -y -loglevel error -i "$SM_AV1DV" -map 0:v:0 -c copy "$TMP/cc.mp4" 2>/dev/null
assert_eq "1" "$(has_dvcc "$TMP/cc.mkv")" "cross-container: ffmpeg -c copy PASTREAZA dvcC ->MKV"
assert_eq "0" "$(has_dvcc "$TMP/cc.mp4")" "cross-container: ffmpeg -c copy PIERDE dvcC ->MP4 (premisa passthrough)"
# 9-MKV. transform av1 hibrid → MKV
_hdv_combine_with_original "$TMP/av1hyb.ivf" "$TMP/av1hyb_o.mp4" "$TMP/9.mkv" >/dev/null 2>&1 || true
assert_eq "1" "$(has_dvcc "$TMP/9.mkv")" "transform av1 hibrid -> MKV: dvcC"
assert_eq "1" "$(has_hdr10p "$TMP/9.mkv")" "transform av1 hibrid -> MKV: HDR10+"

# ════ SCENARIILE MP4Box (gardate pe MSYS / unealta) ════
if [ "$HAVE_MP4BOX" = "1" ]; then
    # ref HEVC DV 8.x in MP4 (pt cross-codec)
    "$MP4BOX" -add "$TMP/hevcdv.hevc:fps=23.976" -new "$TMP/hevcdv_ref.mp4" >/dev/null 2>&1 || true
    # 1. AV1 DV → MP4
    _mux_dv_mp4 "$TMP/av1dv.ivf" "$TMP/av1dv_o.mp4" "$TMP/1.mp4" "$SM_AV1DV" >/dev/null 2>&1 || true
    to_ivf "$TMP/1.mp4" "$TMP/1.ivf"
    assert_eq "1" "$(has_dvcc "$TMP/1.mp4")" "av1 DV -> MP4: dvcC scris"
    assert_eq "10.1" "$(dv_prof "$TMP/1.mp4")" "av1 DV -> MP4: profil 10.1"
    assert_eq "$RPU_AV1DV" "$(rpu_av1 "$TMP/1.ivf")" "av1 DV -> MP4: RPU byte-identic"
    # 3. fallback fara MP4Box (no output partial)
    fb=0; AV_TOOL_MP4BOX="/nonexistent/zz" _mux_dv_mp4 "$TMP/av1dv.ivf" "$TMP/av1dv_o.mp4" "$TMP/3.mp4" "$SM_AV1DV" || fb=1
    assert_eq "1" "$fb" "av1 DV -> MP4 fara MP4Box: fallback (return 1)"
    assert_file_not_exists "$TMP/3.mp4" "av1 DV -> MP4 fara MP4Box: fara output partial"
    # 4-MP4. AV1 hibrid → MP4 (dvcC + HDR10+ + RPU)
    _mux_dv_mp4 "$TMP/av1hyb.ivf" "$TMP/av1hyb_o.mp4" "$TMP/4.mp4" "$SM_AV1HYB" >/dev/null 2>&1 || true
    to_ivf "$TMP/4.mp4" "$TMP/4.ivf"
    assert_eq "1" "$(has_dvcc "$TMP/4.mp4")" "av1 hibrid -> MP4: dvcC scris"
    assert_eq "1" "$(has_hdr10p "$TMP/4.mp4")" "av1 hibrid -> MP4: HDR10+ pastrat"
    assert_eq "$RPU_AV1HYB" "$(rpu_av1 "$TMP/4.ivf")" "av1 hibrid -> MP4: RPU byte-identic"
    # 5. CROSS-CODEC (FIX): av1 raw + ref HEVC-DV(8.x) → profil MUST 10
    case "$(dv_prof "$TMP/hevcdv_ref.mp4")" in 8.*) assert_eq "1" "1" "prep: ref HEVC DV e profil 8.x (non-10)";; *) assert_eq "8.x" "$(dv_prof "$TMP/hevcdv_ref.mp4")" "prep: ref HEVC DV e profil 8.x";; esac
    _mux_dv_mp4 "$TMP/av1dv.ivf" "$TMP/av1dv_o.mp4" "$TMP/5.mp4" "$TMP/hevcdv_ref.mp4" >/dev/null 2>&1 || true
    assert_eq "1" "$(has_dvcc "$TMP/5.mp4")" "cross-codec av1+refHEVC -> MP4: dvcC scris"
    case "$(dv_prof "$TMP/5.mp4")" in 10.*) assert_eq "1" "1" "cross-codec: profil FORTAT la 10 (nu 8 din ref)";; *) assert_eq "10.x" "$(dv_prof "$TMP/5.mp4")" "cross-codec: profil FORTAT la 10";; esac
    # 6-MP4. HEVC DV → MP4 (auto-detect)
    _mux_dv_mp4 "$TMP/hevcdv.hevc" "$TMP/hevcdv_o.mp4" "$TMP/6.mp4" >/dev/null 2>&1 || true
    ffmpeg -y -loglevel error -i "$TMP/6.mp4" -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb "$TMP/6.hevc" 2>/dev/null
    assert_eq "1" "$(has_dvcc "$TMP/6.mp4")" "hevc DV -> MP4: dvcC scris"
    assert_eq "$RPU_HEVCDV" "$(rpu_hevc "$TMP/6.hevc")" "hevc DV -> MP4: RPU byte-identic"
    # 8. PASSTHROUGH: re-signal pe MP4-ul fara dvcC
    to_ivf "$TMP/cc.mp4" "$TMP/cc.ivf"
    _mux_dv_mp4 "$TMP/cc.ivf" "$TMP/cc.mp4" "$TMP/8.mp4" "$SM_AV1DV" >/dev/null 2>&1 || true
    assert_eq "1" "$(has_dvcc "$TMP/8.mp4")" "passthrough: re-signal restaureaza dvcC pe AV1 MP4"
    assert_eq "10.1" "$(dv_prof "$TMP/8.mp4")" "passthrough: profil 10.1"
    # 9-MP4. transform av1 hibrid → MP4
    _hdv_combine_with_original "$TMP/av1hyb.ivf" "$TMP/av1hyb_o.mp4" "$TMP/9.mp4" >/dev/null 2>&1 || true
    assert_eq "1" "$(has_dvcc "$TMP/9.mp4")" "transform av1 hibrid -> MP4: dvcC"
    assert_eq "1" "$(has_hdr10p "$TMP/9.mp4")" "transform av1 hibrid -> MP4: HDR10+"
    # 10. LANT ENCODE REAL (svtav1 → inject → T.35 → dvcC)
    if (ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libsvtav1) && command -v "$(_av_python 2>/dev/null || echo python3)" >/dev/null 2>&1; then
        PY="$(_av_python 2>/dev/null || echo python3)"
        ffmpeg -y -loglevel error -t 2 -i "$SM_AV1DV" -map 0:v:0 -c copy -f ivf "$TMP/e_src.ivf" 2>/dev/null
        E_RPU="$(rpu_av1 "$TMP/e_src.ivf")"
        ffmpeg -y -loglevel error -i "$TMP/e_src.ivf" -c:v libsvtav1 -crf 40 -preset 10 -svtav1-params "enable-hdr=1" -pix_fmt yuv420p10le -f ivf "$TMP/e_base.ivf" 2>/dev/null
        "$AV1DOVI" inject-rpu -i "$TMP/e_base.ivf" --rpu-in "$TMP/e_src.ivf.rpu" -o "$TMP/e_inj.ivf" >/dev/null 2>&1 || true
        "$PY" "$SCRIPT_DIR/av1_dv_t35_repair.py" "$TMP/e_inj.ivf" "$TMP/e_rep.ivf" >/dev/null 2>&1 || true
        ffmpeg -y -loglevel error -i "$TMP/e_rep.ivf" -f lavfi -i "sine=r=48000:d=2" -map 0:v -map 1:a -c copy -c:a aac -shortest "$TMP/e_o.mp4" 2>/dev/null
        _mux_dv_mp4 "$TMP/e_rep.ivf" "$TMP/e_o.mp4" "$TMP/e_final.mp4" "$SM_AV1DV" >/dev/null 2>&1 || true
        to_ivf "$TMP/e_final.mp4" "$TMP/e_out.ivf"
        dec_err=$(ffmpeg -v warning -i "$TMP/e_final.mp4" -f null - 2>&1 | grep -ciE 'malformed|t\.35|error' || true)
        assert_eq "1" "$(has_dvcc "$TMP/e_final.mp4")" "ENCODE REAL: av1 DV svtav1 -> dvcC MP4"
        assert_eq "10.1" "$(dv_prof "$TMP/e_final.mp4")" "ENCODE REAL: profil 10.1"
        assert_eq "$E_RPU" "$(rpu_av1 "$TMP/e_out.ivf")" "ENCODE REAL: RPU byte-identic prin lant"
        assert_eq "0" "$dec_err" "ENCODE REAL: decode dav1d curat (0 erori T.35)"
    else
        echo "  (lant encode real sarit: libsvtav1 / python lipsesc)" >&2
    fi
else
    echo "  (scenariile MP4Box sarite: MSYS sau MP4Box absent — validate pe Linux/macOS + test PS1)" >&2
fi
