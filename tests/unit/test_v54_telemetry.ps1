# v54 PS1 mirror: telemetry/GPS — FIT enhanced+temp, KML gx:Track, NMEA VTG/GGA,
#   NORM 18->24 (pitch/roll/yaw + fix_quality/num_sats/hdop), GoPro ACCL/GYRO + GPS9,
#   DJI pitch/roll/yaw, GPX native fields, burn-in header-driven brand + render.
. "$PSScriptRoot\..\framework.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$src  = Join-Path $root 'src'

$teleSh = Join-Path $src 'av_telemetry.sh'
$telePs = Join-Path $src 'av_telemetry.ps1'
$gpsSh  = Join-Path $src 'av_extractor_gps.sh'
$gpsPs  = Join-Path $src 'av_extractor_gps.ps1'
$burnSh = Join-Path $src 'av_burnin.sh'
$burnPs = Join-Path $src 'av_burnin.ps1'
$render = Join-Path $src 'burnin_render.py'

foreach ($f in @($teleSh,$telePs,$gpsSh,$gpsPs,$burnSh,$burnPs,$render)) {
    if (-not (Test-Path -LiteralPath $f)) { Skip-Test "lipseste $f" }
}

# ordinal substring helpers (evita glob/regex pe needle cu [ ] , ')
function Assert-Has([string]$Text,[string]$Needle,[string]$Msg="has") {
    if ($Text.Contains($Needle)) { _pass } else { _fail ("{0}: '{1}' not found" -f $Msg,$Needle) }
}
function Assert-HasNot([string]$Text,[string]$Needle,[string]$Msg="hasnot") {
    if (-not $Text.Contains($Needle)) { _pass } else { _fail ("{0}: '{1}' found but should not" -f $Msg,$Needle) }
}

$T  = Get-Content -LiteralPath $teleSh -Raw
$TP = Get-Content -LiteralPath $telePs -Raw
$G  = Get-Content -LiteralPath $gpsSh  -Raw
$GP = Get-Content -LiteralPath $gpsPs  -Raw
$BS = Get-Content -LiteralPath $burnSh -Raw
$BP = Get-Content -LiteralPath $burnPs -Raw
$R  = Get-Content -LiteralPath $render -Raw

# ── 1. Schema NORM 24 coloane ────────────────────────────────────────
$newcols = @('pitch_deg','roll_deg','yaw_deg','fix_quality','num_sats','hdop')
$files = @{ 'av_telemetry.sh'=$T; 'av_telemetry.ps1'=$TP; 'av_extractor_gps.sh'=$G; 'av_extractor_gps.ps1'=$GP }
foreach ($name in $files.Keys) {
    foreach ($c in $newcols) { Assert-Has $files[$name] $c "$name contine coloana $c" }
    Assert-Has $files[$name] 'source_brand' "$name pastreaza source_brand"
}

# QuickTime PS1 norm header — exact 24 coloane, source_brand ultima
$qtLine = ($TP -split "`n" | Where-Object { $_ -match 'timestamp,lat,lon,alt_m' -and $_ -match 'pitch_deg' } | Select-Object -First 1)
$m = [regex]::Match($qtLine, '"([^"]*source_brand)"')
Assert-Eq $true $m.Success "QuickTime PS1 header gasit"
$cols = $m.Groups[1].Value.Split(',')
Assert-Eq 24 $cols.Count "QuickTime PS1 norm header = 24 coloane"
Assert-Eq 'source_brand' $cols[-1] "source_brand este ultima coloana"

# QuickTime PS1 data row — 24 coloane
$qtRow = ($TP -split "`n" | Where-Object { $_ -match '\$ts,\$lat,\$lon,\$alt,,,' } | Select-Object -First 1)
$mr = [regex]::Match($qtRow, '"(\$ts[^"]*quicktime)"')
Assert-Eq $true $mr.Success "QuickTime PS1 data row gasit"
Assert-Eq 24 $mr.Groups[1].Value.Split(',').Count "QuickTime PS1 data row = 24 coloane"

# ── 2. GoPro GPMF — G1 (ACCL/GYRO) + G2 (GPS9) ───────────────────────
foreach ($pair in @(@('av_telemetry.sh',$T), @('av_telemetry.ps1',$TP))) {
    $n = $pair[0]; $b = $pair[1]
    Assert-Has $b '_sensor_3axis_mean' "$n helper ACCL/GYRO mean"
    Assert-Has $b '_gps9_points'       "$n parser GPS9 (Hero11+)"
    Assert-Has $b '_gps5_points'       "$n parser GPS5 refactor"
    Assert-Has $b "'ACCL'"             "$n detecteaza ACCL"
    Assert-Has $b "'GYRO'"             "$n detecteaza GYRO"
    Assert-Has $b "'GPS9'"             "$n detecteaza GPS9"
    Assert-Has $b '9.80665'            "$n ACCL m/s2 -> g"
    Assert-Has $b 'gforce_z'           "$n populeaza gforce"
    Assert-Has $b 'gyro_z'             "$n populeaza gyro"
    Assert-Has $b "if 'GPS9' in fourccs" "$n GPS9 preferat, GPS5 fallback"
}

