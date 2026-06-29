#!/usr/bin/env bash
# v81 — Burn-in still layout preview (Tier 1): engine --single/--grid + ramura still
#   in hud_flow (av_burnin.sh/.ps1). ADITIV: render complet + preview clip 5s NEschimbate.
#   Engine burnin_render.py = PARTAJAT bash<->PS1 → testul valideaza acelasi engine.
#   Functional best-effort pe bash (MSYS); coverage garantat pe calea PS1.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

ENGINE="$(cat "$SCRIPT_DIR/burnin_render.py")"
BSH="$(cat "$SCRIPT_DIR/av_burnin.sh")"
BPS="$(cat "$SCRIPT_DIR/av_burnin.ps1")"

# ── 1. Engine: --single + --grid + render_frame grid param ──────────
assert_contains "$ENGINE" '"--single"'                "engine: arg --single definit"
assert_contains "$ENGINE" '"--grid"'                  "engine: arg --grid definit"
assert_contains "$ENGINE" 'out_path, grid=False)'     "engine: render_frame are param grid"
assert_contains "$ENGINE" 'if args.single is not None:' "engine: ramura single (1 cadru)"
assert_contains "$ENGINE" 'grid=args.grid'            "engine: single paseaza grid"
assert_contains "$ENGINE" 'if grid:'                  "engine: bloc grila de pozitionare"

# ── 2. av_burnin.sh: ramura still + 3-cai + ADITIV ──────────────────
assert_contains "$BSH" 'PREVIEW_STILL=0'              "bash: state PREVIEW_STILL"
assert_contains "$BSH" 'PREVIEW_GRID=0'               "bash: state PREVIEW_GRID"
assert_contains "$BSH" 'local allow_still='           "bash: ask_preview accepta allow_still"
assert_contains "$BSH" 'ask_preview 1'                "bash: HUD cheama ask_preview cu still"
assert_contains "$BSH" 'if [ "$PREVIEW_STILL" -eq 1 ]; then' "bash: ramura still in hud_flow"
assert_contains "$BSH" '--single "$_st_t"'            "bash: still foloseste engine --single"
assert_contains "$BSH" 'av_open_path "$_st_out"'      "bash: auto-open PNG"
assert_contains "$BSH" 'PREVIEW_MODE=1'               "bash: ADITIV — calea clip 5s pastrata"

# ── 3. av_burnin.ps1: mirror ────────────────────────────────────────
assert_contains "$BPS" 'PreviewStill'                 "PS1: state PreviewStill"
assert_contains "$BPS" 'PreviewGrid'                  "PS1: state PreviewGrid"
assert_contains "$BPS" 'param([switch]$AllowStill)'   "PS1: Get-PreviewMode -AllowStill"
assert_contains "$BPS" 'Get-PreviewMode -AllowStill'  "PS1: HUD cheama cu -AllowStill"
assert_contains "$BPS" 'if ($script:PreviewStill)'    "PS1: ramura still"
assert_contains "$BPS" '--single'                     "PS1: still foloseste engine --single"
assert_contains "$BPS" 'Invoke-Item $stOut'           "PS1: auto-open PNG"
assert_contains "$BPS" 'PreviewMode = $true'          "PS1: ADITIV — calea clip 5s pastrata"

# ── 4. Functional: engine single/grid + render complet + composite ──
PYBIN="$(command -v python3 || command -v python || true)"
if [[ -n "$PYBIN" ]] && "$PYBIN" -c "import matplotlib" >/dev/null 2>&1; then
    tmpd="$(mktemp -d)"
    cat > "$tmpd/t.csv" <<'CSV'
timestamp,lat,lon,alt_m,speed_mps,speed_kmh,heading_deg,temp_c,source_brand
2024-03-15T12:30:45,44.37,26.10,512.4,12.5,45.0,278,23.7,dji
2024-03-15T12:30:47,44.371,26.101,540.9,14.0,50.4,281,24.1,dji
CSV
    preset="$SCRIPT_DIR/burnin_presets/full.conf"
    # --single → exact 1 cadru (cu grila)
    "$PYBIN" "$SCRIPT_DIR/burnin_render.py" --csv "$tmpd/t.csv" --preset "$preset" \
        --output-dir "$tmpd/single" --fps 10 --duration 1 --single 1.0 --grid \
        --width 480 --height 270 >/dev/null 2>&1
    n_single=$(find "$tmpd/single" -name 'frame_*.png' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "1" "$n_single" "functional: --single → exact 1 cadru (grid)"
    # render complet (fara --single) → multi-cadru (ADITIV, neschimbat)
    "$PYBIN" "$SCRIPT_DIR/burnin_render.py" --csv "$tmpd/t.csv" --preset "$preset" \
        --output-dir "$tmpd/full" --fps 2 --duration 1 --width 320 --height 240 >/dev/null 2>&1
    n_full=$(find "$tmpd/full" -name 'frame_*.png' 2>/dev/null | wc -l | tr -d ' ')
    ffok=1; [[ "$n_full" -ge 2 ]] && ffok=0
    assert_zero "$ffok" "functional: render complet ramane multi-cadru ($n_full)"
    # composite: ffmpeg testsrc + overlay HUD → PNG non-gol (ce face wrapper-ul)
    if command -v ffmpeg >/dev/null 2>&1 && [[ -f "$tmpd/single/frame_000001.png" ]]; then
        ffmpeg -v error -y -f lavfi -i "testsrc=size=480x270:rate=10:duration=1" -pix_fmt yuv420p "$tmpd/v.mp4" >/dev/null 2>&1
        ffmpeg -v error -ss 0.5 -i "$tmpd/v.mp4" -i "$tmpd/single/frame_000001.png" \
            -filter_complex "[0:v][1:v]overlay=0:0[v]" -map "[v]" -frames:v 1 -y "$tmpd/comp.png" >/dev/null 2>&1
        cok="no"; [[ -s "$tmpd/comp.png" ]] && cok="yes"
        assert_eq "yes" "$cok" "functional: compozitie HUD pe cadru video → PNG non-gol"
    fi
    rm -rf "$tmpd"
else
    echo "  (functional skip — python/matplotlib lipseste)" >&2
fi
