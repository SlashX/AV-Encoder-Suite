#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_extractor_gps.sh — Import GPS extern (GPX/FIT/KML → CSV/SRT/Norm)
# Converteste fisiere GPX, FIT si KML de la orice dispozitiv GPS
# (Garmin, Huawei, Apple Watch, Strava, Komoot, etc.)
# Necesita: python3 (Termux: pkg install python; Linux: apt/dnf/pacman; macOS: brew install python3)
# ══════════════════════════════════════════════════════════════════════

# v41: Source av_common.sh pentru detect_platform + paths cross-platform + wrappere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/av_common.sh"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

# ── Verificare python3 ───────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    echo "EROARE: python3 nu este instalat."
    echo "Instaleaza cu: $(av_pkg_install_hint python3)"
    exit 1
fi

# ── Scanare fisiere GPX/FIT/KML ───────────────────────────────────────
shopt -s nullglob nocaseglob
FILES=("$INPUT_DIR"/*.{gpx,fit,kml})
shopt -u nocaseglob nullglob
TOTAL=${#FILES[@]}

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  GPS EXTRACTOR (GPX/FIT/KML)                 ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  Fisiere gasite : $TOTAL"
echo "║  Input  : $INPUT_DIR"
echo "║  Output : $OUTPUT_DIR"
echo "╠══════════════════════════════════════════════╣"
echo "║  Ce doresti sa extragi?                       ║"
echo "║  1) CSV esential (Lat, Lon, Alt, Speed, Time) ║"
echo "║  2) CSV complet (toate metadatele disponibile) ║"
echo "║  3) Subtitrare SRT (pentru overlay in VLC)     ║"
echo "║  4) Totul (CSV esential + CSV complet + SRT)   ║"
echo "║  5) GPX & KML (conversie intre formate)        ║"
echo "║  6) Anulare                                    ║"
echo "╚══════════════════════════════════════════════╝"
read -p "Alege 1-6 [implicit: 1]: " choice

[[ -z "$choice" ]] && choice=1
[[ "$choice" == "6" ]] && { echo "Anulat."; exit 0; }

if [ "$TOTAL" -eq 0 ]; then
    echo ""
    echo "Nu am gasit fisiere .gpx, .fit sau .kml in $INPUT_DIR"
    echo "Pune fisierele GPS in folderul Input si ruleaza din nou."
    exit 1
fi

# v85 (O5): avertisment la coliziune de stem — output-urile se numesc dupa numele
# fara extensie (traseu.gpx + traseu.kml → ambele scriu traseu_norm.csv etc.) →
# al 2-lea suprascrie tacut output-urile primului. Avertizam inainte de procesare.
declare -A _seen_stems
_collision=""
for _f in "${FILES[@]}"; do
    _bn=$(basename "$_f"); _st="${_bn%.*}"
    if [ -n "${_seen_stems[$_st]:-}" ]; then
        _collision+="  ⚠ '$_st': ${_seen_stems[$_st]} + $_bn → output-urile se suprascriu\n"
    else
        _seen_stems[$_st]="$_bn"
    fi
done
if [ -n "$_collision" ]; then
    echo ""
    echo "ATENTIE: fisiere cu acelasi nume (extensii diferite) — output-uri suprascrise:"
    printf "%b" "$_collision"
    echo "  (redenumeste unul dintre ele daca vrei ambele seturi de output)"
fi

echo ""
echo "═══════════════════════════════════════"
echo "Incep procesarea..."
echo "═══════════════════════════════════════"

DONE=0

for file in "${FILES[@]}"; do
    [ -f "$file" ] || continue
    filename=$(basename "$file")
    name="${filename%.*}"
    ext="${filename##*.}"
    ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    echo ""
    echo "── Fisier $((DONE + 1))/$TOTAL: $filename"

    if [[ "$ext_lower" == "gpx" ]]; then
        # ── GPX Processing (XML) ─────────────────────────────────────
        python3 - "$file" "$name" "$OUTPUT_DIR" "$choice" << 'PYEOF'
import xml.etree.ElementTree as ET
import csv, sys, os, math

# v85 (O4): cai prin sys.argv, NU interpolate in textul heredoc (delimiter 'PYEOF'
# quotat) — robust la ghilimele/backslash in nume + pe git-bash argv primeste
# conversia MSYS de cale (interpolarea in text NU o primea → Python nativ nu gasea /d/...).
file_path = sys.argv[1]
name = sys.argv[2]
output_dir = sys.argv[3]
choice = sys.argv[4]

try:
    tree = ET.parse(file_path)
    root = tree.getroot()
except Exception as e:
    print(f"  [SKIP] GPX invalid sau corupt ({e}) - fisier sarit")
    sys.exit(0)

# Detect namespace
ns = ''
if root.tag.startswith('{'):
    ns = root.tag.split('}')[0] + '}'

# Collect all trackpoints
points = []
for trkpt in root.iter(f'{ns}trkpt'):
    p = {}
    p['lat'] = trkpt.get('lat', '')
    p['lon'] = trkpt.get('lon', '')

    ele = trkpt.find(f'{ns}ele')
    p['alt'] = ele.text.strip() if ele is not None and ele.text else ''

    time_el = trkpt.find(f'{ns}time')
    p['time'] = time_el.text.strip() if time_el is not None and time_el.text else ''

    # Native GPX 1.1 trkpt children: sat / hdop / fix / course
    for tag, key in (('hdop','hdop'),('sat','num_sats'),('fix','fix_quality'),('course','heading')):
        el = trkpt.find(f'{ns}{tag}')
        if el is not None and el.text: p[key] = el.text.strip()

    # Speed (from extensions or calculated)
    p['speed'] = ''
    # Try common extension patterns
    for ext_tag in [f'{ns}extensions', 'extensions']:
        ext_el = trkpt.find(ext_tag)
        if ext_el is not None:
            for child in ext_el.iter():
                tag_name = child.tag.split('}')[-1].lower() if '}' in child.tag else child.tag.lower()
                if 'speed' in tag_name and child.text:
                    p['speed'] = child.text.strip()
                if 'hr' in tag_name or 'heartrate' in tag_name:
                    p['hr'] = child.text.strip() if child.text else ''
                if 'cad' in tag_name or 'cadence' in tag_name:
                    p['cad'] = child.text.strip() if child.text else ''
                if 'power' in tag_name:
                    p['power'] = child.text.strip() if child.text else ''
                if 'temp' in tag_name or 'atemp' in tag_name:
                    p['temp'] = child.text.strip() if child.text else ''
                if ('course' in tag_name or 'heading' in tag_name or 'bearing' in tag_name) and child.text and not p.get('heading'):
                    p['heading'] = child.text.strip()

    points.append(p)

if not points:
    # Try waypoints if no trackpoints
    for wpt in root.iter(f'{ns}wpt'):
        p = {}
        p['lat'] = wpt.get('lat', '')
        p['lon'] = wpt.get('lon', '')
        ele = wpt.find(f'{ns}ele')
        p['alt'] = ele.text.strip() if ele is not None and ele.text else ''
        time_el = wpt.find(f'{ns}time')
        p['time'] = time_el.text.strip() if time_el is not None and time_el.text else ''
        p['speed'] = ''
        points.append(p)

if not points:
    print("  [SKIP] Nu am gasit trackpoints in GPX")
    sys.exit(0)

# Calculate speed between points if not in extensions
for i in range(1, len(points)):
    if not points[i].get('speed') and points[i]['lat'] and points[i-1]['lat']:
        try:
            lat1, lon1 = float(points[i-1]['lat']), float(points[i-1]['lon'])
            lat2, lon2 = float(points[i]['lat']), float(points[i]['lon'])
            dlat = math.radians(lat2 - lat1)
            dlon = math.radians(lon2 - lon1)
            a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon/2)**2
            dist = 6371000 * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))
            if points[i].get('time') and points[i-1].get('time'):
                from datetime import datetime
                fmt_opts = ['%Y-%m-%dT%H:%M:%SZ', '%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%S%z']
                t1 = t2 = None
                for fmt in fmt_opts:
                    try:
                        t1 = datetime.strptime(points[i-1]['time'], fmt)
                        t2 = datetime.strptime(points[i]['time'], fmt)
                        break
                    except:
                        continue
                if t1 and t2:
                    dt = (t2 - t1).total_seconds()
                    if dt > 0:
                        points[i]['speed'] = f"{dist/dt:.2f}"
        except:
            pass

print(f"  Puncte GPS: {len(points)}")

# CSV Essential (choice 1, 4)
if choice in ('1', '4'):
    csv_path = os.path.join(output_dir, f"{name}_gps_basic.csv")
    with open(csv_path, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['Latitude', 'Longitude', 'Altitude(m)', 'Speed(m/s)', 'DateTime'])
        for p in points:
            w.writerow([p['lat'], p['lon'], p['alt'], p.get('speed', ''), p.get('time', '')])
    print(f"  [OK] CSV esential: {name}_gps_basic.csv ({len(points)} puncte)")

# CSV Full (choice 2, 4)
if choice in ('2', '4'):
    # Collect all keys
    all_keys = set()
    for p in points:
        all_keys.update(p.keys())
    all_keys = sorted(all_keys)

    csv_path = os.path.join(output_dir, f"{name}_gps_full.csv")
    with open(csv_path, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(all_keys)
        for p in points:
            w.writerow([p.get(k, '') for k in all_keys])
    print(f"  [OK] CSV complet: {name}_gps_full.csv ({len(all_keys)} coloane)")

# SRT (choice 3, 4)
if choice in ('3', '4'):
    srt_path = os.path.join(output_dir, f"{name}_gps.srt")
    with open(srt_path, 'w') as f:
        for i, p in enumerate(points):
            t = p.get('time', '')
            # v94 (B8): campul Speed se scrie DOAR cand sursa chiar are viteza. Inainte,
            # absenta lui producea "Speed: 0.0 km/h" — se citeste ca viteza masurata zero,
            # ceea ce e fals (GPX/KML fara <speed> nu spun nimic despre viteza).
            speed_val = p.get('speed', '')
            try:
                speed_kmh = f"{float(speed_val) * 3.6:.1f}" if speed_val not in ('', None) else None
            except:
                speed_kmh = None

            # SRT timing — use index as seconds if no proper time parsing
            sec_start = i
            sec_end = i + 1
            h1, m1, s1 = sec_start // 3600, (sec_start % 3600) // 60, sec_start % 60
            h2, m2, s2 = sec_end // 3600, (sec_end % 3600) // 60, sec_end % 60

            _fields = []
            if speed_kmh is not None:
                _fields.append(f"Speed: {speed_kmh} km/h")
            _fields.append(f"Alt: {p.get('alt', 'N/A')}m")

            f.write(f"{i+1}\n")
            f.write(f"{h1:02d}:{m1:02d}:{s1:02d},000 --> {h2:02d}:{m2:02d}:{s2:02d},000\n")
            f.write(" | ".join(_fields) + "\n")
            f.write(f"GPS: {p['lat']}, {p['lon']}\n")
            f.write(f"\n")
    print(f"  [OK] SRT: {name}_gps.srt ({len(points)} entries)")

# CSV Normalizat (schema unificata, choice 1, 2, 4)
if choice in ('1', '2', '4'):
    NORM = ['timestamp','lat','lon','alt_m','speed_mps','speed_kmh','heading_deg',
            'gforce_x','gforce_y','gforce_z','gyro_x','gyro_y','gyro_z',
            'temp_c','hr_bpm','cadence_rpm','power_w',
            'pitch_deg','roll_deg','yaw_deg','fix_quality','num_sats','hdop',
            'source_brand']
    csv_path = os.path.join(output_dir, f"{name}_norm.csv")
    with open(csv_path, 'w', newline='') as f:
        w = csv.writer(f); w.writerow(NORM)
        for p in points:
            sp = p.get('speed','')
            try: skmh = f"{float(sp)*3.6:.2f}" if sp else ''
            except: skmh = ''
            row = {c:'' for c in NORM}
            row['timestamp']    = p.get('time','')
            row['lat']          = p.get('lat','')
            row['lon']          = p.get('lon','')
            row['alt_m']        = p.get('alt','')
            row['speed_mps']    = sp
            row['speed_kmh']    = skmh
            row['heading_deg']  = p.get('heading','')
            row['temp_c']       = p.get('temp','')
            row['hr_bpm']       = p.get('hr','')
            row['cadence_rpm']  = p.get('cad','')
            row['power_w']      = p.get('power','')
            row['fix_quality']  = p.get('fix_quality','')
            row['num_sats']     = p.get('num_sats','')
            row['hdop']         = p.get('hdop','')
            row['source_brand'] = 'external_gpx'
            w.writerow([row[c] for c in NORM])
    print(f"  [OK] CSV Norm: {name}_norm.csv ({len(points)} puncte)")

# KML (choice 5 — GPX → KML conversion)
if choice in ('5',):
    kml_path = os.path.join(output_dir, f"{name}.kml")
    with open(kml_path, 'w') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write('<kml xmlns="http://www.opengis.net/kml/2.2">\n')
        f.write(f'<Document><name>{name}</name>\n')
        f.write('<Style id="track"><LineStyle><color>ff0000ff</color><width>3</width></LineStyle></Style>\n')
        f.write('<Placemark><name>Track</name><styleUrl>#track</styleUrl>\n')
        f.write('<LineString><altitudeMode>absolute</altitudeMode><coordinates>\n')
        for p in points:
            alt = p.get('alt', '0') or '0'
            f.write(f"{p['lon']},{p['lat']},{alt}\n")
        f.write('</coordinates></LineString></Placemark></Document></kml>\n')
    print(f"  [OK] KML: {name}.kml ({len(points)} puncte)")

PYEOF

    elif [[ "$ext_lower" == "fit" ]]; then
        # ── FIT Processing (binary) ──────────────────────────────────
        python3 - "$file" "$name" "$OUTPUT_DIR" "$choice" << 'PYEOF'
import struct, csv, sys, os
from datetime import datetime, timedelta

# v85 (O4): cai prin sys.argv, NU interpolate in textul heredoc (delimiter 'PYEOF'
# quotat) — robust la ghilimele/backslash in nume + pe git-bash argv primeste
# conversia MSYS de cale (interpolarea in text NU o primea → Python nativ nu gasea /d/...).
file_path = sys.argv[1]
name = sys.argv[2]
output_dir = sys.argv[3]
choice = sys.argv[4]

# FIT file parser (minimal — extracts record messages with GPS)
FIT_EPOCH = datetime(1989, 12, 31)

try:
    with open(file_path, 'rb') as f:
        data = f.read()
except Exception as e:
    print(f"  [SKIP] FIT invalid sau corupt ({e}) - fisier sarit")
    sys.exit(0)

# Validate FIT header
if len(data) < 14:
    print("  [EROARE] Fisier FIT prea mic")
    sys.exit(1)

header_size = data[0]
if data[1] != 0x10 and data[1] != 0x20:
    # Protocol version check — be lenient
    pass

# Check ".FIT" signature
sig_offset = header_size - 4 if header_size >= 14 else 8
if data[sig_offset:sig_offset+4] != b'.FIT':
    print("  [EROARE] Nu e fisier FIT valid (lipseste semnatura .FIT)")
    sys.exit(1)

# Parse FIT messages
# We need to find record messages (mesg_num=20) with GPS data
# FIT uses definition + data message pairs

points = []
field_defs = {}  # local_mesg_num -> [(field_def_num, size, base_type), ...]
mesg_nums = {}   # local_mesg_num -> global_mesg_num

pos = header_size

while pos < len(data) - 2:  # -2 for CRC
    try:
        record_header = data[pos]
        pos += 1

        if record_header & 0x40:
            # Definition message
            local_mesg = record_header & 0x0F
            pos += 1  # reserved
            arch = data[pos]; pos += 1  # architecture (0=little, 1=big)
            if arch == 0:
                global_mesg = struct.unpack('<H', data[pos:pos+2])[0]
            else:
                global_mesg = struct.unpack('>H', data[pos:pos+2])[0]
            pos += 2
            num_fields = data[pos]; pos += 1

            fields = []
            for _ in range(num_fields):
                fdn = data[pos]; fs = data[pos+1]; fbt = data[pos+2]
                fields.append((fdn, fs, fbt))
                pos += 3

            field_defs[local_mesg] = (fields, arch)
            mesg_nums[local_mesg] = global_mesg

            # Skip developer fields if present
            if record_header & 0x20:
                num_dev = data[pos]; pos += 1
                pos += num_dev * 3

        elif record_header & 0x80:
            # Compressed timestamp
            local_mesg = (record_header >> 5) & 0x03
            if local_mesg not in field_defs:
                break
            fields, arch = field_defs[local_mesg]
            for fdn, fs, fbt in fields:
                pos += fs

        else:
            # Data message
            local_mesg = record_header & 0x0F
            if local_mesg not in field_defs:
                break

            fields, arch = field_defs[local_mesg]
            global_mesg = mesg_nums.get(local_mesg, 0)

            field_values = {}
            for fdn, fs, fbt in fields:
                raw = data[pos:pos+fs]
                pos += fs

                val = None
                if fs == 1:
                    val = raw[0]
                    if val == 0xFF: val = None
                elif fs == 2:
                    fmt = '<H' if arch == 0 else '>H'
                    val = struct.unpack(fmt, raw)[0]
                    if val == 0xFFFF: val = None
                elif fs == 4:
                    fmt = '<I' if arch == 0 else '>I'
                    val = struct.unpack(fmt, raw)[0]
                    if val == 0xFFFFFFFF: val = None
                    # Also try signed
                    if fbt & 0x1F == 0x85:  # sint32
                        fmt = '<i' if arch == 0 else '>i'
                        val = struct.unpack(fmt, raw)[0]
                        if val == 0x7FFFFFFF: val = None

                if val is not None:
                    field_values[fdn] = val

            # Record message (global_mesg=20) — contains GPS
            if global_mesg == 20:
                p = {}
                # Field definitions for record:
                # 0=lat (semicircles), 1=lon (semicircles), 2=altitude, 6=speed
                # 253=timestamp
                if 0 in field_values and 1 in field_values:
                    lat_sc = field_values[0]
                    lon_sc = field_values[1]
                    # Convert semicircles to degrees
                    # Handle signed values
                    if lat_sc > 0x7FFFFFFF: lat_sc -= 0x100000000
                    if lon_sc > 0x7FFFFFFF: lon_sc -= 0x100000000
                    p['lat'] = f"{lat_sc * (180.0 / 2**31):.8f}"
                    p['lon'] = f"{lon_sc * (180.0 / 2**31):.8f}"

                    # Altitude: prefer enhanced_altitude (78, uint32) over standard (2, uint16)
                    # Formula: (value / 5) - 500 (meters)
                    if 78 in field_values:
                        p['alt'] = f"{(field_values[78] / 5.0) - 500:.1f}"
                    elif 2 in field_values and field_values[2] != 0xFFFF:
                        p['alt'] = f"{(field_values[2] / 5.0) - 500:.1f}"
                    else:
                        p['alt'] = ''

                    # Speed: prefer enhanced_speed (73, uint32) over standard (6, uint16)
                    # Both stored as value / 1000 (m/s)
                    if 73 in field_values:
                        p['speed'] = f"{field_values[73] / 1000.0:.2f}"
                    elif 6 in field_values:
                        p['speed'] = f"{field_values[6] / 1000.0:.2f}"
                    else:
                        p['speed'] = ''

                    if 253 in field_values:
                        ts = FIT_EPOCH + timedelta(seconds=field_values[253])
                        p['time'] = ts.strftime('%Y-%m-%d %H:%M:%S')
                    else:
                        p['time'] = ''

                    # Extra fields (FIT SDK 21.x record message)
                    if 3 in field_values:
                        p['hr'] = str(field_values[3])
                    if 4 in field_values:
                        p['cad'] = str(field_values[4])
                    if 7 in field_values:
                        p['power'] = str(field_values[7])
                    # Field 13 = temperature (sint8, °C). NOT field 23 (= accumulated_power)
                    if 13 in field_values:
                        t = field_values[13]
                        if t > 127: t -= 256  # sign-extend sint8
                        p['temp'] = str(t)

                    # Only add if we have valid coordinates
                    lat_f = float(p['lat'])
                    if -90 <= lat_f <= 90 and lat_f != 0:
                        points.append(p)

    except (struct.error, IndexError):
        break

if not points:
    print("  [SKIP] Nu am gasit date GPS in fisierul FIT")
    sys.exit(0)

print(f"  Puncte GPS: {len(points)}")

# CSV Essential
if choice in ('1', '4'):
    csv_path = os.path.join(output_dir, f"{name}_gps_basic.csv")
    with open(csv_path, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['Latitude', 'Longitude', 'Altitude(m)', 'Speed(m/s)', 'DateTime'])
        for p in points:
            w.writerow([p.get('lat',''), p.get('lon',''), p.get('alt',''), p.get('speed',''), p.get('time','')])
    print(f"  [OK] CSV esential: {name}_gps_basic.csv ({len(points)} puncte)")

# CSV Full
if choice in ('2', '4'):
    all_keys = set()
    for p in points:
        all_keys.update(p.keys())
    all_keys = sorted(all_keys)
    csv_path = os.path.join(output_dir, f"{name}_gps_full.csv")
    with open(csv_path, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(all_keys)
        for p in points:
            w.writerow([p.get(k, '') for k in all_keys])
    print(f"  [OK] CSV complet: {name}_gps_full.csv ({len(all_keys)} coloane)")

# SRT
if choice in ('3', '4'):
    srt_path = os.path.join(output_dir, f"{name}_gps.srt")
    with open(srt_path, 'w') as f:
        for i, p in enumerate(points):
            # v94 (B8): Speed doar cand exista in sursa (vezi nota din parserul GPX)
            speed_val = p.get('speed', '')
            try:
                speed_kmh = f"{float(speed_val) * 3.6:.1f}" if speed_val not in ('', None) else None
            except:
                speed_kmh = None
            sec_start = i
            sec_end = i + 1
            h1, m1, s1 = sec_start // 3600, (sec_start % 3600) // 60, sec_start % 60
            h2, m2, s2 = sec_end // 3600, (sec_end % 3600) // 60, sec_end % 60
            _fields = []
            if speed_kmh is not None:
                _fields.append(f"Speed: {speed_kmh} km/h")
            _fields.append(f"Alt: {p.get('alt', 'N/A')}m")
            f.write(f"{i+1}\n")
            f.write(f"{h1:02d}:{m1:02d}:{s1:02d},000 --> {h2:02d}:{m2:02d}:{s2:02d},000\n")
            f.write(" | ".join(_fields) + "\n")
            f.write(f"GPS: {p['lat']}, {p['lon']}\n")
            hr_str = f" | HR: {p['hr']}bpm" if p.get('hr') else ""
            cad_str = f" | Cad: {p['cad']}rpm" if p.get('cad') else ""
            if hr_str or cad_str:
                f.write(f"{hr_str}{cad_str}\n")
            f.write(f"\n")
    print(f"  [OK] SRT: {name}_gps.srt ({len(points)} entries)")

# CSV Normalizat (schema unificata, choice 1, 2, 4)
if choice in ('1', '2', '4'):
    NORM = ['timestamp','lat','lon','alt_m','speed_mps','speed_kmh','heading_deg',
            'gforce_x','gforce_y','gforce_z','gyro_x','gyro_y','gyro_z',
            'temp_c','hr_bpm','cadence_rpm','power_w',
            'pitch_deg','roll_deg','yaw_deg','fix_quality','num_sats','hdop',
            'source_brand']
    csv_path = os.path.join(output_dir, f"{name}_norm.csv")
    with open(csv_path, 'w', newline='') as f:
        w = csv.writer(f); w.writerow(NORM)
        for p in points:
            sp = p.get('speed','')
            try: skmh = f"{float(sp)*3.6:.2f}" if sp else ''
            except: skmh = ''
            row = {c:'' for c in NORM}
            row['timestamp']    = p.get('time','')
            row['lat']          = p.get('lat','')
            row['lon']          = p.get('lon','')
            row['alt_m']        = p.get('alt','')
            row['speed_mps']    = sp
            row['speed_kmh']    = skmh
            row['temp_c']       = p.get('temp','')
            row['hr_bpm']       = p.get('hr','')
            row['cadence_rpm']  = p.get('cad','')
            row['power_w']      = p.get('power','')
            row['source_brand'] = 'external_fit'
            w.writerow([row[c] for c in NORM])
    print(f"  [OK] CSV Norm: {name}_norm.csv ({len(points)} puncte)")

# KML (choice 5 — FIT → KML conversion)
if choice in ('5',):
    kml_path = os.path.join(output_dir, f"{name}.kml")
    with open(kml_path, 'w') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write('<kml xmlns="http://www.opengis.net/kml/2.2">\n')
        f.write(f'<Document><name>{name}</name>\n')
        f.write('<Style id="track"><LineStyle><color>ff0000ff</color><width>3</width></LineStyle></Style>\n')
        f.write('<Placemark><name>Track</name><styleUrl>#track</styleUrl>\n')
        f.write('<LineString><altitudeMode>absolute</altitudeMode><coordinates>\n')
        for p in points:
            alt = p.get('alt', '0') or '0'
            f.write(f"{p['lon']},{p['lat']},{alt}\n")
        f.write('</coordinates></LineString></Placemark></Document></kml>\n')
    print(f"  [OK] KML: {name}.kml ({len(points)} puncte)")

# GPX output (choice 5 — FIT → GPX conversion)
if choice in ('5',):
    gpx_path = os.path.join(output_dir, f"{name}.gpx")
    with open(gpx_path, 'w') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write('<gpx version="1.1" creator="AV Encoder Suite">\n')
        f.write(f'<trk><name>{name}</name><trkseg>\n')
        for p in points:
            alt = p.get('alt', '0') or '0'
            t = p.get('time', '')
            f.write(f'<trkpt lat="{p["lat"]}" lon="{p["lon"]}"><ele>{alt}</ele>')
            if t:
                f.write(f'<time>{t}</time>')
            f.write('</trkpt>\n')
        f.write('</trkseg></trk></gpx>\n')
    print(f"  [OK] GPX: {name}.gpx ({len(points)} puncte)")

PYEOF

    elif [[ "$ext_lower" == "kml" ]]; then
        # ── KML Processing (XML) ─────────────────────────────────────
        python3 - "$file" "$name" "$OUTPUT_DIR" "$choice" << 'PYEOF'
import xml.etree.ElementTree as ET
import csv, sys, os

# v85 (O4): cai prin sys.argv, NU interpolate in textul heredoc (delimiter 'PYEOF'
# quotat) — robust la ghilimele/backslash in nume + pe git-bash argv primeste
# conversia MSYS de cale (interpolarea in text NU o primea → Python nativ nu gasea /d/...).
file_path = sys.argv[1]
name = sys.argv[2]
output_dir = sys.argv[3]
choice = sys.argv[4]

try:
    tree = ET.parse(file_path)
    root = tree.getroot()
except Exception as e:
    print(f"  [SKIP] KML invalid sau corupt ({e}) - fisier sarit")
    sys.exit(0)

ns = ''
if root.tag.startswith('{'):
    ns = root.tag.split('}')[0] + '}'

import re
points = []

# Strategy 1: <gx:Track> (Google Earth gx extension) — used by Strava, Garmin Connect modern exports
# Format: alternating <when> + <gx:coord>"lon lat alt"</gx:coord> children
for elem in root.iter():
    tag = elem.tag.split('}')[-1] if '}' in elem.tag else elem.tag
    if tag == 'Track':  # gx:Track
        times = []
        coords = []
        for child in elem:
            ctag = child.tag.split('}')[-1] if '}' in child.tag else child.tag
            if ctag == 'when':
                times.append((child.text or '').strip())
            elif ctag == 'coord':
                coords.append((child.text or '').strip())
        n = min(len(times), len(coords))
        for i in range(n):
            parts = coords[i].split()  # space-separated in gx:Track
            if len(parts) >= 2:
                p = {'lon': parts[0], 'lat': parts[1]}
                p['alt'] = parts[2] if len(parts) >= 3 else ''
                p['time'] = times[i]
                p['speed'] = ''
                points.append(p)

# Strategy 2: classic <coordinates> (LineString/Point) — fallback if no gx:Track found
if not points:
    coords_elements = list(root.iter(f'{ns}coordinates'))
    if ns:
        coords_elements += list(root.iter('coordinates'))
    for coords_el in coords_elements:
        if coords_el.text:
            tokens = re.split(r'[\s]+', coords_el.text.strip())
            # Try to find paired <TimeStamp><when> in same Placemark ancestor
            ts_text = ''
            parent = coords_el
            for _ in range(6):  # walk up max 6 levels
                parent_map = {c: p for p in root.iter() for c in p}
                parent = parent_map.get(parent)
                if parent is None: break
                ptag = parent.tag.split('}')[-1] if '}' in parent.tag else parent.tag
                if ptag == 'Placemark':
                    for ts in parent.iter():
                        tstag = ts.tag.split('}')[-1] if '}' in ts.tag else ts.tag
                        if tstag == 'when':
                            ts_text = (ts.text or '').strip()
                            break
                    break
            for token in tokens:
                token = token.strip()
                if not token:
                    continue
                parts = token.split(',')
                if len(parts) >= 2:
                    p = {'lon': parts[0].strip(), 'lat': parts[1].strip()}
                    p['alt'] = parts[2].strip() if len(parts) >= 3 else ''
                    p['speed'] = ''
                    p['time'] = ts_text  # single-point Placemark gets its TimeStamp
                    points.append(p)

if not points:
    print("  [SKIP] Nu am gasit coordonate in KML")
    sys.exit(0)

print(f"  Puncte GPS: {len(points)}")

# CSV Essential (choice 1, 4)
if choice in ('1', '4'):
    csv_path = os.path.join(output_dir, f"{name}_gps_basic.csv")
    with open(csv_path, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['Latitude', 'Longitude', 'Altitude(m)', 'Speed(m/s)', 'DateTime'])
        for p in points:
            w.writerow([p['lat'], p['lon'], p.get('alt', ''), p.get('speed', ''), p.get('time', '')])
    print(f"  [OK] CSV esential: {name}_gps_basic.csv ({len(points)} puncte)")

# CSV Full (choice 2, 4)
if choice in ('2', '4'):
    all_keys = sorted(set(k for p in points for k in p.keys()))
    csv_path = os.path.join(output_dir, f"{name}_gps_full.csv")
    with open(csv_path, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(all_keys)
        for p in points:
            w.writerow([p.get(k, '') for k in all_keys])
    print(f"  [OK] CSV complet: {name}_gps_full.csv ({len(all_keys)} coloane)")

# SRT (choice 3, 4)
if choice in ('3', '4'):
    srt_path = os.path.join(output_dir, f"{name}_gps.srt")
    with open(srt_path, 'w') as f:
        for i, p in enumerate(points):
            sec_start = i
            sec_end = i + 1
            h1, m1, s1 = sec_start // 3600, (sec_start % 3600) // 60, sec_start % 60
            h2, m2, s2 = sec_end // 3600, (sec_end % 3600) // 60, sec_end % 60
            f.write(f"{i+1}\n")
            f.write(f"{h1:02d}:{m1:02d}:{s1:02d},000 --> {h2:02d}:{m2:02d}:{s2:02d},000\n")
            # v94 (B8): KML nu are camp de viteza, dar daca parserul il populeaza candva,
            # forma e identica cu GPX/FIT (Speed doar cand exista) → paritate cu PS1.
            _kml_speed = p.get('speed', '')
            try:
                _kml_kmh = f"{float(_kml_speed) * 3.6:.1f}" if _kml_speed not in ('', None) else None
            except:
                _kml_kmh = None
            _fields = []
            if _kml_kmh is not None:
                _fields.append(f"Speed: {_kml_kmh} km/h")
            _fields.append(f"Alt: {p.get('alt', 'N/A')}m")
            f.write(" | ".join(_fields) + "\n")
            f.write(f"GPS: {p['lat']}, {p['lon']}\n\n")
    print(f"  [OK] SRT: {name}_gps.srt ({len(points)} entries)")

# CSV Normalizat (schema unificata, choice 1, 2, 4)
if choice in ('1', '2', '4'):
    NORM = ['timestamp','lat','lon','alt_m','speed_mps','speed_kmh','heading_deg',
            'gforce_x','gforce_y','gforce_z','gyro_x','gyro_y','gyro_z',
            'temp_c','hr_bpm','cadence_rpm','power_w',
            'pitch_deg','roll_deg','yaw_deg','fix_quality','num_sats','hdop',
            'source_brand']
    csv_path = os.path.join(output_dir, f"{name}_norm.csv")
    with open(csv_path, 'w', newline='') as f:
        w = csv.writer(f); w.writerow(NORM)
        for p in points:
            sp = p.get('speed','')
            try: skmh = f"{float(sp)*3.6:.2f}" if sp else ''
            except: skmh = ''
            row = {c:'' for c in NORM}
            row['timestamp']    = p.get('time','')
            row['lat']          = p.get('lat','')
            row['lon']          = p.get('lon','')
            row['alt_m']        = p.get('alt','')
            row['speed_mps']    = sp
            row['speed_kmh']    = skmh
            row['source_brand'] = 'external_kml'
            w.writerow([row[c] for c in NORM])
    print(f"  [OK] CSV Norm: {name}_norm.csv ({len(points)} puncte)")

# GPX output (choice 5 — KML → GPX conversion)
if choice in ('5',):
    gpx_path = os.path.join(output_dir, f"{name}.gpx")
    with open(gpx_path, 'w') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write('<gpx version="1.1" creator="AV Encoder Suite">\n')
        f.write(f'<trk><name>{name}</name><trkseg>\n')
        for p in points:
            alt = p.get('alt', '0') or '0'
            f.write(f'<trkpt lat="{p["lat"]}" lon="{p["lon"]}"><ele>{alt}</ele></trkpt>\n')
        f.write('</trkseg></trk></gpx>\n')
    print(f"  [OK] GPX: {name}.gpx ({len(points)} puncte)")

PYEOF

    else
        echo "  [SKIP] Format necunoscut: .$ext_lower"
    fi

    DONE=$((DONE + 1))
done

echo ""
echo "═══════════════════════════════════════"
echo "FINALIZAT — $DONE fisiere procesate"
echo "Output: $OUTPUT_DIR"
echo "═══════════════════════════════════════"
