#!/usr/bin/env bash
# v62 Faza B — DJI Osmo Action 6 D-Log M via djmd protobuf (.2.4.1==19).
#   Container raporteaza bt709 identic pt Normal SI D-Log M → discriminatorul sta
#   in protobuf-ul djmd. Engine partajat src/dji_djmd_dlogm.py (model-gate AC006).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
# ffmpeg: global (PATH) sau bundle-uit in src/ (Windows testing) — ca la v55/v56
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
INPUT_DIR=/tmp/v62b_in OUTPUT_DIR=/tmp/v62b_out
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
source "$SCRIPT_DIR/av_common.sh"

COMMON_SRC="$(cat "$SCRIPT_DIR/av_common.sh")"
CHECK_SRC="$(cat "$SCRIPT_DIR/av_check.sh")"
ENGINE="$SCRIPT_DIR/dji_djmd_dlogm.py"

# ── 1. Helper + integrare prezente ─────────────────────────────────
assert_eq "function" "$(type -t _detect_dji_dlogm)" "_detect_dji_dlogm exista"
assert_file_exists "$ENGINE" "engine dji_djmd_dlogm.py exista"
DSI="$(declare -f detect_source_info)"
assert_contains "$DSI" "_detect_dji_dlogm" "detect_source_info: sondeaza djmd pe DJI bt709"
GLP="$(declare -f get_log_profile 2>/dev/null)$CHECK_SRC"
assert_contains "$CHECK_SRC" "_detect_dji_dlogm" "av_check get_log_profile: sondeaza djmd"

# ── 2. Engine hermetic — protobuf sintetic (fara ffmpeg/sample) ─────
py=$(_av_python) || skip_test "Python 3 indisponibil"
TMP="$(mktemp -d)"
# Path .2.4.1 = field2{ field4{ field1=VAL } } in wire-format:
#   field1 varint:  08 <val>          (tag (1<<3)|0=0x08)
#   field4 submsg:  22 02 08 <val>    (tag (4<<3)|2=0x22, len 2)
#   field2 submsg:  12 04 22 02 08 <val> (tag (2<<3)|2=0x12, len 4)
GATE="dvtm_ac206.proto"
printf '%s\x12\x04\x22\x02\x08\x13' "$GATE"        > "$TMP/dlog.bin"     # .2.4.1=19 → dlog_m
printf '%s\x12\x04\x22\x02\x08\x05' "$GATE"        > "$TMP/normal.bin"   # .2.4.1=5  → normal
printf '%s' "$GATE"                                > "$TMP/gate_only.bin" # gate, fara path → normal
printf 'no_gate_here\x12\x04\x22\x02\x08\x13'      > "$TMP/nogate.bin"   # fara gate → unknown
printf ''                                          > "$TMP/empty.bin"    # gol → unknown

assert_eq "dlog_m"  "$("$py" "$ENGINE" "$TMP/dlog.bin")"      "engine: .2.4.1=19 → dlog_m"
assert_eq "normal"  "$("$py" "$ENGINE" "$TMP/normal.bin")"    "engine: .2.4.1=5 (≠19) → normal"
assert_eq "normal"  "$("$py" "$ENGINE" "$TMP/gate_only.bin")" "engine: gate fara path → normal"
assert_eq "unknown" "$("$py" "$ENGINE" "$TMP/nogate.bin")"    "engine: fara model-gate → unknown"
assert_eq "unknown" "$("$py" "$ENGINE" "$TMP/empty.bin")"     "engine: dump gol → unknown"
assert_eq "unknown" "$("$py" "$ENGINE" "$TMP/nonexistent")"   "engine: fisier lipsa → unknown"
rm -rf "$TMP"

# ── 3. Functional pe sample-uri reale (skip daca lipsesc — sunt gitignored) ──
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    declare -A EXP=( [DJI_20260529221103_0009_D.MP4]=dlog_m [DJI_20260603165715_0014_D.MP4]=dlog_m
                     [DJI_20260524143912_0007_D.MP4]=normal [DJI_20260603165650_0013_D.MP4]=normal )
    ran=0
    for s in "${!EXP[@]}"; do
        [[ -f "$SCRIPT_DIR/$s" ]] || continue
        ran=1
        assert_eq "${EXP[$s]}" "$(_detect_dji_dlogm "$SCRIPT_DIR/$s")" "real: $s → ${EXP[$s]}"
    done
    if [[ "$ran" -eq 0 ]]; then echo "  (info: sample-uri DJI absente — sar testul functional)" >&2; fi
fi
true
