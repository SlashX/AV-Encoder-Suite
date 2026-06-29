#!/usr/bin/env bash
# Test v48 burn-in features:
# - av_burnin.sh with 3 flows (HUD / SRT / ASS) + main dispatcher
# - burnin_render.py for HUD flow (Python+matplotlib engine)
# - 3 layout presets (minimal / data-strip / full)
# - Launcher main menu opt 8 = Burn-in HUD, opt 9 = Anulare
# - SRT 4 style presets + force_style; ASS 3 scale presets
# - Output naming: <name>_hud.<ext> (HUD) vs <name>_subs.<ext> (SRT/ASS)

source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BURNIN="$PROJECT_ROOT/src/av_burnin.sh"
RENDER="$PROJECT_ROOT/src/burnin_render.py"
LAUNCHER="$PROJECT_ROOT/src/av_launcher.sh"

# ─────────────────────────────────────────────────────────────────────
# 1) Files exist + syntax
# ─────────────────────────────────────────────────────────────────────
[ -s "$BURNIN" ] && _pass || _fail "av_burnin.sh exists"
[ -s "$RENDER" ] && _pass || _fail "burnin_render.py exists"
[ -s "$PROJECT_ROOT/src/burnin_presets/minimal.conf"    ] && _pass || _fail "preset minimal.conf"
[ -s "$PROJECT_ROOT/src/burnin_presets/data-strip.conf" ] && _pass || _fail "preset data-strip.conf"
[ -s "$PROJECT_ROOT/src/burnin_presets/full.conf"       ] && _pass || _fail "preset full.conf"
bash -n "$BURNIN" 2>/dev/null && _pass || _fail "av_burnin.sh syntax"
if command -v python3 &>/dev/null; then
    (cd "$(dirname "$RENDER")" && python3 -m py_compile "$(basename "$RENDER")") 2>/dev/null \
        && _pass || _fail "burnin_render.py syntax"
else
    _pass  # skip-equivalent fara python3
fi

# ─────────────────────────────────────────────────────────────────────
# 2) Main dispatcher menu (3 flow + Anulare)
# ─────────────────────────────────────────────────────────────────────
grep -q 'BURN-IN — selecteaza tipul' "$BURNIN" \
    && _pass || _fail "main menu header present"
grep -q '1) Telemetry HUD' "$BURNIN"      && _pass || _fail "main menu opt 1 = Telemetry HUD"
grep -q '2) Subtitrari SRT' "$BURNIN"     && _pass || _fail "main menu opt 2 = SRT"
grep -q '3) Subtitrari ASS' "$BURNIN"     && _pass || _fail "main menu opt 3 = ASS"
grep -q '4) Image subs PGS/VobSub' "$BURNIN" && _pass || _fail "main menu opt 4 = Image subs"
grep -qE '5\) Anulare' "$BURNIN"          && _pass || _fail "main menu opt 5 = Anulare"
grep -q 'burnin_type'   "$BURNIN"         && _pass || _fail "main dispatcher reads burnin_type"
grep -q 'hud_flow'      "$BURNIN"         && _pass || _fail "main dispatcher calls hud_flow"
grep -q 'srt_flow'      "$BURNIN"         && _pass || _fail "main dispatcher calls srt_flow"
grep -q 'ass_flow'      "$BURNIN"         && _pass || _fail "main dispatcher calls ass_flow"
grep -q 'img_flow'      "$BURNIN"         && _pass || _fail "main dispatcher calls img_flow"

# ─────────────────────────────────────────────────────────────────────
# 3) Launcher integration (v49: opt 9 = Burn-in, opt 10 = Anulare)
# ─────────────────────────────────────────────────────────────────────
grep -qE '9\) Burn-in \(HUD/SRT/ASS/Image' "$LAUNCHER"  && _pass || _fail "launcher opt 9 = Burn-in (v49)"
grep -qE '10\) Anulare'            "$LAUNCHER"  && _pass || _fail "launcher opt 10 = Anulare (v49)"
grep -q 'av_burnin.sh'             "$LAUNCHER"  && _pass || _fail "launcher dispatches av_burnin.sh"

