#!/usr/bin/env bash
# v56 — HDR/DV tools extinse: remove DV / remove HDR10+ / verify / export / plot.
# Valideaza helperii noi din av_common.sh pe RPU sintetic + surse reale (cand exista).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"

# dovi_tool/hdr10plus_tool/ffmpeg pot fi globale (Linux/macOS) sau in src/ (Windows)
command -v dovi_tool >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
command -v dovi_tool >/dev/null 2>&1 || skip_test "dovi_tool nu este disponibil"
command -v ffmpeg    >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

# Cleanup TMP la EXIT, dar pastreaza summary-ul framework (_test_summary).
# (trap simplu 'rm' ar suprascrie trap-ul EXIT al framework-ului → eșecuri mascate.)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"; _test_summary' EXIT

# ── Genereaza un RPU DV base (Profile 8.1) pentru teste export/plot ──
cat > "$TMP/gen.json" <<'EOF'
{ "cm_version": "V40", "length": 5,
  "level6": { "max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 1,
              "max_content_light_level": 1000, "max_frame_average_light_level": 400 } }
EOF
dovi_tool generate -j "$TMP/gen.json" -o "$TMP/base.bin" >/dev/null 2>&1
assert_file_exists "$TMP/base.bin" "generate RPU base"

# ── 1) export_dv_rpu_json (kind=all) produce JSON nevid ──────────────
export_dv_rpu_json "$TMP/base.bin" "$TMP/exp.json" all hevc
assert_zero $? "export_dv_rpu_json (all) returneaza 0"
assert_file_exists "$TMP/exp.json" "export produce JSON"

# ── 2) plot_dv_metadata (l1) produce PNG nativ ───────────────────────
plot_dv_metadata "$TMP/base.bin" "$TMP/plot_l1.png" l1 "test L1" hevc
assert_zero $? "plot_dv_metadata l1 returneaza 0"
assert_file_exists "$TMP/plot_l1.png" "plot l1 produce PNG"

# ── 3) plot fara titlu (ramura optionala) ────────────────────────────
plot_dv_metadata "$TMP/base.bin" "$TMP/plot_nt.png" l1 "" hevc
assert_zero $? "plot_dv_metadata fara titlu returneaza 0"

# ── 4) export pe RPU inexistent esueaza grațios ──────────────────────
export_dv_rpu_json "$TMP/nope.bin" "$TMP/x.json" all hevc
assert_nonzero $? "export pe RPU inexistent returneaza !=0"

# ── 5) Surse reale (cand exista in src/ sau InputVideos) ─────────────
# HDR10+ HEVC → verify (prezent) + remove + verify (absent)
HDR10P_SRC=""
for cand in "$SCRIPT_DIR"/*HDR10Plus*HEVC*.mp4 "$PROJECT_ROOT"/InputVideos/*HDR10Plus*.mp4; do
    [[ -f "$cand" ]] || continue
    HDR10P_SRC="$cand"; break
done
if [[ -n "$HDR10P_SRC" ]]; then
    verify_hdr10plus "$HDR10P_SRC" hevc
    assert_zero $? "verify_hdr10plus pe sursa HDR10+ → prezent (0)"

    raw=$(av_mktemp_ext hevc); clean=$(av_mktemp_ext hevc)
    extract_raw_video "$HDR10P_SRC" "$raw" hevc
    remove_hdr10plus_metadata "$raw" "$clean" hevc
    assert_zero $? "remove_hdr10plus_metadata returneaza 0"
    assert_file_exists "$clean" "remove HDR10+ produce bitstream"

    verify_hdr10plus "$clean" hevc
    assert_nonzero $? "verify_hdr10plus dupa remove → absent (!=0)"
    rm -f "$raw" "$clean"

    # guard onestitate (B/C): sursa HDR10+ HEVC nu are DV → verify_dv_survived absent
    verify_dv_survived "$HDR10P_SRC" hevc
    assert_nonzero $? "verify_dv_survived pe sursa fara DV → absent (!=0)"
else
    echo "  ~ (skip partial) niciun sample HDR10+ HEVC pentru verify/remove"
fi

# DV AV1 → remove DV (necesita fork av1dovi_tool)
DV_SRC=""
for cand in "$SCRIPT_DIR"/*DV*AV1*.mkv "$PROJECT_ROOT"/InputVideos/*DV*.mkv; do
    [[ -f "$cand" ]] || continue
    case "$cand" in *HDR10Plus*) continue ;; esac  # vrem DV pur, nu hibrid
    DV_SRC="$cand"; break
done
if [[ -n "$DV_SRC" ]] && command -v av1dovi_tool >/dev/null 2>&1; then
    raw=$(av_mktemp_ext ivf); clean=$(av_mktemp_ext ivf)
    extract_raw_video "$DV_SRC" "$raw" av1
    remove_dv_layer "$raw" "$clean" av1
    assert_zero $? "remove_dv_layer (AV1) returneaza 0"
    assert_file_exists "$clean" "remove DV produce bitstream"
    rm -f "$raw" "$clean"

    # guard onestitate: sursa DV AV1 originala are DV → verify_dv_survived prezent
    verify_dv_survived "$DV_SRC" av1
    assert_zero $? "verify_dv_survived pe sursa DV → prezent (0)"

    # v56 T.35 repair integrat: inject_dv_rpu auto-repara → remux ffmpeg (care ar
    # arunca T.35 malformat) → DV TREBUIE sa supravietuiasca POST-REMUX. Verificarea
    # se face pe container (nu pe IVF brut, unde av1dovi extract-rpu e tolerant).
    if _av_python >/dev/null 2>&1; then
        rawp=$(av_mktemp_ext ivf); rpup=$(av_mktemp_ext bin)
        injp=$(av_mktemp_ext ivf); outp=$(av_mktemp_ext mkv)
        extract_raw_video "$DV_SRC" "$rawp" av1 >/dev/null 2>&1
        extract_dv_rpu "$DV_SRC" "$rpup" av1 >/dev/null 2>&1
        inject_dv_rpu "$rawp" "$rpup" "$injp" av1 >/dev/null 2>&1
        ffmpeg -v error -y -i "$injp" -map 0:v:0 -c copy "$outp" >/dev/null 2>&1
        verify_dv_survived "$outp" av1
        assert_zero $? "AV1 DV: inject+repair T.35+remux → DV supravietuieste post-remux"
        rm -f "$rawp" "$rpup" "$injp" "$outp"
    else
        echo "  ~ (skip partial) Python 3 lipsa pt test repair T.35"
    fi
else
    echo "  ~ (skip partial) niciun sample DV AV1 / av1dovi_tool lipsa"
fi

# ── 7) wiring: inject_dv_rpu integreaza repair-ul T.35 pe AV1 ────────
grep -q '_repair_av1_dv_t35' "$SCRIPT_DIR/av_common.sh" \
    && _pass || _fail "inject_dv_rpu integreaza _repair_av1_dv_t35"
[[ -f "$SCRIPT_DIR/av1_dv_t35_repair.py" ]] \
    && _pass || _fail "engine av1_dv_t35_repair.py exista in src/"

echo "OK test_v56_hdr_dv_tools"
