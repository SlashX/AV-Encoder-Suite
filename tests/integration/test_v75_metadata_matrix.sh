#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# v75 — MATRICE METADATA prin ENCODE REAL (audit pre-productie). Mirror PS1.
#   HDR10+ -> HDR10+ | DV -> DV | HDR10+ -> hibrid | transform-only
#   × codec sursa/tinta (HEVC/AV1 + cross-codec) × container (MP4 ±MP4Box,
#   MKV ±mkvmerge). Foloseste FUNCTIILE REALE din av_common.sh (sursate):
#   generate_dv_rpu_from_hdr10plus / extract_dv_rpu / inject_dv_rpu[+T.35] /
#   _mux_dv_mkv / _mux_dv_mp4 / verify_dv_survived + extract HDR10+ direct.
#   Encode cu params reale (x265 dhdr10-info / svtav1 _av1_vui+mastering).
#   NOTA build: pe ffmpeg fara hdr10plus-json in libsvtav1 (caps-fail), AV1
#   HDR10+ inline cade pe HDR10 static (asertam fallback). MP4Box se sare pe
#   MSYS (cai /tmp). Auto-skip fara unelte/sample.
# ══════════════════════════════════════════════════════════════════════
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
source "$SCRIPT_DIR/av_common.sh"

MP4BOX="${AV_TOOL_MP4BOX:-mp4box}"; MKVM="${AV_TOOL_MKVMERGE:-mkvmerge}"
for t in ffmpeg ffprobe dovi_tool hdr10plus_tool av1dovi_tool av1hdr10plus_tool; do
    command -v "$t" >/dev/null 2>&1 || skip_test "unealta lipsa: $t"
done
S_HEVC_HP="$SCRIPT_DIR/Upload_S02E01_HDR10Plus_40s_HEVC.mp4"
S_AV1_HP="$SCRIPT_DIR/Upload_S02E01_HDR10Plus_40s_AV1.mkv"
S_HEVC_DV="$SCRIPT_DIR/Test-Jellyfin-4K-DV-P8.1.mp4"
S_AV1_DV="$SCRIPT_DIR/Upload_S02E01_DV_40s_AV1.mkv"
for f in "$S_HEVC_HP" "$S_AV1_HP" "$S_HEVC_DV" "$S_AV1_DV"; do
    [ -f "$f" ] || skip_test "sample lipsa: $(basename "$f")"
done
_is_msys=0; case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) _is_msys=1 ;; esac
HAVE_MP4BOX=0; [ "$_is_msys" = "0" ] && command -v "$MP4BOX" >/dev/null 2>&1 && HAVE_MP4BOX=1
HAVE_MKVM=0; command -v "$MKVM" >/dev/null 2>&1 && HAVE_MKVM=1
SVT_HP=0; ffmpeg -hide_banner -h encoder=libsvtav1 2>&1 | grep -qi hdr10plus && SVT_HP=1

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; _test_summary' EXIT
declare -A SRC_HP=( [hevc]="$S_HEVC_HP" [av1]="$S_AV1_HP" )
declare -A SRC_DV=( [hevc]="$S_HEVC_DV" [av1]="$S_AV1_DV" )

