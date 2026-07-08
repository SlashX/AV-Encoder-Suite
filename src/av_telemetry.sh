#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_telemetry.sh — Extractor unificat de telemetrie din fisiere video
# v40: Suport DJI + GoPro (GPMF). Sony/Garmin VIRB/QuickTime — chunk-uri ulterioare.
# Necesita: exiftool (DJI/QT), ffmpeg, python3 (GoPro GPMF parser)
# ══════════════════════════════════════════════════════════════════════

# v41: Source av_common.sh pentru detect_platform + paths cross-platform + wrappere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/av_common.sh"

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
        if command -v "$AV_TOOL_EXIFTOOL" &>/dev/null; then
            local loc
            loc=$("$AV_TOOL_EXIFTOOL" -s3 -api LargeFileSupport=1 -GPSLatitude "$file" 2>/dev/null)
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
echo "║  7) Extract + embed lossless                  ║"
echo "║     SRT track + CSV/GPX attachments in MKV    ║"
echo "║  8) Anulare                                   ║"
echo "║  Nota: QuickTime are 1 punct GPS (start)      ║"
echo "╚══════════════════════════════════════════════╝"
read -p "Alege 1-8 [implicit: 1]: " choice
choice="${choice:-1}"
[ "$choice" == "8" ] && { echo "Anulat."; exit 0; }

# ── opt 7 (embed) — submenu pentru continut embed ────────────────────
EMBED_AFTER=0
EMBED_PROFILE=""
if [ "$choice" == "7" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  EMBED LOSSLESS — selecteaza continut         ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  1) SRT only (compatibil MKV/MP4/MOV)         ║"
    echo "║  2) SRT + norm CSV (MKV preferred)            ║"
    echo "║  3) SRT + norm CSV + GPX (MKV preferred)      ║"
    echo "║     [implicit]                                ║"
    echo "║  4) Toate (SRT + toate CSV + GPX + KML,       ║"
    echo "║     MKV mandatory)                            ║"
    echo "║  5) Anulare                                   ║"
    echo "╚══════════════════════════════════════════════╝"
    read -p "Alege 1-5 [implicit: 3]: " _emb_prof
    case "${_emb_prof:-3}" in
        1) EMBED_PROFILE="srt";         choice="3" ;;  # SRT only
        2) EMBED_PROFILE="srt_csv";     choice="4" ;;  # SRT + norm CSV
        3) EMBED_PROFILE="srt_csv_gpx"; choice="4" ;;  # default
        4) EMBED_PROFILE="all";         choice="4" ;;  # everything (forces MKV)
        5) echo "Anulat."; exit 0 ;;
        *) EMBED_PROFILE="srt_csv_gpx"; choice="4" ;;
    esac
    EMBED_AFTER=1
fi

# ── Verificare dependente ────────────────────────────────────────────
NEED_EXIFTOOL=0; NEED_PYTHON=0; NEED_FFMPEG=1
case "$choice" in
    1|2|3|4)
        { [ "$DJI_COUNT" -gt 0 ] || [ "$QT_COUNT" -gt 0 ]; } && NEED_EXIFTOOL=1
        { [ "$GOPRO_COUNT" -gt 0 ] || [ "$SONY_COUNT" -gt 0 ] || [ "$GARMIN_COUNT" -gt 0 ]; } && NEED_PYTHON=1
        ;;
    5|6) : ;;  # ffmpeg only
esac

# Soft Python detection pentru DJI norm CSV (nu blocant — paralel cu PS1)
HAVE_PYTHON=0
command -v python3 &>/dev/null && HAVE_PYTHON=1
WANT_PY_DJI_NORM=0
if [ "$DJI_COUNT" -gt 0 ] && [[ "$choice" =~ ^[124]$ ]] && [ "$NEED_PYTHON" -eq 0 ]; then
    WANT_PY_DJI_NORM=1
fi

if [ "$NEED_EXIFTOOL" -eq 1 ] && ! command -v "$AV_TOOL_EXIFTOOL" &>/dev/null; then
    echo "EROARE: $AV_TOOL_EXIFTOOL nu este instalat (necesar pentru DJI/QuickTime)."
    echo "Instaleaza cu: $(av_pkg_install_hint exiftool)"
    exit 1
fi
if [ "$NEED_PYTHON" -eq 1 ] && [ "$HAVE_PYTHON" -eq 0 ]; then
    echo "EROARE: python3 nu este instalat (necesar pentru parser GoPro/Sony/Garmin)."
    echo "Instaleaza cu: $(av_pkg_install_hint python3)"
    exit 1
fi
if [ "$WANT_PY_DJI_NORM" -eq 1 ] && [ "$HAVE_PYTHON" -eq 0 ]; then
    echo "[INFO] python3 nu este disponibil — norm.csv (CSV unificat) va fi sarit pentru DJI."
    echo "       Recomandare: $(av_pkg_install_hint python3)"
fi
if ! command -v ffmpeg &>/dev/null; then
    echo "EROARE: ffmpeg nu este instalat."
    echo "Instaleaza cu: $(av_pkg_install_hint ffmpeg)"
    exit 1
fi

