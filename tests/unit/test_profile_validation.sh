#!/usr/bin/env bash
# Test validate_profile — accepta profile valide, respinge enum/regex invalid, ignora cheia necunoscuta.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"; _test_summary' EXIT

# 1) Profil valid
cat > "$TMPDIR/valid.conf" <<'EOF'
ENCODER_NAME=libx265
CONTAINER=mkv
CRF_PARAM=22
PRESET_PARAM=slow
AUDIO_NORMALIZE=0
EOF
validate_profile "$TMPDIR/valid.conf" 2>/dev/null
assert_zero $? "profil valid trece validarea"

# 2) Enum invalid (CONTAINER=avi nu e in lista)
cat > "$TMPDIR/bad_enum.conf" <<'EOF'
ENCODER_NAME=libx265
CONTAINER=avi
EOF
validate_profile "$TMPDIR/bad_enum.conf" 2>/dev/null
assert_nonzero $? "enum invalid esueaza"

# 3) Regex invalid (CRF_PARAM nu e numar)
cat > "$TMPDIR/bad_regex.conf" <<'EOF'
ENCODER_NAME=libx265
CRF_PARAM=abc
EOF
validate_profile "$TMPDIR/bad_regex.conf" 2>/dev/null
assert_nonzero $? "regex invalid esueaza"

# 4) Cheie necunoscuta — warning, NU error
cat > "$TMPDIR/unknown.conf" <<'EOF'
ENCODER_NAME=libx265
SOME_FUTURE_FIELD=value
EOF
validate_profile "$TMPDIR/unknown.conf" 2>/dev/null
assert_zero $? "cheie necunoscuta nu blocheaza validarea"

# 5) Comentarii + linii goale ignorate
cat > "$TMPDIR/comments.conf" <<'EOF'
# Comentariu top
ENCODER_NAME=libx265

# linie blank de mai sus
CONTAINER=mkv
EOF
validate_profile "$TMPDIR/comments.conf" 2>/dev/null
assert_zero $? "comentarii + blank ignorate"

# 6) Profil inexistent
validate_profile "$TMPDIR/nope.conf" 2>/dev/null
assert_nonzero $? "fisier inexistent esueaza"

# 7) Built-in profiles trebuie sa fie valide
shopt -s nullglob
for p in "$SCRIPT_DIR"/profiles/*/*.conf "$SCRIPT_DIR"/profiles/*.conf; do
    [[ -f "$p" ]] || continue
    validate_profile "$p" >/dev/null 2>&1
    assert_zero $? "built-in $(basename "$p" .conf)"
done
shopt -u nullglob
