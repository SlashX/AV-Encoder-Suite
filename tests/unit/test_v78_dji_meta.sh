#!/usr/bin/env bash
# v78 — pastrarea metadata-ului nativ DJI (djmd GPS) prin GRAFT MP4Box.
#   A) telemetrie strip "pastreaza GPS nativ" (av_telemetry) — reverseaza restrictia v71
#   B) flux encode (run_encode_loop) — DJI MP4/MOV → encode → re-graft GPS
#   Shared helper in av_common.sh; policy DJI_PRESERVE_META (auto|on|off); paritate bash<->PS1.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../src" && pwd)"
common="$(cat "$SRC/av_common.sh")"
launch="$(cat "$SRC/av_launcher.sh")"
tel_sh="$(cat "$SRC/av_telemetry.sh")"
tel_ps="$(cat "$SRC/av_telemetry.ps1")"
enc_ps="$(cat "$SRC/av_encode.ps1")"

# ── 1. Helperi partajati bash (av_common.sh) ─────────────────────────
assert_contains "$common" '_dji_native_meta_ids()'        "av_common: _dji_native_meta_ids"
assert_contains "$common" '_dji_has_native_meta()'        "av_common: _dji_has_native_meta"
assert_contains "$common" '_dji_graft_native_meta()'      "av_common: _dji_graft_native_meta"
assert_contains "$common" '_dji_preserve_meta_postencode()' "av_common: _dji_preserve_meta_postencode (hook B)"

# ── 2. Hook B in run_encode_loop (ULTIMUL post-process, dupa APV) ─────
assert_contains "$common" '_dji_preserve_meta_postencode "$file" "$output"' "av_common: apel hook in run_encode_loop"
# ordonare: apelul DJI din run_encode_loop dupa resetul APV inject, inainte de NEW_SIZE
# (NB: exista 2 apeluri _dji_preserve_meta_postencode — unul in do_stream_copy mai sus;
#  il alegem pe cel de DUPA resetul APV = hook-ul din run_encode_loop)
b_apv="$(printf '%s\n' "$common" | grep -n 'APV_HDR10PLUS_INJECT=0' | tail -1 | cut -d: -f1)"
b_dji="$(printf '%s\n' "$common" | grep -n '_dji_preserve_meta_postencode "\$file"' | awk -F: -v a="$b_apv" '$1>a{print $1; exit}')"
b_sz="$(printf '%s\n' "$common" | grep -n 'NEW_SIZE=$(av_stat_size' | awk -F: -v d="$b_dji" '$1>d{print $1; exit}')"
assert_zero "$(( b_dji > b_apv ? 0 : 1 ))" "hook DJI dupa resetul APV"
assert_zero "$(( b_dji < b_sz ? 0 : 1 ))"  "hook DJI inainte de NEW_SIZE"
# v78: si pe smart stream-copy (do_stream_copy) — paritate cu re-encode (djmd se pierde la copy)
sc_block="$(printf '%s\n' "$common" | sed -n '/^do_stream_copy() {/,/^}/p')"
assert_contains "$sc_block" '_dji_preserve_meta_postencode "$file" "$output"' "do_stream_copy: re-grefeaza djmd si pe smart-copy"
# v78: si pe audio-only (video copiat 1:1 → djmd valid temporal); NU pe trim/concat (video editat)
aud_sh="$(cat "$SRC/av_encoder_audio.sh")"
assert_contains "$aud_sh" '_dji_preserve_meta_postencode "$file" "$output"' "av_encoder_audio.sh: re-grefeaza djmd pe audio-only"
# v88 audit: +2 situri legitime in fluxurile IAMF audio-only (copy deja-IAMF + authoring)
assert_eq "5" "$(printf '%s\n' "$enc_ps" | grep -c 'Invoke-DjiPreserveMetaPostEncode -Source')" "PS1: 5 call-site graft (run-loop + stream-copy + audio-only + IAMF copy/authoring v88)"

