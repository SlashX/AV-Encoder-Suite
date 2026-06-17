#!/usr/bin/env bash
# v72 — dvcC de container pe hibridele AV1 DV → MP4/MOV (inchide ultimul gap din harta
# dvcC, dupa v70 HEVC-MKV + v71 HEVC-MP4 + AV1-MKV). MP4Box NU auto-detecteaza DV pe AV1
# (refuza plasarea OBU de la av1dovi_tool) → `dvp=` EXPLICIT il scrie oricum (RPU
# byte-identic, validat). Compat (10.<id>) derivat din dvcC-ul referintei, fallback 10.1.
#   Source-level (mereu): gate AV1 + derivare dvp in _mux_dv_mp4, ungatarea AV1 in cele 3
#   situri de creatie (triple-layer + _hdv_combine + av_mux capture) + passthrough
#   codec-aware (_dv_resignal_copy) + dispatch dv_ref. Functional (Linux/macOS/Termux;
#   sarit pe MSYS ca test_v71_mp4box_dvcc — vezi test PS1): AV1 DV IVF → _mux_dv_mp4 REAL
#   → MP4 → assert dvcC + RPU.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
source "$SCRIPT_DIR/av_common.sh"
COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
HDV="$(cat "$SCRIPT_DIR/av_hdr_dv_tools.sh")"
MUX="$(cat "$SCRIPT_DIR/av_mux.sh")"

# ── 1. _mux_dv_mp4: AV1 acceptat (gate ivf/av1/obu) + dvp= derivat ────────
assert_contains "$COMMON" 'ivf|av1|obu)   _is_av1=1 ;;' "_mux_dv_mp4: gate AV1 (.ivf/.av1/.obu)"
assert_contains "$COMMON" 'dv_bl_signal_compatibility_id' "_mux_dv_mp4: citeste compat-ul pt dvp"
# FIX audit v72: profilul AV1 e FORTAT la 10 (NU citit din ref) → cross-codec hevc-DV(8.x)→av1 safe
assert_contains "$COMMON" '_dvp="10.${_c}"' "_mux_dv_mp4: profil AV1 fortat la 10 (cross-codec safe)"
assert_contains "$COMMON" '_firstadd="${raw_hevc}:dvp=${_dvp}:fps=${afr}"' "_mux_dv_mp4: -add cu dvp= la AV1"
assert_contains "$COMMON" '_dvp="10.1"' "_mux_dv_mp4: fallback dvp=10.1 (HDR10-cross-compat)"
assert_contains "$COMMON" 'local _dv_ref="${4:-$original}"' "_mux_dv_mp4: referinta compat = arg 4 sau original"

# ── 2. triple-layer: ramura mp4/mov ungateata (HEVC + AV1) + dv_ref=$file ──
assert_contains "$COMMON" '_mux_dv_mp4 "$injected_temp" "$output" "$final_temp" "$file"' "triple-layer: mp4/mov ungateat (HEVC+AV1) cu dv_ref"
# anti-regresie: branch-ul mp4/mov NU mai e gardat pe non-av1
assert_not_contains "$COMMON" '"$_tl_codec" != "av1" && ( "$CONTAINER" == "mp4"' "triple-layer: AV1 NU mai e exclus din ramura mp4"

# ── 3. _hdv_combine: ramura AV1 IVF → MP4/MOV → _mux_dv_mp4 ────────────────
assert_contains "$HDV" '"$_oe" == "mp4" || "$_oe" == "mov" || "$_oe" == "m4v"' "_hdv_combine: ramura IVF acopera MP4/MOV"

# ── 4. passthrough: _dv_resignal_copy accepta AV1 (codec-aware) + dv_ref ───
assert_contains "$COMMON" '[[ "$_sc" == "hevc" || "$_sc" == "av1" ]] || return 0' "_dv_resignal_copy: accepta HEVC + AV1"
assert_contains "$COMMON" '_raw=$(av_mktemp_ext ivf)' "_dv_resignal_copy: extractie AV1 ca IVF"
assert_contains "$COMMON" '_dv_container_signal "$_raw" "$output" "$target" "$source"' "_dv_resignal_copy: paseaza sursa ca referinta compat"

