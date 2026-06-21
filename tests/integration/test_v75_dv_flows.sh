#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# v75 — Fluxuri DV pe HEVC real (P5 / P8.1 / P8.4). Mirror al .ps1.
#   Acopera ce v72 NU acoperea: sample-uri HEVC DV REALE pe profile
#   distincte + REGRESIA codec_tag/dvcC per profil.
#   FOCUS: _mux_dv_mp4 scrie dvcC + codec_tag CORECT per profil prin
#   dvp= EXPLICIT — auto-detect-ul MP4Box mislabeleaza P8.4 (HLG) ca
#   profil 5 (dvh1). Canary: demonstram bug-ul auto-detect (fara dvp).
#   + avertismentele P5 din transform/remove (single-layer, fara HDR10).
#   Source-level ruleaza MEREU; functionalul se sare gratios fara
#   ffmpeg/MP4Box/mkvmerge/sample sau pe MSYS (MP4Box.exe + cai /tmp).
# ══════════════════════════════════════════════════════════════════════
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
export AV_HDR_DV_TEST_MODE=1
source "$SCRIPT_DIR/av_common.sh"
source "$SCRIPT_DIR/av_hdr_dv_tools.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; _test_summary' EXIT

# ── SOURCE-LEVEL (mereu) ──────────────────────────────────────────────
HDV="$SCRIPT_DIR/av_hdr_dv_tools.sh"
CMN="$SCRIPT_DIR/av_common.sh"
# B+ : avertisment P5 in transform + remove (gateat pe "Profil 5")
assert_contains "$(cat "$HDV")" 'Profil 5'                     "av_hdr_dv_tools mentioneaza Profil 5 (avertisment)"
tx="$(awk '/^hdv_flow_transform_rpu\(\)/{f=1} f; /^hdv_flow_inspect\(\)/{exit}' "$HDV")"
assert_match "$tx" 'get_dv_profile'                           "transform: foloseste get_dv_profile"
assert_match "$tx" '\*"Profil 5"\*'                           "transform: warning gateat pe Profil 5"
assert_match "$tx" 'Conversia P5'                             "transform: text avertisment P5->8.1 no-op"
rm_block="$(awk '/^hdv_flow_remove_dv\(\)/{f=1} f; /^hdv_flow_remove_hdr10plus\(\)/{exit}' "$HDV")"
assert_match "$rm_block" 'get_dv_profile'                     "remove: foloseste get_dv_profile"
assert_match "$rm_block" '\*"Profil 5"\*'                     "remove: warning gateat pe Profil 5"
assert_match "$rm_block" 'baza IPT'                           "remove: text avertisment P5 lasa IPT (nu HDR10)"
# dvp= derivare HEVC din referinta in _mux_dv_mp4
mux="$(awk '/^_mux_dv_mp4\(\)/{f=1} f; /^_dv_container_signal\(\)/{exit}' "$CMN")"
assert_match "$mux" 'dvp=\$\{_hp\}\.\$\{_hc\}'                 "_mux_dv_mp4 HEVC: dvp=profil.compat din referinta"
assert_match "$mux" 'stream_side_data=dv_profile'             "_mux_dv_mp4 HEVC: citeste dv_profile din ref"

# ── FUNCTIONAL (gardat) ───────────────────────────────────────────────
MP4BOX="${AV_TOOL_MP4BOX:-mp4box}"
MKVM="${AV_TOOL_MKVMERGE:-mkvmerge}"
SM_P5="$SCRIPT_DIR/Test-Jellyfin-4K-DV-P5.mp4"
SM_P81="$SCRIPT_DIR/Test-Jellyfin-4K-DV-P8.1.mp4"
SM_P84="$SCRIPT_DIR/Test-Jellyfin-4K-DV-P8.4.mp4"
_is_msys=0; case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) _is_msys=1 ;; esac

dv_prof(){ local p c; \
  p=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_profile -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1 | tr -d '[:space:]\r'); \
  c=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_bl_signal_compatibility_id -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1 | tr -d '[:space:]\r'); \
  echo "${p}.${c}"; }
vtag(){ ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1 | tr -d '[:space:]\r'; }
fps_of(){ ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1 | tr -d '\r'; }
raw_of(){ ffmpeg -y -loglevel error -i "$1" -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -t 2 "$2" 2>/dev/null; }

