#!/usr/bin/env bash
# v57: av_check — TIER 1 + TIER 2 partial fixes
#   • AV1 DV detection via side_data per-frame (codec_tag = [0][0][0][0])
#   • 12-bit detection corectata (bits_per_raw_sample + pix_fmt p12)
#   • TYPE/LOG mutual exclusion (LOG sursa NU e HLG nativ)
#   • MKV bitrate fallback (stream → format → size/dur estimate)
#   • HDR rich fields: ColorPrimaries/Space/Range + MaxCLL/FALL + MasterDisplay
#   • HDR10+ scene count (keyframe heuristic)
#   • Per-track audio detail (PS1 nou)
#   • Stale comparison suffix list extins
#   • Audio csv field-order fix (bash latent bug)
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SH="$PROJECT_ROOT/src/av_check.sh"
PS1="$PROJECT_ROOT/src/av_check.ps1"

[[ -f "$SH"  ]] || skip_test "lipseste av_check.sh"
[[ -f "$PS1" ]] || skip_test "lipseste av_check.ps1"

# ══════════════════════════════════════════════════════════════════════
# 1. CSV header — 37 coloane (30 + 7 HDR rich), nume aliniate bash↔PS1
# ══════════════════════════════════════════════════════════════════════
SH_HDR=$(grep -m1 '^echo "Fisier,Format_sursa' "$SH")
SH_HDR_CONTENT=$(sed -E 's/^echo "//; s/" \\$//' <<<"$SH_HDR")
SH_COLS=$(awk -F',' '{print NF}' <<<"$SH_HDR_CONTENT")
assert_eq "38" "$SH_COLS" "bash CSV header = 38 coloane (incl Container)"

PS1_HDR=$(grep -m1 '"Fisier,Format_sursa' "$PS1")
PS1_HDR_CONTENT=$(sed -E 's/^"//; s/".*$//' <<<"$PS1_HDR")
PS1_COLS=$(awk -F',' '{print NF}' <<<"$PS1_HDR_CONTENT")
assert_eq "38" "$PS1_COLS" "PS1 CSV header = 38 coloane (incl Container)"

# Coloanele noi prezente in ambele scripturi (7 HDR rich + 1 Container)
for col in Container ColorPrimaries ColorSpace ColorRange MaxCLL MaxFALL MasterDisplay HDR10Plus_Scenes; do
    assert_contains "$SH_HDR_CONTENT" "$col" "bash CSV contine $col"
    assert_contains "$PS1_HDR_CONTENT" "$col" "PS1 CSV contine $col"
done

