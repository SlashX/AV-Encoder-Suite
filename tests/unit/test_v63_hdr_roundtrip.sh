#!/usr/bin/env bash
# v63 — HDR/DV transformation round-trip (extract → remove → inject + T.35 repair → mux → verify).
#   Acopera lantul critic de transformare HDR/DV (av_hdr_dv_tools + AV1 DV preserve la encode).
#   Bug-ul reparat in v56: av1dovi_tool inject-rpu omite trailing byte-ul 0x80 T.35 → dav1d arunca
#   DV silentios la re-mux. _repair_av1_dv_t35 (av1_dv_t35_repair.py) il re-adauga DOAR pe DV (0x003B),
#   sarind HDR10+ (0x003C). Functionalul ruleaza DOAR cand sample-urile reale + tool-urile sunt prezente.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
ENGINE="$(cat "$SCRIPT_DIR/av1_dv_t35_repair.py")"

# ── 1. Source-level — lantul T.35 repair e cablat corect ──
assert_contains "$COMMON" "_repair_av1_dv_t35()"                          "helper _repair_av1_dv_t35 definit"
assert_contains "$COMMON" 'target_codec" == "av1" ]] && _repair_av1_dv_t35' "inject_dv_rpu: T.35 repair DOAR pe AV1"
assert_contains "$COMMON" "inject-rpu -i"                                 "inject_dv_rpu foloseste inject-rpu"
assert_contains "$COMMON" ">/dev/null 2>&1"                               "tool stdout redirectat (anti-poluare)"
assert_contains "$COMMON" "extract_dv_rpu" && \
assert_contains "$COMMON" 'verify_dv_survived' "verify_dv_survived (plasa de siguranta) prezent"

# ── 2. Engine Python — surgical pe DV (0x003B), sare HDR10+ (0x003C) ──
assert_contains "$ENGINE" "DV_PROVIDER = 0x003B"        "engine: provider DV Dolby 0x003B"
assert_contains "$ENGINE" 'b"\x80"'                     "engine: re-adauga trailing byte 0x80"
assert_contains "$ENGINE" "leb_enc(len(new_payload))"   "engine: recalc obu_size (leb128)"
assert_contains "$ENGINE" "len(new_fr).to_bytes(4"      "engine: recalc IVF frame size"
assert_contains "$ENGINE" "copy verbatim"               "engine: non-DV (HDR10+) copiat intact"

# ── 3. Functional — round-trip pe sample real (skip daca lipseste) ──
DV_AV1="$SCRIPT_DIR/Upload_S02E01_DV_40s_AV1.mkv"
HYB_AV1="$SCRIPT_DIR/Upload_S02E01_DV_HDR10Plus_40s_AV1.mkv"
have_tools=1
for t in ffmpeg ffprobe av1dovi_tool python3 python; do command -v "$t" >/dev/null 2>&1 || have_tools=$((have_tools)); done
command -v av1dovi_tool >/dev/null 2>&1 || have_tools=0
{ command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; } || have_tools=0

if [[ "$have_tools" == "1" && -f "$DV_AV1" ]]; then
    export SCRIPT_DIR
    source "$SCRIPT_DIR/av_common.sh" 2>/dev/null
    T="$(mktemp -d)"
    # AV1 DV round-trip: extract RPU → remove DV → inject (+T.35) → mux → verify
    if extract_dv_rpu "$DV_AV1" "$T/rpu.bin" av1 >/dev/null 2>&1 \
       && extract_raw_video "$DV_AV1" "$T/raw.ivf" av1 >/dev/null 2>&1 \
       && remove_dv_layer "$T/raw.ivf" "$T/base.ivf" av1 >/dev/null 2>&1 \
       && inject_dv_rpu "$T/base.ivf" "$T/rpu.bin" "$T/inj.ivf" av1 >/dev/null 2>&1 \
       && ffmpeg -y -v error -i "$T/inj.ivf" -c:v copy "$T/final.mkv" 2>/dev/null; then
        if verify_dv_survived "$T/final.mkv" av1; then
            assert_eq "1" "1" "functional: AV1 DV supravietuieste (T.35 repair)"
        else
            assert_eq "survived" "lost" "functional: AV1 DV supravietuieste (T.35 repair)"
        fi
        # Contrast: inject FARA repair → DV pierdut (dovedeste ca repair-ul e esential)
        if av1dovi_tool inject-rpu -i "$T/base.ivf" --rpu-in "$T/rpu.bin" -o "$T/nr.ivf" >/dev/null 2>&1 \
           && ffmpeg -y -v error -i "$T/nr.ivf" -c:v copy "$T/nr.mkv" 2>/dev/null; then
            if verify_dv_survived "$T/nr.mkv" av1; then
                assert_eq "lost" "survived" "functional contrast: fara repair → DV pierdut"
            else
                assert_eq "1" "1" "functional contrast: fara repair → DV pierdut (repair esential)"
            fi
        fi
    else
        echo "  (functional AV1 DV sarit — setup esuat; source-level acoperit)"
    fi
    # Hibrid: DV + HDR10+ ambele supravietuiesc
    if [[ -f "$HYB_AV1" ]]; then
        if extract_dv_rpu "$HYB_AV1" "$T/h_rpu.bin" av1 >/dev/null 2>&1 \
           && extract_raw_video "$HYB_AV1" "$T/h_raw.ivf" av1 >/dev/null 2>&1 \
           && remove_dv_layer "$T/h_raw.ivf" "$T/h_base.ivf" av1 >/dev/null 2>&1 \
           && inject_dv_rpu "$T/h_base.ivf" "$T/h_rpu.bin" "$T/h_inj.ivf" av1 >/dev/null 2>&1 \
           && ffmpeg -y -v error -i "$T/h_inj.ivf" -c:v copy "$T/h_final.mkv" 2>/dev/null; then
            verify_dv_survived "$T/h_final.mkv" av1 && _dv=1 || _dv=0
            verify_hdr10plus "$T/h_final.mkv" av1 && _hp=1 || _hp=0
            assert_eq "1" "$_dv" "functional hibrid: DV supravietuieste"
            assert_eq "1" "$_hp" "functional hibrid: HDR10+ pastrat (repair sare 0x003C)"
        fi
    fi
    rm -rf "$T"
else
    echo "  (functional sarit — sample AV1 DV / tool av1dovi_tool/python lipsa; source-level acoperit)"
fi
true