if command -v ffprobe >/dev/null 2>&1 && [ -f "$SM_P84" ] && [ "$_is_msys" = "0" ] && command -v "$MP4BOX" >/dev/null 2>&1; then
    # Tabel asteptat: profil -> (dvcC prof.compat, codec_tag)
    #   P5   -> 5.0  / dvh1   (DV only, single-layer)
    #   P8.1 -> 8.1  / hvc1   (HDR10-compatible)
    #   P8.4 -> 8.4  / hvc1   (HLG-compatible)  ← REGRESIA: NU 5/dvh1
    declare -A WANT_PROF=( [P5]=5.0 [P8.1]=8.1 [P8.4]=8.4 )
    declare -A WANT_TAG=(  [P5]=dvh1 [P8.1]=hvc1 [P8.4]=hvc1 )
    declare -A SM=( [P5]="$SM_P5" [P8.1]="$SM_P81" [P8.4]="$SM_P84" )
    for k in P5 P8.1 P8.4; do
        orig="${SM[$k]}"; [ -f "$orig" ] || { echo "  ($k sample lipsa)" >&2; continue; }
        raw="$TMP/$k.hevc"; out="$TMP/$k.mp4"
        raw_of "$orig" "$raw"
        _mux_dv_mp4 "$raw" "$orig" "$out" "$orig" >/dev/null 2>&1 || true
        if [ -s "$out" ]; then
            assert_eq "${WANT_PROF[$k]}" "$(dv_prof "$out")" "_mux_dv_mp4 $k: dvcC ${WANT_PROF[$k]} (dvp= corect)"
            assert_eq "${WANT_TAG[$k]}"  "$(vtag "$out")"    "_mux_dv_mp4 $k: codec_tag ${WANT_TAG[$k]}"
        else
            echo "  ($k: _mux_dv_mp4 fara output — sarit)" >&2
        fi
    done

    # REGRESIE transform: _mux_dv_mp4 FARA dv_ref ($4) NU trebuie sa derive profilul din
    # original (la transform $original e PRE-transform, alt profil decat stream-ul produs) →
    # auto-detect pe stream-ul produs (8.1). Simulam: modified = stream 8.1 real, original =
    # fisier P5, FARA al 4-lea arg.
    if [ -f "$SM_P81" ] && [ -f "$SM_P5" ]; then
        raw_of "$SM_P81" "$TMP/r81.hevc"
        _mux_dv_mp4 "$TMP/r81.hevc" "$SM_P5" "$TMP/tregr.mp4" >/dev/null 2>&1 || true
        [ -s "$TMP/tregr.mp4" ] && assert_eq "8.1" "$(dv_prof "$TMP/tregr.mp4")" "REGRESIE transform: fara dv_ref NU deriva din original PRE-transform (8.1 nu 5.0)"
    fi

    # CANARY: auto-detect MP4Box (FARA dvp) mislabeleaza P8.4 ca profil 5.
    # Demonstreaza ca dvp= face munca reala. Daca un MP4Box viitor repara
    # auto-detect-ul (→ 8.4), acest assert pica → re-evalueaza necesitatea dvp.
    if [ -f "$SM_P84" ]; then
        raw_of "$SM_P84" "$TMP/canary.hevc"
        "$MP4BOX" -add "$TMP/canary.hevc:fps=$(fps_of "$SM_P84")" -new "$TMP/canary.mp4" >/dev/null 2>&1 || true
        if [ -s "$TMP/canary.mp4" ]; then
            cp="$(dv_prof "$TMP/canary.mp4")"
            case "$cp" in
                5.*) assert_eq "1" "1" "CANARY: MP4Box auto-detect mislabeleaza P8.4 ca $cp (de-aia dvp=)" ;;
                *)   assert_eq "5.x" "$cp" "CANARY: MP4Box auto-detect P8.4 — comportament SCHIMBAT (reevalueaza dvp=)" ;;
            esac
        fi
    fi

    # MKV (mkvmerge): calea P8.4 era CORECTA si fara dvp (contrast cu MP4)
    if command -v "$MKVM" >/dev/null 2>&1; then
        ffmpeg -y -loglevel error -i "$SM_P84" -f lavfi -i "sine=r=48000:d=2" -map 0:v -map 1:a -c copy -c:a aac -shortest "$TMP/p84_o.mkv" 2>/dev/null
        _mux_dv_mkv "$TMP/P8.4.hevc" "$TMP/p84_o.mkv" "$TMP/p84.mkv" >/dev/null 2>&1 || true
        if [ -s "$TMP/p84.mkv" ]; then
            assert_eq "8.4" "$(dv_prof "$TMP/p84.mkv")" "_mux_dv_mkv P8.4: dvcC 8.4 (mkvmerge corect, fara dvp)"
        fi
    fi
else
    echo "  (functional sarit: lipsa ffprobe/MP4Box/sample P8.4 sau MSYS — validat pe Linux/macOS + test PS1)" >&2
fi
