#!/usr/bin/env bash
# Test profile_diff.sh — outputul, exit codes, sectiuni.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DIFF_TOOL="$PROJECT_ROOT/src/tools/profile_diff.sh"
assert_file_exists "$DIFF_TOOL" "profile_diff.sh exista"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/a.conf" <<'EOF'
ENCODER_NAME=libx265
CONTAINER=mkv
CRF_PARAM=22
ONLY_IN_A=foo
EOF

cat > "$TMPDIR/b.conf" <<'EOF'
ENCODER_NAME=libx265
CONTAINER=mp4
CRF_PARAM=22
ONLY_IN_B=bar
EOF

# 1) Run, capture output + exit
out=$(bash "$DIFF_TOOL" "$TMPDIR/a.conf" "$TMPDIR/b.conf" 2>&1)
rc=$?
assert_eq "1" "$rc" "exit=1 cand exista diferente"
assert_contains "$out" "ONLY_IN_A" "raporteaza ONLY_IN_A"
assert_contains "$out" "ONLY_IN_B" "raporteaza ONLY_IN_B"
assert_contains "$out" "CONTAINER" "raporteaza CONTAINER diferit"
assert_not_contains "$out" "ENCODER_NAME " "NU raporteaza ENCODER_NAME (egal)"
assert_contains "$out" "Doar in A" "sectiune Doar in A"
assert_contains "$out" "Doar in B" "sectiune Doar in B"
assert_contains "$out" "Valori diferite" "sectiune Valori diferite"

# 2) Profile identice → exit 0
cp "$TMPDIR/a.conf" "$TMPDIR/a2.conf"
out=$(bash "$DIFF_TOOL" "$TMPDIR/a.conf" "$TMPDIR/a2.conf" 2>&1)
rc=$?
assert_eq "0" "$rc" "exit=0 cand identice"
assert_contains "$out" "identice" "raporteaza identice"

# 3) Argumente invalide → exit 2
bash "$DIFF_TOOL" 2>/dev/null
assert_eq "2" "$?" "exit=2 fara args"
bash "$DIFF_TOOL" "$TMPDIR/nope1" "$TMPDIR/nope2" 2>/dev/null
assert_eq "2" "$?" "exit=2 cand fisier inexistent"
