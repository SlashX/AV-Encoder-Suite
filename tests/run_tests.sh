#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  run_tests.sh — discover and run test_*.sh files
#  Usage: ./run_tests.sh [pattern]
#    pattern defaults to "test_*.sh"
# ═══════════════════════════════════════════════════════════════

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
RESULTS_DIR="$TESTS_DIR/results"
mkdir -p "$RESULTS_DIR"

# v58: prepend src/ to PATH so tests find local binaries (ffmpeg/ffprobe/exiftool/
# dovi_tool/hdr10plus_tool/av1*) without requiring global install. Backward
# compatible: on Linux/macOS/Termux where src/ has no binaries, falls back to
# system PATH unchanged; on Windows where src/ has .exe builds, integration tests
# run instead of skipping.
export PATH="$PROJECT_ROOT/src:$PATH"

PATTERN="${1:-test_*.sh}"

# Color
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ -n "$(tput colors 2>/dev/null)" ]]; then
    GREEN=$(tput setaf 2); RED=$(tput setaf 1); YELLOW=$(tput setaf 3); DIM=$(tput dim 2>/dev/null || echo ""); RESET=$(tput sgr0)
else
    GREEN=""; RED=""; YELLOW=""; DIM=""; RESET=""
fi

# Discover: tests/test_*.sh + tests/{unit,integration,hw}/test_*.sh
shopt -s nullglob
TESTS=()
for f in "$TESTS_DIR"/$PATTERN; do
    [[ -f "$f" ]] && TESTS+=("$f")
done
for d in unit integration hw; do
    for f in "$TESTS_DIR/$d"/$PATTERN; do
        [[ -f "$f" ]] && TESTS+=("$f")
    done
done
shopt -u nullglob

if [[ ${#TESTS[@]} -eq 0 ]]; then
    echo "${YELLOW}No tests matched pattern: $PATTERN${RESET}"
    exit 0
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  AV Encoder Suite — test runner (bash)"
echo "  ${#TESTS[@]} test(s) discovered (pattern: $PATTERN)"
echo "═══════════════════════════════════════════════════════════════"

passed=0; failed=0; skipped=0
declare -a failed_names=()
start_ts=$(date +%s)

export PROJECT_ROOT TESTS_DIR

for t in "${TESTS[@]}"; do
    name="${t#$TESTS_DIR/}"
    log="$RESULTS_DIR/$(basename "$t" .sh).log"
    bash "$t" > "$log" 2>&1
    rc=$?
    case $rc in
        0)
            echo "  ${GREEN}✓${RESET} $name"
            passed=$((passed+1))
            ;;
        77)
            reason=$(grep '^SKIP ' "$log" | head -1 | sed 's/^SKIP[^—]*— //')
            echo "  ${YELLOW}~${RESET} $name ${DIM}(skip: $reason)${RESET}"
            skipped=$((skipped+1))
            ;;
        *)
            echo "  ${RED}✗${RESET} $name"
            failed=$((failed+1))
            failed_names+=("$name")
            echo "${DIM}    --- output (last 15 lines of $log) ---${RESET}"
            tail -15 "$log" | sed 's/^/    /'
            ;;
    esac
done

end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

echo "═══════════════════════════════════════════════════════════════"
printf "  Total: %d  ${GREEN}Pass: %d${RESET}  ${RED}Fail: %d${RESET}  ${YELLOW}Skip: %d${RESET}  Time: %ds\n" \
    "${#TESTS[@]}" "$passed" "$failed" "$skipped" "$elapsed"
if [[ $failed -gt 0 ]]; then
    echo "  Failed:"
    for n in "${failed_names[@]}"; do echo "    - $n"; done
fi
echo "═══════════════════════════════════════════════════════════════"

[[ $failed -eq 0 ]] || exit 1
exit 0
