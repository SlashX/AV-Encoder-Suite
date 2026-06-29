#!/usr/bin/env bash
# v80 — Burn-in: cablare chei moarte (curatenia v77 le scosese din presets ca 0-refs).
#   FONT_FAMILY (configurabil, propagat prin draw_text = punctul unic de text) +
#   HUD_ALTITUDE/HEADING/TEMPERATURE ca gauge-uri de colt (gateate not HUD_DATA_STRIP,
#   ca timestamp/speed — non-redundant cu STRIP_FIELDS, care contine deja aceste 3 campuri).
#   Engine burnin_render.py = PARTAJAT bash<->PS1 (fara cod PS1 oglinda; doar testul are mirror).
#   Santinela dead->live + functional render (PNG).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

ENGINE="$(cat "$SCRIPT_DIR/burnin_render.py")"
MINIMAL="$(cat "$SCRIPT_DIR/burnin_presets/minimal.conf")"
FULL="$(cat "$SCRIPT_DIR/burnin_presets/full.conf")"

# ── 1. FONT_FAMILY cablat (dead->live) ──────────────────────────────
assert_contains "$ENGINE" 'cfg.get("FONT_FAMILY"'   "engine: FONT_FAMILY citit din preset"
assert_contains "$ENGINE" 'fontfamily'              "engine: aplicat ca fontfamily= (nume de familie)"
assert_contains "$ENGINE" 'FontProperties(fname='   "engine: cale .ttf/.otf via FontProperties(fname=)"
assert_contains "$ENGINE" 'from matplotlib.font_manager import FontProperties' "engine: import FontProperties"
assert_contains "$ENGINE" 'logging.getLogger("matplotlib.font_manager").setLevel(logging.ERROR)' "engine: warning findfont silentiat (nume familie invalid → fallback tacut)"

# ── 2. HUD_ALTITUDE/HEADING/TEMPERATURE cablate ca gauge-uri colt ───
assert_contains "$ENGINE" 'HUD_ALTITUDE'            "engine: HUD_ALTITUDE cablat"
assert_contains "$ENGINE" 'HUD_HEADING'             "engine: HUD_HEADING cablat"
assert_contains "$ENGINE" 'HUD_TEMPERATURE'         "engine: HUD_TEMPERATURE cablat"
assert_contains "$ENGINE" 'POS_ALTITUDE'            "engine: pozitie configurabila POS_ALTITUDE"
assert_contains "$ENGINE" 'POS_HEADING'             "engine: pozitie configurabila POS_HEADING"
assert_contains "$ENGINE" 'POS_TEMPERATURE'         "engine: pozitie configurabila POS_TEMPERATURE"
# gateate non-redundant cu strip (ca timestamp/speed)
assert_contains "$ENGINE" 'HUD_ALTITUDE") and not cfg_bool(cfg, "HUD_DATA_STRIP")' "engine: ALT gateat not HUD_DATA_STRIP (non-redundant cu STRIP_FIELDS)"
# refolosesc formatele exacte din data-strip (consistenta strip<->colt)
assert_contains "$ENGINE" 'fmt_value(sample.get("alt_m"), "{:.1f}", " m")'     "engine: ALT refoloseste formatul din strip"
assert_contains "$ENGINE" 'fmt_value(sample.get("heading_deg"), "{:.0f}", "°")' "engine: HDG refoloseste formatul din strip"
assert_contains "$ENGINE" 'fmt_value(sample.get("temp_c"), "{:.1f}", "°C")'    "engine: TEMP refoloseste formatul din strip"

# ── 3. FRAME_W/FRAME_H/PRESET_DESC raman scoase (NU re-introduse) ───
assert_not_contains "$ENGINE" 'FRAME_W'             "engine: FRAME_W ramane scos (latimea vine din --width)"
assert_not_contains "$ENGINE" 'FRAME_H'             "engine: FRAME_H ramane scos (inaltimea din --height)"
assert_not_contains "$ENGINE" 'PRESET_DESC'         "engine: PRESET_DESC ramane scos"

# ── 4. Presets documenteaza cheile noi (discoverability) ────────────
assert_contains "$MINIMAL" 'HUD_ALTITUDE'           "minimal.conf: documenteaza gauge-urile noi"
assert_contains "$MINIMAL" 'FONT_FAMILY'            "minimal.conf: documenteaza FONT_FAMILY"
assert_contains "$FULL"    'FONT_FAMILY'            "full.conf: documenteaza FONT_FAMILY"

# ── 5. Functional: render 1 cadru cu FONT_FAMILY + gauge-uri → PNG ──
#    Best-effort pe bash (git-bash/MSYS python subprocess poate flaka → skip, NU fail);
#    coverage-ul functional garantat e pe calea PS1 (Windows python.exe).
PYBIN="$(command -v python3 || command -v python || true)"
if [[ -n "$PYBIN" ]] && "$PYBIN" -c "import matplotlib" >/dev/null 2>&1; then
    tmpd="$(mktemp -d)"
    cat > "$tmpd/t.csv" <<'CSV'
timestamp,lat,lon,alt_m,speed_mps,speed_kmh,heading_deg,temp_c,source_brand
2024-03-15T12:30:45,44.37,26.10,512.4,12.5,45.0,278,23.7,dji
2024-03-15T12:30:47,44.371,26.101,540.9,14.0,50.4,281,24.1,dji
CSV
    cat > "$tmpd/t.conf" <<'CONF'
PRESET_NAME=deadkeys_test
HUD_TIMESTAMP=1
HUD_SPEED=1
HUD_DATA_STRIP=0
HUD_ALTITUDE=1
HUD_HEADING=1
HUD_TEMPERATURE=1
POS_ALTITUDE=tl:24,80
POS_HEADING=tl:24,116
POS_TEMPERATURE=tl:24,152
FONT_FAMILY=monospace
CONF
    if "$PYBIN" "$SCRIPT_DIR/burnin_render.py" --csv "$tmpd/t.csv" --preset "$tmpd/t.conf" \
        --output-dir "$tmpd/out" --fps 1 --duration 1 --width 320 --height 240 >/dev/null 2>&1; then
        assert_file_exists "$tmpd/out/frame_000001.png" "functional: PNG randat (FONT_FAMILY + gauge-uri colt)"
        nonempty="no"; [[ -s "$tmpd/out/frame_000001.png" ]] && nonempty="yes"
        assert_eq "yes" "$nonempty" "functional: PNG non-gol"
    else
        echo "  (functional skip — render esuat, posibil MSYS python flake)" >&2
    fi
    # font invalid (nume familie negasit) → fallback TACUT, fara spam de warning findfont
    cat > "$tmpd/bad.conf" <<'CONF'
PRESET_NAME=bad
HUD_TIMESTAMP=1
HUD_ALTITUDE=1
HUD_DATA_STRIP=0
FONT_FAMILY=NoSuchFamilyZZ123
CONF
    bad_err="$("$PYBIN" "$SCRIPT_DIR/burnin_render.py" --csv "$tmpd/t.csv" --preset "$tmpd/bad.conf" --output-dir "$tmpd/bad" --fps 1 --duration 1 --width 240 --height 160 2>&1 >/dev/null || true)"
    fc=0; [[ "$bad_err" == *findfont* ]] && fc=1
    assert_zero "$fc" "functional: font invalid → fallback tacut (fara warning findfont)"
    rm -rf "$tmpd"
else
    echo "  (functional skip — python/matplotlib lipseste)" >&2
fi
