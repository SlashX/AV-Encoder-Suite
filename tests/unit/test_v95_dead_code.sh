#!/usr/bin/env bash
# v95 — nicio functie bash din src/ nu are voie sa ramana fara apelanti.
#
# De ce exista: curatenia v95 a scos 5 functii moarte din av_common.sh (88 linii) si un bloc
# de 282 de linii din av_encode.ps1. Doua dintre ele erau in repo de la v44, iar una
# (`remux_container_with_tag`) avea chiar 8 aserţiuni proprii — deci suita „acoperea" cod pe
# care nimic nu-l executa. Fara garda, situatia se reface: helperii raman in urma cand fluxul
# lor se muta in alt fisier (aici: Remux → av_mux, v49; tag-urile → codec_tag_for_container,
# v57), si nimeni nu observa.
#
# Detectorul: pentru fiecare functie definita in src/*.sh, numara aparitiile numelui in TOATE
# fisierele .sh din src/ (se sourceaza intre ele) cu COMENTARIILE PE LINIE INTREAGA scoase.
# Comentariile conteaza: exact asa a scapat `Invoke-Remux` la prima mea baleiere — numele lui
# aparea intr-un comentariu, deci parea folosit. Se taie DOAR liniile care incep cu `#`, nu si
# comentariile de la capat de linie, ca sa nu ciuntim cod ce contine `#` intr-un sir.
#
# Definitiile se cauta si INDENTAT (`^[[:space:]]*nume() {`): proiectul are 9 helperi definiti
# in interiorul altor functii sau al unor blocuri `if` — `_vi_field`, `to_kbps`, `_demux_ffmpeg`
# s.a. Toti sunt vii azi, dar o ancorare la coloana 0 i-ar lasa nescanati pe vecie, adica exact
# genul de gaura pe care santinela asta exista ca s-o inchida. Parantezele GOALE din tipar sunt
# ce ne fereste de functiile `awk` din heredoc-uri (`function val(x, n,d,p)` are argumente).
#
# `src/tools/` se scaneaza SEPARAT, per fisier: installerele nu se sourceaza niciunul pe altul
# (spre deosebire de src/*.sh), deci acolo „mort" inseamna „fara apelanti in propriul fisier".
#
# ALLOWLIST — `av_sed_inplace` si `av_date_to_epoch`: fac parte din stratul de wrappere
# cross-platform (v41), iar santinela C din test_v69_source_invariants INTERZICE folosirea
# directa a `sed -i` / `date -d`. Sunt API pus la dispozitie, nu resturi: daca le stergem,
# primul care are nevoie de ele va ocoli regula. Sunt nefolosite azi si asa raman, deliberat.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

ALLOWLIST=" av_sed_inplace av_date_to_epoch "

TMPD=$(mktemp -d)
# NU `trap 'rm' EXIT` — ar suprascrie _test_summary din framework (regula proiectului).
trap 'rm -rf "$TMPD"; _test_summary' EXIT

# Totul intr-O SINGURA invocare awk per director. Varianta naiva (un `grep`/`awk` per
# functie) pornea ~200 de procese si dura ~55-68s pe MSYS — adica santinela asta singura ar
# fi cantarit ~8% din suita bash. Acum e o trecere: acelasi pas colecteaza definitiile SI
# numara identificatorii, iar comentariile pe linie intreaga se sar inainte de amandoua.
_awk_dead='
function emit(  d) { for (d in defs) if (!(d in allow) && cnt[d] <= 1) print defs[d] ":" d }
BEGIN { n = split(allowlist, tmp, " "); for (i = 1; i <= n; i++) if (tmp[i] != "") allow[tmp[i]] = 1 }
FNR == 1 { fname = FILENAME; sub(/^.*\//, "", fname)
           if (perfile == 1 && NR > 1) { emit(); delete defs; delete cnt } }
/^[[:space:]]*#/ { next }
{ if (match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*\(\)/)) {
      d = substr($0, RSTART, RLENGTH); gsub(/[[:space:]()]/, "", d); defs[d] = fname }
  s = $0
  while (match(s, /[A-Za-z_][A-Za-z0-9_]*/)) {
      cnt[substr(s, RSTART, RLENGTH)]++; s = substr(s, RSTART + RLENGTH) } }
END { emit() }'