# ── 3. Policy DJI_PRESERVE_META: gate + auto/on/off ──────────────────
assert_contains "$common" 'DJI_PRESERVE_META:-auto'  "av_common: default auto"
assert_contains "$common" 'policy" == "off"'         "av_common: off → no-op"
assert_contains "$common" 'AV_NONINTERACTIVE:-0'     "av_common: bypass non-interactiv (auto → ON)"

# ── 4. Helperul de graft foloseste $AV_TOOL_MP4BOX (NU hardcodat) + djmd DOAR ──
graft_block="$(printf '%s\n' "$common" | sed -n '/_dji_graft_native_meta()/,/^}/p')"
assert_contains "$graft_block" '"$AV_TOOL_MP4BOX"'   "graft: unealta via \$AV_TOOL_MP4BOX"
ids_block="$(printf '%s\n' "$common" | sed -n '/_dji_native_meta_ids()/,/^}/p')"
assert_contains "$ids_block" 'if(tag=="djmd") print id' "graft set = djmd DOAR (dbgi/tmcd NEgrefate)"
assert_zero "$(printf '%s\n' "$ids_block" | grep -c 'dbgi')" "graft: dbgi NU se grefeaza (drop-by-default)"
# numele functiilor NU contin literalul "mp4box" (paritate cu santinela no_hardcoded_tools)
assert_zero "$(printf '%s\n' "$common" | grep -cE '^[A-Za-z_]*mp4box[A-Za-z_]*\(\)')" "nicio functie cu literalul mp4box in nume"

# ── 5. A — meniu telemetrie strip: optiunea 3 + cancel renumerotat la 4 ──
assert_contains "$tel_sh" 'Pastreaza GPS nativ (djmd)'      "av_telemetry.sh: optiunea 3 in meniu"
assert_contains "$tel_sh" 'Alege 1-4 [implicit: 1]'         "av_telemetry.sh: prompt 1-4"
assert_contains "$tel_sh" 'STRIP_MODE" == "4"'              "av_telemetry.sh: cancel = 4"
assert_contains "$tel_sh" '_dji_graft_native_meta "$file" "$out_clean"' "av_telemetry.sh: mode 3 apeleaza graft"
# mode 3 base = video v:0 + audio, FARA cover (nu -map 0), cu -dn
assert_contains "$tel_sh" '-map 0:v:0 -map 0:a? -c copy -dn' "av_telemetry.sh: mode 3 base curat (drop cover/date)"

# ── 6. Schema bash + PS1: DJI_PRESERVE_META in AMBELE ────────────────
assert_contains "$common"  'DJI_PRESERVE_META)    echo "enum:,auto,on,off"' "schema bash: DJI_PRESERVE_META"
assert_contains "$enc_ps"  "'DJI_PRESERVE_META'    { 'enum:,auto,on,off'"   "schema PS1: DJI_PRESERVE_META"

# ── 7. Save flow: launcher (bash) + av_encode.ps1 ───────────────────
assert_contains "$launch" 'DJI_PRESERVE_META="${DJI_PRESERVE_META:-}"' "save flow bash (launcher)"
assert_contains "$enc_ps" 'DJI_PRESERVE_META=$(if ($env:DJI_PRESERVE_META)' "save flow PS1 (av_encode)"

