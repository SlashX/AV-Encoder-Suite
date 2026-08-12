#!/usr/bin/env bash
# v96 — formatarea zecimala din bash nu are voie sa depinda de setarile regionale.
#
# Aceeasi clasa reparata deja de doua ori pe PowerShell (v94: coloana FPS; v95: `~1,2 GB`
# in estimari), lasata atunci descoperita pe bash cu nota "bash NEATINS, ruleaza pe 3
# platforme". Presupunerea n-a fost verificata pana la auditul v96, iar cand a fost, a picat.
#
# Cauza: `mawk` — awk-ul IMPLICIT pe Debian/Ubuntu (gawk ajunge acolo doar daca il aduce alt
# pachet) — foloseste separatorul zecimal al locale-ului la iesire:
#     LC_ALL=ro_RO.UTF-8 mawk 'BEGIN{printf "%.2f", 43.2}'   →  43,20
# gawk, original-awk si busybox awk sunt imune, de-aceea nu s-a vazut pe boxa de dezvoltare.
#
# Ce se rupea concret (dovedit cap-coada pe Ubuntu + ro_RO.UTF-8):
#   - burn-in preview  : PREVIEW_T_START=1,504 → `ffmpeg -ss 1,500` → rc=234
#                        "Invalid duration for option ss" → preview-ul nu se produce deloc
#   - thumbnails trim/concat : acelasi lant
#   - CSV av_check     : FPS "59,94", Bitrate "54,62", SampleRate "48,0", Est_* "~7,0 GB",
#                        MasterDisplay "min 0,0050n" — continut dependent de MASINA
#   - conversia de FPS : valoarea cu virgula se interpoleaza ca TEXT intr-un al doilea
#                        program awk → argument in plus / eroare de sintaxa → se sare tacut
#
# Reparatia foloseste conventia care exista deja in proiect (`LC_ALL=C awk`, folosita in
# av_common.sh si av_mux.sh cu comentariul "previne formatare cu virgula in EU locales").
# Se aplica DOAR pe apelurile care emit zecimale: iesirile intregi s-au dovedit corecte, iar
# prefixarea oarba a tuturor apelurilor ar face si clasele de caractere doar-ASCII.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"

# ── 1. Zero apeluri awk cu %f nepazite, in tot src/ ──────────────────
unguarded=0
while IFS= read -r f; do
    while IFS= read -r hit; do
        n="${hit%%:*}"; body="${hit#*:}"
        case "${body#"${body%%[![:space:]]*}"}" in '#'*) continue ;; esac
        # e un apel awk in pozitie de comanda, care emite %f, si NU e precedat de LC_ALL=C?
        if printf '%s' "$body" | grep -qE '(^|[|;&(]|[[:space:]])awk[[:space:]]' \
           && printf '%s' "$body" | grep -qE '%[-+ 0-9.#]*f' ; then
            if ! printf '%s' "$body" | grep -qE 'LC_ALL=C[[:space:]]+awk'; then
                _fail "$(basename "$f"):$n — awk cu %f fara LC_ALL=C: $(printf '%s' "$body" | sed 's/^[[:space:]]*//' | cut -c1-90)"
                unguarded=$((unguarded+1))
            fi
        fi
    done < <(grep -n "awk" "$f" 2>/dev/null)
done < <(find "$SRC" -maxdepth 2 -name '*.sh' 2>/dev/null)
[ "$unguarded" -eq 0 ] && _pass

