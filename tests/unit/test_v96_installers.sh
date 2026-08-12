#!/usr/bin/env bash
# v96 — installerele de unelte trebuie sa fie complete pe TOATE cele trei platforme.
#
# Bug-ul pazit aici a fost introdus chiar de refactorizarea v96 si gasit la auditul de
# dinaintea productiei: `dovi_parser.sh` si `hdr10plus_parser.sh` au primit un bloc de
# platforma (Darwin / Termux / Linux), dar ramura Termux seta DOAR `IS_TERMUX=1` — linia
# veche `BIN_DEST=/data/data/com.termux/...` fusese stearsa si nu mai era pusa inapoi.
# Efectul pe Termux: compilarea reusea, apoi `cp binar ""` esua → installer rupt exact pe
# platforma originala a proiectului, cu un mesaj de eroare care arata o cale GOALA.
# A scapat fiindca Termux nu se poate rula de pe boxa de dezvoltare.
#
# Testul NU face grep dupa nume de variabile: SIMULEAZA blocul de platforma pe fiecare din
# cele trei sisteme (uname substituit, prezenta /data/data/com.termux fortata) si verifica
# ce iese. Asa prinde si o ramura noua adaugata mai tarziu care ar uita o initializare.
#
# bash-only prin natura: installerele .ps1 descarca binare gata compilate pe Windows, deci
# nu au notiunea de "ramura de platforma" pe care o pazeste testul asta.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TOOLS="$PROJECT_ROOT/src/tools"

INSTALLERS="dovi_parser.sh hdr10plus_parser.sh av1dovi_parser.sh av1hdr10plus_parser.sh"

# Extrage blocul `case "$(uname -s ...)" ... esac` si il ruleaza cu platforma simulata.
# Intoarce "BIN_DEST|IS_TERMUX".
_sim_platform() {
    local f="$1" uname_out="$2" is_termux="$3" blk
    blk=$(sed -n '/^case "\$(uname -s/,/^esac/p' "$f")
    [ -n "$blk" ] || { echo "|"; return; }
    blk=${blk//'$(uname -s 2>/dev/null)'/$uname_out}
    if [ "$is_termux" = "1" ]; then
        blk=${blk//'[ -d "/data/data/com.termux" ]'/'true'}
    else
        blk=${blk//'[ -d "/data/data/com.termux" ]'/'false'}
    fi
    (
        DEST_BIN="probe_bin"; HOME="/home/probe"
        BIN_DEST=""; IS_TERMUX=""
        eval "$blk" >/dev/null 2>&1
        printf '%s|%s' "$BIN_DEST" "$IS_TERMUX"
    )
}

# ── 1. Fiecare platforma primeste o destinatie NEGOALA + IS_TERMUX ───
for inst in $INSTALLERS; do
    f="$TOOLS/$inst"
    assert_file_exists "$f" "$inst exista"

    r=$(_sim_platform "$f" "Linux" "1")   # Termux
    bd="${r%%|*}"; it="${r##*|}"
    case "$bd" in
        */data/data/com.termux/files/usr/bin/*) _pass ;;
        "") _fail "$inst [Termux]: BIN_DEST GOL — binarul nu are unde sa fie instalat" ;;
        *)  _fail "$inst [Termux]: BIN_DEST neasteptat ($bd)" ;;
    esac
    assert_eq "1" "$it" "$inst [Termux]: IS_TERMUX=1"

    r=$(_sim_platform "$f" "Linux" "0")   # Linux desktop
    bd="${r%%|*}"; it="${r##*|}"
    assert_match "$bd" "^/home/probe/\.local/bin/" "$inst [Linux]: instaleaza in ~/.local/bin"
    assert_eq "0" "$it" "$inst [Linux]: IS_TERMUX=0"

    r=$(_sim_platform "$f" "Darwin" "0")  # macOS
    bd="${r%%|*}"; it="${r##*|}"
    assert_match "$bd" "^/usr/local/bin/" "$inst [macOS]: instaleaza in /usr/local/bin"
    assert_eq "0" "$it" "$inst [macOS]: IS_TERMUX=0"
done

# ── 2. `pkg install` (Termux) NU se executa pe Linux/macOS ───────────
# pkg e managerul Termux; pe un Linux obisnuit comanda ori nu exista, ori e alt program.
for inst in $INSTALLERS; do
    f="$TOOLS/$inst"
    while IFS= read -r ln; do
        n="${ln%%:*}"
        # linia trebuie sa fie intr-un bloc gardat pe Termux — verificam ca deasupra ei,
        # in ultimele 30 de linii, exista o conditie IS_TERMUX
        ctx=$(sed -n "$(( n > 30 ? n-30 : 1 )),${n}p" "$f")
        case "$ctx" in
            *'IS_TERMUX'*) : ;;
            *) _fail "$inst:$n — 'pkg install' negardat pe Termux" ;;
        esac
    done < <(grep -n "pkg install" "$f" | grep -v "^\s*#")
done
_pass  # daca bucla n-a semnalat nimic

# ── 3. Ocolirea fontconfig e prezenta si NEgardata pe Termux ─────────
# Build-ul poate folosi un font intern in loc de biblioteca de sistem. Solutia exista de
# mult, dar era conditionata sa se aplice doar pe Termux → pe un Linux fara libfontconfig
# utilizatorul primea eroarea bruta de compilator.
for inst in $INSTALLERS; do
    f="$TOOLS/$inst"
    assert_contains "$(cat "$f")" "internal-font" "$inst: ocolirea fontconfig exista"
    blk=$(grep -B4 -- "--features internal-font" "$f" | grep -c 'IS_TERMUX.*=.*"1"' || true)
    assert_eq "0" "$blk" "$inst: ocolirea fontconfig NU e gardata pe Termux (e universala)"
done

# ── 4. Esecul de plasare a binarului iese cu cod de eroare ───────────
for inst in $INSTALLERS; do
    f="$TOOLS/$inst"
    assert_contains "$(cat "$f")" 'nu am putut instala binarul' "$inst: esecul de plasare e raportat"
    # ...si NU tipareste succes pe aceeasi ramura
    seg=$(sed -n '/nu am putut instala binarul/,/^    fi$/p' "$f")
    case "$seg" in
        *"INSTALARE REUSITA"*) _fail "$inst: ramura de esec ajunge la mesajul de succes" ;;
        *) _pass ;;
    esac
    assert_contains "$seg" "exit 1" "$inst: ramura de esec iese cu 1"
done

# ── 5. Indrumare rustup la esec de build (cauza frecventa: rustc vechi) ──
for inst in $INSTALLERS; do
    assert_contains "$(cat "$TOOLS/$inst")" "sh.rustup.rs" "$inst: hint rustup la esec"
done

# ── 6. Sfatul IMPOSIBIL nu s-a intors ────────────────────────────────
# `cargo install dovi_tool` esueaza mereu: uneltele quietvoid nu sunt publicate pe crates.io.
for inst in $INSTALLERS; do
    out=$(grep -v '^[[:space:]]*#' "$TOOLS/$inst" | grep -c "cargo install" || true)
    assert_eq "0" "$out" "$inst: fara 'cargo install' (uneltele nu sunt pe crates.io)"
done

_test_summary
