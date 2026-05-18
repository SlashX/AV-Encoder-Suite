#!/usr/bin/env bash
# Test v47 features:
# - av_telemetry.sh menu has opt 7 "Extract + embed lossless" + opt 8 "Anulare"
# - embed_telemetry_lossless function defined with expected structure
# - Container routing: MKV → mkv; MP4/MOV → dialog; unknown → mkv
# - EMBED_AFTER override mechanism (choice=7 → choice=4 + flag)
# - Main loop hook present

source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TELEM="$PROJECT_ROOT/src/av_telemetry.sh"

# ─────────────────────────────────────────────────────────────────────
# 1) Menu structure — opt 7 + opt 8
# ─────────────────────────────────────────────────────────────────────
grep -q '7) Extract + embed lossless' "$TELEM" \
    && _pass || _fail "menu has opt 7 'Extract + embed lossless'"
grep -q '8) Anulare' "$TELEM" \
    && _pass || _fail "menu opt 8 = Anulare (shifted from 7)"
grep -q 'Alege 1-8' "$TELEM" \
    && _pass || _fail "Read prompt updated to 'Alege 1-8'"
grep -q '\[ "\$choice" == "8" \] && { echo "Anulat.";' "$TELEM" \
    && _pass || _fail "choice=8 triggers Anulat"

# ─────────────────────────────────────────────────────────────────────
# 2) EMBED_AFTER override mechanism
# ─────────────────────────────────────────────────────────────────────
grep -q 'EMBED_AFTER=0' "$TELEM" \
    && _pass || _fail "EMBED_AFTER flag declared with default 0"
grep -q 'EMBED_AFTER=1' "$TELEM" \
    && _pass || _fail "EMBED_AFTER=1 set when choice=7"
grep -qE 'if \[ "\$choice" == "7" \]' "$TELEM" \
    && _pass || _fail "choice=7 triggers EMBED_AFTER override"
grep -q 'choice="4"' "$TELEM" \
    && _pass || _fail "choice overridden to 4 for extraction reuse"

# ─────────────────────────────────────────────────────────────────────
# 3) embed_telemetry_lossless function defined
# ─────────────────────────────────────────────────────────────────────
grep -q '^embed_telemetry_lossless()' "$TELEM" \
    && _pass || _fail "embed_telemetry_lossless function defined"

# ─────────────────────────────────────────────────────────────────────
# 4) Function body — artifact detection
# ─────────────────────────────────────────────────────────────────────
grep -q 'srt_file="\$OUTPUT_DIR/\${name}.srt"' "$TELEM" \
    && _pass || _fail "embed detects SRT artifact path"
grep -q 'csv_norm="\$OUTPUT_DIR/\${name}_norm.csv"' "$TELEM" \
    && _pass || _fail "embed detects normalized CSV path"
grep -q 'gpx_file="\$OUTPUT_DIR/\${name}.gpx"' "$TELEM" \
    && _pass || _fail "embed detects GPX path"

# ─────────────────────────────────────────────────────────────────────
# 5) Container routing — MKV/MP4 logic
# ─────────────────────────────────────────────────────────────────────
grep -q 'case "\$src_ext" in' "$TELEM" \
    && _pass || _fail "embed has container source extension case"
grep -q 'mp4|mov|m4v)' "$TELEM" \
    && _pass || _fail "embed handles mp4/mov/m4v containers"
grep -q 'target_ext="mkv"' "$TELEM" \
    && _pass || _fail "default target = mkv"

# ─────────────────────────────────────────────────────────────────────
# 6) ffmpeg cmd — attachments only for MKV
# ─────────────────────────────────────────────────────────────────────
grep -qE 'if \[\[ "\$target_ext" == "mkv" \]\]; then' "$TELEM" \
    && _pass || _fail "attachments gate on target=mkv"
grep -q '\-attach.*csv_norm' "$TELEM" \
    && _pass || _fail "ffmpeg -attach used for CSV (norm)"
grep -q '\-attach.*gpx_file' "$TELEM" \
    && _pass || _fail "ffmpeg -attach used for GPX"
grep -q 'mimetype=text/csv' "$TELEM" \
    && _pass || _fail "CSV mimetype set"
grep -q 'mimetype=application/gpx+xml' "$TELEM" \
    && _pass || _fail "GPX mimetype set"

# ─────────────────────────────────────────────────────────────────────
# 7) Subtitle codec — srt for MKV, mov_text for MP4
# ─────────────────────────────────────────────────────────────────────
grep -q 'subs_codec="srt"' "$TELEM" \
    && _pass || _fail "MKV subtitle codec = srt"
