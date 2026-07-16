#!/usr/bin/env bash
# v76 — conversie DV Profile 7 → 8.1 (dual-layer aware): bash.
#   Source-level: config AV_TOOL_MKVEXTRACT/AV_ENGINE_DV_P7 + helperi puri (av_common.sh)
#     + orchestrator convert_p7_to_81 + branch P7 in transform flow (av_hdr_dv_tools.sh).
#   Hermetic: engine dv_p7_analyze.py (clasificare MEL/FEL_SAFE/FEL_COMPLEX/UNKNOWN —
#     functie pura, fara HW/tool extern).
#   Functional (mkvextract→discard→mkvmerge) = validat in PS1 pe Windows + manual (vezi memorie);
#     aici se sare (MSYS path quirks pe mkvextract/mkvmerge, ca test_v71/v72).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"

COMMON="$(cat "$SRC/av_common.sh")"
TOOLS="$(cat "$SRC/av_hdr_dv_tools.sh")"
ENGINE="$SRC/dv_p7_analyze.py"

# ── 1. Config: tool + engine ──────────────────────────────────────────
assert_contains "$COMMON" 'AV_TOOL_MKVEXTRACT="'  "AV_TOOL_MKVEXTRACT in blocul de config"
assert_contains "$COMMON" 'AV_ENGINE_DV_P7="'     "AV_ENGINE_DV_P7 in blocul de config"

# ── 2. Helperi puri (av_common.sh) ────────────────────────────────────
assert_contains "$COMMON" '_dv_bl_peak_nits()'       "helper _dv_bl_peak_nits"
assert_contains "$COMMON" '_dv_extract_full_hevc()'  "helper _dv_extract_full_hevc"
assert_contains "$COMMON" '_classify_p7_el()'        "helper _classify_p7_el"
assert_contains "$COMMON" 'frame_side_data=max_content' "bl_peak din MaxCLL real al BL"
assert_contains "$COMMON" 'tracks "${vid}:${out}"'   "extract full foloseste mkvextract tracks"
assert_contains "$COMMON" 'hevc_mp4toannexb'         "fallback ffmpeg pe non-MKV"

# ── 3. Orchestrator + branch (av_hdr_dv_tools.sh) ─────────────────────
assert_contains "$TOOLS" 'convert_p7_to_81()'        "orchestrator convert_p7_to_81"
assert_contains "$TOOLS" '-m 2 convert --discard'    "conversie P7->8.1 (discard EL)"
assert_contains "$TOOLS" '_hdv_combine_with_original "$bl81"' "re-mux dvcC via _hdv_combine_with_original"
assert_contains "$TOOLS" 'Profil 7'                  "branch P7 in hdv_flow_transform_rpu"
assert_contains "$TOOLS" '_dv81.'                    "sufix output _dv81"

# ── 4. Gate de siguranta FEL ──────────────────────────────────────────
assert_contains "$TOOLS" 'FEL_COMPLEX|UNKNOWN)'      "gate trateaza FEL_COMPLEX/UNKNOWN"
assert_contains "$TOOLS" 'DV_P7_FORCE'               "gate are escape DV_P7_FORCE"
assert_contains "$TOOLS" 'AV_NONINTERACTIVE'         "gate refuza non-interactiv (fara force)"

# ── 5. Engine: structura ──────────────────────────────────────────────
ENG="$(cat "$ENGINE")"
assert_contains "$ENG" 'def pq_to_nits'   "engine: EOTF ST.2084"
assert_contains "$ENG" 'MARGIN_NITS = 50' "engine: marja 50 niti peste BL peak"
assert_contains "$ENG" '"el_type":"MEL"'  "engine: detecteaza MEL"
assert_contains "$ENG" 'def collect_l1_max' "engine: aduna L1 max_pq recursiv"