# ── validatori ──
has_dvcc(){ ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type -of default=nw=1:nk=1 "$1" 2>/dev/null | grep -qi "DOVI configuration record" && echo 1 || echo 0; }
dv_prof(){ local p c; p=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_profile -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1 | tr -d '[:space:]\r'); c=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_bl_signal_compatibility_id -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1 | tr -d '[:space:]\r'); echo "${p}.${c}"; }
trc_of(){ ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1 | tr -d '[:space:]\r'; }
has_hdr10p(){ local f="$1" codec="$2" ext=hevc tool=hdr10plus_tool raw j; [ "$codec" = av1 ] && { ext=ivf; tool=av1hdr10plus_tool; }; raw="$TMP/hpck_$RANDOM.$ext"; j="$TMP/hpck_$RANDOM.json"; if [ "$codec" = av1 ]; then ffmpeg -y -loglevel error -i "$f" -map 0:v:0 -c copy -f ivf "$raw" 2>/dev/null; else ffmpeg -y -loglevel error -i "$f" -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb "$raw" 2>/dev/null; fi; "$tool" extract -i "$raw" -o "$j" >/dev/null 2>&1 || true; if [ -f "$j" ] && [ "$(av_stat_size "$j" 2>/dev/null || echo 0)" -gt 200 ]; then echo 1; else echo 0; fi; rm -f "$raw" "$j"; }
extract_hp(){ local f="$1" codec="$2" out="$3" ext=hevc tool=hdr10plus_tool raw; [ "$codec" = av1 ] && { ext=ivf; tool=av1hdr10plus_tool; }; raw="$TMP/hpx_$RANDOM.$ext"; if [ "$codec" = av1 ]; then ffmpeg -y -loglevel error -i "$f" -map 0:v:0 -c copy -f ivf "$raw" 2>/dev/null; else ffmpeg -y -loglevel error -i "$f" -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb "$raw" 2>/dev/null; fi; "$tool" extract -i "$raw" -o "$out" >/dev/null 2>&1 || true; rm -f "$raw"; [ -f "$out" ] && [ "$(av_stat_size "$out" 2>/dev/null || echo 0)" -gt 200 ]; }

# encode base HDR10 PQ (+optional dhdr10-info bare-name via cd) -> echo raw path
encode_base(){
    local src="$1" tc="$2" hp="$3" out
    ( cd "$TMP" || exit 1
      if [ "$tc" = av1 ]; then
        out="base_$RANDOM.ivf"
        local p="color-primaries=9:transfer-characteristics=16:matrix-coefficients=9:mastering-display=G(0.265,0.690)B(0.150,0.060)R(0.680,0.320)WP(0.3127,0.3290)L(1000,0.0001):content-light=1000,400"
        [ -n "$hp" ] && [ "$SVT_HP" = 1 ] && p="${p}:hdr10plus-json=$(basename "$hp")"
        ffmpeg -y -loglevel error -t 3 -i "$src" -an -c:v libsvtav1 -preset 12 -pix_fmt yuv420p10le \
            -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -svtav1-params "$p" -f ivf "$out" 2>/dev/null
      else
        out="base_$RANDOM.hevc"
        local p="colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400:hdr10-opt=1"
        [ -n "$hp" ] && p="${p}:dhdr10-info=$(basename "$hp")"
        ffmpeg -y -loglevel error -t 3 -i "$src" -an -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le \
            -x265-params "$p" -f hevc "$out" 2>/dev/null
      fi
      [ -s "$out" ] && echo "$TMP/$out" )
}
# muxeaza raw DV in container cu/fara unealta
mux_dv(){
    local raw="$1" orig="$2" ext="$3" usetool="$4" dvref="$5"
    local out="$TMP/o_$RANDOM.$ext"  # NB: linie separata — `local x=$ext` pe aceeasi linie cu `ext=` NU vede ext (args local expandate inainte de aplicare)
    if [ "$usetool" = 1 ]; then
        if [ "$ext" = mkv ]; then _mux_dv_mkv "$raw" "$orig" "$out" >/dev/null 2>&1 || true
        else _mux_dv_mp4 "$raw" "$orig" "$out" "$dvref" >/dev/null 2>&1 || true; fi
    else
        local step="$TMP/st_$RANDOM.mp4"
        ffmpeg -y -loglevel error -i "$raw" -c copy "$step" 2>/dev/null || true
        [ -s "$step" ] && ffmpeg -y -loglevel error -i "$step" -c copy "$out" 2>/dev/null || true
        rm -f "$step"
    fi
    [ -s "$out" ] && echo "$out"
}

