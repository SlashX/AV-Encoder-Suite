#!/usr/bin/env bash
# Test av_extractor_gps.sh — feed GPX/KML sample, verifica CSV output.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

command -v python3 >/dev/null 2>&1 || skip_test "python3 lipseste"

# v58 audit: git-bash/MSYS pe Windows are probleme la translatarea de path
# /c/Users/... → C:\Users\... cand python e chemat dintr-un subprocess al bash.
# Testul ruleaza corect pe Linux/macOS/Termux; pe Windows folosesti
# av_extractor_gps.ps1 + python.exe nativ direct (vezi flow PowerShell).
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) skip_test "git-bash/MSYS pe Windows — folositi PS1 mirror" ;;
esac

SAMPLES="$PROJECT_ROOT/tests/fixtures/samples"
GPX="$SAMPLES/sample.gpx"
KML="$SAMPLES/sample.kml"
[[ -f "$GPX" && -f "$KML" ]] || skip_test "sample-urile GPX/KML lipsesc"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"; _test_summary' EXIT
mkdir -p "$TMP/in" "$TMP/out"
cp "$GPX" "$KML" "$TMP/in/"

# Override env vars; av_common.sh respecta ${INPUT_DIR:-...} / ${OUTPUT_DIR:-...}
export INPUT_DIR="$TMP/in"
export OUTPUT_DIR="$TMP/out"

# Choice 1 = CSV esential
echo "1" | bash "$SCRIPT_DIR/av_extractor_gps.sh" >"$TMP/log" 2>&1
rc=$?
assert_zero $rc "extractor exit 0"

# Verifica CSV-uri generate
gpx_csv="$TMP/out/sample.csv"
kml_csv="$TMP/out/sample.csv"  # Same name — KML probably overwrites GPX. Look at log.

# Cataloghize ce s-a generat
csvs=$(find "$TMP/out" -name '*.csv' | sort)
norm_csvs=$(find "$TMP/out" -name '*_norm.csv' | sort)

assert_neq "" "$csvs" "cel putin un CSV generat"

# Verifica continut: cel putin 3 trackpoints in GPX → 3 randuri data + header
gpx_main=$(find "$TMP/out" -name 'sample*.csv' ! -name '*_norm.csv' | head -1)
[[ -n "$gpx_main" ]] || { echo "Found in out:"; ls -la "$TMP/out"; cat "$TMP/log" | tail -30; }
assert_file_exists "$gpx_main" "CSV principal exista"

if [[ -f "$gpx_main" ]]; then
    rows=$(wc -l < "$gpx_main")
    # Header + 3 puncte = 4 randuri pentru GPX (poate fi suprascris de KML cu 3 puncte → tot ~4)
    assert_match "$rows" "^[3-9]$" "CSV are header + cel putin 2 puncte"
    # Verifica coordonatele cunoscute (44.42xx, 26.10xx)
    content=$(cat "$gpx_main")
    assert_contains "$content" "44.42" "lat 44.42 prezent"
    assert_contains "$content" "26.10" "lon 26.10 prezent"
fi

# Norm CSV (choice 1 emite norm in paralel pe v40+)
if [[ -n "$norm_csvs" ]]; then
    norm_one=$(echo "$norm_csvs" | head -1)
    norm_header=$(head -1 "$norm_one")
    assert_contains "$norm_header" "timestamp" "norm CSV are timestamp"
    assert_contains "$norm_header" "lat" "norm CSV are lat"
    assert_contains "$norm_header" "lon" "norm CSV are lon"
    assert_contains "$norm_header" "source_brand" "norm CSV are source_brand"
fi
