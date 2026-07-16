#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# v91 — TS/BD [PROGRAM] stream double-listing dedupe (bash).
#   ffprobe pe transport streams cu program (.m2ts/.mts/.ts, ex. rip-uri
#   Blu-ray) listeaza FIECARE stream de DOUA ori (o data prin [PROGRAM],
#   o data normal) → count-urile de piste se dubleaza. Aceeasi clasa ca
#   dublarea IAMF-in-MP4 (v88, deja deduplicata pe AUDIO_COUNT) si DJI v:0.
#   Fix v91: dedupe pe index (sort -u / seen-set) pe caile INCA neacoperite:
#     - av_check get_subtitles_info (subtitle count era dublu pe .m2ts)
#     - handle_multi_audio_dialog ntracks + atinfo (dialog per-pista
#       fals-declansat pe TS single-audio + piste fantoma la selectie)
#   Source-level ruleaza mereu; functionalul (sinteza .ts + ffprobe) se
#   auto-sare cand lipseste ffmpeg/ffprobe.
# ══════════════════════════════════════════════════════════════════════
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SRC:$PATH"

CHK="$(cat "$SRC/av_check.sh")"
CMN="$(cat "$SRC/av_common.sh")"

# ── 1. Source-level: subtitle dedupe (av_check get_subtitles_info) ─────
SUBFN="$(awk '/^get_subtitles_info\(\)/{f=1} f{print} f&&/^}$/{exit}' "$SRC/av_check.sh")"
assert_contains "$SUBFN" '_cur_dup'       "get_subtitles_info deduplica (marcaj _cur_dup)"
assert_contains "$SUBFN" '_seen'          "get_subtitles_info tine set de indecsi vazuti"
assert_contains "$SUBFN" 'index=([0-9]+)' "get_subtitles_info parseaza indexul pt dedupe"

# ── 2. Source-level: multi-audio ntracks + atinfo dedupe (av_common) ──
MAD="$(awk '/^handle_multi_audio_dialog\(\)/{f=1} f{print} f&&/^}$/{exit}' "$SRC/av_common.sh")"
assert_contains "$MAD" 'sort -u'   "ntracks deduplica pe index (sort -u)"
assert_contains "$MAD" '_at_seen'  "atinfo dialog deduplica pe index (_at_seen)"
assert_contains "$MAD" 'stream=index,codec_name,channels' "atinfo query include index pt dedupe"

# ── 2b. _file_spatial_label deduplica (parity cu Get-FileSpatialLabel PS1) ──
FSL="$(awk '/^_file_spatial_label\(\)/{f=1} f{print} f&&/^}$/{exit}' "$SRC/av_common.sh")"
assert_contains "$FSL" 'sort -u'   "_file_spatial_label deduplica pe index (TS/BD parity)"

# ── 3. Functional hermetic (sinteza .ts cu [PROGRAM]) ─────────────────
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    TMP="$(mktemp -d)"
    _dedup_count() {   # replica pipeline-ul ntracks din handle_multi_audio_dialog
        ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" 2>/dev/null | \
            tr -d '\r' | sed 's/,*$//' | grep '^[0-9]' | sort -u | grep -c .
    }
    _raw_count() {
        ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" 2>/dev/null | \
            tr -d '\r' | grep -c '^[0-9]'
    }

    # .ts cu 1 audio → program dubleaza la ffprobe (raw=2), dedupe=1
    ffmpeg -v error -y -f lavfi -i "testsrc=size=320x240:rate=10:duration=1" \
        -f lavfi -i "sine=frequency=440:duration=1" \
        -c:v libx264 -c:a aac -f mpegts "$TMP/a1.ts" </dev/null 2>/dev/null
    if [ -s "$TMP/a1.ts" ]; then
        # premisa: TS-ul chiar dubleaza (altfel testul nu dovedeste nimic)
        assert_eq "2" "$(_raw_count "$TMP/a1.ts")" "premisa: .ts 1-audio dubleaza la ffprobe (raw=2)"
        assert_eq "1" "$(_dedup_count "$TMP/a1.ts")" "dedupe .ts 1-audio → ntracks=1 (fara dialog fals)"
    else
        skip_test "sinteza .ts esuata (libx264/aac lipsa?)"
    fi

    # .ts cu 2 audio → raw=4, dedupe=2 (dialogul vede piste REALE, nu fantome)
    ffmpeg -v error -y -f lavfi -i "testsrc=size=320x240:rate=10:duration=1" \
        -f lavfi -i "sine=frequency=440:duration=1" \
        -f lavfi -i "sine=frequency=880:duration=1" \
        -map 0:v -map 1:a -map 2:a -c:v libx264 -c:a aac -f mpegts "$TMP/a2.ts" </dev/null 2>/dev/null
    if [ -s "$TMP/a2.ts" ]; then
        assert_eq "4" "$(_raw_count "$TMP/a2.ts")"   "premisa: .ts 2-audio → raw=4 (2×2 program)"
        assert_eq "2" "$(_dedup_count "$TMP/a2.ts")" "dedupe .ts 2-audio → ntracks=2 (piste reale)"
    fi

    # regresie: fisier normal (MKV cu 1 PGS, fara program) → 1 subtitrare (dedupe nu
    # strica numararea pe surse care NU dubleaza). Gated pe sample-ul PGS din src/.
    PGS="$SRC/Forced-Sub-Sample-(PGS).mkv"
    if [ -f "$PGS" ]; then
        mkdir -p "$TMP/pgsdir"; cp "$PGS" "$TMP/pgsdir/"
        _subline=$(printf '\n\n\n' | INPUT_DIR="$TMP/pgsdir" OUTPUT_DIR="$TMP" \
            bash "$SRC/av_check.sh" 2>/dev/null | grep -a "Subtitrari" | head -1)
        assert_match "$_subline" '1'      "regresie: PGS MKV (fara program) → 1 subtitrare (dedupe nu strica normalul)"
    fi

    rm -rf "$TMP"
else
    echo "  (functional sarit — ffmpeg/ffprobe lipsesc)"
fi

# sumarul vine din trap-ul EXIT al framework-ului