# ════ GRUP A: HDR10+ -> HDR10+ ════
for sc in hevc av1; do for tc in hevc av1; do
    src="${SRC_HP[$sc]}"; hp="$TMP/hpA_${sc}_${tc}.json"; hpf=""
    extract_hp "$src" "$sc" "$hp" && hpf="$hp"
    base=$(encode_base "$src" "$tc" "$hpf")
    [ -n "$base" ] || { assert_eq 1 0 "A $sc->$tc encode base"; continue; }
    outA="$TMP/A_${sc}_${tc}.mp4"; ffmpeg -y -loglevel error -i "$base" -c copy "$outA" 2>/dev/null
    if [ "$tc" = hevc ]; then
        assert_eq 1 "$(has_hdr10p "$outA" hevc)" "A $sc->HEVC: HDR10+ SUPRAVIETUIESTE (dhdr10-info)"
    else
        if [ "$SVT_HP" = 1 ]; then assert_eq 1 "$(has_hdr10p "$outA" av1)" "A $sc->AV1: HDR10+ supravietuieste (hdr10plus-json)"
        else assert_eq "smpte2084" "$(trc_of "$outA")" "A $sc->AV1: HDR10 static (build fara hdr10plus-json - fallback corect)"; fi
    fi
    rm -f "$base"
done; done

# ════ GRUP B: DV -> DV (±unealta) ════
for sc in hevc av1; do for tc in hevc av1; do
    src="${SRC_DV[$sc]}"; rpu="$TMP/rpuB_${sc}_${tc}.bin"
    extract_dv_rpu "$src" "$rpu" "$sc" || { assert_eq 1 0 "B $sc->$tc extract RPU"; continue; }
    base=$(encode_base "$src" "$tc" "")
    [ -n "$base" ] || { assert_eq 1 0 "B $sc->$tc encode base"; continue; }
    ext=hevc; [ "$tc" = av1 ] && ext=ivf; inj="$TMP/injB_${sc}_${tc}.$ext"
    if inject_dv_rpu "$base" "$rpu" "$inj" "$tc"; then
        assert_eq 1 1 "B $sc->$tc: inject RPU (cross-codec auto-profil)"
        if [ "$HAVE_MKVM" = 1 ]; then
            mkv=$(mux_dv "$inj" "$src" mkv 1 "$src")
            if [ -n "$mkv" ]; then
                assert_eq 1 "$(has_dvcc "$mkv")" "B $sc->$tc MKV+mkvmerge: dvcC scris"
                want='^8'; [ "$tc" = av1 ] && want='^10'
                assert_match "$(dv_prof "$mkv")" "$want" "B $sc->$tc MKV: profil corect pe codec tinta"
                if verify_dv_survived "$mkv" "$tc" >/dev/null 2>&1; then assert_eq 1 1 "B $sc->$tc MKV: DV supravietuieste (RPU)"; else assert_eq 1 0 "B $sc->$tc MKV: DV supravietuieste (RPU)"; fi
            fi
        fi
        if [ "$HAVE_MP4BOX" = 1 ]; then
            mp4=$(mux_dv "$inj" "$src" mp4 1 "$src")
            if [ -n "$mp4" ]; then
                assert_eq 1 "$(has_dvcc "$mp4")" "B $sc->$tc MP4+MP4Box: dvcC scris"
                if verify_dv_survived "$mp4" "$tc" >/dev/null 2>&1; then assert_eq 1 1 "B $sc->$tc MP4: DV supravietuieste (RPU)"; else assert_eq 1 0 "B $sc->$tc MP4: DV supravietuieste (RPU)"; fi
            fi
        fi
        mkvno=$(mux_dv "$inj" "$src" mkv 0 "$src")
        if [ -n "$mkvno" ]; then
            if verify_dv_survived "$mkvno" "$tc" >/dev/null 2>&1; then assert_eq 1 1 "B $sc->$tc MKV fara unealta: DV in bitstream supravietuieste"; else assert_eq 1 0 "B $sc->$tc MKV fara unealta: DV in bitstream"; fi
        fi
    else assert_eq 1 0 "B $sc->$tc: inject RPU"; fi
    rm -f "$base"
done; done