# ── 6. Hermetic: verdicte engine pe JSON sintetic (doar python) ───────
if command -v python3 >/dev/null 2>&1; then
    TMP="$(mktemp -d)"
    _v() { python3 "$ENGINE" "$1" "${2:-1000}" 2>/dev/null | awk '{print $1}'; }

    printf '%s' '[{"el_type":"MEL","dm_data":[{"Level1":{"max_pq":2400}}]}]' > "$TMP/mel.json"
    assert_eq "MEL" "$(_v "$TMP/mel.json" 1000)" "MEL → MEL (discard lossless)"

    printf '%s' '[{"el_type":"FEL","dm_data":[{"Level1":{"max_pq":2400}}]}]' > "$TMP/fels.json"
    assert_eq "FEL_SAFE" "$(_v "$TMP/fels.json" 1000)" "FEL max_pq=2400 (214 niti) vs BL 1000 → FEL_SAFE"

    printf '%s' '[{"el_type":"FEL","dm_data":[{"Level1":{"max_pq":3600}}]}]' > "$TMP/felc.json"
    assert_eq "FEL_COMPLEX" "$(_v "$TMP/felc.json" 1000)" "FEL max_pq=3600 (3219 niti) vs BL 1000 → FEL_COMPLEX"

    # acelasi FEL dar BL graded 4000 → sigur (prag content-aware)
    assert_eq "FEL_SAFE" "$(_v "$TMP/felc.json" 4000)" "FEL 3219 niti vs BL 4000 → FEL_SAFE"

    printf '%s' 'nu-i json' > "$TMP/bad.json"
    assert_eq "UNKNOWN" "$(_v "$TMP/bad.json" 1000)" "JSON corupt → UNKNOWN (conservator)"

    rm -rf "$TMP"
else
    skip_test "python3 lipseste — hermetic engine sarit"
fi

# ── 7. Situatia 2: DV-preserve P7-aware pe calea de ENCODE ─────────────
# Baza re-encodata e mereu single-layer HDR10 → un RPU profil-7 injectat ar produce DV
# invalid. _extract_preserve_rpu converteste 7→8.1 inainte de inject (EL pierdut oricum
# la re-encode); restul surselor (P8.x / AV1 P10) → extract_dv_rpu normal.
assert_contains "$COMMON" '_extract_preserve_rpu()' "helper _extract_preserve_rpu (Situatia 2)"
PRES="$(awk '/^_extract_preserve_rpu\(\)/{f=1} f{print} f&&/^}/{exit}' "$SRC/av_common.sh")"
assert_contains "$PRES" 'Profil 7'           "gate _extract_preserve_rpu pe Profil 7"
assert_contains "$PRES" '_dv_extract_full_hevc' "P7 → extract stream complet (EL in MKV block additions)"
assert_contains "$PRES" '-m 2 convert --discard' "P7 → convert STREAM 7→8.1 (NU -m editor pe RPU = no-op)"
assert_contains "$PRES" 'extract-rpu "$conv"'    "P7 → extract RPU profil-8 din streamul convertit"
assert_contains "$PRES" 'extract_dv_rpu'      "non-P7/non-hevc → extract_dv_rpu normal (fallback)"

# Toate siturile de DV-preserve pe encode trec prin helper (zero extract_dv_rpu brut)
assert_contains "$COMMON" '_extract_preserve_rpu "$file" "$rpu_tmp" "$src_codec"' "hw_preserve (av_common) foloseste _extract_preserve_rpu"
X265="$(cat "$SRC/av_encoder_x265.sh")"
AV1SRC="$(cat "$SRC/av_encoder_av1.sh")"
assert_eq "2" "$(printf '%s\n' "$X265"   | grep -c '_extract_preserve_rpu "')" "x265: 2 situri preserve via helper (SW + MediaCodec)"
assert_eq "2" "$(printf '%s\n' "$AV1SRC" | grep -c '_extract_preserve_rpu "')" "av1: 2 situri preserve via helper (SW + MediaCodec)"
assert_eq "0" "$(printf '%s\n' "$X265"   | grep -c 'extract_dv_rpu')" "x265: zero extract_dv_rpu brut (toate prin helper)"
assert_eq "0" "$(printf '%s\n' "$AV1SRC" | grep -c 'extract_dv_rpu')" "av1: zero extract_dv_rpu brut (toate prin helper)"