# ── Sub-dialog strip metadata (optiunea 6) ───────────────────────────
STRIP_MODE=""
if [ "$choice" == "6" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ELIMINA METADATA (REMUX FARA RE-ENCODE)     ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  DJI (pista de date proprietara):            ║"
    echo "║   1) Sterge telemetria (djmd/dbgi/tmcd)      ║"
    echo "║   2) Sterge telemetria + cover (mjpeg)       ║"
    echo "║   3) Pastreaza GPS nativ (djmd) (-cover)     ║"
    echo "║  GoPro/Sony/Garmin: orice optiune sterge     ║"
    echo "║   track-ul de telemetrie (gpmd/nmea/fdsc)    ║"
    echo "║   4) Anulare                                 ║"
    echo "╚══════════════════════════════════════════════╝"
    echo "  Notă DJI: opt 1/2 elimina telemetria (ffmpeg nu re-muxeaza"
    echo "  pistele de date proprietare djmd/dbgi/tmcd, codec none)."
    echo "  Opt 3 PASTREAZA GPS-ul nativ (djmd) prin MP4Box, eliminand"
    echo "  doar cover-ul — necesita MP4Box (installer in tools/)."
    read -p "Alege 1-4 [implicit: 1]: " STRIP_MODE
    STRIP_MODE="${STRIP_MODE:-1}"
    [ "$STRIP_MODE" == "4" ] && { echo "Anulat."; exit 0; }
fi

# ── Template-uri ExifTool (DJI) ──────────────────────────────────────
GPX_FMT=$(mktemp); KML_FMT=$(mktemp)
cat <<'GPXEOF' > "$GPX_FMT"
#[HEAD]<?xml version="1.0" encoding="utf-8"?>
#[HEAD]<gpx version="1.0" creator="ExifTool $[ExifToolVersion]" xmlns="http://www.topografix.com/GPX/1/0">
#[HEAD]<trk><name>$filename</name><trkseg>
#[BODY]<trkpt lat="$gpslatitude#" lon="$gpslongitude#"><ele>$gpsaltitude#</ele><time>$gpsdatetime</time></trkpt>
#[TAIL]</trkseg></trk></gpx>
GPXEOF
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
# Basic CSV per-sample (track complet, nu doar 1 punct ca -csv) — mirror campuri GPX
DJI_BASIC_FMT=$(mktemp); DJI_NORM_FMT=$(mktemp)
cat <<'DJIBASICEOF' > "$DJI_BASIC_FMT"
#[HEAD]GPSDateTime,GPSLatitude,GPSLongitude,GPSAltitude
#[BODY]$gpsdatetime,$gpslatitude#,$gpslongitude#,$gpsaltitude#
DJIBASICEOF
# Norm source per-sample (pipe-delim, -f forteaza '-' pe lipsa); Python normalizeaza la 24 col
cat <<'DJINORMEOF' > "$DJI_NORM_FMT"
#[BODY]$sampletime#|$gpsdatetime|$gpslatitude#|$gpslongitude#|$gpsaltitude#|$accelerometerx#|$accelerometery#|$accelerometerz#|$pitch#|$roll#|$yaw#|$gimbalpitchdegree#|$gimbalrolldegree#|$gimbalyawdegree#
DJINORMEOF

# ── Python GPMF parser (GoPro) — scris ca temp file la nevoie ────────
GPMF_PY=""
write_gpmf_parser() {
    GPMF_PY=$(av_mktemp_ext py)
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

def _sensor_3axis_mean(strm_klvs, fourcc):
    # ACCL/GYRO: 3 valori per sample (ordine GoPro: z,x,y), scalate de SCAL.
    # Rata sample (~200Hz) >> rata GPS (~18Hz) → returnam media pe STRM-ul DEVC.
    scale = None; samples = []
    for fc, tc, ss, sc, payload in strm_klvs:
        if fc == 'SCAL':
            scale = unpack_scal(tc, ss, sc, payload)
        elif fc == fourcc:
            vals = unpack_scal(tc, ss, sc, payload)
            if vals:
                for i in range(0, len(vals) - 2, 3):
                    samples.append((vals[i], vals[i+1], vals[i+2]))
    if not samples: return None
    div = (scale[0] if scale else 1) or 1
    n = len(samples)
    return (sum(s[0] for s in samples)/n/div,
            sum(s[1] for s in samples)/n/div,
            sum(s[2] for s in samples)/n/div)

def _gps5_points(strm_klvs, strm_state):
    out = []
    for fc, tc, ss, sc, payload in strm_klvs:
        if fc != 'GPS5': continue
        scale = strm_state.get('scale') or [1,1,1,1,1]
        if len(scale) < 5: scale = list(scale) + [1]*(5-len(scale))
        for i in range(sc):
            if i*20+20 > len(payload): break
            vals = struct.unpack('>5i', payload[i*20:i*20+20])
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
            if strm_state.get('temp') is not None: p['temp'] = f"{strm_state['temp']:.1f}"
            if strm_state.get('devnm'): p['device'] = strm_state['devnm']
            fix_val = strm_state.get('fix', 0)
            if fix_val and fix_val < 2: continue
            try:
                if abs(float(p['lat'])) < 0.001 and abs(float(p['lon'])) < 0.001: continue
            except: continue
            out.append(p)
    return out

def _gps9_points(strm_klvs, strm_state):
    # GPS9 (Hero11+): per-sample struct 7×int32 + 2×uint16 = 32 bytes.
    # Ordine: lat,lon,alt,2Dspeed,3Dspeed,days_since_2000,secs_since_midnight,DOP,fix. SCAL = 9 divizori.
    from datetime import datetime as _dt, timedelta as _td
    out = []
    for fc, tc, ss, sc, payload in strm_klvs:
        if fc != 'GPS9': continue
        scale = strm_state.get('scale') or [1]*9
        if len(scale) < 9: scale = list(scale) + [1]*(9-len(scale))
        rec = ss if ss >= 32 else 32
        for i in range(sc):
            off = i*rec
            if off+32 > len(payload): break
            try:
                lat,lon,alt,sp2,sp3,days,secs = struct.unpack('>7i', payload[off:off+28])
                dop,fix = struct.unpack('>2H', payload[off+28:off+32])
            except: break
            def sd(v, idx):
                d = scale[idx] or 1; return v/d
            fix_v = int(sd(fix,8)) if scale[8] else int(fix)
            if fix_v and fix_v < 2: continue
            latf = sd(lat,0); lonf = sd(lon,1)
            try:
                if abs(latf) < 0.001 and abs(lonf) < 0.001: continue
            except: continue
            tstr = strm_state.get('time','')
            try:
                base = _dt(2000,1,1) + _td(days=sd(days,5), seconds=sd(secs,6))
                tstr = base.strftime('%Y-%m-%dT%H:%M:%S.') + f"{base.microsecond//1000:03d}Z"
            except: pass
            p = {
                'lat': f"{latf:.7f}", 'lon': f"{lonf:.7f}",
                'alt': f"{sd(alt,2):.2f}", 'speed': f"{sd(sp2,3):.2f}",
                'speed3d': f"{sd(sp3,4):.2f}", 'time': tstr,
                'fix': str(fix_v), 'dop': f"{sd(dop,7):.2f}",
            }
            if strm_state.get('temp') is not None: p['temp'] = f"{strm_state['temp']:.1f}"
            if strm_state.get('devnm'): p['device'] = strm_state['devnm']
            out.append(p)
    return out

def parse_gpmf(file_path):
    with open(file_path,'rb') as fh: data = fh.read()
    points = []
    state = {'scale':None,'time':'','fix':'','dop':'','temp':None,'devnm':''}
    for fc, tc, ss, sc, payload in parse_klv_stream(data):
        if fc == 'DEVC' and tc == '\x00':
            dev_state = dict(state)
            devc_points = []; accl_mean = None; gyro_mean = None
            for fc2, tc2, ss2, sc2, payload2 in parse_klv_stream(payload):
                if fc2 == 'DVNM':
                    dev_state['devnm'] = payload2.decode('ascii', errors='replace').rstrip('\x00').strip()
                elif fc2 == 'STRM' and tc2 == '\x00':
                    strm_klvs = list(parse_klv_stream(payload2))
                    fourccs = set(k[0] for k in strm_klvs)
                    if 'ACCL' in fourccs:
                        m = _sensor_3axis_mean(strm_klvs, 'ACCL')
                        if m: accl_mean = m
                        continue
                    if 'GYRO' in fourccs:
                        m = _sensor_3axis_mean(strm_klvs, 'GYRO')
                        if m: gyro_mean = m
                        continue
                    if not ('GPS5' in fourccs or 'GPS9' in fourccs):
                        continue
                    strm_state = dict(dev_state)
                    # Pre-pass: SCAL/GPSU/GPSF/GPSP/TMPC apply to GPS in same STRM
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
                    # GPS9 (Hero11+) preferat; GPS5 fallback
                    if 'GPS9' in fourccs:
                        devc_points.extend(_gps9_points(strm_klvs, strm_state))
                    else:
                        devc_points.extend(_gps5_points(strm_klvs, strm_state))
            # Stampam media ACCL/GYRO a DEVC-ului pe fiecare punct GPS din acelasi DEVC
            if accl_mean or gyro_mean:
                for p in devc_points:
                    if accl_mean:
                        p['gforce_z'] = f"{accl_mean[0]/9.80665:.3f}"
                        p['gforce_x'] = f"{accl_mean[1]/9.80665:.3f}"
                        p['gforce_y'] = f"{accl_mean[2]/9.80665:.3f}"
                    if gyro_mean:
                        p['gyro_z'] = f"{gyro_mean[0]:.4f}"
                        p['gyro_x'] = f"{gyro_mean[1]:.4f}"
                        p['gyro_y'] = f"{gyro_mean[2]:.4f}"
            points.extend(devc_points)
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
                'temp_c','hr_bpm','cadence_rpm','power_w',
                'pitch_deg','roll_deg','yaw_deg','fix_quality','num_sats','hdop',
                'source_brand']

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
            row['gforce_x']     = p.get('gforce_x','')
            row['gforce_y']     = p.get('gforce_y','')
            row['gforce_z']     = p.get('gforce_z','')
            row['gyro_x']       = p.get('gyro_x','')
            row['gyro_y']       = p.get('gyro_y','')
            row['gyro_z']       = p.get('gyro_z','')
            row['temp_c']       = p.get('temp','')
            row['hr_bpm']       = p.get('hr','')
            row['cadence_rpm']  = p.get('cad','')
            row['power_w']      = p.get('power','')
            row['pitch_deg']    = p.get('pitch','')
            row['roll_deg']     = p.get('roll','')
            row['yaw_deg']      = p.get('yaw','')
            row['fix_quality']  = p.get('fix_quality', p.get('fix',''))
            row['num_sats']     = p.get('num_sats','')
            row['hdop']         = p.get('hdop', p.get('dop',''))
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
                    if 78 in fv: p['alt']=f"{(fv[78]/5.0)-500:.2f}"
                    elif 2 in fv and fv[2]!=0xFFFF: p['alt']=f"{(fv[2]/5.0)-500:.2f}"
                    else: p['alt']=''
                    if 73 in fv: p['speed']=f"{fv[73]/1000.0:.2f}"
                    elif 6 in fv: p['speed']=f"{fv[6]/1000.0:.2f}"
                    else: p['speed']=''
                    p['time']=(FIT_EPOCH+timedelta(seconds=fv[253])).strftime('%Y-%m-%dT%H:%M:%SZ') if 253 in fv else ''
                    if 3 in fv: p['hr']=str(fv[3])
                    if 4 in fv: p['cad']=str(fv[4])
                    if 7 in fv: p['power']=str(fv[7])
                    if 13 in fv:
                        t=fv[13]
                        if t>127: t-=256
                        p['temp']=str(t)
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
            # parts[6]=fix_quality, [7]=num_sats, [8]=hdop, [9]=altitude
            try:
                if points:
                    last = points[-1]
                    if not last.get('alt'): last['alt'] = parts[9]
                    fq = parts[6].strip() if len(parts) > 6 else ''
                    ns = parts[7].strip() if len(parts) > 7 else ''
                    hd = parts[8].strip() if len(parts) > 8 else ''
                    if fq: last['fix_quality'] = fq
                    if ns: last['num_sats'] = ns
                    if hd: last['hdop'] = hd
            except: pass
        elif sentence in ('$GPVTG','$GNVTG') and len(parts) >= 8:
            # Track made good + ground speed. Used as fallback when RMC speed/heading missing.
            # parts[1]=track_true_deg, parts[5]=speed_knots, parts[7]=speed_kmh
            try:
                if points:
                    track_t = parts[1].strip() if len(parts) > 1 else ''
                    sp_kn = parts[5].strip() if len(parts) > 5 else ''
                    sp_kmh = parts[7].strip() if len(parts) > 7 else ''
                    last = points[-1]
                    if not last.get('heading') and track_t:
                        last['heading'] = track_t
                    sp_existing = last.get('speed', '')
                    if (not sp_existing or sp_existing == '0.00'):
                        if sp_kn:
                            try: last['speed'] = f"{float(sp_kn)*0.514444:.2f}"
                            except: pass
                        elif sp_kmh:
                            try: last['speed'] = f"{float(sp_kmh)/3.6:.2f}"
                            except: pass
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
            "$AV_TOOL_EXIFTOOL" -p "$GPX_FMT" -ee3 -api LargeFileSupport=1 "$file" > "$OUTPUT_DIR/${name}.gpx" 2>/dev/null
            # v85: fmt-ul are HEAD/TAIL → fisierul e non-gol si FARA puncte;
            # verifica trkpt real (altfel un clip fara GPS raporta [OK] pe schelet)
            if grep -q "<trkpt" "$OUTPUT_DIR/${name}.gpx" 2>/dev/null; then echo "  [OK] GPX: ${name}.gpx"
            else echo "  [SKIP] GPX: nu s-au gasit date GPS"; rm -f "$OUTPUT_DIR/${name}.gpx"; fi
            ;;
    esac
    case "$choice" in
        1|4)
            # Track complet per-sample (DJI protobuf): -p template, NU -csv (care colapseaza la 1 rand)
            "$AV_TOOL_EXIFTOOL" -p "$DJI_BASIC_FMT" -ee3 -api LargeFileSupport=1 "$file" > "$OUTPUT_DIR/${name}_basic.csv" 2>/dev/null
            # v85: header-only (fara randuri de date) = fara GPS → SKIP onest
            if [ "$(wc -l < "$OUTPUT_DIR/${name}_basic.csv" 2>/dev/null || echo 0)" -gt 1 ]; then echo "  [OK] CSV Basic: ${name}_basic.csv"
            else echo "  [SKIP] CSV Basic: nu s-au gasit date GPS"; rm -f "$OUTPUT_DIR/${name}_basic.csv"; fi
            ;;
    esac
    case "$choice" in
        2|4)
            "$AV_TOOL_EXIFTOOL" -ee3 -api LargeFileSupport=1 -csv -G -n "$file" > "$OUTPUT_DIR/${name}_FULL.csv" 2>/dev/null
            [ -s "$OUTPUT_DIR/${name}_FULL.csv" ] && echo "  [OK] CSV Full: ${name}_FULL.csv" || rm -f "$OUTPUT_DIR/${name}_FULL.csv"
            ;;
    esac
    # v85 (F3): SRT-ul DJI se genereaza din ACEEASI extractie per-sample ca norm CSV,
    # cu index + timpi RELATIVI reali (SampleTime) + downsample 1Hz. Vechiul template
    # exiftool producea SRT INVALID (fara index, timestamp-uri EXIF absolute cu
    # start==end) → ffmpeg il refuza → embed-ul (opt 7) pica pe DJI; pe clipuri
    # fara GPS ieseau doar linii goale raportate [OK].
    # CSV normalizat — extractie per-sample (track complet protobuf): GPS + accelerometru (g) +
    # orientare (modele care o expun). Viteza/heading calculate din delta GPS cu sampletime sub-secunda.
    local want_norm=0 want_srt=0
    case "$choice" in 1|2|4) want_norm=1 ;; esac
    case "$choice" in 3|4)   want_srt=1  ;; esac
    case "$choice" in
        1|2|3|4)
            local norm_src="$OUTPUT_DIR/${name}_normsrc.csv.tmp"
            "$AV_TOOL_EXIFTOOL" -p "$DJI_NORM_FMT" -f -ee3 -api LargeFileSupport=1 "$file" > "$norm_src" 2>/dev/null
            # SRT-ul e scris de python DOAR cand exista puncte → sterge un
            # eventual fisier vechi, altfel un stale ar trece drept [OK]
            [ "$want_srt" -eq 1 ] && rm -f "$OUTPUT_DIR/${name}.srt"
            if [ -s "$norm_src" ] && [ "$HAVE_PYTHON" -eq 1 ]; then
                python3 -c "