# ── 5. dispatch _dv_container_signal forwardeaza dv_ref (arg 4) ────────────
assert_contains "$COMMON" 'local raw="$1" built="$2" target="$3" dv_ref="${4:-}"' "_dv_container_signal: primeste dv_ref"
assert_contains "$COMMON" '_mux_dv_mp4 "$raw" "$built" "$tmp" "$dv_ref"' "_dv_container_signal: forwardeaza dv_ref la _mux_dv_mp4"

# ── 6. av_mux: capturile AV1 pe MP4/MOV ───────────────────────────────────
assert_contains "$MUX" 'case "$_vextmp4" in hevc|h265|265|av1|ivf) _dv_raw_src="$video" ;; esac' "av_mux: captura AV1/IVF pe MP4/MOV"

# ── 7. FUNCTIONAL — AV1 DV IVF → _mux_dv_mp4 REAL → MP4 → dvcC + RPU ───────
# Sarit pe MSYS (MP4Box.exe nu accepta cai /tmp cu :dvp/:fps) — validat prin test PS1.
MP4BOX="${AV_TOOL_MP4BOX:-mp4box}"
AV1DOVI="${AV_TOOL_AV1DOVI:-av1dovi_tool}"
_is_msys=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) _is_msys=1 ;; esac
AV1_SAMPLE=""
for c in "$SCRIPT_DIR"/Upload_*DV*AV1.mkv "$SCRIPT_DIR"/*DV*AV1*.mkv; do [ -f "$c" ] && { AV1_SAMPLE="$c"; break; }; done
if [ "$_is_msys" = "0" ] && [ -n "$AV1_SAMPLE" ] && command -v ffmpeg >/dev/null 2>&1 \
   && command -v ffprobe >/dev/null 2>&1 && command -v "$AV1DOVI" >/dev/null 2>&1 \
   && command -v "$MP4BOX" >/dev/null 2>&1; then
    TD="$(mktemp -d)"
    # AV1 DV brut (IVF) + un original MP4 (video + audio sintetic) pt copierea pistelor
    ffmpeg -v error -y -t 2 -i "$AV1_SAMPLE" -map 0:v:0 -c:v copy -f ivf "$TD/v.ivf" 2>/dev/null
    "$AV1DOVI" extract-rpu -i "$TD/v.ivf" -o "$TD/rb.bin" >/dev/null 2>&1 || true
    ffmpeg -v error -y -i "$TD/v.ivf" -f lavfi -i "sine=r=48000:d=2" \
        -map 0:v -map 1:a -c copy -c:a aac -shortest "$TD/orig.mp4" 2>/dev/null
    if [ -s "$TD/rb.bin" ] && [ -s "$TD/orig.mp4" ]; then
        ok=0; _mux_dv_mp4 "$TD/v.ivf" "$TD/orig.mp4" "$TD/out.mp4" "$AV1_SAMPLE" && ok=1
        assert_eq "1" "$ok" "functional: _mux_dv_mp4 reuseste pe AV1 DV → MP4"
        dvcc=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type -of default=noprint_wrappers=1:nokey=1 "$TD/out.mp4" 2>/dev/null | grep -ci "DOVI" || true)
        assert_eq "1" "$dvcc" "functional: dvcC scris in MP4 (AV1)"
        # RPU byte-identic dupa MP4Box
        ffmpeg -v error -y -i "$TD/out.mp4" -map 0:v:0 -c copy -f ivf "$TD/back.ivf" 2>/dev/null
        "$AV1DOVI" extract-rpu -i "$TD/back.ivf" -o "$TD/ra.bin" >/dev/null 2>&1 || true
        if [ -s "$TD/rb.bin" ] && [ -s "$TD/ra.bin" ]; then
            same=$(cmp -s "$TD/rb.bin" "$TD/ra.bin" && echo 1 || echo 0)
            assert_eq "1" "$same" "functional: RPU AV1 byte-identic dupa dvp= mux"
        fi
    else
        echo "  (functional sarit: build IVF/orig esuat)" >&2
    fi
    rm -rf "$TD"
else
    echo "  (functional sarit: MSYS / AV1 DV sample / ffmpeg / av1dovi_tool / MP4Box lipsesc)" >&2
fi