# ─────────────────────────────────────────────────────────────────────
# 4) Preset structure (HUD)
# ─────────────────────────────────────────────────────────────────────
grep -q '^PRESET_NAME=minimal'    "$PROJECT_ROOT/src/burnin_presets/minimal.conf"    && _pass || _fail "minimal: PRESET_NAME"
grep -q '^PRESET_NAME=data-strip' "$PROJECT_ROOT/src/burnin_presets/data-strip.conf" && _pass || _fail "data-strip: PRESET_NAME"
grep -q '^PRESET_NAME=full'       "$PROJECT_ROOT/src/burnin_presets/full.conf"       && _pass || _fail "full: PRESET_NAME"
grep -q '^HUD_MAP=1'              "$PROJECT_ROOT/src/burnin_presets/full.conf"       && _pass || _fail "full preset enables map"
grep -q '^HUD_DATA_STRIP=1'       "$PROJECT_ROOT/src/burnin_presets/data-strip.conf" && _pass || _fail "data-strip enables strip"
grep -q '^HUD_DATA_STRIP=0'       "$PROJECT_ROOT/src/burnin_presets/minimal.conf"    && _pass || _fail "minimal disables strip"

# ─────────────────────────────────────────────────────────────────────
# 5) HUD flow markers
# ─────────────────────────────────────────────────────────────────────
grep -q 'hud_flow() {'                  "$BURNIN" && _pass || _fail "hud_flow() defined"
grep -q 'LAYOUT PRESET'                 "$BURNIN" && _pass || _fail "hud: layout menu present"
grep -q 'PRESET="minimal"'              "$BURNIN" && _pass || _fail "hud: preset minimal"
grep -q 'PRESET="data-strip"'           "$BURNIN" && _pass || _fail "hud: preset data-strip"
grep -q 'PRESET="full"'                 "$BURNIN" && _pass || _fail "hud: preset full"
grep -qE 'out_suffix="hud"'             "$BURNIN" && _pass || _fail "hud: output naming hud suffix"
grep -q '_\${out_suffix}\.\${ext}'      "$BURNIN" && _pass || _fail "hud: output template <name>_<suffix>.<ext>"
grep -q 'filter_complex.*overlay'       "$BURNIN" && _pass || _fail "hud: filter_complex overlay"
grep -q 'frame_%06d.png'                "$BURNIN" && _pass || _fail "hud: PNG seq pattern"
grep -q 'extract_brand_from_csv'        "$BURNIN" && _pass || _fail "hud: brand extraction from CSV"
grep -qE 'external_\*\)'                "$BURNIN" && _pass || _fail "hud: external_* triggers sync offset prompt"
grep -q 'import matplotlib, numpy'      "$BURNIN" && _pass || _fail "hud: matplotlib+numpy detection"

# ─────────────────────────────────────────────────────────────────────
# 6) SRT flow markers
# ─────────────────────────────────────────────────────────────────────
grep -q 'srt_flow() {'                  "$BURNIN" && _pass || _fail "srt_flow() defined"
grep -q 'SRT BURN-IN'                   "$BURNIN" && _pass || _fail "srt: header banner"
grep -q 'STIL SRT'                      "$BURNIN" && _pass || _fail "srt: style menu"
grep -q 'FontSize=18'                   "$BURNIN" && _pass || _fail "srt: style 1 Small font 18"
grep -q 'FontSize=24'                   "$BURNIN" && _pass || _fail "srt: style 2 Medium font 24"
grep -q 'FontSize=32'                   "$BURNIN" && _pass || _fail "srt: style 3 Large font 32"
grep -q 'force_style'                   "$BURNIN" && _pass || _fail "srt: force_style applied"
grep -q "subtitles=" "$BURNIN"                     && _pass || _fail "srt: subtitles= filter"
[ "$(grep -c 'out_suffix="subs"' "$BURNIN")" -ge 1 ] && _pass || _fail "srt/ass/img: output naming subs suffix"