import sys, csv, math
from datetime import datetime, timedelta
NORM=['timestamp','lat','lon','alt_m','speed_mps','speed_kmh','heading_deg','gforce_x','gforce_y','gforce_z','gyro_x','gyro_y','gyro_z','temp_c','hr_bpm','cadence_rpm','power_w','pitch_deg','roll_deg','yaw_deg','fix_quality','num_sats','hdop','source_brand']
def num(s):
    s=(s or '').strip()
    if not s or s=='-': return None
    try: return float(s)
    except: return None
def hav(la1,lo1,la2,lo2):
    R=6371000.0; p1=math.radians(la1); p2=math.radians(la2)
    dp=math.radians(la2-la1); dl=math.radians(lo2-lo1)
    a=math.sin(dp/2)**2+math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return 2*R*math.asin(min(1.0,math.sqrt(a)))
def brg(la1,lo1,la2,lo2):
    p1=math.radians(la1); p2=math.radians(la2); dl=math.radians(lo2-lo1)
    y=math.sin(dl)*math.cos(p2); x=math.cos(p1)*math.sin(p2)-math.sin(p1)*math.cos(p2)*math.cos(dl)
    return (math.degrees(math.atan2(y,x))+360)%360
base=None; first_st=None; ld=None; lsp=0.0; lhd=''
want_norm=(sys.argv[4]=='1'); want_srt=(sys.argv[5]=='1')
pts=[]; srt_t0=None
with open(sys.argv[1], encoding='utf-8', errors='replace') as fi, open(sys.argv[2],'w',newline='',encoding='utf-8') as fo:
    w=csv.writer(fo); wrote=False
    for line in fi:
        p=line.rstrip('\r\n').split('|')
        if len(p)<5: continue
        lat=num(p[2]); lon=num(p[3])
        if lat is None or lon is None: continue
        st=num(p[0]); alt=num(p[4])
        gdt=(p[1] or '').strip()
        if base is None and gdt and gdt!='-':
            try: base=datetime.strptime(gdt[:19],'%Y:%m:%d %H:%M:%S')
            except: base=None
            first_st=st if st is not None else 0.0
        if base is not None and st is not None: ts=(base+timedelta(seconds=st-(first_st or 0.0))).isoformat()
        elif st is not None: ts='%.3f'%st
        else: ts=gdt
        if ld is None:
            sp=lsp; ld=(st,lat,lon)
        elif lat!=ld[1] or lon!=ld[2]:
            dt=(st-ld[0]) if (st is not None and ld[0] is not None) else 0
            if dt and dt>0:
                v=hav(ld[1],ld[2],lat,lon)/dt
                if 0<=v<=150.0: lsp=v; lhd='%.1f'%brg(ld[1],ld[2],lat,lon)
            ld=(st,lat,lon); sp=lsp
        else:
            sp=lsp
        out={c:'' for c in NORM}
        out['timestamp']=ts; out['lat']='%.7f'%lat; out['lon']='%.7f'%lon
        if alt is not None: out['alt_m']='%.3f'%alt
        out['speed_mps']='%.2f'%sp; out['speed_kmh']='%.2f'%(sp*3.6); out['heading_deg']=lhd
        gx=num(p[5]) if len(p)>5 else None; gy=num(p[6]) if len(p)>6 else None; gz=num(p[7]) if len(p)>7 else None
        if gx is not None: out['gforce_x']='%.4f'%gx
        if gy is not None: out['gforce_y']='%.4f'%gy
        if gz is not None: out['gforce_z']='%.4f'%gz
        pit=num(p[8]) if len(p)>8 else None
        if pit is None and len(p)>11: pit=num(p[11])
        rol=num(p[9]) if len(p)>9 else None
        if rol is None and len(p)>12: rol=num(p[12])
        yaw=num(p[10]) if len(p)>10 else None
        if yaw is None and len(p)>13: yaw=num(p[13])
        if pit is not None: out['pitch_deg']='%.2f'%pit
        if rol is not None: out['roll_deg']='%.2f'%rol
        if yaw is not None: out['yaw_deg']='%.2f'%yaw
        out['source_brand']='dji'
        if want_norm:
            if not wrote: w.writerow(NORM); wrote=True
            w.writerow([out[c] for c in NORM])
        if want_srt and st is not None:
            if srt_t0 is None: srt_t0=st
            pts.append((st-srt_t0, lat, lon, alt, sp))
