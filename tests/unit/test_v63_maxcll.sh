#!/usr/bin/env bash
# v63 — MaxCLL/MaxFALL masurat (opt-in, Varianta B) + fix extract_hdr10_static_metadata.
#   Measure luma-based (signalstats) cand HDR10_MEASURE_CLL=1 si sursa nu are light-level inscris.
#   Fix: extract folosea `frame=side_data_list` (gol pe ffprobe curent) → acum `frame_side_data=`.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
X265="$(cat "$SCRIPT_DIR/av_encoder_x265.sh")"
AV1="$(cat "$SCRIPT_DIR/av_encoder_av1.sh")"
ENC_PS1="$(cat "$SCRIPT_DIR/av_encode.ps1")"
LAUNCHER="$(cat "$SCRIPT_DIR/av_launcher.sh")"

# ── 1. bash — motor + hook + prompt + state + schema + fix extract ──
assert_contains "$COMMON" "measure_hdr10_cll()"                        "bash: functia measure_hdr10_cll"
assert_contains "$COMMON" "signalstats,metadata=print"                 "bash: reteta signalstats"
assert_contains "$COMMON" 'HDR10_MEASURE_CLL:-0}" = "1" ] && [ -z "$_real_cll" ]' "bash: hook masoara doar fara CLL inscris"
assert_contains "$COMMON" 'HDR10_STATIC_SOURCE="measured-cll"'         "bash: marker measured-cll"
assert_contains "$COMMON" "ask_hdr10_measure_cll()"                    "bash: prompt opt-in (Varianta B)"
assert_contains "$COMMON" 'HDR10_MEASURE_CLL_BASE="${HDR10_MEASURE_CLL:-0}"' "bash: baza env/profil (anti-leak)"
assert_contains "$COMMON" 'HDR10_MEASURE_CLL="${HDR10_MEASURE_CLL_BASE:-0}"' "bash: reset per-fisier la baza"
assert_contains "$COMMON" 'HDR10_MEASURE_CLL)    echo "enum:0,1"'      "bash: schema profil"
assert_contains "$COMMON" "frame_side_data=side_data_type,red_x"       "bash FIX: extract foloseste frame_side_data="
assert_not_contains "$COMMON" "show_entries frame=side_data_list"      "bash FIX: nu mai foloseste frame=side_data_list"

# ── 2. bash — hlg_to_hdr10 (x265 + av1) cheama masurarea ──
assert_contains "$X265" 'HDR10_MEASURE_CLL:-0}" = "1" ] && measure_hdr10_cll "$file"'  "x265 hlg_to_hdr10: masoara opt-in"
assert_contains "$AV1"  'HDR10_MEASURE_CLL:-0}" = "1" ] && measure_hdr10_cll "$file"'  "av1 hlg_to_hdr10: masoara opt-in"

# ── 3. PS1 paritate — Measure + hook + prompt + state + schema + fix ──
assert_contains "$ENC_PS1" "function Measure-Hdr10Cll"                 "PS1: Measure-Hdr10Cll"
assert_contains "$ENC_PS1" 'hdr10MeasureCll -and -not $realCll'        "PS1: hook masoara doar fara CLL inscris"
assert_contains "$ENC_PS1" '$script:hdr10StaticSource = "measured-cll"' "PS1: marker measured-cll"
assert_contains "$ENC_PS1" "function Read-Hdr10MeasureChoice"          "PS1: prompt opt-in (Varianta B)"
assert_contains "$ENC_PS1" '$script:hdr10MeasureCll = $script:hdr10MeasureCllBase' "PS1: reset per-fisier la baza"
assert_contains "$ENC_PS1" "'HDR10_MEASURE_CLL'    { 'enum:0,1'"       "PS1: schema profil"
assert_contains "$ENC_PS1" "frame_side_data=side_data_type,red_x"      "PS1 FIX: extract foloseste frame_side_data="
assert_not_contains "$ENC_PS1" "show_entries frame=side_data_list"     "PS1 FIX: nu mai foloseste frame=side_data_list"
assert_contains "$LAUNCHER" 'HDR10_MEASURE_CLL="${HDR10_MEASURE_CLL:-0}"' "launcher: save flow profil"

# ── 4. Functional — fix extract (CLL inscris → probe) + measure (HLG fara CLL → measured) ──
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    # av_common.sh defineste functii la source (fara main) → safe
    source "$SCRIPT_DIR/av_common.sh" 2>/dev/null
    tmpd="$(mktemp -d)"
    pq="$tmpd/pq.mp4"; hlg="$tmpd/hlg.mp4"
    # (a) sursa PQ CU master-display + max-cll inscris (831,200)
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" \
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast \
        -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1):max-cll=831,200:log-level=none" \
        -an "$pq" 2>/dev/null
    # (b) sursa HLG (fara metadata statica)
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" \
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast \
        -x265-params "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:log-level=none" \
        -an "$hlg" 2>/dev/null
    if [[ -s "$pq" && -s "$hlg" ]]; then
        # FIX extract: sursa cu CLL inscris → SOURCE=probe + CLL real (NU default 1000,400)
        ( HDR10_MEASURE_CLL=1; hdr10_static_resolve "$pq" 2>/dev/null
          assert_eq "probe" "$HDR10_STATIC_SOURCE" "functional: CLL inscris citit (extract fix → probe)"
          assert_eq "831,200" "$HDR10_MAX_CLL"     "functional: MaxCLL inscris pastrat, NU masurat" )
        # measure: HLG fara CLL + flag ON → SOURCE=measured-cll + CLL != default
        ( HDR10_MEASURE_CLL=1; hdr10_static_resolve "$hlg" 2>/dev/null
          assert_eq "measured-cll" "$HDR10_STATIC_SOURCE" "functional: HLG fara CLL → masoara"
          if [[ "$HDR10_MAX_CLL" != "1000,400" && "$HDR10_MAX_CLL" =~ ^[0-9]+,[0-9]+$ ]]; then
              assert_eq "1" "1" "functional: MaxCLL masurat ($HDR10_MAX_CLL) != default"
          else
              assert_eq "masurat" "$HDR10_MAX_CLL" "functional: MaxCLL masurat != default"
          fi )
        # flag OFF → default (fara masurare)
        ( HDR10_MEASURE_CLL=0; hdr10_static_resolve "$hlg" 2>/dev/null
          assert_eq "1000,400" "$HDR10_MAX_CLL" "functional: flag OFF → default 1000,400" )
    fi
    rm -rf "$tmpd"
fi
true