# ── 1b. Clasa A: zecimala CITITA dintr-un camp de intrare ────────────
# Distinctia conteaza si a fost stabilita empiric pe mawk + ro_RO.UTF-8:
#   - camp de intrare  (`$1+0` din stdin)      → SE STRICA  ("0.265"+0 → 0)
#   - valoare cu `-v`  (`awk -v d=8.008`)      → corecta
#   - literal interpolat de shell in program   → corect
# Deci un awk fara `%f` poate fi la fel de periculos: cel din av_check care clasifica
# primarele masterului citea `$1+0` si raspundea mereu "BT.2020", indiferent de valoare.
_classA=0
while IFS= read -r f; do
    while IFS= read -r hit; do
        n="${hit%%:*}"; body="${hit#*:}"
        case "${body#"${body%%[![:space:]]*}"}" in '#'*) continue ;; esac
        # awk care face aritmetica pe un CAMP de intrare ($N cu operator sau +0)
        printf '%s' "$body" | grep -qE '\$[0-9]+ *\+ *0|v *= *\$[0-9]+ *\+' || continue
        if ! printf '%s' "$body" | grep -qE 'LC_ALL=C[[:space:]]+awk'; then
            _fail "$(basename "$f"):$n — awk citeste zecimala din camp fara LC_ALL=C"
            _classA=$((_classA+1))
        fi
    done < <(grep -n "awk" "$f" 2>/dev/null)
done < <(find "$SRC" -maxdepth 2 -name '*.sh' 2>/dev/null)
[ "$_classA" -eq 0 ] && _pass

# situl concret care s-a dovedit rupt (clasificarea primarelor din master display)
assert_contains "$(sed -n '665,676p' "$SRC/av_check.sh")" "LC_ALL=C awk '{v=\$1+0"     "av_check: clasificarea primarelor citeste campul sub LC_ALL=C"

# ── 2. Siturile care ajung in linia de comanda ffmpeg sunt pazite ────
# (verificare tintita, ca sa ramana explicit DE CE conteaza)
assert_match "$(sed -n '85p' "$SRC/av_burnin.sh")"  "LC_ALL=C awk" "av_burnin: PREVIEW_T_START (intra in -ss)"
assert_match "$(sed -n '91p' "$SRC/av_burnin.sh")"  "LC_ALL=C awk" "av_burnin: PREVIEW_T_MID (intra in -ss)"
assert_contains "$(sed -n '650,660p' "$SRC/av_trimconcat.sh")" "LC_ALL=C awk" "av_trimconcat: timestamps thumbnail (intra in -ss)"
assert_contains "$(sed -n '460,470p' "$SRC/av_common.sh")"     "LC_ALL=C awk" "av_common: SRC_FPS_DEC (intra in lantul de filtre)"

# ── 3. Coloanele de CSV care s-au dovedit corupte ────────────────────
for ln in 481 561 569 666; do
    assert_match "$(sed -n "${ln}p" "$SRC/av_check.sh")" "LC_ALL=C awk" "av_check:$ln — coloana CSV pazita"
done

# ── 4. FUNCTIONAL: forma pazita e stabila indiferent de locale ───────
# Ruleaza doar unde exista mawk + o locale cu virgula (pe alte sisteme, nota onesta).
_loc=""
for cand in ro_RO.UTF-8 de_DE.UTF-8 fr_FR.UTF-8; do
    _norm=$(printf '%s' "$cand" | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/')
    if locale -a 2>/dev/null | tr 'A-Z' 'a-z' | grep -qx "$_norm"; then _loc="$cand"; break; fi
done
if command -v mawk >/dev/null 2>&1 && [ -n "$_loc" ]; then
    bare=$(LC_ALL="$_loc" mawk 'BEGIN{printf "%.2f", 43.2}' 2>/dev/null)
    guarded=$(LC_ALL="$_loc" bash -c 'LC_ALL=C mawk "BEGIN{printf \"%.2f\", 43.2}"' 2>/dev/null)
    assert_eq "43,20" "$bare"    "premisa: mawk NEpazit chiar produce virgula sub $_loc"
    assert_eq "43.20" "$guarded" "forma pazita ramane cu punct sub $_loc"
    # si ca ffmpeg chiar respinge varianta cu virgula (de-aia conteaza)
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -v error -y -ss "1,500" -f lavfi -i testsrc=size=64x64:duration=3 -frames:v 1 \
               -f null - >/dev/null 2>&1 && _fail "ffmpeg a acceptat -ss cu virgula (premisa cazuta)" || _pass
    fi
else
    echo "  NOTA: mawk sau o locale cu virgula lipsesc — partea functionala se sare"
    echo "        (verificarile de sursa de mai sus raman autoritare)"
fi

_test_summary