if want_srt and pts:
    # downsample 1Hz (prima mostra din fiecare secunda) — DJI emite sub-secunda
    sel=[]; last_sec=None
    for r in pts:
        sec=int(r[0])
        if sec!=last_sec: sel.append(r); last_sec=sec
    def fmt_srt(t):
        if t<0: t=0.0
        ms=int(round((t-int(t))*1000)); s=int(t)
        if ms==1000: s+=1; ms=0
        return '%02d:%02d:%02d,%03d'%(s//3600,(s%3600)//60,s%60,ms)
    with open(sys.argv[3],'w',encoding='utf-8') as fs:
        n=len(sel)
        for i in range(n):
            r=sel[i]
            t1=sel[i+1][0] if i+1<n else r[0]+1.0
            alt_s=('%.1f'%r[3]) if r[3] is not None else 'N/A'
            fs.write('%d\n%s --> %s\n'%(i+1,fmt_srt(r[0]),fmt_srt(t1)))
            fs.write('Viteza: %.2f m/s | Alt: %sm\n'%(r[4],alt_s))
            fs.write('Coord: %.7f, %.7f\n\n'%(r[1],r[2]))
" "$norm_src" "$OUTPUT_DIR/${name}_norm.csv" "$OUTPUT_DIR/${name}.srt" "$want_norm" "$want_srt" 2>/dev/null
                if [ "$want_norm" -eq 1 ]; then
                    [ -s "$OUTPUT_DIR/${name}_norm.csv" ] && echo "  [OK] CSV Norm: ${name}_norm.csv" || rm -f "$OUTPUT_DIR/${name}_norm.csv"
                else
                    rm -f "$OUTPUT_DIR/${name}_norm.csv"
                fi
                if [ "$want_srt" -eq 1 ]; then
                    if [ -s "$OUTPUT_DIR/${name}.srt" ]; then echo "  [OK] SRT: ${name}.srt"
                    else echo "  [SKIP] SRT: nu s-au gasit date GPS"; rm -f "$OUTPUT_DIR/${name}.srt"; fi
                fi
            else
                [ "$want_srt" -eq 1 ] && echo "  [SKIP] SRT: nu s-au gasit date GPS (sau python3 lipseste)"
                [ "$want_norm" -eq 1 ] && [ "$HAVE_PYTHON" -eq 0 ] && echo "  [SKIP] CSV Norm: python3 lipseste"
            fi
            rm -f "$norm_src"
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
    local out_clean="$OUTPUT_DIR/${name}_clean.${ext}"
    # v85 (F4): muxer-ul MOV/MP4 REGENEREAZA un track tmcd din metadata de timecode
    # a pistei video chiar cu -dn (dropul afecteaza doar pistele de INPUT) → fara
    # -write_tmcd 0 output-ul "curat" contine tot un tmcd, desi meniul promite
    # eliminarea lui. Optiunea e a muxer-ului mov → doar pe mp4/mov/m4v.
    local tmcd_flag=""
    case "${ext,,}" in mp4|mov|m4v) tmcd_flag="-write_tmcd 0" ;; esac

    if [ "$STRIP_MODE" == "3" ]; then
        # v78: PASTREAZA GPS-ul nativ (djmd). ffmpeg singur nu il poate re-muxa →
        # producem o baza curata (video real v:0 + audio, FARA cover/date) apoi grefam
        # djmd inapoi cu MP4Box (_dji_graft_native_meta din av_common.sh). Reverseaza
        # restrictia v71 — pe MP4/MOV GPS-ul nativ POATE ramane, prin MP4Box (nu ffmpeg).
        ffmpeg -v error -i "$file" -map 0:v:0 -map 0:a? -c copy -dn $tmcd_flag -map_metadata 0 "$out_clean" -y </dev/null 2>/dev/null
        if [ $? -ne 0 ] || [ ! -s "$out_clean" ]; then
            echo "  [EROARE] Remux esuat"; rm -f "$out_clean"; return
        fi
        if _dji_graft_native_meta "$file" "$out_clean"; then
            echo "  [OK] ${name}_clean.${ext} ($(du -h "$file" | cut -f1) → $(du -h "$out_clean" | cut -f1))"
            echo "  Notă: GPS nativ DJI (djmd) PASTRAT via MP4Box; cover eliminat."
        else
            echo "  [OK] ${name}_clean.${ext} (cover eliminat)"
            echo "  Notă: GPS nativ NU a putut fi pastrat (MP4Box lipseste/esec) → telemetria"
            echo "        s-a pierdut. Instaleaza MP4Box (installer in tools/) sau extrage"
            echo "        GPS-ul cu optiunile 1-5 din meniul telemetrie."
        fi
        return
    fi

    # -dn: pistele de date DJI (djmd/dbgi/tmcd) sunt codec=none → ffmpeg NU le poate
    # re-muxa (-c copy esueaza: "tag for codec none" pe MP4 / "Only ... Matroska" pe
    # MKV). Le eliminam mereu; GPS-ul se extrage separat (opt 1-5) sau se pastreaza cu
    # opt 3 (MP4Box). v71 audit: inainte modurile ffmpeg care PASTRAU date esuau pe DJI.
    local maps="-map 0 -dn"
    if [ "$STRIP_MODE" == "2" ]; then
        # mode 2: elimina si cover-ul (mjpeg/jpeg — pista video secundara). NB: codec_tag
        # al cover-ului DJI e [0][0][0][0] → detectam dupa codec_NAME, nu tag. Index ABSOLUT.
        local _vidx _vcodec
        while IFS=, read -r _vidx _vcodec; do
            _vidx="${_vidx%$'\r'}"; _vcodec="${_vcodec%$'\r'}"
            [[ "$_vcodec" =~ ^(mjpeg|jpeg|png)$ ]] && maps="$maps -map -0:$_vidx"
        done < <(ffprobe -v error -select_streams v -show_entries stream=index,codec_name -of csv=p=0 "$file" 2>/dev/null)
    fi
    ffmpeg -v error -i "$file" $maps -c copy $tmcd_flag -map_metadata 0 "$out_clean" -y </dev/null 2>/dev/null
    if [ $? -eq 0 ] && [ -s "$out_clean" ]; then
        echo "  [OK] ${name}_clean.${ext} ($(du -h "$file" | cut -f1) → $(du -h "$out_clean" | cut -f1))"
        echo "  Notă: telemetria DJI (djmd/dbgi/tmcd) eliminata (ffmpeg nu o re-muxeaza); GPS via opt 1-5."
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
            local maps="-map 0 -dn"   # -dn: data proprietar (gpmd) e codec=none → ne-re-muxabil
            local local_idx=0
            while IFS= read -r tag; do
                if echo "$tag" | grep -qi "gpmd"; then maps="$maps -map -0:$local_idx"; fi
                local_idx=$((local_idx + 1))
            done < <(ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 "$file" 2>/dev/null)
            local out_clean="$OUTPUT_DIR/${name}_clean.${ext}"
            # v85 (F4): -write_tmcd 0 pe mp4/mov — muxer-ul regenereaza tmcd altfel
            local tmcd_flag=""
            case "${ext,,}" in mp4|mov|m4v) tmcd_flag="-write_tmcd 0" ;; esac
            ffmpeg -v error -i "$file" $maps -c copy $tmcd_flag -map_metadata 0 "$out_clean" -y </dev/null 2>/dev/null
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
    local ext="${file##*.}"; local maps="-map 0 -dn"; local local_idx=0   # -dn: data codec=none ne-re-muxabil
    while IFS= read -r tag; do
        if echo "$tag" | grep -qiE "$tag_re"; then maps="$maps -map -0:$local_idx"; fi
        local_idx=$((local_idx + 1))
    done < <(ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 "$file" 2>/dev/null)
    local out_clean="$OUTPUT_DIR/${name}_clean.${ext}"
    # v85 (F4): -write_tmcd 0 pe mp4/mov — muxer-ul regenereaza tmcd altfel
    local tmcd_flag=""
    case "${ext,,}" in mp4|mov|m4v) tmcd_flag="-write_tmcd 0" ;; esac
    ffmpeg -v error -i "$file" $maps -c copy $tmcd_flag -map_metadata 0 "$out_clean" -y </dev/null 2>/dev/null
    if [ $? -eq 0 ] && [ -s "$out_clean" ]; then
        echo "  [OK] ${name}_clean.${ext} ($(du -h "$file" | cut -f1) → $(du -h "$out_clean" | cut -f1))"
    else echo "  [EROARE] Remux esuat"; rm -f "$out_clean"; fi
}

