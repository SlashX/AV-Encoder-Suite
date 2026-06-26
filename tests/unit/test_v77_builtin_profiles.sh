#!/usr/bin/env bash
# v77 — Test-invariant: profilele built-in (example + DJI Action 6) trebuie sa fie
# la zi cu schema curenta. Prinde drift-ul de tip "APV_PROFILE rot" (cheie veche
# ramasa intr-un profil dupa ce schema a fost reorganizata) SI orice violare de schema.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"

PROFILES_DIR="$SCRIPT_DIR/profiles"

# Lista profilelor livrate cu suita (relative la src/profiles/)
BUILTIN_PROFILES=(
    "example_profile.conf"
    "dji_action6/DJI_Action6_Airsoft_Indoor.conf"
    "dji_action6/DJI_Action6_Airsoft_Outdoor.conf"
    "dji_action6/DJI_Action6_DLogM_Outdoor.conf"
    "dji_action6/DJI_Action6_Moto_Cinematic.conf"
    "dji_action6/DJI_Action6_Moto_Outdoor.conf"
)

for rel in "${BUILTIN_PROFILES[@]}"; do
    pf="$PROFILES_DIR/$rel"
    name="$(basename "$rel")"
    assert_file_exists "$pf" "profil livrat exista: $name"

    if out=$(validate_profile "$pf" 2>&1); then rc=0; else rc=1; fi

    # (1) Rot guard: nicio cheie necunoscuta (warning, dar semnaleaza drift de schema)
    assert_not_contains "$out" "cheie necunoscuta" "fara chei necunoscute in $name"
    # (2) Schema guard: zero violari (return 0)
    assert_eq "0" "$rc" "validate_profile curat pe $name"
done

# Regresie specifica: putregaiul APV_PROFILE reparat in v77 — example foloseste
# noile campuri APV (v65), NU vechiul APV_PROFILE.
example="$PROFILES_DIR/example_profile.conf"
assert_nonzero "$(grep -c '^APV_PIXFMT=' "$example" || true)" "example are APV_PIXFMT (camp v65 nou)"
assert_eq "0" "$(grep -c '^APV_PROFILE=' "$example" || true)" "example NU mai are APV_PROFILE (camp mort)"

# Cheile moarte de burn-in scoase din preset-uri (v77 cleanup)
BURNIN_DIR="$SCRIPT_DIR/burnin_presets"
for dead in HUD_ALTITUDE HUD_HEADING HUD_TEMPERATURE FONT_FAMILY FRAME_W FRAME_H PRESET_DESC; do
    cnt=$(grep -rlE "^${dead}=" "$BURNIN_DIR" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "0" "$cnt" "cheie burn-in moarta scoasa din preset-uri: $dead"
done

# Cheile vii de burn-in raman in cel putin un preset
for live in PRESET_NAME HUD_TIMESTAMP STRIP_FIELDS MAP_SIZE SPEED_UNIT; do
    cnt=$(grep -rlE "^${live}=" "$BURNIN_DIR" 2>/dev/null | wc -l | tr -d ' ')
    assert_nonzero "$cnt" "cheie burn-in vie pastrata: $live"
done

true