# ─────────────────────────────────────────────────────────────────────
# 7) ASS flow markers
# ─────────────────────────────────────────────────────────────────────
grep -q 'ass_flow() {'                  "$BURNIN" && _pass || _fail "ass_flow() defined"
grep -q 'ASS BURN-IN'                   "$BURNIN" && _pass || _fail "ass: header banner"
grep -q 'ASS FONT SCALE'                "$BURNIN" && _pass || _fail "ass: scale menu"
grep -q 'ScaleX=125,ScaleY=125'         "$BURNIN" && _pass || _fail "ass: 1.25x scale option"
grep -q 'ScaleX=150,ScaleY=150'         "$BURNIN" && _pass || _fail "ass: 1.5x scale option"
grep -q "ass_filter=\"ass\""            "$BURNIN" && _pass || _fail "ass: ass filter used"

# ─────────────────────────────────────────────────────────────────────
# 7b) Image subs flow markers (PGS / VobSub, ext + embedded)
# ─────────────────────────────────────────────────────────────────────
grep -q 'img_flow() {'                  "$BURNIN" && _pass || _fail "img_flow() defined"
grep -q 'img_scan_dir() {'              "$BURNIN" && _pass || _fail "img_scan_dir() defined"
grep -q 'IMAGE SUBS BURN-IN'            "$BURNIN" && _pass || _fail "img: header banner"
grep -q 'PGS \.sup'                     "$BURNIN" && _pass || _fail "img: external PGS .sup scan"
grep -q 'VobSub \.idx/\.sub'            "$BURNIN" && _pass || _fail "img: external VobSub .idx+.sub scan"
grep -q 'hdmv_pgs_subtitle'             "$BURNIN" && _pass || _fail "img: embedded PGS detection (ffprobe codec)"
grep -q 'dvd_subtitle'                  "$BURNIN" && _pass || _fail "img: embedded VobSub detection"
grep -q 'PGS embedded s:'               "$BURNIN" && _pass || _fail "img: embedded track label"
grep -q 'PAIRS_KIND'                    "$BURNIN" && _pass || _fail "img: PAIRS_KIND tracking"
grep -q 'PAIRS_TRACK'                   "$BURNIN" && _pass || _fail "img: PAIRS_TRACK tracking (stream idx)"
grep -qE 'ext_pgs\|ext_vob\)|case "\$kind"' "$BURNIN" && _pass || _fail "img: kind dispatcher"
grep -q '0:v\]\[1:s\]overlay'           "$BURNIN" && _pass || _fail "img: ext overlay filter [0:v][1:s]"
grep -qE '\[0:v\]\[0:s:\$\{track\}\]overlay' "$BURNIN" && _pass || _fail "img: embedded overlay filter [0:v][0:s:N]"
[ "$(grep -c 'out_suffix="subs"' "$BURNIN")" -ge 3 ] && _pass || _fail "img: subs suffix used by srt+ass+img (>=3 occurrences)"

# ─────────────────────────────────────────────────────────────────────
# 7c) Preview mode (shared, opt-in pe toate 4 flow-uri)
# ─────────────────────────────────────────────────────────────────────
grep -q 'ask_preview() {'               "$BURNIN" && _pass || _fail "preview: ask_preview() defined"
grep -q 'preview_compute_window() {'    "$BURNIN" && _pass || _fail "preview: preview_compute_window() defined"
grep -q 'PREVIEW_MODE='                 "$BURNIN" && _pass || _fail "preview: PREVIEW_MODE flag init"
grep -q 'PREVIEW_T_START='              "$BURNIN" && _pass || _fail "preview: PREVIEW_T_START flag"
grep -q 'PREVIEW_DURATION='             "$BURNIN" && _pass || _fail "preview: PREVIEW_DURATION flag"
grep -q '5s clip la mid-point'          "$BURNIN" && _pass || _fail "preview: prompt text 5s mid-point"
grep -q '_preview\.'                    "$BURNIN" && _pass || _fail "preview: output naming _preview"
# 4 flow-uri trebuie sa cheme ask_preview (HUD-ul il cheama cu arg: `ask_preview 1` pt still layout, v81)
[ "$(grep -cE 'ask_preview( [0-9]+)?$' "$BURNIN")" -ge 4 ] && _pass || _fail "preview: 4 flow-uri cheama ask_preview"
grep -q '"\${seek_args\[@\]}"'          "$BURNIN" && _pass || _fail "preview: seek_args expansiune"
grep -q -- '-ss "\$PREVIEW_T_START"'    "$BURNIN" && _pass || _fail "preview: ffmpeg -ss PREVIEW_T_START"
grep -q -- '-t "\$PREVIEW_DURATION"'    "$BURNIN" && _pass || _fail "preview: ffmpeg -t PREVIEW_DURATION"
grep -q -- '-copyts'                    "$BURNIN" && _pass || _fail "preview: -copyts pt subtitle filters"

