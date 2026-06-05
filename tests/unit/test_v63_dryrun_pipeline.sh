#!/usr/bin/env bash
# v63 — Dry-run pentru pipeline Trim+Concat (paritate bash ↔ PS1).
#   Calea TrimConcat NU primeste DRY_RUN-ul global (launcher il exporta abia pe calea de encode)
#   → prompt de mod la intrarea in pipeline + raport plan pe pass-uri, return inainte de orice ffmpeg/temp.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

TC="$(cat "$SCRIPT_DIR/av_trimconcat.sh")"
ENC_PS1="$(cat "$SCRIPT_DIR/av_encode.ps1")"

# ── 1. bash — prompt mod + respecta env DRY_RUN ──
assert_contains "$TC" 'local DRY_RUN="${DRY_RUN:-0}"'   "bash pipeline: respecta DRY_RUN din env"
assert_contains "$TC" "Mod pipeline:"                   "bash pipeline: prompt mod (executa/dry-run)"
assert_contains "$TC" '_pl_mode" == "2" ]] && DRY_RUN=1' "bash pipeline: opt 2 activeaza dry-run"

# ── 2. bash — guard + raport plan pe pass-uri ──
assert_contains "$TC" 'if [[ "$DRY_RUN" == "1" ]]; then'      "bash pipeline: guard dry-run"
assert_contains "$TC" "DRY-RUN — plan executie"               "bash pipeline: titlu raport plan"
assert_contains "$TC" "Pass 1/3: trim"                        "bash pipeline: breakdown Pass 1"
assert_contains "$TC" "Pass 2/3: concat"                      "bash pipeline: breakdown Pass 2"
assert_contains "$TC" "Pass 3/3"                              "bash pipeline: breakdown Pass 3"

# ── 3. bash — guard-ul returneaza INAINTE de executie (create_temp_subdir pipeline) ──
guard_ln=$(grep -n "DRY-RUN — plan executie" "$SCRIPT_DIR/av_trimconcat.sh" | head -1 | cut -d: -f1)
exec_ln=$(grep -n 'create_temp_subdir "pipeline"' "$SCRIPT_DIR/av_trimconcat.sh" | head -1 | cut -d: -f1)
if [[ -n "$guard_ln" && -n "$exec_ln" ]] && (( guard_ln < exec_ln )); then
    assert_eq "1" "1" "bash pipeline: guard ($guard_ln) inainte de Pass 1 exec ($exec_ln)"
else
    assert_eq "before" "after" "bash pipeline: guard inainte de executie (guard=$guard_ln exec=$exec_ln)"
fi

# ── 4. PS1 paritate — prompt mod + guard + raport ──
assert_contains "$ENC_PS1" '$dryRun = [bool]$dryRun'    "PS1 pipeline: normalizeaza dryRun (calea TC nu are global)"
assert_contains "$ENC_PS1" "Mod pipeline:"              "PS1 pipeline: prompt mod"
assert_contains "$ENC_PS1" 'if ($plMode -eq "2") { $dryRun = $true }' "PS1 pipeline: opt 2 activeaza dry-run"
assert_contains "$ENC_PS1" 'if ($dryRun) {'             "PS1 pipeline: guard dry-run"
assert_contains "$ENC_PS1" "DRY-RUN — plan executie"    "PS1 pipeline: titlu raport plan"
assert_contains "$ENC_PS1" "Pass 3/3:"                  "PS1 pipeline: breakdown Pass 3"

# ── 5. PS1 — guard inainte de executie (New-TempSubdir pipeline) ──
g_ps=$(grep -n "DRY-RUN — plan executie" "$SCRIPT_DIR/av_encode.ps1" | head -1 | cut -d: -f1)
e_ps=$(grep -n 'New-TempSubdir "pipeline"' "$SCRIPT_DIR/av_encode.ps1" | head -1 | cut -d: -f1)
if [[ -n "$g_ps" && -n "$e_ps" ]] && (( g_ps < e_ps )); then
    assert_eq "1" "1" "PS1 pipeline: guard ($g_ps) inainte de Pass 1 exec ($e_ps)"
else
    assert_eq "before" "after" "PS1 pipeline: guard inainte de executie (guard=$g_ps exec=$e_ps)"
fi

true