# ── 7b. Advisory P7 pe copy-paths (v91, echo-only) ────────────────────
# Chokepoint _dv_resignal_copy (toate 8 siturile de copy) + oglinzile PS1
# (Invoke-DvResignalCopy in av_encode.ps1 + inline in av_mux.ps1 Remux).
_ADV='Sursa e DV Profil 7 (dual-layer Blu-ray)'
RES="$(awk '/^_dv_resignal_copy\(\)/{f=1} f{print} f&&/^}$/{exit}' "$SRC/av_common.sh")"
assert_contains "$RES" "$_ADV"        "advisory P7 in _dv_resignal_copy"
assert_contains "$RES" '== "7"'       "gate numeric dv_profile==7"
assert_contains "${RES%%Verificam intai OUTPUT*}" "$_ADV" "advisory INAINTE de early-return-ul →MKV"
ENCPS="$(cat "$SRC/av_encode.ps1")"
MUXPS="$(cat "$SRC/av_mux.ps1")"
assert_contains "$ENCPS" "$_ADV"      "paritate mesaj advisory in av_encode.ps1 (Invoke-DvResignalCopy)"
assert_contains "$MUXPS" "$_ADV"      "paritate mesaj advisory in av_mux.ps1 (Remux inline)"

# ── 8. FEL REAL (sample-gated — src/DVFEL local, gitignored; campanie 2026-07-16) ──
# 3 mostre P7 FEL reale au deblocat validarea: clasificatorul pe FEL real (ambele
# ramuri) + gate-ul FEL_COMPLEX (refuz non-interactiv / DV_P7_FORCE) + encode-preserve
# pe FEL. NU folosim skip_test aici (exit 77 ar masca source+hermetic de mai sus) →
# note cand lipsesc mostrele/tools. Pe MSYS partea mkvextract/mkvmerge se sare (clasa
# v71 — cai /tmp POSIX; validata prin PS1 + meniurile reale cu TMPDIR Windows-form).
FEL_MP4="$SRC/DVFEL/DV FEL Test DT DL P7 CMV4.0 4000nits v3.mp4"   # FEL_COMPLEX (CM v4.0, L1 10000 nits)
FEL_MKV="$SRC/DVFEL/DV FEL All Layers Test (Woman at 80s).mkv"     # FEL_SAFE (CM v2.9, L1 961 nits)
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SRC:$PATH"
_is_msys=0; case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) _is_msys=1 ;; esac
if [ -f "$FEL_MP4" ] && command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 \
   && command -v dovi_tool >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    export AV_HDR_DV_TEST_MODE=1
    source "$SRC/av_hdr_dv_tools.sh"     # sourceaza si av_common.sh (helperii puri)
    TMP8="$(mktemp -d)"

    # (a) clasificatorul pe FEL REAL — ramura FEL_COMPLEX (MP4 → calea ffmpeg, MSYS-safe)
    _f8=$(av_mktemp_ext hevc)
    if _dv_extract_full_hevc "$FEL_MP4" "$_f8"; then
        _v8=$(_classify_p7_el "$_f8" "$FEL_MP4")
        assert_eq "FEL_COMPLEX" "${_v8%% *}" "FEL real CM v4.0 (L1 10000 nits) -> FEL_COMPLEX (helperi reali)"
    else
        assert_eq "extract-ok" "extract-fail" "extract stream complet pe FEL MP4 esuat"
    fi
    rm -f "$_f8"

    # (b) gate: non-interactiv fara force -> refuz rc=2, fara output (refuzul e INAINTE
    #     de conversie/mux -> MSYS-safe)
    _o8="$TMP8/fel_dv81.mkv"
    AV_NONINTERACTIVE=1 convert_p7_to_81 "$FEL_MP4" "$_o8" >/dev/null 2>&1
    _rc8=$?
    assert_eq "2" "$_rc8" "FEL_COMPLEX non-interactiv fara DV_P7_FORCE -> refuz rc=2"
    if [ -e "$_o8" ]; then
        assert_eq "absent" "prezent" "refuzul NU trebuie sa lase output"
    else
        assert_eq "absent" "absent" "refuz -> niciun output creat"
    fi

    # (c) encode-preserve pe FEL: RPU extras pt inject TREBUIE profil 8, nu 7
    #     (MP4 -> calea ffmpeg + dovi_tool cu argumente simple, MSYS-safe)
    _r8=$(av_mktemp_ext bin)
    if _extract_preserve_rpu "$FEL_MP4" "$_r8" hevc >/dev/null 2>&1 && [ -s "$_r8" ]; then
        _ri8=$(dovi_tool info -i "$_r8" -s 2>&1)
        assert_match "$_ri8" 'Profile: 8' "_extract_preserve_rpu pe FEL real -> RPU profil 8 (NU 7)"
    else
        assert_eq "preserve-ok" "preserve-fail" "_extract_preserve_rpu pe FEL a esuat"
    fi
    rm -f "$_r8"

    # (c2) advisory P7 pe copy (v91): copy MP4→MKV pastreaza dvcC → _dv_resignal_copy
    #      face early-return DUPA advisory (fara MP4Box/mkvmerge → MSYS-safe)
    _cpy8="$TMP8/fel_cpy.mkv"
    ffmpeg -y -v error -i "$FEL_MP4" -map 0:v:0 -c copy "$_cpy8" </dev/null 2>/dev/null
    if [ -s "$_cpy8" ]; then
        _adv8=$(_dv_resignal_copy "$FEL_MP4" "$_cpy8" mkv 2>/dev/null)
        assert_contains "$_adv8" 'Sursa e DV Profil 7 (dual-layer Blu-ray)' "advisory P7 afisat pe copy real (functional)"
    else
        assert_eq "copy-ok" "copy-fail" "copy MP4→MKV pt advisory a esuat"
    fi

    # (d) force + conversie completa (mkvmerge dvcC) + FEL_SAFE pe MKV (mkvextract) —
    #     DOAR non-MSYS; pe Windows validate prin PS1 (nativ) + meniurile reale
    if [ "$_is_msys" = "0" ] && command -v mkvmerge >/dev/null 2>&1; then
        DV_P7_FORCE=1 convert_p7_to_81 "$FEL_MP4" "$_o8" >/dev/null 2>&1
        _rcf=$?
        assert_eq "0" "$_rcf" "FEL_COMPLEX + DV_P7_FORCE=1 -> conversie rc=0"
        _dvp8=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_profile \
            -of default=nw=1:nk=1 "$_o8" 2>/dev/null | head -1 | tr -d '[:space:]\r')
        assert_eq "8" "${_dvp8:-MISSING}" "output force -> dvcC dv_profile=8"
        if [ -f "$FEL_MKV" ] && command -v mkvextract >/dev/null 2>&1; then
            _fs8=$(av_mktemp_ext hevc)
            if _dv_extract_full_hevc "$FEL_MKV" "$_fs8"; then
                _vs8=$(_classify_p7_el "$_fs8" "$FEL_MKV")
                assert_eq "FEL_SAFE" "${_vs8%% *}" "FEL real CM v2.9 (L1 961 nits) -> FEL_SAFE"
            fi
            rm -f "$_fs8"
        fi
    else
        echo "  (nota MSYS/fara mkvmerge: force-convert + FEL_SAFE MKV sarite — validate prin PS1 + meniurile reale)"
    fi
    rm -rf "$TMP8"
else
    echo "  (nota: mostre FEL src/DVFEL absente sau tools lipsa — sectiunea FEL REAL sarita)"
fi

# sumarul vine din trap-ul EXIT al framework-ului (explicit aici = dublu print, clasa v85)
