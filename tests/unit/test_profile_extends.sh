#!/usr/bin/env bash
# Test EXTENDS chain — root→leaf, override semantics, cycle, missing parent, depth limit.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Override USER_PROFILES_DIR + PROFILES_DIR pentru izolare
USER_PROFILES_DIR="$TMPDIR/user"
PROFILES_DIR="$TMPDIR/builtin"
mkdir -p "$USER_PROFILES_DIR" "$PROFILES_DIR/cat1"

# Profile-ul root in builtin/cat1/
cat > "$PROFILES_DIR/cat1/base.conf" <<'EOF'
ENCODER_NAME=libx265
CONTAINER=mkv
CRF_PARAM=22
PRESET_PARAM=slow
EOF

# Child in user dir, refera builtin (nume scurt)
cat > "$USER_PROFILES_DIR/child.conf" <<'EOF'
EXTENDS=base
CRF_PARAM=18
EOF

# Grandchild in user dir, refera child (sibling)
cat > "$USER_PROFILES_DIR/grand.conf" <<'EOF'
EXTENDS=child
PRESET_PARAM=veryslow
EOF

# 1) Lant 3 niveluri
chain=$(build_extends_chain "$USER_PROFILES_DIR/grand.conf" 2>/dev/null)
assert_zero $? "build_extends_chain reuseste pentru grand"
# Chain trebuie sa fie root, child, grand (3 linii)
line_count=$(echo "$chain" | wc -l)
assert_eq "3" "$line_count" "chain are 3 niveluri"
# Prima linie = root
first=$(echo "$chain" | head -1)
assert_contains "$first" "base.conf" "root e base.conf"
# Ultima linie = leaf
last=$(echo "$chain" | tail -1)
assert_contains "$last" "grand.conf" "leaf e grand.conf"

# 2) Override semantics — load + check override propagation
unset ENCODER_NAME CONTAINER CRF_PARAM PRESET_PARAM
load_profile_validated "$USER_PROFILES_DIR/grand.conf" >/dev/null 2>&1
assert_zero $? "load reuseste"
assert_eq "libx265" "$ENCODER_NAME" "ENCODER_NAME mostenit din root"
assert_eq "mkv" "$CONTAINER" "CONTAINER mostenit din root"
assert_eq "18" "$CRF_PARAM" "CRF_PARAM override din child"
assert_eq "veryslow" "$PRESET_PARAM" "PRESET_PARAM override din grandchild"

# 3) Cycle detection
cat > "$USER_PROFILES_DIR/cycA.conf" <<'EOF'
EXTENDS=cycB
EOF
cat > "$USER_PROFILES_DIR/cycB.conf" <<'EOF'
EXTENDS=cycA
EOF
build_extends_chain "$USER_PROFILES_DIR/cycA.conf" >/dev/null 2>&1
assert_nonzero $? "cycle detectat"

# 4) Missing parent
cat > "$USER_PROFILES_DIR/orphan.conf" <<'EOF'
EXTENDS=does_not_exist_anywhere
EOF
build_extends_chain "$USER_PROFILES_DIR/orphan.conf" >/dev/null 2>&1
assert_nonzero $? "missing parent detectat"

# 5) Profil fara EXTENDS — chain de 1 element
chain=$(build_extends_chain "$PROFILES_DIR/cat1/base.conf")
line_count=$(echo "$chain" | wc -l)
assert_eq "1" "$line_count" "fara EXTENDS → chain 1 element"

# 6) Depth limit (>5 niveluri)
for i in 1 2 3 4 5 6; do
    if [[ $i -eq 1 ]]; then
        echo "ENCODER_NAME=libx265" > "$USER_PROFILES_DIR/d$i.conf"
    else
        prev=$((i-1))
        echo "EXTENDS=d$prev" > "$USER_PROFILES_DIR/d$i.conf"
    fi
done
build_extends_chain "$USER_PROFILES_DIR/d6.conf" >/dev/null 2>&1
assert_nonzero $? "depth limit 5 enforced"

# 7) Leaf inexistent — eroare clara, nu crash
build_extends_chain "$USER_PROFILES_DIR/inexistent.conf" >/dev/null 2>&1
assert_nonzero $? "leaf inexistent detectat"
build_extends_chain "" >/dev/null 2>&1
assert_nonzero $? "leaf gol detectat"

# 8) Cycle prin path duplicat (ex: dir/. vs dir) — canonicalization
cat > "$USER_PROFILES_DIR/dupA.conf" <<EOF
EXTENDS=$USER_PROFILES_DIR/./dupA.conf
EOF
build_extends_chain "$USER_PROFILES_DIR/dupA.conf" >/dev/null 2>&1
assert_nonzero $? "cycle via './' duplicate path detectat (canonicalized)"

# 9) Non-interactive guard — load_profile_validated cu erori
cat > "$USER_PROFILES_DIR/bad.conf" <<'EOF'
ENCODER_NAME=invalid_codec_xyz
EOF
# AV_NONINTERACTIVE=1 → return 1 fara prompt
unset ENCODER_NAME
AV_NONINTERACTIVE=1 load_profile_validated "$USER_PROFILES_DIR/bad.conf" </dev/null >/dev/null 2>&1
assert_nonzero $? "non-interactive guard: erori → abort fara prompt"