# ════ GRUP C: HDR10+ -> HIBRID ════
for sc in hevc av1; do for tc in hevc av1; do
    src="${SRC_HP[$sc]}"; hp="$TMP/hpC_${sc}_${tc}.json"
    extract_hp "$src" "$sc" "$hp" || { assert_eq 1 0 "C $sc->$tc extract HDR10+"; continue; }
    rpu=$(generate_dv_rpu_from_hdr10plus "$hp" "$tc" "$src" 2>/dev/null)
    if [ -n "$rpu" ] && [ -s "$rpu" ]; then assert_eq 1 1 "C $sc->$tc: genereaza DV RPU din HDR10+"; else assert_eq 1 0 "C $sc->$tc: genereaza DV RPU"; continue; fi
    base=$(encode_base "$src" "$tc" "$hp")
    [ -n "$base" ] || { assert_eq 1 0 "C $sc->$tc encode"; continue; }
    ext=hevc; [ "$tc" = av1 ] && ext=ivf; inj="$TMP/injC_${sc}_${tc}.$ext"
    if inject_dv_rpu "$base" "$rpu" "$inj" "$tc"; then
        if [ "$HAVE_MKVM" = 1 ]; then
            mkv=$(mux_dv "$inj" "$src" mkv 1 "$src")
            if [ -n "$mkv" ]; then
                assert_eq 1 "$(has_dvcc "$mkv")" "C $sc->$tc hibrid MKV: dvcC (DV)"
                if verify_dv_survived "$mkv" "$tc" >/dev/null 2>&1; then assert_eq 1 1 "C $sc->$tc hibrid MKV: DV supravietuieste"; else assert_eq 1 0 "C $sc->$tc hibrid MKV: DV supravietuieste"; fi
                if [ "$tc" = hevc ]; then assert_eq 1 "$(has_hdr10p "$mkv" hevc)" "C $sc->HEVC hibrid: HDR10+ pastrat (al 3-lea strat)"
                else assert_eq "smpte2084" "$(trc_of "$mkv")" "C $sc->AV1 hibrid: HDR10 base (HDR10+ inline indisp. build)"; fi
            fi
        fi
    else assert_eq 1 0 "C $sc->$tc inject"; fi
    rm -f "$base"
done; done

# ════ GRUP D: TRANSFORM-ONLY HDR10+ -> hibrid ════
for sc in hevc av1; do
    src="${SRC_HP[$sc]}"; ext=hevc; [ "$sc" = av1 ] && ext=ivf
    raw="$TMP/rawD_$sc.$ext"
    extract_raw_video "$src" "$raw" "$sc" || { assert_eq 1 0 "D $sc raw extract"; continue; }
    hp="$TMP/hpD_$sc.json"; extract_hp "$src" "$sc" "$hp" || { assert_eq 1 0 "D $sc extract HDR10+"; continue; }
    rpu=$(generate_dv_rpu_from_hdr10plus "$hp" "$sc" "$src" 2>/dev/null)
    [ -n "$rpu" ] && [ -s "$rpu" ] || { assert_eq 1 0 "D $sc generate RPU"; continue; }
    inj="$TMP/injD_$sc.$ext"
    if inject_dv_rpu "$raw" "$rpu" "$inj" "$sc"; then
        assert_eq 1 1 "D $sc transform: inject DV (fara re-encode)"
        if [ "$HAVE_MKVM" = 1 ]; then
            mkv=$(mux_dv "$inj" "$src" mkv 1 "$src")
            if [ -n "$mkv" ]; then
                assert_eq 1 "$(has_dvcc "$mkv")" "D $sc transform MKV: dvcC"
                if verify_dv_survived "$mkv" "$sc" >/dev/null 2>&1; then assert_eq 1 1 "D $sc transform MKV: DV supravietuieste"; else assert_eq 1 0 "D $sc transform MKV: DV supravietuieste"; fi
                assert_eq 1 "$(has_hdr10p "$mkv" "$sc")" "D $sc transform: HDR10+ pastrat (lossless)"
            fi
        fi
    else assert_eq 1 0 "D $sc transform inject"; fi
done
