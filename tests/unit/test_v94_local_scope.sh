#!/usr/bin/env bash
# v94 (Faza 4) — `local` NU are voie in afara unei functii.
#
# Regula exista din v66: `local` la nivel de script tipareste
# „local: can only be used in a function", intoarce non-zero SI lasa variabila nesetata.
# Buclele NU sunt functii — `for`/`while`/`if` la nivel de script sunt tot nivel de script.
#
# Regula a fost incalcata de DOUA ori (v66 in ramura AC3 din av_encoder_audio.sh, apoi
# v94/B7 in acelasi fisier), si nicio santinela nu o acoperea → asta e santinela.
#
# Detectorul trebuie sa fie:
#   - heredoc-aware  (`}` din JSON-ul scris cu heredoc nu inchide o functie —
#                     exact ce a produs fals-pozitive in av_common.sh:2009)
#   - tolerant la functii INDENTATE (`to_kbps() {` definit intr-un bloc `elif`)
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

PYBIN="$(command -v python3 || command -v python || true)"
if [[ -z "$PYBIN" ]]; then skip_test "python lipseste (detectorul e in python)"; fi

TMPD="$(mktemp -d)"
# framework.sh instaleaza `trap _test_summary EXIT`; il suprascriem, deci trebuie sa-l
# rechemam noi (altfel sumarul dispare si testul iese mereu 0 — regula documentata).
trap 'rm -rf "$TMPD"; _test_summary' EXIT

cat > "$TMPD/detect_local.py" <<'PYEOF'
import re, sys, pathlib
sys.stdout.reconfigure(encoding="utf-8")

FUNC_OPEN = re.compile(r'^\s*(?:function\s+)?[A-Za-z_][A-Za-z0-9_]*\s*(?:\(\))?\s*\{\s*(?:#.*)?$')
HEREDOC   = re.compile(r'<<-?\s*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\1')

def offenders(path):
    out = []
    lines = pathlib.Path(path).read_text(encoding="utf-8", errors="replace").split("\n")
    depth = 0          # adancimea de acolade, doar in afara heredoc-urilor
    fstack = []        # adancimile la care s-au deschis functii
    hd = None          # terminatorul de heredoc activ
    for i, ln in enumerate(lines, 1):
        if hd is not None:
            if ln.strip() == hd: hd = None
            continue
        m = HEREDOC.search(ln)
        if m and not ln.lstrip().startswith("#"):
            hd = m.group(2)
            continue
        if re.match(r'^\s*local\s', ln) and not fstack:
            out.append((i, ln.strip()[:70]))
        if FUNC_OPEN.match(ln):
            fstack.append(depth); depth += 1
            continue
        # acolade „structurale": ignoram ${...} si acoladele din interiorul ghilimelelor
        clean = re.sub(r'\$\{[^}]*\}', '', ln)
        clean = re.sub(r'"[^"]*"|\'[^\']*\'', '', clean)
        depth += clean.count("{") - clean.count("}")
        while fstack and depth <= fstack[-1]:
            fstack.pop()
    return out

total = 0
for p in sorted(pathlib.Path(sys.argv[1]).glob("*.sh")):
    for ln, txt in offenders(p):
        print(f"{p.name}:{ln}: {txt}")
        total += 1
print(f"TOTAL={total}")
PYEOF

out=$("$PYBIN" "$TMPD/detect_local.py" "$SCRIPT_DIR" 2>&1)
found=$(printf '%s' "$out" | sed -n 's/^TOTAL=\([0-9]*\)$/\1/p')
[[ -n "$found" ]] || { echo "$out" >&2; _fail "detectorul nu a raportat TOTAL"; found=-1; }
if [[ "$found" != "0" ]]; then printf '%s\n' "$out" | grep -v '^TOTAL=' >&2; fi
assert_eq "0" "$found" "zero 'local' in afara functiilor (regula v66)"

# ── Detectorul PRINDE o violare plantata? (altfel santinela e decorativa) ──
plant="$TMPD/plant"; mkdir -p "$plant"
cat > "$plant/bad.sh" <<'EOF'
#!/usr/bin/env bash
f() { local ok=1; echo "$ok"; }
for x in a b; do
    local rau=2
    echo "$x $rau"
done
EOF
pl=$("$PYBIN" "$TMPD/detect_local.py" "$plant" 2>&1 | sed -n 's/^TOTAL=\([0-9]*\)$/\1/p')
assert_eq "1" "$pl" "detectorul prinde un 'local' plantat intr-un for la nivel de script"

# ── Si NU da fals-pozitiv pe cele doua capcane reale din repo ──
cat > "$plant/ok.sh" <<'EOF'
#!/usr/bin/env bash
# capcana 1: acolada din heredoc (ca JSON-ul din generate_dv_rpu_from_hdr10plus)
gen() {
    cat > /dev/null <<'CONF'
{
  "level6": { "x": 1 }
}
CONF
    local rc=$?
    echo "$rc"
}
# capcana 2: functie INDENTATA (ca to_kbps din av_launcher.sh)
if true; then
    to_kbps() {
        local br="$1"
        echo "$br"
    }
fi
EOF
rm -f "$plant/bad.sh"
pl2=$("$PYBIN" "$TMPD/detect_local.py" "$plant" 2>&1 | sed -n 's/^TOTAL=\([0-9]*\)$/\1/p')
assert_eq "0" "$pl2" "zero fals-pozitive pe heredoc + functie indentata"
