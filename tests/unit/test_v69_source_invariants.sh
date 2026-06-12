#!/usr/bin/env bash
# v69 — invarianti pe sursa (enforcement mecanic al regulilor "What NOT to do"):
#   A. Zero CRLF in fisierele .sh (src + tools + tests)
#   B. Zero anti-pattern-uri ffprobe NEAMBIGUE: `frame_side_data=type` (selectorul
#      invalid ignora filtrul → full dump → false-negative) si `side_data_list`
#      (fragil; forma canonica = frame_side_data). NB: csv=p=0 single-field NU e
#      verificat mecanic — exista ~28 utilizari intentionat TOLERANTE (grep pe
#      codec_tag, numarare de randuri) documentate in CLAUDE.md.
#   C. Zero bypass al wrapperelor av_* (GNU vs BSD) in src/*.sh — singura garda
#      posibila: macOS/Termux nu se pot testa empiric pe dev box. Allowlist:
#      sectiunea wrapperelor v41 din av_common + repair_hdr10_signaling
#      (grep -oP documentat Termux-only — GNU grep are PCRE acolo).
#   G. Zero mentiuni de asistent in fisierele user-facing (README/av_info/changelog).
#   D. Meta-test: orice `trap ... EXIT` din teste contine _test_summary
#      (altfel suprascrie summary-ul → fals-verde). + runnerele au garda 0-asertiuni.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"

# ── A. CRLF in .sh ───────────────────────────────────────────────────
# ATENTIE: NU grep pe continut — pe git-bash stratul text-mode MSYS adauga
# CR la CITIRE (artefact de masurare documentat; fisierele pe disc sunt LF).
# Sursa AUTORITARA: git ls-files --eol (index + working tree). Fisierele
# netracked noi sunt acoperite de mirror-ul PS1 (citire de bytes fidela).
crlf=$(cd "$PROJECT_ROOT" && git ls-files --eol -- '*.sh' 2>/dev/null \
    | grep -E 'i/crlf|w/crlf|i/mixed|w/mixed' || true)
assert_eq "" "$crlf" "A: zero CRLF in fisierele .sh tracked (git ls-files --eol) ($crlf)"

# ── B. Anti-pattern-uri ffprobe ──────────────────────────────────────
b_hits=$(grep -rn 'frame_side_data=type\|side_data_list' "$SRC"/*.sh "$SRC"/*.ps1 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:\s*#' || true)
assert_eq "" "$b_hits" "B: zero frame_side_data=type / side_data_list in src ($b_hits)"

# ── C. Bypass wrappere av_* in src/*.sh ──────────────────────────────
# Range-uri allowlist derivate DINAMIC (nu line numbers hardcodate):
W_START=$(grep -n 'Cross-platform wrappers (v41)' "$SRC/av_common.sh" | head -1 | cut -d: -f1)
W_END=$(awk -v s="$W_START" 'NR>s+2 && /═══════/ {print NR; exit}' "$SRC/av_common.sh")
R_START=$(grep -n '^repair_hdr10_signaling()' "$SRC/av_common.sh" | head -1 | cut -d: -f1)
R_END=$(awk -v s="$R_START" 'NR>s && /^\}/ {print NR; exit}' "$SRC/av_common.sh")
assert_eq "1" "$([[ -n "$W_START" && -n "$W_END" && -n "$R_START" && -n "$R_END" ]] && echo 1 || echo 0)" \
    "C: range-urile allowlist derivate (wrappers $W_START-$W_END, repair $R_START-$R_END)"

FORBIDDEN='stat -[cf][ %]|sed -i[ '"'"']|mktemp --suffix|readlink -f[ "]|grep -[A-Za-z]*P[ "]|date -[dj] |(^|[^[:alnum:]_./-])nproc([^[:alnum:]_-]|$)|df -'
c_viol=""
for f in "$SRC"/*.sh; do
    if [[ "$(basename "$f")" == "av_common.sh" ]]; then
        hits=$(awk -v ws="$W_START" -v we="$W_END" -v rs="$R_START" -v re="$R_END" \
            '(NR<ws || NR>we) && (NR<rs || NR>re) {print FILENAME":"NR":"$0}' "$f" \
            | grep -E "$FORBIDDEN" | grep -vE '^[^:]+:[0-9]+:\s*#' || true)
    else
        hits=$(grep -nE "$FORBIDDEN" "$f" | grep -vE '^[0-9]+:\s*#' | sed "s|^|$f:|" || true)
    fi
    [[ -n "$hits" ]] && c_viol+="$hits"$'\n'
done
[[ -n "${c_viol//[$'\n ']/}" ]] && echo "$c_viol" | head -8
assert_eq "" "${c_viol//[$'\n ']/}" "C: zero bypass al wrapperelor av_* in src/*.sh"

# ── G. Mentiuni asistent in fisiere user-facing ──────────────────────
g_hits=$(grep -rliE 'claude|anthropic|chatgpt|copilot|openai' \
    "$PROJECT_ROOT/README.md" "$PROJECT_ROOT/docs/av_info.txt" "$PROJECT_ROOT/docs/av_changelog.txt" 2>/dev/null || true)
assert_eq "" "$g_hits" "G: zero mentiuni asistent in README/av_info/av_changelog ($g_hits)"

# ── D. Meta-test pe teste + garda runner ─────────────────────────────
# pattern ancorat la inceput de instructiune (nu match-uieste propriul grep)
d_viol=$(grep -rnE "^[[:space:]]*trap .*EXIT" "$PROJECT_ROOT"/tests/unit/*.sh "$PROJECT_ROOT"/tests/integration/*.sh 2>/dev/null \
    | grep -v '_test_summary' || true)
assert_eq "" "$d_viol" "D: orice trap EXIT din teste contine _test_summary ($d_viol)"
assert_contains "$(cat "$PROJECT_ROOT/tests/run_tests.sh")" "(0 assertions)" "D: run_tests.sh are garda 0-asertiuni"
assert_contains "$(cat "$PROJECT_ROOT/tests/run_tests.ps1")" "(0 assertions)" "D: run_tests.ps1 are garda 0-asertiuni"

# ── H. Fix v69 audit: HEVC-raw → MKV prin pas intermediar MP4 ────────
# (matroska refuza annexb fara PTS pe B-frames → output gol; toate 4 siturile
# de remux post-inject trebuie sa aiba ruta in 2 pasi pe tinta mkv)
assert_contains "$(cat "$SRC/av_hdr_dv_tools.sh")" '_step1=$(av_mktemp_ext mp4)' "H: combine bash are pas intermediar MP4"
assert_contains "$(cat "$SRC/av_common.sh")" '_tl_step1=$(av_mktemp_ext mp4)'   "H: triple-layer bash are pas intermediar MP4"
assert_contains "$(cat "$SRC/av_encode.ps1")" 'hdvstep1_'                       "H: combine PS1 are pas intermediar MP4"
assert_contains "$(cat "$SRC/av_encode.ps1")" 'tlstep1_'                        "H: triple-layer PS1 are pas intermediar MP4"
assert_contains "$(cat "$SRC/av_mux.sh")" '_raw_wrap=$(av_mktemp_ext mp4)'      "H: Mux bash pre-wrap video brut → MP4 pe tinta mkv/webm"
assert_contains "$(cat "$SRC/av_mux.ps1")" 'muxwrap_'                           "H: Mux PS1 pre-wrap video brut → MP4 pe tinta mkv/webm"
true
