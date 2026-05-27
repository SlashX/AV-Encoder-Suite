#!/usr/bin/env bash
# v55 — HDR/DV tools: convert_rpu_profile (editor pattern) + generate L6 din sursa.
# Prinde regresia v55: `dovi_tool convert -m N --rpu-out` esua exit 2 in 2.x.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"

# dovi_tool poate fi instalat global (Linux/macOS) sau in src/ (Windows testing)
command -v dovi_tool >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
command -v dovi_tool >/dev/null 2>&1 || skip_test "dovi_tool nu este disponibil"
command -v ffmpeg   >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

# Cleanup TMP la EXIT, dar pastreaza summary-ul framework (_test_summary).
TMP=$(mktemp -d); trap 'rm -rf "$TMP"; _test_summary' EXIT

# ── Genereaza un RPU DV base (Profile 8.1) pentru teste ──────────────
cat > "$TMP/gen.json" <<'EOF'
{ "cm_version": "V40", "length": 5,
  "level6": { "max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 1,
              "max_content_light_level": 1000, "max_frame_average_light_level": 400 } }
EOF
dovi_tool generate -j "$TMP/gen.json" -o "$TMP/base.bin" >/dev/null 2>&1
assert_file_exists "$TMP/base.bin" "generate RPU base"

# ── 1) REGRESIE: sintaxa veche `convert -m N --rpu-out` TREBUIE sa esueze ──
# (daca trece, dovi_tool a revenit la API-ul vechi — testul ne avertizeaza)
dovi_tool convert -m 2 --rpu-out "$TMP/old.bin" "$TMP/base.bin" >/dev/null 2>&1
assert_nonzero $? "sintaxa veche 'convert -m --rpu-out' esueaza in dovi_tool 2.x (regresie)"

# ── 2) FIX: convert_rpu_profile mode=2 (force 8.1) ───────────────────
convert_rpu_profile "$TMP/base.bin" "$TMP/conv2.bin" 2 hevc
assert_zero $? "convert_rpu_profile mode=2 returneaza 0"
assert_file_exists "$TMP/conv2.bin" "convert mode=2 produce RPU"

# ── 3) FIX: convert_rpu_profile mode=5 (8.1 preserving mapping) ──────
convert_rpu_profile "$TMP/base.bin" "$TMP/conv5.bin" 5 hevc
assert_zero $? "convert_rpu_profile mode=5 returneaza 0"
assert_file_exists "$TMP/conv5.bin" "convert mode=5 produce RPU"

# ── 4) info -s (summary) functioneaza pe RPU-ul convertit ────────────
summary=$(dovi_tool info -i "$TMP/conv2.bin" -s 2>/dev/null)
assert_contains "$summary" "Profile" "info -s contine 'Profile'"
assert_contains "$summary" "Frames" "info -s contine 'Frames'"

# ── 5) generate_dv_rpu_from_hdr10plus cu source_file (L6 din sursa) ──
# Necesita o sursa HDR10+ reala; cautam in src/ sau InputVideos, altfel skip.
HDR10P_SRC=""
for cand in "$SCRIPT_DIR"/*HDR10Plus*HEVC*.mp4 "$PROJECT_ROOT"/InputVideos/*.mp4 "$PROJECT_ROOT"/InputVideos/*.mkv; do
    [[ -f "$cand" ]] || continue
    if extract_hdr10plus_metadata "$cand" >/dev/null 2>&1; then HDR10P_SRC="$cand"; break; fi
done
if [[ -n "$HDR10P_SRC" ]]; then
    hpj=$(extract_hdr10plus_metadata "$HDR10P_SRC" 2>/dev/null)
    if [[ -n "$hpj" ]] && [[ -s "$hpj" ]]; then
        rpu_g=$(generate_dv_rpu_from_hdr10plus "$hpj" hevc "$HDR10P_SRC" 2>/dev/null | tail -1)
        assert_file_exists "$rpu_g" "generate_dv_rpu_from_hdr10plus (source_file) produce RPU"
        rm -f "$hpj" "$rpu_g"
    fi
else
    echo "  ~ (skip partial) niciun sample HDR10+ pentru test generate L6"
fi

echo "OK test_v55_hdr_dv"