# ── Embed lossless — atașeaza telemetria in container ───────────────
# Profile (EMBED_PROFILE): srt | srt_csv | srt_csv_gpx | all
# Output: $OUTPUT_DIR/<name>_telem.<ext>; sursa neatinsa.
# Genereaza KML din _norm.csv (fallback non-DJI; DJI primeste KML din exiftool)
_gen_kml_from_norm_csv() {
    local csv="$1" kml="$2" track_name="$3"
    [[ ! -s "$csv" ]] && return 1
    python3 -c "
import csv, sys, html
name = html.escape(sys.argv[3])
with open(sys.argv[1], newline='') as fi:
    r = csv.DictReader(fi)
    coords = []
    for row in r:
        lat = row.get('lat','').strip(); lon = row.get('lon','').strip()
        alt = row.get('alt_m','').strip() or '0'
        if not lat or not lon: continue
        coords.append(f'{lon},{lat},{alt}')
if not coords: sys.exit(1)
with open(sys.argv[2], 'w') as fo:
    fo.write('<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n')
    fo.write('<kml xmlns=\"http://www.opengis.net/kml/2.2\">\n')
    fo.write(f'<Document><name>{name}</name>\n')
    fo.write('<Style id=\"track\"><LineStyle><color>ff0000ff</color><width>3</width></LineStyle></Style>\n')
    fo.write(f'<Placemark><name>{name}</name><styleUrl>#track</styleUrl>\n')
    fo.write('<LineString><altitudeMode>absolute</altitudeMode><coordinates>\n')
    fo.write(' '.join(coords))
    fo.write('\n</coordinates></LineString></Placemark></Document></kml>\n')
" "$csv" "$kml" "$track_name" 2>/dev/null
    [[ -s "$kml" ]]
}

