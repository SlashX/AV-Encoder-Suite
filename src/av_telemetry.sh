#!/data/data/com.termux/files/usr/bin/bash
# ══════════════════════════════════════════════════════════════════════
# av_telemetry.sh — Extractor unificat de telemetrie din fisiere video
# v40: Suport DJI + GoPro (GPMF). Sony/Garmin VIRB/QuickTime — chunk-uri ulterioare.
# Necesita: exiftool (DJI/QT), ffmpeg, python3 (GoPro GPMF parser)
# ══════════════════════════════════════════════════════════════════════

INPUT_DIR="/storage/emulated/0/Media/InputVideos"
OUTPUT_DIR="/storage/emulated/0/Media/OutputVideos"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

# ── Detect brand per fisier (codec_tag scan) ─────────────────────────
detect_brand() {
    local file="$1"
    local tags
    tags=$(ffprobe -v error -show_entries stream=codec_tag_string,codec_name -of csv=p=0 "$file" 2>/dev/null)
    if   echo "$tags" | grep -qiE "djmd|dbgi"; then echo "dji"
    elif echo "$tags" | grep -qi  "gpmd";       then echo "gopro"
    elif echo "$tags" | grep -qi  "fdsc";       then echo "garmin"
    elif echo "$tags" | grep -qiE "nmea|sony";  then echo "sony"
    else
        # Fallback: ISO 6709 single-point GPS (Apple/Samsung/Android stock)
        if command -v exiftool &>/dev/null; then
            local loc
            loc=$(exiftool -s3 -api LargeFileSupport=1 -GPSLatitude "$file" 2>/dev/null)
            if [[ -n "$loc" ]]; then echo "quicktime"; return; fi
        fi
        echo "unknown"
    fi
}

# Index track-ului telemetry (gpmd / djmd) — pentru ffmpeg -map
detect_telemetry_track_idx() {
    local file="$1"; local target_tag="$2"
    local idx=0
    while IFS= read -r tag; do
        if echo "$tag" | grep -qi "$target_tag"; then
            echo "$idx"; return 0
        fi
        idx=$((idx + 1))
    done < <(ffprobe -v error -show_entries stream=codec_tag_string,codec_name -of csv=p=0 "$file" 2>/dev/null)
    return 1
}

