#!/usr/bin/env bash
# Test profile_schema_get — recunoaste cheile, returneaza tipul corect, gestioneaza necunoscute.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"

# Enum lookup
schema=$(profile_schema_get "ENCODER_NAME")
assert_eq "enum:libx265,libx264,av1,dnxhr,prores,apv,hwenc" "$schema" "ENCODER_NAME enum"

# Regex lookup
schema=$(profile_schema_get "CRF_PARAM")
assert_match "$schema" "^regex:" "CRF_PARAM is regex"
assert_contains "$schema" "[0-9]" "CRF_PARAM regex contains digits class"

# HW backend enum (allows empty)
schema=$(profile_schema_get "HW_BACKEND")
assert_contains "$schema" "nvenc" "HW_BACKEND knows nvenc"
assert_contains "$schema" "videotoolbox" "HW_BACKEND knows videotoolbox"
assert_contains "$schema" "mediacodec" "HW_BACKEND knows mediacodec"

# EXTENDS path
schema=$(profile_schema_get "EXTENDS")
assert_eq "path:" "$schema" "EXTENDS is path"

# Unknown returns empty
schema=$(profile_schema_get "TOTALLY_BOGUS_KEY_XYZ")
assert_eq "" "$schema" "unknown key returns empty"

# Container enum
schema=$(profile_schema_get "CONTAINER")
assert_contains "$schema" "mkv" "CONTAINER knows mkv"
assert_contains "$schema" "mp4" "CONTAINER knows mp4"
assert_contains "$schema" "mxf" "CONTAINER knows mxf"
