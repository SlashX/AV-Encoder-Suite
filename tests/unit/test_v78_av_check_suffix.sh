#!/usr/bin/env bash
# v78 — av_check output-suffix recognition: _dv81 (static) + _rpu<mode> (dinamic, regex).
#   Invariant: fiecare sufix produs de suita e recunoscut de chain-stripping-ul av_check
#   ("COMPARATIE INPUT vs OUTPUT" leaga output-ul de sursa) + paritate bash<->PS1.
#   Gap reparat: _dv81 (P7->8.1, v76) + _rpu<mode> (Transform RPU, mod 2/3/5) lipseau.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../src" && pwd)"
sh_src="$(cat "$SRC/av_check.sh")"
ps_src="$(cat "$SRC/av_check.ps1")"

# ── 1. _dv81 (STATIC) recunoscut in ambele liste literale ─────────────
assert_contains "$sh_src" '_dvhybrid _dv81'      "av_check.sh: _dv81 in lista de sufixe"
assert_contains "$ps_src" '"_dvhybrid","_dv81"'  "av_check.ps1: _dv81 in lista de sufixe"

# ── 2. _rpu<mode> (DINAMIC) — regex strip in ambele (lista literala nu acopera) ──
assert_contains "$sh_src" '_rpu[0-9]+$'  "av_check.sh: regex _rpu<mode> dinamic"
assert_contains "$ps_src" '_rpu\d+$'     "av_check.ps1: regex _rpu<mode> dinamic"

# ── 3. PARITATE: aceleasi sufixe literale bash <-> PS1 ────────────────
sh_list="$(printf '%s\n' "$sh_src" | sed -n '/for suffix in/,/; do/p' | grep -oE '_[a-z0-9]+' | sort -u | tr '\n' ' ')"
ps_list="$(printf '%s\n' "$ps_src" | sed -n '/foreach ($sfx in @(/,/)) {/p' | grep -oE '_[a-z0-9]+' | sort -u | tr '\n' ' ')"
assert_eq "$sh_list" "$ps_list" "paritate: liste literale identice bash<->PS1"
assert_contains "$sh_list" "_dv81" "setul de paritate contine _dv81"

# ── 4. COMPLETITUDINE: fiecare encoder_get_suffix e recunoscut ────────
for enc in "$SRC"/av_encoder_*.sh; do
    sfx="$(sed -n 's/.*encoder_get_suffix() { echo "\(_[a-z0-9]*\)".*/\1/p' "$enc")"
    [ -z "$sfx" ] && continue
    assert_contains "$sh_src" "$sfx"      "av_check.sh recunoaste encoder $sfx ($(basename "$enc"))"
    assert_contains "$ps_src" "\"$sfx\""  "av_check.ps1 recunoaste encoder $sfx ($(basename "$enc"))"
done

# ── 5. COMPLETITUDINE: sufixele uneltelor (paritate explicita) ────────
for sfx in _audio _remux _mux _telem _hud _subs _preview _nodv _nohdr10plus _dvhybrid _dv81; do
    assert_contains "$sh_src" "$sfx"      "av_check.sh recunoaste tool $sfx"
    assert_contains "$ps_src" "\"$sfx\""  "av_check.ps1 recunoaste tool $sfx"
done

# ── 6. FUNCTIONAL: replica logica de strip av_check.sh (lista reala) ──
strip_name() {
    local b="$1"
    for s in _x265 _x264 _av1 _dnxhr _prores _apv _audio _hwenc _remux _mux _telem _hud _subs _preview _nodv _nohdr10plus _dvhybrid _dv81; do
        b="${b/$s/}"
    done
    b="${b%.*}"
    [[ "$b" =~ ^(.+)_rpu[0-9]+$ ]] && b="${BASH_REMATCH[1]}"
    echo "$b"
}
assert_eq "movie"   "$(strip_name movie_dv81.mkv)"      "_dv81 -> base"
assert_eq "movie"   "$(strip_name movie_rpu2.mkv)"      "_rpu2 -> base"
assert_eq "movie"   "$(strip_name movie_rpu5.mov)"      "_rpu5 -> base"
assert_eq "clip"    "$(strip_name clip_rpu3_telem.mp4)" "_rpu3_telem compus -> base"
assert_eq "movie"   "$(strip_name movie.mkv)"           "fara sufix -> neschimbat"
assert_eq "holiday" "$(strip_name holiday_av1.mp4)"     "_av1 fara fals-match _rpu"
