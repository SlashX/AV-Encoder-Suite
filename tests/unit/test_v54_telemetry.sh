#!/usr/bin/env bash
# v54: telemetry/GPS — FIT enhanced+temp fix, KML gx:Track, NMEA VTG/GGA,
#      NORM schema 18→24 (pitch/roll/yaw + fix_quality/num_sats/hdop),
#      GoPro ACCL/GYRO (G1) + GPS9 (G2), DJI pitch/roll/yaw (G4), GPX native fields.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"

TELE_SH="$SRC/av_telemetry.sh"
TELE_PS="$SRC/av_telemetry.ps1"
GPS_SH="$SRC/av_extractor_gps.sh"
GPS_PS="$SRC/av_extractor_gps.ps1"
BURN_SH="$SRC/av_burnin.sh"
BURN_PS="$SRC/av_burnin.ps1"
RENDER="$SRC/burnin_render.py"

for f in "$TELE_SH" "$TELE_PS" "$GPS_SH" "$GPS_PS" "$BURN_SH" "$BURN_PS" "$RENDER"; do
    [[ -f "$f" ]] || skip_test "lipseste $f"
done

# helper: numara coloanele intr-o linie CSV header data-flat
csv_cols() { awk -F',' '{print NF; exit}' <<<"$1"; }

# ══════════════════════════════════════════════════════════════════════
# 1. Schema NORM 24 coloane — noile campuri prezente in toate fisierele
# ══════════════════════════════════════════════════════════════════════
NEWCOLS="pitch_deg roll_deg yaw_deg fix_quality num_sats hdop"
for f in "$TELE_SH" "$TELE_PS" "$GPS_SH" "$GPS_PS"; do
    base=$(basename "$f")
    for col in $NEWCOLS; do
        assert_match "$(grep -c "$col" "$f")" "^[1-9][0-9]*$" "$base contine coloana $col"
    done
    assert_contains "$(cat "$f")" "source_brand" "$base pastreaza source_brand"
done

# QuickTime header (bash) — exact 24 coloane, source_brand ultima
QT_HDR=$(grep -m1 'timestamp,lat,lon,alt_m,speed_mps,speed_kmh,heading_deg' "$TELE_SH" | grep 'pitch_deg' | head -1)
QT_HDR=$(sed -E 's/^[^"]*"//; s/".*$//' <<<"$QT_HDR")
assert_eq "24" "$(csv_cols "$QT_HDR")" "QuickTime norm header = 24 coloane"
assert_match "$QT_HDR" "source_brand\$" "source_brand este ultima coloana"

# QuickTime data row (bash) — exact 24 coloane
QT_ROW=$(grep -m1 '\$ts,\$lat,\$lon,\$alt,,,,' "$TELE_SH")
QT_ROW=$(sed -E 's/^[^"]*"//; s/".*$//' <<<"$QT_ROW")
assert_eq "24" "$(csv_cols "$QT_ROW")" "QuickTime norm data row = 24 coloane"

# ══════════════════════════════════════════════════════════════════════
# 2. GoPro GPMF — G1 (ACCL/GYRO) + G2 (GPS9) markers, bash + PS1
# ══════════════════════════════════════════════════════════════════════
for f in "$TELE_SH" "$TELE_PS"; do
    base=$(basename "$f")
    body=$(cat "$f")
    assert_contains "$body" "_sensor_3axis_mean" "$base: helper ACCL/GYRO mean"
    assert_contains "$body" "_gps9_points"       "$base: parser GPS9 (Hero11+)"
    assert_contains "$body" "_gps5_points"       "$base: parser GPS5 refactor"
    assert_contains "$body" "'ACCL'"             "$base: detecteaza ACCL"
    assert_contains "$body" "'GYRO'"             "$base: detecteaza GYRO"
    assert_contains "$body" "'GPS9'"             "$base: detecteaza GPS9"
    assert_contains "$body" "9.80665"            "$base: ACCL m/s2 -> g"
    assert_contains "$body" "gforce_z"           "$base: populeaza gforce"
    assert_contains "$body" "gyro_z"             "$base: populeaza gyro"
    # GPS9 fallback la GPS5
    assert_contains "$body" "if 'GPS9' in fourccs" "$base: GPS9 preferat, GPS5 fallback"
done

# ══════════════════════════════════════════════════════════════════════
# 3. FIT (Garmin) — B1 temp fix (field 13, NU 23) + G3 enhanced fields
# ══════════════════════════════════════════════════════════════════════
for f in "$TELE_SH" "$GPS_SH"; do
    base=$(basename "$f")
    body=$(cat "$f")
    assert_contains "$body" "78 in"   "$base: enhanced_altitude (field 78)"
    assert_contains "$body" "73 in"   "$base: enhanced_speed (field 73)"
    assert_contains "$body" "13 in"   "$base: temperature field 13 (corect)"
    # nu mai folosim field 23 (accumulated_power) ca temperatura
    assert_not_contains "$body" "field_values[23]" "$base: NU mai citeste field 23 ca temp"