embed_telemetry_lossless() {
    local file="$1" name="$2"
    local src_ext="${file##*.}"; src_ext="${src_ext,,}"
    local profile="${EMBED_PROFILE:-srt_csv_gpx}"

    local srt_file="$OUTPUT_DIR/${name}.srt"
    local csv_norm="$OUTPUT_DIR/${name}_norm.csv"
    local csv_basic="$OUTPUT_DIR/${name}_basic.csv"
    local csv_full="$OUTPUT_DIR/${name}_FULL.csv"
    local gpx_file="$OUTPUT_DIR/${name}.gpx"
    local kml_file="$OUTPUT_DIR/${name}.kml"

    # Pentru profilul `all`: genereaza KML daca lipseste (DJI prin exiftool, restul prin python)
    if [[ "$profile" == "all" && ! -s "$kml_file" ]]; then
        if [[ -s "$file" ]] && command -v "$AV_TOOL_EXIFTOOL" &>/dev/null && \
           ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 "$file" 2>/dev/null | grep -qiE 'djmd|dbgi'; then
            "$AV_TOOL_EXIFTOOL" -p "$KML_FMT" -ee3 -api LargeFileSupport=1 "$file" > "$kml_file" 2>/dev/null
            [[ -s "$kml_file" ]] || rm -f "$kml_file"
        fi
        if [[ ! -s "$kml_file" && -s "$csv_norm" ]]; then
            _gen_kml_from_norm_csv "$csv_norm" "$kml_file" "$name"
        fi
    fi

    # Selecteaza artefactele in functie de profil
    local has_srt=0 want_csv_norm=0 want_csv_basic=0 want_csv_full=0 want_gpx=0 want_kml=0
    [[ -s "$srt_file" ]] && has_srt=1
    case "$profile" in
        srt)         : ;;  # doar SRT
        srt_csv)     [[ -s "$csv_norm" ]] && want_csv_norm=1 ;;
        srt_csv_gpx) [[ -s "$csv_norm" ]] && want_csv_norm=1; [[ -s "$gpx_file" ]] && want_gpx=1 ;;
        all)
            [[ -s "$csv_norm"  ]] && want_csv_norm=1
            [[ -s "$csv_basic" ]] && want_csv_basic=1
            [[ -s "$csv_full"  ]] && want_csv_full=1
            [[ -s "$gpx_file"  ]] && want_gpx=1
            [[ -s "$kml_file"  ]] && want_kml=1
            ;;
    esac
    local total_artifacts=$((has_srt + want_csv_norm + want_csv_basic + want_csv_full + want_gpx + want_kml))
    if [[ $total_artifacts -eq 0 ]]; then
        echo "  [SKIP] Embed: nu exista artefacte de embed pentru profilul '$profile'"
        return 1
    fi

    # Container decision (per profil)
    local target_ext="mkv"
    case "$profile" in
        srt)
            # SRT-only: respecta containerul sursa (mov_text pe MP4/MOV, srt pe MKV)
            case "$src_ext" in
                mkv|mp4|mov|m4v) target_ext="$src_ext" ;;
                *) target_ext="mkv" ;;
            esac
            ;;
        all)
            # MKV mandatory pentru profilul Toate (attachments necesare)
            target_ext="mkv"
            ;;
        srt_csv|srt_csv_gpx)
            case "$src_ext" in
                mkv) target_ext="mkv" ;;
                mp4|mov|m4v)
                    echo ""
                    echo "  Sursa este .$src_ext — MP4/MOV nu suporta attachments (CSV/GPX)."
                    echo "    1) Convert la MKV — embed total [recomandat]"
                    echo "    2) Pastreaza .$src_ext — doar SRT (mov_text); CSV/GPX raman side-files"
                    echo "    3) Skip embed pentru acest fisier"
                    read -p "  Alege 1-3 [implicit: 1]: " _emb_ch
                    case "${_emb_ch:-1}" in
                        1) target_ext="mkv" ;;
                        2) target_ext="$src_ext" ;;
                        3) echo "  Embed sarit"; return 0 ;;
                        *) target_ext="mkv" ;;
                    esac
                    ;;
                *) target_ext="mkv" ;;
            esac
            ;;
    esac

    local out="$OUTPUT_DIR/${name}_telem.${target_ext}"

    # v73 (T2): pe sursa DV + output non-MKV, dvcC de container se pierde (ffmpeg il pastreaza
    # DOAR la →MKV). Embed-ul ramane lossless (RPU e in bitstream → PC vede DV), dar TV-ul va
    # reda HDR10. Avertizam onest (re-signal automat se face pe encode/concat/mux, nu aici —
    # telemetria e standalone; cazul DV+telemetrie e niche, iar default-ul MKV il acopera).
    if [[ "$target_ext" != "mkv" ]] && ffprobe -v error -select_streams v:0 \
            -show_entries stream_side_data=side_data_type -of default=noprint_wrappers=1:nokey=1 \
            "$file" 2>/dev/null | grep -qi "DOVI"; then
        echo ""
        echo "  ⚠ Sursa are Dolby Vision: pe .$target_ext semnalizarea DV de container (dvcC) se"
        echo "    pierde → TV-ul va reda HDR10. Pentru DV pe TV, pastreaza output-ul MKV (default)."
    fi

    # Build ffmpeg args
    local -a ff_args=(-v error -i "$file")
    # NU mapam pista de date sursa (djmd/dbgi/tmcd/gpmd): ffmpeg le vede ca
    # `codec=none` (proprietare DJI/GoPro) → `-c copy` esueaza ("Could not find
    # tag for codec none" pe MP4; "Only audio/video/subtitles supported" pe MKV)
    # → embed-ul pica complet. `-dn` le elimina; telemetria e oricum re-exprimata
    # ca SRT + CSV + GPX + KML. Raw-ul brut se obtine separat (optiunile 5/Raw).
    local -a ff_maps=(-map "0:v" -map "0:a?")
    local -a ff_meta=()
    local subs_codec="copy"

    if [[ $has_srt -eq 1 ]]; then
        ff_args+=(-i "$srt_file")
        ff_maps+=(-map "1:s")
        if [[ "$target_ext" == "mkv" ]]; then subs_codec="srt"; else subs_codec="mov_text"; fi
        ff_meta+=("-metadata:s:s:0" "title=Telemetry" "-metadata:s:s:0" "language=eng")
    fi

    # Attachments — MKV only
    if [[ "$target_ext" == "mkv" ]]; then
        local att_idx=0
        if [[ $want_csv_norm -eq 1 ]]; then
            ff_args+=(-attach "$csv_norm")
            ff_meta+=("-metadata:s:t:${att_idx}" "mimetype=text/csv")
            att_idx=$((att_idx+1))
        fi
        if [[ $want_csv_basic -eq 1 ]]; then
            ff_args+=(-attach "$csv_basic")
            ff_meta+=("-metadata:s:t:${att_idx}" "mimetype=text/csv")
            att_idx=$((att_idx+1))
        fi
        if [[ $want_csv_full -eq 1 ]]; then
            ff_args+=(-attach "$csv_full")
            ff_meta+=("-metadata:s:t:${att_idx}" "mimetype=text/csv")
            att_idx=$((att_idx+1))
        fi
        if [[ $want_gpx -eq 1 ]]; then
            ff_args+=(-attach "$gpx_file")
            ff_meta+=("-metadata:s:t:${att_idx}" "mimetype=application/gpx+xml")
            att_idx=$((att_idx+1))
        fi
        if [[ $want_kml -eq 1 ]]; then
            ff_args+=(-attach "$kml_file")
            ff_meta+=("-metadata:s:t:${att_idx}" "mimetype=application/vnd.google-earth.kml+xml")
            att_idx=$((att_idx+1))
        fi
    fi

    ff_args+=("${ff_maps[@]}" -dn -c:v copy -c:a copy)
    [[ $has_srt -eq 1 ]] && ff_args+=(-c:s "$subs_codec")
    ff_args+=("${ff_meta[@]}")
    case "$target_ext" in
        mp4|mov|m4v)
            # v57: tag codec_tag pe MP4/MOV — stream copy pastreaza tag-ul sursei
            # (adesea hev1) → playere DV-aware nu engaja DV. Aplicam tag-ul corect.
            local _src_codec; _src_codec=$(detect_source_codec "$file")
            local _telem_tag; _telem_tag=$(codec_tag_for_container "$_src_codec" "$target_ext")
            [[ -n "$_telem_tag" ]] && ff_args+=($_telem_tag)
            ff_args+=(-movflags +faststart)
            ;;
    esac
    ff_args+=("$out" -y)

    if ffmpeg "${ff_args[@]}" </dev/null 2>/dev/null; then
        local size_str=""
        size_str=$(du -h "$out" 2>/dev/null | cut -f1)
        local emb_str=""
        [[ $has_srt -eq 1 ]] && emb_str+=" SRT"
        if [[ "$target_ext" == "mkv" ]]; then
            [[ $want_csv_norm  -eq 1 ]] && emb_str+=" norm"
            [[ $want_csv_basic -eq 1 ]] && emb_str+=" basic"
            [[ $want_csv_full  -eq 1 ]] && emb_str+=" FULL"
            [[ $want_gpx       -eq 1 ]] && emb_str+=" GPX"
            [[ $want_kml       -eq 1 ]] && emb_str+=" KML"
        fi
        echo "  [OK] Embed [$profile]: ${name}_telem.${target_ext} ($size_str) —${emb_str}"
        return 0
    else
        echo "  [EROARE] Embed esuat"
        rm -f "$out"
        return 1
    fi
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
            lat=$("$AV_TOOL_EXIFTOOL" -s3 -api LargeFileSupport=1 -n -GPSLatitude "$file" 2>/dev/null)
            lon=$("$AV_TOOL_EXIFTOOL" -s3 -api LargeFileSupport=1 -n -GPSLongitude "$file" 2>/dev/null)
            alt=$("$AV_TOOL_EXIFTOOL" -s3 -api LargeFileSupport=1 -n -GPSAltitude "$file" 2>/dev/null)
            dt=$("$AV_TOOL_EXIFTOOL" -s3 -api LargeFileSupport=1 -CreateDate "$file" 2>/dev/null | head -1)
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
                    echo "timestamp,lat,lon,alt_m,speed_mps,speed_kmh,heading_deg,gforce_x,gforce_y,gforce_z,gyro_x,gyro_y,gyro_z,temp_c,hr_bpm,cadence_rpm,power_w,pitch_deg,roll_deg,yaw_deg,fix_quality,num_sats,hdop,source_brand"
                    echo "$ts,$lat,$lon,$alt,,,,,,,,,,,,,,,,,,,,quicktime"
                } > "$OUTPUT_DIR/${name}_norm.csv"
                echo "  [OK] CSV Norm: ${name}_norm.csv (1 punct)"
            fi
            if [ "$choice" == "2" ] || [ "$choice" == "4" ]; then
                "$AV_TOOL_EXIFTOOL" -api LargeFileSupport=1 -csv -G -n "$file" > "$OUTPUT_DIR/${name}_FULL.csv" 2>/dev/null
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
        6)  echo "  [INFO] QuickTime: foloseste $AV_TOOL_EXIFTOOL -gps:all= pentru a sterge tag-urile (fara remux)" ;;
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

    # dupa extractie, embed in container daca user a ales opt 7
    if [ "$EMBED_AFTER" == "1" ] && [ "$brand" != "unknown" ]; then
        embed_telemetry_lossless "$file" "$name"
    fi
done

# ── Curatenie ────────────────────────────────────────────────────────
rm -f "$GPX_FMT" "$KML_FMT" "$DJI_BASIC_FMT" "$DJI_NORM_FMT"
[ -n "$GPMF_PY" ] && rm -f "$GPMF_PY"

echo ""
echo "═══════════════════════════════════════"
echo "FINALIZAT — $DONE fisiere procesate"
echo "Output: $OUTPUT_DIR"
echo "═══════════════════════════════════════"
