#!/usr/bin/env bash
# v95 — calea de PROFIL nu are voie sa ocoleasca initializari de care depinde encodarea.
#
# Bug-ul reparat (bash): schema accepta VBR_MAXRATE/VBR_BUFSIZE GOALE, dialogul interactiv le
# calculeaza mereu, dar calea prin profil (AV_PROFILE — cea documentata pentru CI/cron) nu
# trecea pe acolo. Encoderele SW le consuma BRUT (`-maxrate $VBR_MAXRATE -bufsize $VBR_BUFSIZE`),
# deci ffmpeg primea doua flag-uri fara valoare → "Error applying encoder options: Invalid
# argument" → 0 octeti, pe x265/x264/av1 = calea implicita. Backend-urile HW aveau deja
# fallback (`${VBR_MAXRATE:-${VBR_TARGET}}`), de-aceea lovea doar SW-ul.
#
# CAPCANA DE PLASARE, pazita mai jos: prima varianta a fixului statea in blocul de normalizare
# din av_launcher.sh — si n-avea NICIUN efect, fiindca `goto_launch`/`SKIP_CONFIG` sare tot
# blocul de configurare. Adica exact calea care avea nevoie de fix il ocolea. Apelul trebuie sa
# stea DUPA `fi  # end SKIP_CONFIG`, singurul punct prin care trec ambele cai.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

# ── 1. Helperul exista si e in av_common.sh (partajat, nu inline) ────
assert_contains "$(cat "$SCRIPT_DIR/av_common.sh")" "_vbr_fill_defaults()" \
    "_vbr_fill_defaults e definit in av_common.sh"

# ── 2. PLASAREA: apelul e DUPA blocul de configurare, nu inauntru ────
LAUNCH="$SCRIPT_DIR/av_launcher.sh"
_end_skip=$(grep -n '^fi  # end SKIP_CONFIG' "$LAUNCH" | head -1 | cut -d: -f1)
_call=$(grep -n '^_vbr_fill_defaults' "$LAUNCH" | head -1 | cut -d: -f1)
assert_nonzero "$_end_skip" "blocul SKIP_CONFIG se inchide identificabil"
assert_nonzero "$_call"     "apelul _vbr_fill_defaults exista in launcher"
if [ -n "$_end_skip" ] && [ -n "$_call" ] && [ "$_call" -gt "$_end_skip" ]; then _pass
else _fail "apelul (linia $_call) trebuie sa fie DUPA inchiderea SKIP_CONFIG (linia $_end_skip) — altfel calea de profil il sare"
fi

# ── 3. Comportament: aceeasi formula ca dialogul interactiv ──────────
source "$SCRIPT_DIR/av_common.sh" 2>/dev/null

_try() {  # mode target maxrate bufsize → "maxrate|bufsize"
    ENCODE_MODE="$1"; VBR_PARAM="$2"; VBR_MAXRATE="$3"; VBR_BUFSIZE="$4"
    _vbr_fill_defaults
    printf '%s|%s' "$VBR_MAXRATE" "$VBR_BUFSIZE"
}
assert_eq "2250k|3000k" "$(_try 3 1500k '' '')"   "2-pass: maxrate 1.5x / bufsize 2x (ca in dialog)"
assert_eq "6000k|8000k" "$(_try 2 4M '' '')"      "VBR 1-pass: unitatea M se converteste corect"
assert_eq "|"           "$(_try 1 1500k '' '')"   "pe CRF nu se completeaza nimic"
assert_eq "9000k|1000k" "$(_try 3 1500k 9000k 1000k)" "valorile date de utilizator NU se suprascriu"
assert_eq "9000k|3000k" "$(_try 3 1500k 9000k '')"    "se completeaza DOAR ce lipseste"
assert_eq "|"           "$(_try 3 '' '' '')"      "fara tinta nu se inventeaza nimic"
assert_eq "|"           "$(_try 3 abc '' '')"     "tinta invalida → nicio completare"

# ── 4. Encoderele SW chiar consuma variabilele completate ────────────
# (daca cineva le rescrie cu un fallback local, fixul devine inutil — dar tot ar merge;
#  aserţiunea e aici ca sa ramana clar DE CE trebuie completate inainte)
for e in x265 x264 av1; do
    assert_contains "$(cat "$SCRIPT_DIR/av_encoder_$e.sh")" '-maxrate $VBR_MAXRATE' \
        "av_encoder_$e.sh consuma VBR_MAXRATE direct (deci trebuie completat in amonte)"
done

# ── 5. Modul VBR cere si o TINTA — garda care trebuie sa ramana ──────
# Schema accepta VBR_TARGET gol; fara garda, `-b:v ""` face ffmpeg sa refuze optiunile
# encoderului. bash o are de mult si cade grațios pe CRF; PS1 a primit-o in v95 (paritate).
for e in x265 x264 av1; do
    assert_contains "$(cat "$SCRIPT_DIR/av_encoder_$e.sh")" 'ENCODE_MODE" == "2" && -n "$VBR_TARGET"' \
        "av_encoder_$e.sh: VBR 1-pass gardat si pe tinta ne-goala"
done
assert_contains "$(cat "$SCRIPT_DIR/av_encode.ps1")" '-or ($encMode -eq "3")) -and $vbrTarget' \
    "PS1 are garda echivalenta pe tinta (paritate — altfel profilul fara tinta da 0 octeti)"