done

# ══════════════════════════════════════════════════════════════════════
# 4. NMEA (Sony) — G7 (GGA fix_quality/num_sats/hdop) + G8 (VTG)
# ══════════════════════════════════════════════════════════════════════
TELE_BODY=$(cat "$TELE_SH")
assert_contains "$TELE_BODY" "GPVTG" "telemetry: NMEA VTG handler (G8)"
assert_contains "$TELE_BODY" "fix_quality" "telemetry: GGA fix_quality (G7)"
assert_contains "$TELE_BODY" "num_sats"    "telemetry: GGA num_sats (G7)"
# fix_quality din parts[6], num_sats parts[7], hdop parts[8]
assert_contains "$TELE_BODY" "parts[6]" "telemetry: GGA parts[6]=fix_quality"
assert_contains "$TELE_BODY" "parts[7]" "telemetry: GGA parts[7]=num_sats"
assert_contains "$TELE_BODY" "parts[8]" "telemetry: GGA parts[8]=hdop"

# ══════════════════════════════════════════════════════════════════════
# 5. DJI — track complet per-sample (protobuf GPS+accel) + viteza/heading
#    calculate din delta GPS; orientare optionala (bash + PS1)
# ══════════════════════════════════════════════════════════════════════
for f in "$TELE_SH" "$TELE_PS"; do
    base=$(basename "$f")
    body=$(cat "$f")
    # Extractie per-sample prin -p template (NU -csv care colapseaza la 1 rand)
    assert_contains "$body" "GPSDateTime,GPSLatitude,GPSLongitude,GPSAltitude" "$base: basic CSV per-sample template (track complet)"
    assert_contains "$body" "sampletime" "$base: sampletime sub-secunda per-sample"
    assert_contains "$body" "accelerometerx" "$base: accelerometru DJI -> g-force"
    assert_contains "$body" "gimbalpitchdegree" "$base: orientare gimbal optionala in template"
    # Viteza + heading derivate din delta GPS (Action 6 nu are GPSSpeed/GPSTrack)
    assert_contains "$body" "hav(" "$base: viteza din haversine delta GPS"
    assert_contains "$body" "brg(" "$base: heading din bearing GPS"
    assert_contains "$body" "pitch_deg" "$base: scrie pitch_deg in norm DJI"
    assert_contains "$body" "source_brand" "$base: source_brand dji in norm"
done

# ══════════════════════════════════════════════════════════════════════
# 6. GPX extern — native trkpt sat/hdop/fix/course (bash + PS1)
# ══════════════════════════════════════════════════════════════════════
for f in "$GPS_SH" "$GPS_PS"; do
    base=$(basename "$f")
    body=$(cat "$f")
    assert_contains "$body" "'hdop','hdop'" "$base: captureaza <hdop>"
    assert_contains "$body" "'sat','num_sats'" "$base: captureaza <sat>"
    assert_contains "$body" "'fix','fix_quality'" "$base: captureaza <fix>"
    assert_contains "$body" "'course','heading'" "$base: captureaza <course>"
done

# ══════════════════════════════════════════════════════════════════════
# 7. KML modern — G5 (gx:Track) + G6 (timestamps) markers
# ══════════════════════════════════════════════════════════════════════
for f in "$GPS_SH" "$GPS_PS"; do
    base=$(basename "$f")
    body=$(cat "$f")
    assert_contains "$body" "Track" "$base: suport gx:Track (G5)"
    assert_contains "$body" "when"  "$base: timestamps gx:Track/TimeStamp (G6)"
done

# B2: tag-ul corect <name> (NU <n>) in generatorul KML/GPX bash
GPS_BODY=$(cat "$GPS_SH")
assert_not_contains "$GPS_BODY" "<n>" "extractor: fara tag corupt <n> (B2)"

# ══════════════════════════════════════════════════════════════════════
# 8. Burn-in — brand extractor header-driven + render noile campuri
# ══════════════════════════════════════════════════════════════════════
assert_contains "$(cat "$BURN_SH")" 'h=="source_brand"' "burnin.sh: brand extractor header-driven"
assert_contains "$(cat "$BURN_PS")" 'source_brand") { $idx = $i' "burnin.ps1: brand extractor header-driven"
RENDER_BODY=$(cat "$RENDER")
assert_contains "$RENDER_BODY" "pitch_deg" "render: parseaza pitch_deg"
assert_contains "$RENDER_BODY" "num_sats"  "render: parseaza num_sats"
assert_contains "$RENDER_BODY" '"gforce"'  "render: strip field gforce"
assert_contains "$RENDER_BODY" '"satellites"' "render: strip field satellites"