grep -q 'subs_codec="mov_text"' "$TELEM" \
    && _pass || _fail "MP4 subtitle codec = mov_text"

# ─────────────────────────────────────────────────────────────────────
# 8) Main loop hook
# ─────────────────────────────────────────────────────────────────────
grep -q 'if \[ "\$EMBED_AFTER" == "1" \]' "$TELEM" \
    && _pass || _fail "main loop hook gated on EMBED_AFTER"
grep -q 'embed_telemetry_lossless "\$file" "\$name"' "$TELEM" \
    && _pass || _fail "main loop calls embed_telemetry_lossless"

# ─────────────────────────────────────────────────────────────────────
# 9) Output naming convention
# ─────────────────────────────────────────────────────────────────────
grep -q 'name}_telem\.\${target_ext}' "$TELEM" \
    && _pass || _fail "output naming: <name>_telem.<ext>"

# ─────────────────────────────────────────────────────────────────────
# 10) v47 submenu — 4 profile options + Anulare
# ─────────────────────────────────────────────────────────────────────
grep -q 'EMBED LOSSLESS — selecteaza continut' "$TELEM" \
    && _pass || _fail "submenu header present"
grep -q '1) SRT only' "$TELEM" \
    && _pass || _fail "submenu opt 1 = SRT only"
grep -q '2) SRT + norm CSV' "$TELEM" \
    && _pass || _fail "submenu opt 2 = SRT + norm CSV"
grep -q '3) SRT + norm CSV + GPX' "$TELEM" \
    && _pass || _fail "submenu opt 3 = SRT + norm CSV + GPX"
grep -q '4) Toate' "$TELEM" \
    && _pass || _fail "submenu opt 4 = Toate"
grep -q '5) Anulare' "$TELEM" \
    && _pass || _fail "submenu opt 5 = Anulare"
grep -q 'EMBED_PROFILE="srt"' "$TELEM" \
    && _pass || _fail "EMBED_PROFILE=srt for opt 1"
grep -q 'EMBED_PROFILE="srt_csv"' "$TELEM" \
    && _pass || _fail "EMBED_PROFILE=srt_csv for opt 2"
grep -q 'EMBED_PROFILE="srt_csv_gpx"' "$TELEM" \
    && _pass || _fail "EMBED_PROFILE=srt_csv_gpx for opt 3 (default)"
grep -q 'EMBED_PROFILE="all"' "$TELEM" \
    && _pass || _fail "EMBED_PROFILE=all for opt 4"

# ─────────────────────────────────────────────────────────────────────
# 11) v47 — choice override per profile
# ─────────────────────────────────────────────────────────────────────
grep -qE 'EMBED_PROFILE="srt";\s+choice="3"' "$TELEM" \
    && _pass || _fail "opt 1 overrides choice=3 (SRT-only extract)"
grep -qE 'EMBED_PROFILE="all";\s+choice="4"' "$TELEM" \
    && _pass || _fail "opt 4 overrides choice=4"

# ─────────────────────────────────────────────────────────────────────
# 12) v47 — EMBED_PROFILE honored in embed function
# ─────────────────────────────────────────────────────────────────────
grep -q 'profile="\${EMBED_PROFILE:-srt_csv_gpx}"' "$TELEM" \
    && _pass || _fail "embed function reads EMBED_PROFILE with default srt_csv_gpx"
grep -q 'case "\$profile" in' "$TELEM" \
    && _pass || _fail "embed function branches per profile"
grep -q 'want_csv_basic=1' "$TELEM" \
    && _pass || _fail "profile=all attaches basic CSV"
grep -q 'want_csv_full=1' "$TELEM" \
    && _pass || _fail "profile=all attaches FULL CSV"
grep -q 'want_kml=1' "$TELEM" \
    && _pass || _fail "profile=all attaches KML"

# ─────────────────────────────────────────────────────────────────────
# 13) v47 — KML generator + all-profile MKV-only
# ─────────────────────────────────────────────────────────────────────
grep -q '_gen_kml_from_norm_csv' "$TELEM" \
    && _pass || _fail "KML generator helper defined"
grep -q 'mimetype=application/vnd.google-earth.kml+xml' "$TELEM" \
    && _pass || _fail "KML mimetype set"
grep -qE 'all\)\s*$' "$TELEM" \
    && _pass || _fail "profile=all has dedicated container branch"