# ══════════════════════════════════════════════════════════════════════
# 2. 12-bit depth detection — bits_per_raw_sample + pix_fmt p12 fallback
# ══════════════════════════════════════════════════════════════════════
# bash get_source_format trebuie sa accepte parametrul 5 (bits_raw)
assert_match "$(grep -c 'bits_raw="\${5' "$SH")" "^[1-9]" \
    "bash get_source_format accepta bits_raw"
# Pattern-uri p12/p012 si p16/p016 prezente
for pat in 'p12\*' 'p012\*' 'p16\*' 'p016\*'; do
    assert_match "$(grep -c "$pat" "$SH")" "^[1-9]" "bash pix_fmt pattern $pat"
done
# 12bit label produs
assert_contains "$(cat "$SH")" 'depth_label="${depth}bit"' "bash depth_label dynamic"

# PS1: Get-SourceInfo cu bits_per_raw_sample + match p10/p12/p16
assert_contains "$(cat "$PS1")" 'bits_per_raw_sample' "PS1 fetch bits_per_raw_sample"
for pat in 'p10|p010' 'p12|p012' 'p16|p016'; do
    assert_contains "$(cat "$PS1")" "$pat" "PS1 pix_fmt pattern $pat"
done

# ══════════════════════════════════════════════════════════════════════
# 3. AV1 DV detection via side_data per-frame
# ══════════════════════════════════════════════════════════════════════
assert_contains "$(cat "$SH")" 'DV_FROM_FRAMES' "bash AV1 DV detection marker"
assert_contains "$(cat "$SH")" 'Dolby Vision Metadata' "bash side_data DV match"
assert_contains "$(cat "$PS1")" 'isDVFrames' "PS1 AV1 DV detection marker"
assert_contains "$(cat "$PS1")" 'Dolby Vision Metadata' "PS1 side_data DV match"

# Get-DVProfile in PS1 are codec_tag fallback (paritate bash)
assert_contains "$(cat "$PS1")" "dvhe" "PS1 Get-DVProfile codec_tag fallback"

# ══════════════════════════════════════════════════════════════════════
# 4. TYPE/LOG mutual exclusion
# ══════════════════════════════════════════════════════════════════════
assert_contains "$(cat "$SH")" 'SDR (LOG)' "bash TYPE=SDR (LOG) override"
assert_contains "$(cat "$PS1")" 'SDR (LOG)' "PS1 TYPE=SDR (LOG) override"

# ══════════════════════════════════════════════════════════════════════
# 5. MKV bitrate fallback (stream → format → estimat)
# ══════════════════════════════════════════════════════════════════════
assert_contains "$(cat "$SH")" 'FMT_BITRATE' "bash format=bit_rate fallback"
assert_contains "$(cat "$SH")" '(est)' "bash size/dur estimate label"
assert_contains "$(cat "$PS1")" 'fmtBr' "PS1 format=bit_rate fallback"
assert_contains "$(cat "$PS1")" '(est)' "PS1 size/dur estimate label"

# ══════════════════════════════════════════════════════════════════════
# 6. HDR rich fields — ColorPrimaries/Space/Range + MaxCLL/FALL + MasterDisplay
# ══════════════════════════════════════════════════════════════════════
for field in COLOR_PRIMARIES COLOR_SPACE_VAL COLOR_RANGE_VAL MAX_CLL MAX_FALL MASTER_DISPLAY HDR10PLUS_SCENES; do
    assert_contains "$(cat "$SH")" "$field" "bash var $field prezent"
done

# PS1 Get-HdrRichInfo helper si proprietatile
assert_contains "$(cat "$PS1")" 'function Get-HdrRichInfo' "PS1 Get-HdrRichInfo definita"
for prop in colorPrimaries colorSpace colorRange maxCll maxFall masterDisplay hdr10PlusScenes; do
    assert_contains "$(cat "$PS1")" "$prop" "PS1 hash prop $prop"
done

# Mastering display primaries detection thresholds (BT.2020/DCI-P3/BT.709)
assert_contains "$(cat "$SH")"  "BT.2020" "bash primaries BT.2020 detect"
assert_contains "$(cat "$SH")"  "DCI-P3"  "bash primaries DCI-P3 detect"
assert_contains "$(cat "$PS1")" "BT.2020" "PS1 primaries BT.2020 detect"
assert_contains "$(cat "$PS1")" "DCI-P3"  "PS1 primaries DCI-P3 detect"

# ══════════════════════════════════════════════════════════════════════
# 7. HDR10+ scene count — keyframe scan bounded
# ══════════════════════════════════════════════════════════════════════
assert_contains "$(cat "$SH")"  '-skip_frame nokey' "bash HDR10+ keyframe scan"
assert_contains "$(cat "$PS1")" '-skip_frame nokey' "PS1 HDR10+ keyframe scan"

# ══════════════════════════════════════════════════════════════════════
# 8. Per-track audio detail (PS1 nou pentru paritate cu bash)
# ══════════════════════════════════════════════════════════════════════
assert_contains "$(cat "$SH")"  "AUDIO_TRACKS_DETAIL" "bash AUDIO_TRACKS_DETAIL existent"
assert_contains "$(cat "$PS1")" 'audioTracksDetail' "PS1 audioTracksDetail nou"
# Compact format folosit (robust la reordonare ffprobe)
assert_contains "$(cat "$SH")"  'compact=nk=0:p=0' "bash audio per-track compact format"
assert_contains "$(cat "$PS1")" 'compact=nk=0:p=0' "PS1 audio per-track compact format"

# ══════════════════════════════════════════════════════════════════════
# 9. Audio main field-order fix (bash latent bug — csv reordoneaza)
# ══════════════════════════════════════════════════════════════════════
# Bash trecut la default= cu parse via awk per-key (_ai_field)
assert_contains "$(cat "$SH")" '_ai_field' "bash audio main parse via key=value"
assert_contains "$(cat "$SH")" 'default=noprint_wrappers=1' "bash audio main default= format"

# ══════════════════════════════════════════════════════════════════════
# 10. Stale comparison suffix list — extins cu v44+ outputs
# ══════════════════════════════════════════════════════════════════════
NEW_SFX="_prores _apv _remux _mux _telem _hud _subs _preview _nodv _nohdr10plus _dvhybrid _hwenc"
for sfx in $NEW_SFX; do
    assert_contains "$(cat "$SH")"  "$sfx" "bash comp suffix $sfx"
    assert_contains "$(cat "$PS1")" "$sfx" "PS1 comp suffix $sfx"
done

# ══════════════════════════════════════════════════════════════════════
# 11. Duplicate DNxH branch eliminata (bash)
# ══════════════════════════════════════════════════════════════════════
DNXH_COUNT=$(grep -c '"DNxH"' "$SH")
assert_eq "1" "$DNXH_COUNT" "bash DNxH branch — un singur match (dup eliminat)"

# ══════════════════════════════════════════════════════════════════════
# 12. PS1 attachments mimes display (paritate bash)
# ══════════════════════════════════════════════════════════════════════
assert_contains "$(cat "$PS1")" 'attMimes' "PS1 attachments mimes parsing"

# ══════════════════════════════════════════════════════════════════════
# 13. PS1 env override AV_INPUT_DIR / AV_OUTPUT_DIR (testability)
# ══════════════════════════════════════════════════════════════════════
assert_contains "$(cat "$PS1")" 'AV_INPUT_DIR'  "PS1 AV_INPUT_DIR env override"
assert_contains "$(cat "$PS1")" 'AV_OUTPUT_DIR' "PS1 AV_OUTPUT_DIR env override"

# ══════════════════════════════════════════════════════════════════════
# 14. side_data query correctness — bug critic descoperit pe real samples
#      `frame_side_data=type` e invalid (ignora selector → full frame dump);
#      corect e `frame_side_data=side_data_type`. Toate site-urile HDR10+/DV
#      per-frame trebuie sa foloseasca varianta corecta.
# ══════════════════════════════════════════════════════════════════════
BAD_SH=$(grep -c "frame_side_data=type" "$SH" || true)
assert_eq "0" "$BAD_SH" "bash zero query frame_side_data=type (invalid)"
GOOD_SH=$(grep -c "frame_side_data=side_data_type" "$SH" || true)
assert_match "$GOOD_SH" "^[2-9]" "bash >=2 site-uri frame_side_data=side_data_type"
BAD_PS1=$(grep -c "frame_side_data=type" "$PS1" || true)
assert_eq "0" "$BAD_PS1" "PS1 zero query frame_side_data=type (invalid)"
GOOD_PS1=$(grep -c "frame_side_data=side_data_type" "$PS1" || true)
assert_match "$GOOD_PS1" "^[3-9]" "PS1 >=3 site-uri frame_side_data=side_data_type"

# ══════════════════════════════════════════════════════════════════════
# 15. Samsung Log — short-circuit pe `com.samsung.android.logvideo`
#      Tag-ul autoritar (format-level) este definitive marker pentru S24 Ultra.
# ══════════════════════════════════════════════════════════════════════
assert_contains "$(cat "$SH")"  "com\\.samsung\\.android\\.logvideo" "bash Samsung Log tag autoritar"
assert_contains "$(cat "$PS1")" "com\\.samsung\\.android\\.logvideo" "PS1 Samsung Log tag autoritar"

# Pix_fmt fallback pentru bits_per_raw_sample=N/A (necesar pe S24 Ultra unde
# bits_per_raw_sample lipseste, dar pix_fmt=yuv420p10le e prezent).
assert_contains "$(cat "$SH")"  "deriva depth-ul din pix_fmt" "bash pix_fmt fallback in get_log_profile"
assert_contains "$(cat "$PS1")" "deriva depth-ul din pix_fmt" "PS1 pix_fmt fallback in Get-LogProfile"

# DJI camera_make: fallback `encoder=DJI` pe langa `make=dji` (clipuri re-muxed
# fara djmd/dbgi tracks raman recognoscute; paritate cu Samsung short-circuit).
assert_contains "$(cat "$SH")"  'encoder=.*dji' "bash encoder=DJI fallback in get_log_profile"
assert_contains "$(cat "$PS1")" 'encoder=.*dji' "PS1 encoder=DJI fallback in Get-LogProfile"

# ══════════════════════════════════════════════════════════════════════
# 16. PS1 Get-FFprobeValue — csv=p=0 trailing comma fix (paritate bash)
#      ffprobe 8.x emite trailing virgula la csv=p=0 single-field queries
#      → polua display + CSV. Switch la default=noprint_wrappers=1:nokey=1.
# ══════════════════════════════════════════════════════════════════════
GFV_BLOCK=$(awk '/function Get-FFprobeValue/,/^}/' "$PS1")
assert_contains "$GFV_BLOCK" "default=noprint_wrappers=1:nokey=1" "PS1 Get-FFprobeValue foloseste default= format"
# Linia care invoca ffprobe NU mai are csv=p=0 (comentariile pot mentiona)
# Filtru strict: lini ffprobe-call ($&), exclude comentariile (#)
GFV_FFPROBE_LINE=$(echo "$GFV_BLOCK" | grep -E '^\s*\(\$\(' | grep "ffprobe" | head -1)
echo "$GFV_FFPROBE_LINE" | grep -q "csv=p=0" && assert_eq "1" "0" "PS1 Get-FFprobeValue inca foloseste csv=p=0" || assert_eq "1" "1" "PS1 Get-FFprobeValue ffprobe call fara csv=p=0"

# ══════════════════════════════════════════════════════════════════════
# 17. Integration smoke (daca ffprobe disponibil): rulare pe sample HDR10
# ══════════════════════════════════════════════════════════════════════
if command -v ffprobe >/dev/null 2>&1; then
    SAMPLES="$PROJECT_ROOT/tests/fixtures/samples"
    if [[ -f "$SAMPLES/hdr10_320p.mkv" && -f "$SAMPLES/sdr_320p.mp4" ]]; then
        TMPDIR_TEST=$(mktemp -d)
        mkdir -p "$TMPDIR_TEST/IN" "$TMPDIR_TEST/OUT"
        cp "$SAMPLES/hdr10_320p.mkv" "$SAMPLES/sdr_320p.mp4" "$TMPDIR_TEST/IN/"
        INPUT_DIR="$TMPDIR_TEST/IN" OUTPUT_DIR="$TMPDIR_TEST/OUT" bash "$SH" >/dev/null 2>&1 || true
        CSV="$TMPDIR_TEST/OUT/av_check_report.csv"
        if [[ -f "$CSV" ]]; then
            HDR_ROW=$(grep -m1 'hdr10' "$CSV" || true)
            assert_contains "$HDR_ROW" "HDR10"   "integration: HDR10 sample detectat ca HDR10"
            assert_contains "$HDR_ROW" "bt2020"  "integration: ColorPrimaries=bt2020"
            assert_contains "$HDR_ROW" "1000"    "integration: MaxCLL=1000 prezent"
            # Header line trebuie sa fie 38 coloane
            HEAD_COLS=$(head -1 "$CSV" | awk -F',' '{print NF}')
            assert_eq "38" "$HEAD_COLS" "integration: CSV header = 38 coloane runtime"
        fi
        rm -rf "$TMPDIR_TEST"
    fi
fi