# ── Scanare fisiere ──────────────────────────────────────────────────
shopt -s nullglob nocaseglob
FILES=("$INPUT_DIR"/*.{mp4,mov,mkv,m2ts,mts,vob,mxf,apv,360,lrv})
shopt -u nocaseglob nullglob
TOTAL=${#FILES[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo "Nu am gasit fisiere video in $INPUT_DIR"
    exit 1
fi

# ── Pre-scan: clasificare brand per fisier ───────────────────────────
echo ""
echo "Scanare brand telemetrie..."
declare -a BRANDS
DJI_COUNT=0; GOPRO_COUNT=0; SONY_COUNT=0; GARMIN_COUNT=0; QT_COUNT=0; UNKNOWN_COUNT=0
for ((i=0; i<TOTAL; i++)); do
    b=$(detect_brand "${FILES[$i]}")
    BRANDS[$i]="$b"
    case "$b" in
        dji)       DJI_COUNT=$((DJI_COUNT+1)) ;;
        gopro)     GOPRO_COUNT=$((GOPRO_COUNT+1)) ;;
        sony)      SONY_COUNT=$((SONY_COUNT+1)) ;;
        garmin)    GARMIN_COUNT=$((GARMIN_COUNT+1)) ;;
        quicktime) QT_COUNT=$((QT_COUNT+1)) ;;
        unknown)   UNKNOWN_COUNT=$((UNKNOWN_COUNT+1)) ;;
    esac
done

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  TELEMETRY EXTRACTOR                         ║"
echo "║  (DJI / GoPro / Sony / Garmin VIRB / QT)     ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  Total : $TOTAL  | DJI: $DJI_COUNT  GoPro: $GOPRO_COUNT  Sony: $SONY_COUNT"
echo "║  Garmin: $GARMIN_COUNT  QuickTime: $QT_COUNT  ?: $UNKNOWN_COUNT"
echo "║  Input   : $INPUT_DIR"
echo "║  Output  : $OUTPUT_DIR"
echo "╠══════════════════════════════════════════════╣"
echo "║  1) Standard (GPX + CSV esential)             ║"
echo "║  2) Full Data (GPX + CSV TOATE metadatele)    ║"
echo "║  3) Subtitrare (.SRT pentru VLC)              ║"
echo "║  4) Totul (GPX + CSV + SRT)                   ║"
echo "║  5) Raw streams (DJI:djmd/dbgi/tmcd/cover     ║"
echo "║      GoPro:gpmf  Sony:nmea  Garmin:fit)       ║"
echo "║  6) Elimina metadata (remux fara re-encode)   ║"
echo "║  7) Anulare                                   ║"
echo "║  Nota: QuickTime are 1 punct GPS (start)      ║"
echo "╚══════════════════════════════════════════════╝"
read -p "Alege 1-7 [implicit: 1]: " choice
choice="${choice:-1}"
[ "$choice" == "7" ] && { echo "Anulat."; exit 0; }

# ── Verificare dependente ────────────────────────────────────────────
NEED_EXIFTOOL=0; NEED_PYTHON=0; NEED_FFMPEG=1
case "$choice" in
    1|2|3|4)
        { [ "$DJI_COUNT" -gt 0 ] || [ "$QT_COUNT" -gt 0 ]; } && NEED_EXIFTOOL=1
        { [ "$GOPRO_COUNT" -gt 0 ] || [ "$SONY_COUNT" -gt 0 ] || [ "$GARMIN_COUNT" -gt 0 ]; } && NEED_PYTHON=1
        ;;
    5|6) : ;;  # ffmpeg only
esac

if [ "$NEED_EXIFTOOL" -eq 1 ] && ! command -v exiftool &>/dev/null; then
    echo "EROARE: exiftool nu este instalat (necesar pentru DJI/QuickTime)."
    echo "Instaleaza cu: pkg install exiftool  sau  cpan App::ExifTool"
    exit 1
fi
if [ "$NEED_PYTHON" -eq 1 ] && ! command -v python3 &>/dev/null; then
    echo "EROARE: python3 nu este instalat (necesar pentru parser GoPro/Sony/Garmin)."
    echo "Instaleaza cu: pkg install python"
    exit 1
fi
if ! command -v ffmpeg &>/dev/null; then
    echo "EROARE: ffmpeg nu este instalat."
    exit 1
fi

# ── Sub-dialog strip metadata (optiunea 6) ───────────────────────────
STRIP_MODE=""
if [ "$choice" == "6" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ELIMINA METADATA (REMUX FARA RE-ENCODE)     ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  DJI:                                         ║"
    echo "║   1) Doar debug (dbgi ~295 MB) [implicit]     ║"
    echo "║   2) GPS + debug (djmd + dbgi)                ║"
    echo "║   3) Tot (djmd + dbgi + tmcd + cover)         ║"
    echo "║  GoPro/Sony/Garmin: orice optiune sterge      ║"
    echo "║   track-ul de telemetrie (gpmd/nmea/fdsc)     ║"
    echo "║   4) Anulare                                  ║"
    echo "╚══════════════════════════════════════════════╝"
    read -p "Alege 1-4 [implicit: 1]: " STRIP_MODE
    STRIP_MODE="${STRIP_MODE:-1}"
    [ "$STRIP_MODE" == "4" ] && { echo "Anulat."; exit 0; }
fi

# ── Template-uri ExifTool (DJI) ──────────────────────────────────────
GPX_FMT=$(mktemp); SRT_FMT=$(mktemp); KML_FMT=$(mktemp)
cat <<'GPXEOF' > "$GPX_FMT"
#[HEAD]<?xml version="1.0" encoding="utf-8"?>
#[HEAD]<gpx version="1.0" creator="ExifTool $[ExifToolVersion]" xmlns="http://www.topografix.com/GPX/1/0">
#[HEAD]<trk><name>$filename</name><trkseg>
#[BODY]<trkpt lat="$gpslatitude#" lon="$gpslongitude#"><ele>$gpsaltitude#</ele><time>$gpsdatetime</time></trkpt>
#[TAIL]</trkseg></trk></gpx>
GPXEOF
cat <<'SRTEOF' > "$SRT_FMT"
#[BODY]${self:SampleIndex}
#[BODY]${gpsdatetime} --> ${gpsdatetime}
#[BODY]Viteza: ${gpsspeed#} m/s | Alt: ${gpsaltitude#}m
#[BODY]Coord: ${gpslatitude#}, ${gpslongitude#}
#[BODY]
SRTEOF
cat <<'KMLEOF' > "$KML_FMT"
#[HEAD]<?xml version="1.0" encoding="UTF-8"?>
#[HEAD]<kml xmlns="http://www.opengis.net/kml/2.2">
#[HEAD]<Document><name>$filename</name>
#[HEAD]<Style id="track"><LineStyle><color>ff0000ff</color><width>3</width></LineStyle></Style>
#[HEAD]<Placemark><name>Track</name><styleUrl>#track</styleUrl>
#[HEAD]<LineString><altitudeMode>absolute</altitudeMode><coordinates>
#[BODY]$gpslongitude#,$gpslatitude#,$gpsaltitude#
#[TAIL]</coordinates></LineString></Placemark></Document></kml>
KMLEOF

# ── Python GPMF parser (GoPro) — scris ca temp file la nevoie ────────
GPMF_PY=""
write_gpmf_parser() {
    GPMF_PY=$(mktemp --suffix=.py)
    cat > "$GPMF_PY" << 'PYEOF'
import struct, sys, os, csv

def parse_klv_stream(data, start=0, end=None):
    if end is None: end = len(data)
    pos = start
    while pos + 8 <= end:
        try:
            fourcc = data[pos:pos+4].decode('ascii', errors='replace')
            type_byte = data[pos+4]
            ss = data[pos+5]
            sc = struct.unpack('>H', data[pos+6:pos+8])[0]
        except: break
        pos += 8
        psize = ss * sc
        padded = (psize + 3) & ~3
        if pos + psize > end: break
        payload = data[pos:pos+psize]
        pos += padded
        tc = chr(type_byte) if type_byte != 0 else '\x00'
        yield (fourcc, tc, ss, sc, payload)

def fmt_gpsu(s):
    s = s.rstrip('\x00').strip()
    if len(s) < 12: return s
    try:
        yy=int(s[0:2]); MM=int(s[2:4]); dd=int(s[4:6])
        hh=int(s[6:8]); mm=int(s[8:10]); ss=float(s[10:])
        year = 2000+yy if yy < 90 else 1900+yy
        return f"{year:04d}-{MM:02d}-{dd:02d}T{hh:02d}:{mm:02d}:{ss:06.3f}Z"
    except: return s

def unpack_scal(tc, ss, sc, payload):
    n = (ss*sc) // max(ss,1) if ss else 0
    try:
        if tc=='s': count=(ss*sc)//2;  return list(struct.unpack(f'>{count}h', payload[:count*2]))
        if tc=='S': count=(ss*sc)//2;  return list(struct.unpack(f'>{count}H', payload[:count*2]))
        if tc=='l': count=(ss*sc)//4;  return list(struct.unpack(f'>{count}i', payload[:count*4]))
        if tc=='L': count=(ss*sc)//4;  return list(struct.unpack(f'>{count}I', payload[:count*4]))
        if tc=='f': count=(ss*sc)//4;  return list(struct.unpack(f'>{count}f', payload[:count*4]))
        if tc=='d': count=(ss*sc)//8;  return list(struct.unpack(f'>{count}d', payload[:count*8]))
    except: pass
    return []

def parse_gpmf(file_path):
    with open(file_path,'rb') as fh: data = fh.read()
    points = []
    state = {'scale':None,'time':'','fix':'','dop':'','temp':None,'devnm':''}
    for fc, tc, ss, sc, payload in parse_klv_stream(data):
        if fc == 'DEVC' and tc == '\x00':
            dev_state = dict(state)
            for fc2, tc2, ss2, sc2, payload2 in parse_klv_stream(payload):
                if fc2 == 'DVNM':
                    dev_state['devnm'] = payload2.decode('ascii', errors='replace').rstrip('\x00').strip()
                elif fc2 == 'STRM' and tc2 == '\x00':
                    strm_state = dict(dev_state)
                    strm_klvs = list(parse_klv_stream(payload2))
                    # Pre-pass: SCAL/GPSU/GPSF/GPSP/TMPC apply to GPS5 in same STRM
                    for fc3, tc3, ss3, sc3, payload3 in strm_klvs:
                        if fc3 == 'SCAL':
                            strm_state['scale'] = unpack_scal(tc3, ss3, sc3, payload3)
                        elif fc3 == 'GPSU':
                            strm_state['time'] = fmt_gpsu(payload3.decode('ascii', errors='replace'))
                        elif fc3 == 'GPSF':
                            if len(payload3)>=4: strm_state['fix'] = struct.unpack('>I', payload3[:4])[0]
                        elif fc3 == 'GPSP':
                            if len(payload3)>=2: strm_state['dop'] = struct.unpack('>H', payload3[:2])[0]
                        elif fc3 == 'TMPC':
                            if len(payload3)>=4: strm_state['temp'] = struct.unpack('>f', payload3[:4])[0]
                    # Extract GPS5 with the resolved scale
                    for fc3, tc3, ss3, sc3, payload3 in strm_klvs:
                        if fc3 == 'GPS5':
                            scale = strm_state.get('scale') or [1,1,1,1,1]
                            if len(scale) < 5: scale = list(scale) + [1]*(5-len(scale))
                            for i in range(sc3):
                                if i*20+20 > len(payload3): break
                                vals = struct.unpack('>5i', payload3[i*20:i*20+20])
                                p = {
                                    'lat': f"{vals[0]/scale[0]:.7f}" if scale[0] else f"{vals[0]}",
                                    'lon': f"{vals[1]/scale[1]:.7f}" if scale[1] else f"{vals[1]}",
                                    'alt': f"{vals[2]/scale[2]:.2f}" if scale[2] else f"{vals[2]}",
                                    'speed': f"{vals[3]/scale[3]:.2f}" if scale[3] else f"{vals[3]}",
                                    'speed3d': f"{vals[4]/scale[4]:.2f}" if scale[4] else f"{vals[4]}",
                                    'time': strm_state.get('time',''),
                                    'fix': str(strm_state.get('fix','')) if strm_state.get('fix') != '' else '',
                                    'dop': f"{strm_state.get('dop',0)/100:.2f}" if strm_state.get('dop') else '',
                                }
                                if strm_state.get('temp') is not None:
                                    p['temp'] = f"{strm_state['temp']:.1f}"
                                if strm_state.get('devnm'):
                                    p['device'] = strm_state['devnm']
                                # Filter no-fix points (fix=0 or 1 = no fix)
                                fix_val = strm_state.get('fix', 0)
                                if fix_val and fix_val < 2: continue
                                # Filter zero coordinates
                                try:
                                    if abs(float(p['lat'])) < 0.001 and abs(float(p['lon'])) < 0.001: continue
                                except: continue
                                points.append(p)
    return points

def write_csv_basic(points, path):
    with open(path,'w',newline='') as f:
        w=csv.writer(f); w.writerow(['Latitude','Longitude','Altitude(m)','Speed(m/s)','Speed3D(m/s)','DateTime','Fix','DOP'])
        for p in points: w.writerow([p['lat'],p['lon'],p.get('alt',''),p.get('speed',''),p.get('speed3d',''),p.get('time',''),p.get('fix',''),p.get('dop','')])

def write_csv_full(points, path):
    keys=sorted(set(k for p in points for k in p.keys()))
    with open(path,'w',newline='') as f:
        w=csv.writer(f); w.writerow(keys)
        for p in points: w.writerow([p.get(k,'') for k in keys])

# ── CSV normalizat (schema unificata cross-brand) ────────────────────
NORM_COLUMNS = ['timestamp','lat','lon','alt_m','speed_mps','speed_kmh','heading_deg',
                'gforce_x','gforce_y','gforce_z','gyro_x','gyro_y','gyro_z',
                'temp_c','hr_bpm','cadence_rpm','power_w','source_brand']

def _kmh_from_mps(s):
    try: return f"{float(s)*3.6:.2f}" if s != '' else ''
    except: return ''

def write_csv_normalized(points, path, brand):
    with open(path,'w',newline='') as f:
        w=csv.writer(f); w.writerow(NORM_COLUMNS)
        for p in points:
            row = {col:'' for col in NORM_COLUMNS}
            row['timestamp']    = p.get('time','')
            row['lat']          = p.get('lat','')
            row['lon']          = p.get('lon','')
            row['alt_m']        = p.get('alt','')
            row['speed_mps']    = p.get('speed','')
            row['speed_kmh']    = _kmh_from_mps(p.get('speed',''))
            row['heading_deg']  = p.get('heading','')
            row['temp_c']       = p.get('temp','')
            row['hr_bpm']       = p.get('hr','')
            row['cadence_rpm']  = p.get('cad','')
            row['power_w']      = p.get('power','')
            row['source_brand'] = brand
            w.writerow([row[c] for c in NORM_COLUMNS])

def write_gpx(points, name, path):
    with open(path,'w') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.0" creator="AV Encoder Suite (GoPro GPMF)" xmlns="http://www.topografix.com/GPX/1/0">\n')
        f.write(f'<trk><name>{name}</name><trkseg>\n')
        for p in points:
            t = p.get('time','')
            f.write(f'<trkpt lat="{p["lat"]}" lon="{p["lon"]}"><ele>{p.get("alt","0") or "0"}</ele>')
            if t: f.write(f'<time>{t}</time>')
            f.write('</trkpt>\n')
        f.write('</trkseg></trk></gpx>\n')

def write_srt(points, path):
    with open(path,'w') as f:
        for i,p in enumerate(points):
            sv=p.get('speed','0')
            try: sk=f"{float(sv)*3.6:.1f}" if sv else "0.0"
            except: sk="0.0"
            s1,s2=i,i+1
            f.write(f"{i+1}\n{s1//3600:02d}:{(s1%3600)//60:02d}:{s1%60:02d},000 --> {s2//3600:02d}:{(s2%3600)//60:02d}:{s2%60:02d},000\n")
            f.write(f"Speed: {sk} km/h | Alt: {p.get('alt','N/A')}m\n")
            f.write(f"GPS: {p['lat']}, {p['lon']}")
            if p.get('time'): f.write(f" @ {p['time']}")
            f.write("\n\n")

# ── FIT parser (Garmin VIRB) ─────────────────────────────────────────
from datetime import datetime, timedelta
def parse_fit(file_path):
    FIT_EPOCH = datetime(1989,12,31)
    import struct as _s
    with open(file_path,'rb') as f: data=f.read()
    if len(data)<14: return []
    hs = data[0]
    sig_off = hs-4 if hs>=14 else 8
    if data[sig_off:sig_off+4] != b'.FIT': return []
    points=[]; field_defs={}; mesg_nums={}; pos=hs
    while pos < len(data)-2:
        try:
            rh=data[pos]; pos+=1
            if rh & 0x40:
                lm=rh&0x0F; pos+=1; arch=data[pos]; pos+=1
                gm=_s.unpack('<H' if arch==0 else '>H',data[pos:pos+2])[0]; pos+=2
                nf=data[pos]; pos+=1; flds=[]
                for _ in range(nf): flds.append((data[pos],data[pos+1],data[pos+2])); pos+=3
                field_defs[lm]=(flds,arch); mesg_nums[lm]=gm
                if rh&0x20: nd=data[pos]; pos+=1; pos+=nd*3
            elif rh&0x80:
                lm=(rh>>5)&0x03
                if lm not in field_defs: break
                for _,fs,_t in field_defs[lm][0]: pos+=fs
            else:
                lm=rh&0x0F
                if lm not in field_defs: break
                flds,arch=field_defs[lm]; gm=mesg_nums.get(lm,0); fv={}
                for fdn,fs,fbt in flds:
                    raw=data[pos:pos+fs]; pos+=fs; val=None
                    if fs==1: val=raw[0]; val=None if val==0xFF else val
                    elif fs==2: val=_s.unpack('<H' if arch==0 else '>H',raw)[0]; val=None if val==0xFFFF else val
                    elif fs==4:
                        val=_s.unpack('<I' if arch==0 else '>I',raw)[0]; val=None if val==0xFFFFFFFF else val
                        if fbt&0x1F==0x85: val=_s.unpack('<i' if arch==0 else '>i',raw)[0]; val=None if val==0x7FFFFFFF else val
                    if val is not None: fv[fdn]=val
                if gm==20 and 0 in fv and 1 in fv:
                    lat_sc,lon_sc=fv[0],fv[1]
                    if lat_sc>0x7FFFFFFF: lat_sc-=0x100000000
                    if lon_sc>0x7FFFFFFF: lon_sc-=0x100000000
                    p={'lat':f"{lat_sc*(180.0/2**31):.7f}",'lon':f"{lon_sc*(180.0/2**31):.7f}"}
                    p['alt']=f"{(fv[2]/5.0)-500:.2f}" if 2 in fv and fv[2]!=0xFFFF else ''
                    p['speed']=f"{fv[6]/1000.0:.2f}" if 6 in fv else ''
                    p['time']=(FIT_EPOCH+timedelta(seconds=fv[253])).strftime('%Y-%m-%dT%H:%M:%SZ') if 253 in fv else ''
                    if 3 in fv: p['hr']=str(fv[3])
                    if 4 in fv: p['cad']=str(fv[4])
                    if 7 in fv: p['power']=str(fv[7])
                    if 23 in fv: p['temp']=str(fv[23])
                    try:
                        if -90<=float(p['lat'])<=90 and float(p['lat'])!=0: points.append(p)
                    except: pass
        except: break
    return points

# ── NMEA parser (Sony Action Cam) ────────────────────────────────────
def nmea_to_decimal(coord, hemi):
    if not coord or '.' not in coord: return None
    try:
        dot = coord.find('.')
        if dot < 2: return None
        deg = int(coord[:dot-2])
        minutes = float(coord[dot-2:])
        decimal = deg + minutes / 60.0
        if hemi in ('S','W'): decimal = -decimal
        return decimal
    except: return None

def parse_nmea(file_path):
    with open(file_path,'rb') as f: data = f.read()
    try: text = data.decode('ascii', errors='replace')
    except: text = data.decode('latin-1', errors='replace')
    points = []
    for raw_line in text.split('\n'):
        line = raw_line.strip()
        if not line.startswith('$'): continue
        if '*' in line: line = line.split('*')[0]
        parts = line.split(',')
        if len(parts) < 2: continue
        sentence = parts[0]
        if sentence in ('$GPRMC','$GNRMC') and len(parts) >= 10:
            time_s, status = parts[1], parts[2]
            lat_s, lat_d = parts[3], parts[4]
            lon_s, lon_d = parts[5], parts[6]
            speed_kn = parts[7]; heading = parts[8]; date_s = parts[9]
            if status != 'A': continue
            lat = nmea_to_decimal(lat_s, lat_d); lon = nmea_to_decimal(lon_s, lon_d)
            if lat is None or lon is None: continue
            try: speed_mps = float(speed_kn) * 0.514444 if speed_kn else 0.0
            except: speed_mps = 0.0
            ts = ''
            if len(date_s) == 6 and len(time_s) >= 6:
                try:
                    dd, MM = date_s[0:2], date_s[2:4]
                    yy = int(date_s[4:6]); year = 2000+yy if yy < 90 else 1900+yy
                    hh, mm, ss = time_s[0:2], time_s[2:4], time_s[4:]
                    ts = f"{year:04d}-{MM}-{dd}T{hh}:{mm}:{ss}Z"
                except: pass
            points.append({
                'lat': f"{lat:.7f}", 'lon': f"{lon:.7f}", 'alt': '',
                'speed': f"{speed_mps:.2f}", 'heading': heading.strip() if heading else '',
                'time': ts,
            })
        elif sentence in ('$GPGGA','$GNGGA') and len(parts) >= 10:
            try:
                alt = parts[9]
                if points and not points[-1].get('alt'): points[-1]['alt'] = alt
            except: pass
    return points

# ── Main dispatcher: <fmt> <bin_file> <name> <output_dir> <choice> [brand] ─
if __name__ == '__main__':
    if len(sys.argv) < 6:
        print("Usage: parser.py <fmt:gpmf|fit|nmea> <bin_file> <name> <output_dir> <choice> [brand]"); sys.exit(1)
    fmt = sys.argv[1]; bin_file = sys.argv[2]; name = sys.argv[3]; out_dir = sys.argv[4]; choice = sys.argv[5]
    brand = sys.argv[6] if len(sys.argv) > 6 else fmt
    if   fmt == 'gpmf': pts = parse_gpmf(bin_file); label = 'GPMF'
    elif fmt == 'fit':  pts = parse_fit(bin_file);  label = 'FIT'
    elif fmt == 'nmea': pts = parse_nmea(bin_file); label = 'NMEA'
    else: print(f"  [EROARE] Format necunoscut: {fmt}"); sys.exit(1)
    if not pts:
        print(f"  [SKIP] {label}: nu am gasit puncte GPS valide"); sys.exit(0)
    print(f"  {label}: {len(pts)} puncte GPS extrase")
    if choice in ('1','2','4'): write_gpx(pts, name, os.path.join(out_dir, f"{name}.gpx")); print(f"  [OK] GPX: {name}.gpx")
    if choice in ('1','4'):     write_csv_basic(pts, os.path.join(out_dir, f"{name}_basic.csv")); print(f"  [OK] CSV Basic: {name}_basic.csv")
    if choice in ('2','4'):     write_csv_full(pts, os.path.join(out_dir, f"{name}_FULL.csv")); print(f"  [OK] CSV Full: {name}_FULL.csv")
    if choice in ('3','4'):     write_srt(pts, os.path.join(out_dir, f"{name}.srt")); print(f"  [OK] SRT: {name}.srt")
    if choice in ('1','2','4'): write_csv_normalized(pts, os.path.join(out_dir, f"{name}_norm.csv"), brand); print(f"  [OK] CSV Norm: {name}_norm.csv")
PYEOF
}

# ── Procesare DJI (existing logic) ───────────────────────────────────
process_dji() {
    local file="$1"; local name="$2"
    case "$choice" in
        1|2|4)
            exiftool -p "$GPX_FMT" -ee3 -api LargeFileSupport=1 "$file" > "$OUTPUT_DIR/${name}.gpx" 2>/dev/null
            if [ -s "$OUTPUT_DIR/${name}.gpx" ]; then echo "  [OK] GPX: ${name}.gpx"
            else echo "  [SKIP] GPX: nu s-au gasit date GPS"; rm -f "$OUTPUT_DIR/${name}.gpx"; fi
            ;;
    esac
    case "$choice" in
        1|4)
            exiftool -ee3 -api LargeFileSupport=1 -csv -n -GPSLatitude -GPSLongitude -GPSAltitude -GPSSpeed -GPSTrack -GPSDateTime "$file" > "$OUTPUT_DIR/${name}_basic.csv" 2>/dev/null
            [ -s "$OUTPUT_DIR/${name}_basic.csv" ] && echo "  [OK] CSV Basic: ${name}_basic.csv" || rm -f "$OUTPUT_DIR/${name}_basic.csv"
            ;;
    esac
    case "$choice" in
        2|4)
            exiftool -ee3 -api LargeFileSupport=1 -csv -G -n "$file" > "$OUTPUT_DIR/${name}_FULL.csv" 2>/dev/null
            [ -s "$OUTPUT_DIR/${name}_FULL.csv" ] && echo "  [OK] CSV Full: ${name}_FULL.csv" || rm -f "$OUTPUT_DIR/${name}_FULL.csv"
            ;;
    esac
    case "$choice" in
        3|4)
            exiftool -p "$SRT_FMT" -ee3 -api LargeFileSupport=1 "$file" > "$OUTPUT_DIR/${name}.srt" 2>/dev/null
            if [ -s "$OUTPUT_DIR/${name}.srt" ]; then echo "  [OK] SRT: ${name}.srt"
            else echo "  [SKIP] SRT: nu s-au gasit date GPS"; rm -f "$OUTPUT_DIR/${name}.srt"; fi
            ;;
    esac
    # CSV normalizat — derivat din basic CSV exiftool
    case "$choice" in
        1|2|4)
            local basic_src="$OUTPUT_DIR/${name}_basic.csv"
            if [ ! -s "$basic_src" ]; then
                # Generam temporar daca nu exista (choice 2)
                exiftool -ee3 -api LargeFileSupport=1 -csv -n -GPSLatitude -GPSLongitude -GPSAltitude -GPSSpeed -GPSTrack -GPSDateTime "$file" > "$basic_src.tmp" 2>/dev/null
                [ -s "$basic_src.tmp" ] && basic_src="$basic_src.tmp"
            fi
            if [ -s "$basic_src" ]; then
                python3 -c "
import csv, sys
NORM=['timestamp','lat','lon','alt_m','speed_mps','speed_kmh','heading_deg','gforce_x','gforce_y','gforce_z','gyro_x','gyro_y','gyro_z','temp_c','hr_bpm','cadence_rpm','power_w','source_brand']
with open(sys.argv[1]) as fi, open(sys.argv[2],'w',newline='') as fo:
    r=csv.DictReader(fi); w=csv.writer(fo); w.writerow(NORM)
    for row in r:
        lat=row.get('GPSLatitude','').strip(); lon=row.get('GPSLongitude','').strip()
        if not lat or not lon: continue
        sp=row.get('GPSSpeed','').strip()
        try: skmh=f'{float(sp)*3.6:.2f}' if sp else ''
        except: skmh=''
        out={c:'' for c in NORM}
        out['timestamp']=row.get('GPSDateTime','').strip()
        out['lat']=lat; out['lon']=lon
        out['alt_m']=row.get('GPSAltitude','').strip()
        out['speed_mps']=sp; out['speed_kmh']=skmh
        out['heading_deg']=row.get('GPSTrack','').strip()
        out['source_brand']='dji'
        w.writerow([out[c] for c in NORM])
" "$basic_src" "$OUTPUT_DIR/${name}_norm.csv" 2>/dev/null
                [ -s "$OUTPUT_DIR/${name}_norm.csv" ] && echo "  [OK] CSV Norm: ${name}_norm.csv" || rm -f "$OUTPUT_DIR/${name}_norm.csv"
                rm -f "$OUTPUT_DIR/${name}_basic.csv.tmp"
            fi
            ;;
    esac
    if [ "$choice" == "5" ]; then process_dji_raw "$file" "$name"; fi
    if [ "$choice" == "6" ]; then process_dji_strip "$file" "$name"; fi
}

process_dji_raw() {
    local file="$1"; local name="$2"
    local local_idx=0
    while IFS= read -r tag; do
        if echo "$tag" | grep -qi "djmd"; then
            ffmpeg -v error -i "$file" -map 0:$local_idx -c copy -f data "$OUTPUT_DIR/${name}_djmd.bin" -y </dev/null 2>/dev/null
            [ -s "$OUTPUT_DIR/${name}_djmd.bin" ] && echo "  [OK] djmd: ${name}_djmd.bin ($(du -h "$OUTPUT_DIR/${name}_djmd.bin" | cut -f1))" || rm -f "$OUTPUT_DIR/${name}_djmd.bin"
        elif echo "$tag" | grep -qi "dbgi"; then
            ffmpeg -v error -i "$file" -map 0:$local_idx -c copy -f data "$OUTPUT_DIR/${name}_dbgi.bin" -y </dev/null 2>/dev/null
            [ -s "$OUTPUT_DIR/${name}_dbgi.bin" ] && echo "  [OK] dbgi: ${name}_dbgi.bin ($(du -h "$OUTPUT_DIR/${name}_dbgi.bin" | cut -f1))" || rm -f "$OUTPUT_DIR/${name}_dbgi.bin"
        elif echo "$tag" | grep -qi "tmcd"; then
            ffmpeg -v error -i "$file" -map 0:$local_idx -c copy -f data "$OUTPUT_DIR/${name}_tmcd.bin" -y </dev/null 2>/dev/null
            [ -s "$OUTPUT_DIR/${name}_tmcd.bin" ] && echo "  [OK] tmcd: ${name}_tmcd.bin ($(du -h "$OUTPUT_DIR/${name}_tmcd.bin" | cut -f1))" || rm -f "$OUTPUT_DIR/${name}_tmcd.bin"
        elif echo "$tag" | grep -qiE "mjpeg|jpeg"; then
            ffmpeg -v error -i "$file" -map 0:$local_idx -c copy -f mjpeg "$OUTPUT_DIR/${name}_cover.jpg" -y </dev/null 2>/dev/null
            [ -s "$OUTPUT_DIR/${name}_cover.jpg" ] && echo "  [OK] cover: ${name}_cover.jpg ($(du -h "$OUTPUT_DIR/${name}_cover.jpg" | cut -f1))" || rm -f "$OUTPUT_DIR/${name}_cover.jpg"
        fi
        local_idx=$((local_idx + 1))
    done < <(ffprobe -v error -show_entries stream=codec_tag_string,codec_name -of csv=p=0 "$file" 2>/dev/null)
}

process_dji_strip() {
    local file="$1"; local name="$2"
    local ext="${file##*.}"
    local maps="-map 0"
    local local_idx=0
    while IFS= read -r tag; do
        case "$STRIP_MODE" in
            1) echo "$tag" | grep -qi "dbgi" && maps="$maps -map -0:$local_idx" ;;
            2) echo "$tag" | grep -qiE "djmd|dbgi" && maps="$maps -map -0:$local_idx" ;;
            3) echo "$tag" | grep -qiE "djmd|dbgi|tmcd|mjpeg|jpeg" && maps="$maps -map -0:$local_idx" ;;
        esac
        local_idx=$((local_idx + 1))
    done < <(ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 "$file" 2>/dev/null)
    local out_clean="$OUTPUT_DIR/${name}_clean.${ext}"
    ffmpeg -v error -i "$file" $maps -c copy -map_metadata 0 "$out_clean" -y </dev/null 2>/dev/null
    if [ $? -eq 0 ] && [ -s "$out_clean" ]; then
        echo "  [OK] ${name}_clean.${ext} ($(du -h "$file" | cut -f1) → $(du -h "$out_clean" | cut -f1))"
    else
        echo "  [EROARE] Remux esuat"; rm -f "$out_clean"
    fi
}

# ── Procesare GoPro (GPMF) ───────────────────────────────────────────
process_gopro() {
    local file="$1"; local name="$2"
    case "$choice" in
        1|2|3|4)
            # Extract gpmd track to .bin, parse with Python, write outputs
            local idx
            idx=$(detect_telemetry_track_idx "$file" "gpmd")
            if [ -z "$idx" ]; then echo "  [SKIP] gpmd track nu a fost gasit"; return; fi
            local bin_tmp="$OUTPUT_DIR/${name}_gpmf.bin"
            ffmpeg -v error -i "$file" -map "0:$idx" -c copy -f data "$bin_tmp" -y </dev/null 2>/dev/null
            if [ ! -s "$bin_tmp" ]; then echo "  [SKIP] Extragere gpmd esuata"; rm -f "$bin_tmp"; return; fi
            python3 "$GPMF_PY" "gpmf" "$bin_tmp" "$name" "$OUTPUT_DIR" "$choice" "gopro"
            rm -f "$bin_tmp"
            ;;
        5)  # Raw streams: pastram bin-ul GPMF
            local idx
            idx=$(detect_telemetry_track_idx "$file" "gpmd")
            if [ -z "$idx" ]; then echo "  [SKIP] gpmd track nu a fost gasit"; return; fi
            ffmpeg -v error -i "$file" -map "0:$idx" -c copy -f data "$OUTPUT_DIR/${name}_gpmf.bin" -y </dev/null 2>/dev/null
            [ -s "$OUTPUT_DIR/${name}_gpmf.bin" ] && echo "  [OK] gpmf: ${name}_gpmf.bin ($(du -h "$OUTPUT_DIR/${name}_gpmf.bin" | cut -f1))" || { echo "  [EROARE] Extragere gpmf esuata"; rm -f "$OUTPUT_DIR/${name}_gpmf.bin"; }
            ;;
        6)  # Strip: orice STRIP_MODE elimina gpmd
            local ext="${file##*.}"
            local maps="-map 0"
            local local_idx=0
            while IFS= read -r tag; do
                if echo "$tag" | grep -qi "gpmd"; then maps="$maps -map -0:$local_idx"; fi
                local_idx=$((local_idx + 1))
            done < <(ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 "$file" 2>/dev/null)
            local out_clean="$OUTPUT_DIR/${name}_clean.${ext}"
            ffmpeg -v error -i "$file" $maps -c copy -map_metadata 0 "$out_clean" -y </dev/null 2>/dev/null
            if [ $? -eq 0 ] && [ -s "$out_clean" ]; then
                echo "  [OK] ${name}_clean.${ext} ($(du -h "$file" | cut -f1) → $(du -h "$out_clean" | cut -f1))"
            else echo "  [EROARE] Remux esuat"; rm -f "$out_clean"; fi
            ;;
    esac
}

# ── Helper generic: extract telemetry track + parse cu Python ────────
# Args: file, name, codec_tag, fmt, output_label, brand
_telem_extract_and_parse() {
    local file="$1"; local name="$2"; local tag="$3"; local fmt="$4"; local label="$5"; local brand="$6"
    local idx
    idx=$(detect_telemetry_track_idx "$file" "$tag")
    if [ -z "$idx" ]; then echo "  [SKIP] $label track ($tag) nu a fost gasit"; return; fi
    local bin_tmp="$OUTPUT_DIR/${name}_${fmt}.bin"
    ffmpeg -v error -i "$file" -map "0:$idx" -c copy -f data "$bin_tmp" -y </dev/null 2>/dev/null
    if [ ! -s "$bin_tmp" ]; then echo "  [SKIP] Extragere $label esuata"; rm -f "$bin_tmp"; return; fi
    python3 "$GPMF_PY" "$fmt" "$bin_tmp" "$name" "$OUTPUT_DIR" "$choice" "$brand"
    rm -f "$bin_tmp"
}

_telem_extract_raw() {
    local file="$1"; local name="$2"; local tag="$3"; local fmt="$4"
    local idx
    idx=$(detect_telemetry_track_idx "$file" "$tag")
    if [ -z "$idx" ]; then echo "  [SKIP] $tag track nu a fost gasit"; return; fi
    local out="$OUTPUT_DIR/${name}_${fmt}.bin"
    ffmpeg -v error -i "$file" -map "0:$idx" -c copy -f data "$out" -y </dev/null 2>/dev/null
    [ -s "$out" ] && echo "  [OK] $fmt: ${name}_${fmt}.bin ($(du -h "$out" | cut -f1))" || { echo "  [EROARE] Extragere $tag esuata"; rm -f "$out"; }
}

_telem_strip_track() {
    local file="$1"; local name="$2"; local tag_re="$3"
    local ext="${file##*.}"; local maps="-map 0"; local local_idx=0
    while IFS= read -r tag; do
        if echo "$tag" | grep -qiE "$tag_re"; then maps="$maps -map -0:$local_idx"; fi
        local_idx=$((local_idx + 1))
    done < <(ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 "$file" 2>/dev/null)
    local out_clean="$OUTPUT_DIR/${name}_clean.${ext}"
    ffmpeg -v error -i "$file" $maps -c copy -map_metadata 0 "$out_clean" -y </dev/null 2>/dev/null
    if [ $? -eq 0 ] && [ -s "$out_clean" ]; then
        echo "  [OK] ${name}_clean.${ext} ($(du -h "$file" | cut -f1) → $(du -h "$out_clean" | cut -f1))"
    else echo "  [EROARE] Remux esuat"; rm -f "$out_clean"; fi
}

# ── Procesare Sony (NMEA) ────────────────────────────────────────────
process_sony() {
    local file="$1"; local name="$2"
    case "$choice" in
        1|2|3|4) _telem_extract_and_parse "$file" "$name" "nmea" "nmea" "Sony NMEA" "sony" ;;
        5)       _telem_extract_raw       "$file" "$name" "nmea" "nmea" ;;
        6)       _telem_strip_track       "$file" "$name" "nmea" ;;
    esac
}

# ── Procesare Garmin VIRB (FIT embedded) ─────────────────────────────
process_garmin() {
    local file="$1"; local name="$2"
    case "$choice" in
        1|2|3|4) _telem_extract_and_parse "$file" "$name" "fdsc" "fit" "Garmin FIT" "garmin" ;;
        5)       _telem_extract_raw       "$file" "$name" "fdsc" "fit" ;;
        6)       _telem_strip_track       "$file" "$name" "fdsc" ;;
    esac
}

# ── Procesare QuickTime (single-point GPS, Apple/Samsung/Android) ────
process_quicktime() {
    local file="$1"; local name="$2"
    case "$choice" in
        1|2|3|4)
            # Extract single-point GPS via ExifTool ISO 6709
            local lat lon alt dt
            lat=$(exiftool -s3 -api LargeFileSupport=1 -n -GPSLatitude "$file" 2>/dev/null)
            lon=$(exiftool -s3 -api LargeFileSupport=1 -n -GPSLongitude "$file" 2>/dev/null)
            alt=$(exiftool -s3 -api LargeFileSupport=1 -n -GPSAltitude "$file" 2>/dev/null)
            dt=$(exiftool -s3 -api LargeFileSupport=1 -CreateDate "$file" 2>/dev/null | head -1)
            if [ -z "$lat" ] || [ -z "$lon" ]; then
                echo "  [SKIP] QuickTime: fara coordonate GPS in atom ISO 6709"; return
            fi
            [ -z "$alt" ] && alt="0"
            local ts=""
            if [ -n "$dt" ]; then
                ts=$(echo "$dt" | sed 's/^\([0-9]*\):\([0-9]*\):\([0-9]*\) /\1-\2-\3T/')Z
            fi
            if [ "$choice" == "1" ] || [ "$choice" == "2" ] || [ "$choice" == "4" ]; then
                {
                    echo '<?xml version="1.0" encoding="UTF-8"?>'
                    echo '<gpx version="1.0" creator="AV Encoder Suite (QuickTime ISO 6709)" xmlns="http://www.topografix.com/GPX/1/0">'
                    echo "<wpt lat=\"$lat\" lon=\"$lon\"><ele>$alt</ele>"
                    [ -n "$ts" ] && echo "<time>$ts</time>"
                    echo "<name>$name</name></wpt>"
                    echo '</gpx>'
                } > "$OUTPUT_DIR/${name}.gpx"
                echo "  [OK] GPX: ${name}.gpx (1 punct)"
            fi
            if [ "$choice" == "1" ] || [ "$choice" == "4" ]; then
                {
                    echo "Latitude,Longitude,Altitude(m),Speed(m/s),DateTime,Source"
                    echo "$lat,$lon,$alt,,$ts,QuickTime ISO 6709"
                } > "$OUTPUT_DIR/${name}_basic.csv"
                echo "  [OK] CSV Basic: ${name}_basic.csv (1 punct)"
            fi
            # CSV normalizat (1 rand)
            if [ "$choice" == "1" ] || [ "$choice" == "2" ] || [ "$choice" == "4" ]; then
                {
                    echo "timestamp,lat,lon,alt_m,speed_mps,speed_kmh,heading_deg,gforce_x,gforce_y,gforce_z,gyro_x,gyro_y,gyro_z,temp_c,hr_bpm,cadence_rpm,power_w,source_brand"
                    echo "$ts,$lat,$lon,$alt,,,,,,,,,,,,,,quicktime"
                } > "$OUTPUT_DIR/${name}_norm.csv"
                echo "  [OK] CSV Norm: ${name}_norm.csv (1 punct)"
            fi
            if [ "$choice" == "2" ] || [ "$choice" == "4" ]; then
                exiftool -api LargeFileSupport=1 -csv -G -n "$file" > "$OUTPUT_DIR/${name}_FULL.csv" 2>/dev/null
                [ -s "$OUTPUT_DIR/${name}_FULL.csv" ] && echo "  [OK] CSV Full: ${name}_FULL.csv" || rm -f "$OUTPUT_DIR/${name}_FULL.csv"
            fi
            if [ "$choice" == "3" ] || [ "$choice" == "4" ]; then
                {
                    echo "1"
                    echo "00:00:00,000 --> 00:00:05,000"
                    echo "GPS: $lat, $lon | Alt: ${alt}m"
                    [ -n "$ts" ] && echo "Time: $ts"
                    echo ""
                } > "$OUTPUT_DIR/${name}.srt"
                echo "  [OK] SRT: ${name}.srt (1 punct)"
            fi
            ;;
        5)  echo "  [INFO] QuickTime nu are stream raw — datele sunt in atom-ul mvhd/mdta" ;;
        6)  echo "  [INFO] QuickTime: foloseste exiftool -gps:all= pentru a sterge tag-urile (fara remux)" ;;
    esac
}

# ── Pregateste parser-ul Python daca e nevoie ────────────────────────
[ "$NEED_PYTHON" -eq 1 ] && [ "$choice" != "5" ] && [ "$choice" != "6" ] && write_gpmf_parser

# ── Main loop ────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════"
echo "Incep extractia..."
echo "═══════════════════════════════════════"

DONE=0
for ((i=0; i<TOTAL; i++)); do
    file="${FILES[$i]}"
    [ -f "$file" ] || continue
    filename=$(basename "$file")
    name="${filename%.*}"
    brand="${BRANDS[$i]}"

    DONE=$((DONE + 1))
    echo ""
    echo "── $DONE/$TOTAL: $filename  [$brand]"

    case "$brand" in
        dji)       process_dji       "$file" "$name" ;;
        gopro)     process_gopro     "$file" "$name" ;;
        sony)      process_sony      "$file" "$name" ;;
        garmin)    process_garmin    "$file" "$name" ;;
        quicktime) process_quicktime "$file" "$name" ;;
        unknown)   echo "  [SKIP] Brand telemetrie nedetectat" ;;
    esac
done

# ── Curatenie ────────────────────────────────────────────────────────
rm -f "$GPX_FMT" "$SRT_FMT" "$KML_FMT"
[ -n "$GPMF_PY" ] && rm -f "$GPMF_PY"

echo ""
echo "═══════════════════════════════════════"
echo "FINALIZAT — $DONE fisiere procesate"
echo "Output: $OUTPUT_DIR"
echo "═══════════════════════════════════════"