# Bug-uri rezolvate v48 audit:
# - preview_compute_window returneaza 1 pe durata invalida (caller fall-back)
grep -q 'return 1'                      "$BURNIN" && _pass || _fail "preview: compute_window returneaza 1 pe durata invalida"
grep -q 'd+0 > 0.05'                    "$BURNIN" && _pass || _fail "preview: validare numerica durata (awk)"
# - 4 flow-uri verifica daca preview_compute_window a reusit
[ "$(grep -c 'if preview_compute_window' "$BURNIN")" -ge 4 ] && _pass \
    || _fail "preview: 4 flow-uri verifica return code (caller fall-back)"
# - WARN message la fall-back
grep -q 'Durata invalida'               "$BURNIN" && _pass || _fail "preview: WARN message la fall-back"
# - img_scan_dir folosesta || true pe ffprobe (previne abort set -e)
grep -qE 'ffprobe.*\|\| true|2>/dev/null \|\| true' "$BURNIN" && _pass \
    || _fail "img_scan_dir: ffprobe protejat cu || true (set -e safety)"
# - img_flow foloseste if/then pe ffmpeg (nu rc=\$? care abortaza set -e)
[ "$(grep -c 'if ffmpeg -v error -stats' "$BURNIN")" -ge 4 ] && _pass \
    || _fail "img_flow: if ffmpeg in toate ramurile (set -e safety, >= 4 hits)"
# - scan exclude *_preview in toate locurile
[ "$(grep -c '\*_preview' "$BURNIN")" -ge 2 ] && _pass \
    || _fail "scan: *_preview in exclude list (scan_for_pairs + img_scan_dir)"

# ─────────────────────────────────────────────────────────────────────
# 8) Shared helpers
# ─────────────────────────────────────────────────────────────────────
grep -q 'ask_encoder()'                 "$BURNIN" && _pass || _fail "shared: ask_encoder()"
grep -q 'pick_files()'                  "$BURNIN" && _pass || _fail "shared: pick_files()"
grep -q 'scan_for_pairs()'              "$BURNIN" && _pass || _fail "shared: scan_for_pairs()"
grep -q 'escape_ffmpeg_filter_path()'   "$BURNIN" && _pass || _fail "shared: escape_ffmpeg_filter_path()"
grep -q 'ENC_NAME="libx265"'            "$BURNIN" && _pass || _fail "encoder opt 1 = libx265"
grep -q 'ENC_NAME="libx264"'            "$BURNIN" && _pass || _fail "encoder opt 2 = libx264"
grep -q 'ENC_NAME="libsvtav1"'          "$BURNIN" && _pass || _fail "encoder opt 3 = libsvtav1"

# ─────────────────────────────────────────────────────────────────────
# 9) Python render engine (HUD)
# ─────────────────────────────────────────────────────────────────────
grep -q 'def load_csv_points'  "$RENDER" && _pass || _fail "render: load_csv_points"
grep -q 'def sample_at'        "$RENDER" && _pass || _fail "render: sample_at"
grep -q 'def render_frame'     "$RENDER" && _pass || _fail "render: render_frame"
grep -q 'def build_route_xy'   "$RENDER" && _pass || _fail "render: build_route_xy"
grep -qE -e '--csv'    "$RENDER" && _pass || _fail "render: --csv arg"
grep -qE -e '--preset' "$RENDER" && _pass || _fail "render: --preset arg"
grep -qE -e '--fps'    "$RENDER" && _pass || _fail "render: --fps arg"
grep -qE -e '--offset' "$RENDER" && _pass || _fail "render: --offset arg"
