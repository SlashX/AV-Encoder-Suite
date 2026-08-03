#!/usr/bin/env bash
# v94 (Faza 4) — validarea input-ului de la utilizator.
#
# Campania v94 a lovit ACCIDENTAL cinci validatoare (raspunsuri decalate in
# secventele de stdin): „Segment invalid", „start >= end. Reintrodu.", „Sarit.",
# „Optiune invalida", „Format invalid". Toate s-au comportat corect — dar era o
# dovada intamplatoare, nu un test: niciunul nu era acoperit.
#
# Ele stau intre o greseala de tastare a userului si o rulare corupta, deci merita
# santinele. Testul verifica: (1) contractul regex al fiecarui validator,
# (2) cablarea (validatorul chiar opreste fluxul), (3) paritatea bash <-> PS1.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

LAUNCH="$(cat "$SCRIPT_DIR/av_launcher.sh")"
TC="$(cat "$SCRIPT_DIR/av_trimconcat.sh")"
ENC_PS1="$(cat "$SCRIPT_DIR/av_encode.ps1")"

# ── 1. Bitrate VBR: `^[0-9]+[kKmM]$` ────────────────────────────────
assert_contains "$LAUNCH" 'validate_bitrate() { [[ "$1" =~ ^[0-9]+[kKmM]$ ]]; }' \
    "bitrate: validatorul exista ca functie"
assert_contains "$LAUNCH" 'EROARE: Format invalid' "bitrate: mesaj + oprire"
_vb() { [[ "$1" =~ ^[0-9]+[kKmM]$ ]]; }
for good in 2000k 4000K 4M 8m 500k; do
    _vb "$good" && assert_eq "0" "0" "bitrate: '$good' acceptat" || assert_eq "0" "1" "bitrate: '$good' acceptat"
done
for bad in "" "2000" "abc" "2000kb" "-500k" "2,5M" "2000 k" "k2000"; do
    if _vb "$bad"; then assert_eq "respins" "acceptat" "bitrate: '$bad' respins"
    else assert_eq "respins" "respins" "bitrate: '$bad' respins"; fi
done

# ── 2. Parametri extra encoder: segmente `key=value` separate cu `:` ──
assert_contains "$LAUNCH" 'ERROR_MSG="Segment gol detectat"' "extra: segment gol prins"
assert_contains "$LAUNCH" "ERROR_MSG=\"Segment invalid: '\$seg'\"" "extra: segment fara key= prins"
# A 3-a ramura, esentiala: `key=` fara valoare. Fara ea, input-ul ajunge la ffmpeg,
# care il refuza cu rc=-22 si mesaj criptic („Error setting option x265-params").
assert_contains "$LAUNCH" 'elif [[ -z "${seg#*=}" ]]; then' "extra: valoare goala prinsa"
assert_contains "$LAUNCH" 'ERROR_MSG="Valoare lipsa' "extra: mesaj dedicat pt valoare goala"
# Contractul complet, replicat (validatorul e inline in launcher, nu functie).
# TOATE cele 3 ramuri — o replica incompleta ar face santinela fals-negativa.
_seg_ok() {
    local input="$1" seg
    [[ -z "$input" ]] && return 0                 # gol = „sari", valid
    IFS=':' read -ra _S <<< "$input"
    for seg in "${_S[@]}"; do
        [[ -z "$seg" ]] && return 1                             # segment gol
        [[ "$seg" =~ ^[a-zA-Z][a-zA-Z0-9_-]*= ]] || return 1    # fara key=
        [[ -z "${seg#*=}" ]] && return 1                        # valoare goala
    done
    return 0
}
for good in "rc-lookahead=40" "rc-lookahead=40:psy-rd=1.5" "aq-mode=3" ""; do
    if _seg_ok "$good"; then assert_eq "ok" "ok" "extra: '$good' acceptat"
    else assert_eq "ok" "respins" "extra: '$good' acceptat"; fi
done
# '1' e exact ce a picat accidental in campanie (raspuns decalat pe stdin);
# 'aq-mode=' e cel pe care ffmpeg il refuza cu rc=-22 daca trece de validator.
for bad in "1" "40" "rc-lookahead" "=40" "rc-lookahead=40::psy-rd=1" "-bad=1" "aq-mode=" "a=1:b="; do
    if _seg_ok "$bad"; then assert_eq "respins" "acceptat" "extra: '$bad' respins"
    else assert_eq "respins" "respins" "extra: '$bad' respins"; fi
done
# Paritate: PS1 prinde acelasi caz cu UN regex (`=.`), bash cu o ramura separata
# si mesaj mai specific („Valoare lipsa: 'aq-mode'"). Ambele RESPING — diferenta e
# doar de formulare, deliberat pastrata.
assert_contains "$ENC_PS1" '$seg -notmatch' "PS1: valideaza segmentul cu regex"
_ps1_re=$(printf '%s' "$ENC_PS1" | grep -oE "notmatch '[^']*='?\.?'" | head -1)
assert_match "$_ps1_re" '=\.' "PS1: regex-ul cere cel putin un caracter dupa '=' (=.)"

# ── 3. Trim: start >= end se RE-cere, nu se accepta ─────────────────
assert_contains "$TC" 'EROARE: start >= end. Reintrodu.' "trim: guard start>=end"
assert_contains "$TC" 'if (( start_s >= end_s )); then' "trim: comparatie numerica"
# guard-ul e intr-un `while true` → re-cere, nu iese
_ctx=$(printf '%s' "$TC" | grep -A 8 'while true; do' | grep -c 'start >= end')
assert_nonzero "$_ctx" "trim: guard-ul e in bucla de re-cerere (nu exit)"

# ── 4. Meniuri: optiune invalida nu continua tacut ──────────────────
n_inv=$(printf '%s' "$LAUNCH" | grep -c 'Optiune invalida')
assert_nonzero "$n_inv" "meniuri: exista mesaj de optiune invalida"

# ── 5. Paritate PS1 (aceleasi validatoare, aceeasi semantica) ───────
assert_contains "$ENC_PS1" 'Test-BitrateFormat' "PS1: validator de bitrate"
assert_contains "$ENC_PS1" 'Format invalid!' "PS1: bitrate — mesaj + oprire"
assert_contains "$ENC_PS1" 'Segment gol detectat (:: dublu).' "PS1: segment gol"
assert_contains "$ENC_PS1" "Segment invalid: '\$seg' (format: key=value)" "PS1: segment fara key="
assert_contains "$ENC_PS1" 'Format invalid. Exemple: 45 / 1:30' "PS1: timp — mesaj cu exemple"