# _dead_funcs <dir> [perfile] → "fisier:functie" pentru fiecare functie fara apelanti.
# perfile=1 → fiecare fisier se judeca singur (installerele din tools/, care nu se sourceaza).
_dead_funcs() {
    local dir="$1" perfile="${2:-0}" files
    files=$(ls "$dir"/*.sh 2>/dev/null)
    [ -n "$files" ] || return 0
    # FARA `2>/dev/null`: o eroare de sintaxa awk ar da iesire GOALA, adica „zero cod mort" —
    # un fals-verde perfect. (S-a intamplat: un regex stricat a facut detectorul mut, iar
    # aserţiunile pe violarile plantate au fost singurele care au observat.)
    # shellcheck disable=SC2086
    awk -v allowlist="$ALLOWLIST" -v perfile="$perfile" "$_awk_dead" $files | sort
}

# ── 1. src/ e curat ──────────────────────────────────────────────────
dead=$(_dead_funcs "$SCRIPT_DIR")
dead_n=$(printf '%s' "$dead" | grep -c . || true)
[ "$dead_n" != "0" ] && printf '%s\n' "$dead" >&2
assert_eq "0" "$dead_n" "zero functii bash fara apelanti in src/*.sh"

# ── 1b. src/tools/ e curat (per fisier — installerele nu se sourceaza) ──
deadt=$(_dead_funcs "$SCRIPT_DIR/tools" 1)
deadt_n=$(printf '%s' "$deadt" | grep -c . || true)
[ "$deadt_n" != "0" ] && printf '%s\n' "$deadt" >&2
assert_eq "0" "$deadt_n" "zero functii bash fara apelanti in src/tools/*.sh"

# ── 1c. Definitiile INDENTATE chiar sunt scanate ─────────────────────
# (fara asta, cei 9 helperi definiti in interiorul altor functii ar fi invizibili pe vecie)
assert_contains "$(grep -oE '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$SCRIPT_DIR/av_launcher.sh" | sed 's/^[[:space:]]*//')" \
    "to_kbps()" "tiparul de definitie prinde si functiile indentate (to_kbps din av_launcher.sh)"

# ── 2. Detectorul PRINDE o violare plantata (altfel santinela e decorativa) ──
plant="$TMPD/plant"; mkdir -p "$plant"
cat > "$plant/a.sh" <<'EOF'
#!/usr/bin/env bash
viu() { echo "sunt chemat"; }
mort() { echo "nimeni nu ma cheama"; }
viu
EOF
pl=$(_dead_funcs "$plant")
assert_contains "$pl" "a.sh:mort"  "detectorul prinde o functie fara apelanti"
case "$pl" in *"a.sh:viu"*) _fail "fals-pozitiv pe o functie chemata" ;; *) _pass ;; esac

# ── 2b. …inclusiv una INDENTATA (definita intr-un bloc) ──────────────
cat > "$plant/ind.sh" <<'EOF'
#!/usr/bin/env bash
if true; then
    mort_indentat() { echo "definit intr-un bloc, chemat de nimeni"; }
    viu_indentat() { echo "x"; }
fi
viu_indentat
EOF
pli=$(_dead_funcs "$plant")
assert_contains "$pli" "ind.sh:mort_indentat" "detectorul prinde si o functie INDENTATA fara apelanti"
case "$pli" in *"ind.sh:viu_indentat"*) _fail "fals-pozitiv pe o functie indentata chemata" ;; *) _pass ;; esac

# ── 2c. Functiile awk din heredoc-uri NU sunt confundate cu functii bash ──
cat > "$plant/awkf.sh" <<'EOF'
#!/usr/bin/env bash
ruleaza() {
    awk 'function val(x,   n,d,p){ return x } { print val($1) }' "$1"
}
ruleaza /dev/null
EOF
pla=$(_dead_funcs "$plant")
case "$pla" in *"awkf.sh:val"*) _fail "fals-pozitiv: functie awk luata drept functie bash" ;; *) _pass ;; esac

# ── 3. Fara fals-pozitiv cand apelantul e in ALT fisier (bash se sourceaza) ──
cat > "$plant/b.sh" <<'EOF'
#!/usr/bin/env bash
source ./a.sh
partajata_din_alt_fisier
EOF
cat >> "$plant/a.sh" <<'EOF'
partajata_din_alt_fisier() { echo "definita in a.sh, chemata din b.sh"; }
EOF
pl2=$(_dead_funcs "$plant")
case "$pl2" in
    *"partajata_din_alt_fisier"*) _fail "fals-pozitiv: apelantul e in alt fisier din src/" ;;
    *) _pass ;;
esac

# ── 4. Comentariile NU tin o functie in viata ────────────────────────
# (capcana reala: `# Invoke-Remux — re-mux container...` a mascat o functie moarta)
cat > "$plant/c.sh" <<'EOF'
#!/usr/bin/env bash
# doar_in_comentariu face ceva foarte util, candva
doar_in_comentariu() { echo "x"; }
EOF
pl3=$(_dead_funcs "$plant")
assert_contains "$pl3" "c.sh:doar_in_comentariu" "un nume aparut doar in comentariu NU conteaza ca apel"

# ── 5. Allowlist-ul e respectat si documentat ────────────────────────
for w in av_sed_inplace av_date_to_epoch; do
    assert_contains "$(cat "$SCRIPT_DIR/av_common.sh")" "${w}()" "wrapper-ul $w exista (allowlist v41)"
done