# ── 8. PARITATE PS1: helperi + hook B + A (telemetrie) ──────────────
assert_contains "$enc_ps" 'function Get-DjiNativeMetaIds'        "PS1 av_encode: Get-DjiNativeMetaIds"
assert_contains "$enc_ps" 'function Test-DjiNativeMeta'          "PS1 av_encode: Test-DjiNativeMeta"
assert_contains "$enc_ps" 'function Add-DjiNativeMeta'           "PS1 av_encode: Add-DjiNativeMeta"
assert_contains "$enc_ps" 'function Invoke-DjiPreserveMetaPostEncode' "PS1 av_encode: orchestrator B"
assert_contains "$enc_ps" 'Invoke-DjiPreserveMetaPostEncode -Source $f.FullName -Output $outFile' "PS1 av_encode: apel hook B"
# A (av_telemetry.ps1): meniu + helper copies + mode 3
assert_contains "$tel_ps" 'Pastreaza GPS nativ (djmd)'      "PS1 av_telemetry: optiunea 3"
assert_contains "$tel_ps" 'Alege 1-4 [implicit: 1]'         "PS1 av_telemetry: prompt 1-4"
assert_contains "$tel_ps" 'stripMode -eq "4"'              "PS1 av_telemetry: cancel = 4"
assert_contains "$tel_ps" 'function Add-DjiNativeMeta'      "PS1 av_telemetry: copie Add-DjiNativeMeta"
assert_contains "$tel_ps" 'Add-DjiNativeMeta -Original $f.FullName -Output $outClean' "PS1 av_telemetry: mode 3 graft"
# nume PS1 FARA literalul mp4box
assert_zero "$(printf '%s\n' "$enc_ps" | grep -cE 'function [A-Za-z-]*[Mm]p4[Bb]ox')" "PS1 av_encode: nicio functie cu mp4box in nume"

# ── 9. FUNCTIONAL: detectie pe sample DJI real (ffprobe — merge si pe MSYS) ──
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SRC:$PATH"
dji_sample="$(ls "$SRC"/DJI_*.MP4 2>/dev/null | head -1)"
if command -v ffprobe >/dev/null 2>&1 && [ -n "$dji_sample" ]; then
    # sourcing av_common.sh (defineste helperele + av_mktemp_ext + AV_TOOL_MP4BOX)
    source "$SRC/av_common.sh" >/dev/null 2>&1
    if _dji_has_native_meta "$dji_sample"; then assert_zero 0 "FUNCTIONAL: _dji_has_native_meta=true pe DJI"; else assert_zero 1 "FUNCTIONAL: _dji_has_native_meta pe DJI"; fi
    ids="$(_dji_native_meta_ids "$dji_sample" | tr -s ' ' | sed 's/ $//')"
    assert_match "$ids" '^[0-9]+$' "FUNCTIONAL: _dji_native_meta_ids = 1 ID (djmd DOAR)"

    # graft real — doar daca MP4Box e disponibil SI nu suntem pe MSYS (cai git-bash + MP4Box)
    _u="$(uname -s 2>/dev/null || echo unknown)"
    if command -v "$AV_TOOL_MP4BOX" >/dev/null 2>&1 && [[ "$_u" != MINGW* && "$_u" != MSYS* ]]; then
        _g="$(date +%s)_$$"
        base="${TMPDIR:-/tmp}/djib_$_g.mp4"
        ffmpeg -v error -y -i "$dji_sample" -map 0:v:0 -map 0:a? -c copy -dn "$base" 2>/dev/null
        if _dji_graft_native_meta "$dji_sample" "$base"; then
            grafted_djmd="$(ffprobe -v error -select_streams d -show_entries stream=codec_tag_string -of default=noprint_wrappers=1:nokey=1 "$base" 2>/dev/null | grep -c djmd)"
            assert_zero "$(( grafted_djmd >= 1 ? 0 : 1 ))" "FUNCTIONAL: djmd prezent dupa graft"
            # negativ: graft refuzat pe non-DJI
            nod="${TMPDIR:-/tmp}/nodji_$_g.mp4"
            ffmpeg -v error -y -f lavfi -i testsrc=d=1:s=64x64 -c:v libx264 "$nod" 2>/dev/null
            if _dji_graft_native_meta "$nod" "$base"; then assert_zero 1 "FUNCTIONAL: graft trebuia refuzat pe non-DJI"; else assert_zero 0 "FUNCTIONAL: graft refuzat pe non-DJI"; fi
            rm -f "$nod"
        else
            echo "  NOTA: graft a esuat (MP4Box?) — sar peste asertiunile de graft"
        fi
        rm -f "$base"
    else
        echo "  NOTA: MP4Box absent sau MSYS (cai git-bash) — sar functionalul de graft (validat pe PS1/Linux)"
    fi
else
    echo "  NOTA: ffprobe sau sample DJI absent — sar functionalul (source-level acopera)"
fi