# ── 3. FIT — B1 temp (field 13) + G3 enhanced (73/78) ────────────────
foreach ($pair in @(@('av_telemetry.sh',$T), @('av_extractor_gps.sh',$G))) {
    $n = $pair[0]; $b = $pair[1]
    Assert-Has $b '78 in'  "$n enhanced_altitude (field 78)"
    Assert-Has $b '73 in'  "$n enhanced_speed (field 73)"
    Assert-Has $b '13 in'  "$n temperature field 13 (corect)"
    Assert-HasNot $b 'field_values[23]' "$n NU mai citeste field 23 ca temp"
}

# ── 4. NMEA — G7 (GGA fix/sats/hdop) + G8 (VTG) ──────────────────────
Assert-Has $T 'GPVTG'       "telemetry: NMEA VTG handler (G8)"
Assert-Has $T 'fix_quality' "telemetry: GGA fix_quality (G7)"
Assert-Has $T 'num_sats'    "telemetry: GGA num_sats (G7)"
Assert-Has $T 'parts[6]'    "telemetry: GGA parts[6]=fix_quality"
Assert-Has $T 'parts[7]'    "telemetry: GGA parts[7]=num_sats"
Assert-Has $T 'parts[8]'    "telemetry: GGA parts[8]=hdop"

# ── 5. DJI — track complet per-sample (protobuf GPS+accel) + viteza/heading ──
foreach ($pair in @(@('av_telemetry.sh',$T), @('av_telemetry.ps1',$TP))) {
    $n = $pair[0]; $b = $pair[1]
    Assert-Has $b 'GPSDateTime,GPSLatitude,GPSLongitude,GPSAltitude' "$n basic CSV per-sample template (track complet)"
    Assert-Has $b 'sampletime'        "$n sampletime sub-secunda per-sample"
    Assert-Has $b 'accelerometerx'    "$n accelerometru DJI -> g-force"
    Assert-Has $b 'gimbalpitchdegree' "$n orientare gimbal optionala in template"
    Assert-Has $b 'hav('              "$n viteza din haversine delta GPS"
    Assert-Has $b 'brg('              "$n heading din bearing GPS"
    Assert-Has $b 'pitch_deg'         "$n scrie pitch_deg in norm DJI"
    Assert-Has $b 'source_brand'      "$n source_brand dji in norm"
}

# ── 6. GPX extern — native sat/hdop/fix/course ───────────────────────
foreach ($pair in @(@('av_extractor_gps.sh',$G), @('av_extractor_gps.ps1',$GP))) {
    $n = $pair[0]; $b = $pair[1]
    Assert-Has $b "'hdop','hdop'"       "$n captureaza <hdop>"
    Assert-Has $b "'sat','num_sats'"    "$n captureaza <sat>"
    Assert-Has $b "'fix','fix_quality'" "$n captureaza <fix>"
    Assert-Has $b "'course','heading'"  "$n captureaza <course>"
}

# ── 7. KML modern — G5 (gx:Track) + G6 (timestamps) + B2 ─────────────
foreach ($pair in @(@('av_extractor_gps.sh',$G), @('av_extractor_gps.ps1',$GP))) {
    $n = $pair[0]; $b = $pair[1]
    Assert-Has $b 'Track' "$n suport gx:Track (G5)"
    Assert-Has $b 'when'  "$n timestamps gx:Track/TimeStamp (G6)"
}
Assert-HasNot $G '<n>' "extractor: fara tag corupt <n> (B2)"

# ── 8. Burn-in — brand extractor header-driven + render noile campuri ─
Assert-Has $BS 'h=="source_brand"' "burnin.sh: brand extractor header-driven"
Assert-Has $BP 'source_brand") { $idx = $i' "burnin.ps1: brand extractor header-driven"
Assert-Has $R  'pitch_deg'   "render: parseaza pitch_deg"
Assert-Has $R  'num_sats'    "render: parseaza num_sats"
Assert-Has $R  '"gforce"'    "render: strip field gforce"
Assert-Has $R  '"satellites"' "render: strip field satellites"

Invoke-TestSummary
