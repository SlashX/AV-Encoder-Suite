# ══════════════════════════════════════════════════════════════════════
# av_telemetry.ps1 — Extractor unificat de telemetrie (Windows/PowerShell)
# v40: Suport DJI + GoPro (GPMF). Sony/Garmin VIRB/QuickTime — chunk-uri ulterioare.
# Rulare: powershell -ExecutionPolicy Bypass -File av_telemetry.ps1
# ══════════════════════════════════════════════════════════════════════

# ── Verificare ffmpeg/ffprobe ────────────────────────────────────────
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "[EROARE] ffmpeg nu a fost gasit." -ForegroundColor Red
    Write-Host "Download: https://ffmpeg.org/download.html"
    Read-Host; exit
}
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "[EROARE] ffprobe nu a fost gasit." -ForegroundColor Red
    Read-Host; exit
}

$InputDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutputDir = Join-Path $InputDir "output"
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }

function Format-Bytes {
    param([long]$bytes)
    if ($bytes -ge 1GB) { "{0:N2} GB" -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { "{0:N2} MB" -f ($bytes / 1MB) }
    elseif ($bytes -ge 1KB) { "{0:N2} KB" -f ($bytes / 1KB) }
    else { "$bytes B" }
}

# ── Detect brand per fisier (codec_tag scan) ─────────────────────────
function Get-TelemetryBrand {
    param([string]$file, [string]$exifCmd = $null)
    $tags = & ffprobe -v error -show_entries stream=codec_tag_string,codec_name -of csv=p=0 $file 2>$null
    if ($tags | Where-Object { $_ -imatch "djmd|dbgi" }) { return "dji" }
    if ($tags | Where-Object { $_ -imatch "gpmd" })      { return "gopro" }
    if ($tags | Where-Object { $_ -imatch "fdsc" })      { return "garmin" }
    if ($tags | Where-Object { $_ -imatch "nmea|sony" }) { return "sony" }
    # Fallback: ISO 6709 single-point GPS (Apple/Samsung/Android stock)
    if (-not $exifCmd) {
        if (Get-Command "exiftool" -ErrorAction SilentlyContinue) { $exifCmd = "exiftool" }
        elseif (Test-Path (Join-Path $PSScriptRoot "exiftool.exe")) { $exifCmd = Join-Path $PSScriptRoot "exiftool.exe" }
    }
    if ($exifCmd) {
        $loc = & $exifCmd -s3 -api LargeFileSupport=1 -GPSLatitude $file 2>$null
        if ($loc) { return "quicktime" }
    }
    return "unknown"
}

function Get-TelemetryTrackIdx {
    param([string]$file, [string]$tag)
    $idx = 0
    $tags = & ffprobe -v error -show_entries stream=codec_tag_string,codec_name -of csv=p=0 $file 2>$null
    foreach ($t in $tags) {
        if ($t -imatch $tag) { return $idx }
        $idx++
    }
    return -1
}

# ── Scanare fisiere video ────────────────────────────────────────────
$videoExt = @("*.mp4","*.mov","*.mkv","*.m2ts","*.mts","*.vob","*.mxf","*.apv","*.360","*.lrv")
$inputFiles = Get-ChildItem -Path $InputDir -Include $videoExt -File -ErrorAction SilentlyContinue
$fileCount = ($inputFiles | Measure-Object).Count
if ($fileCount -eq 0) {
    Write-Host "Nu am gasit fisiere video in $InputDir" -ForegroundColor Red
    Read-Host; exit
}

# ── Pre-scan: clasificare brand ──────────────────────────────────────
Write-Host "`nScanare brand telemetrie..." -ForegroundColor Yellow
# Pre-resolve exiftool to use during pre-scan (for QuickTime fallback detection)
$exifProbe = $null
if (Get-Command "exiftool" -ErrorAction SilentlyContinue) { $exifProbe = "exiftool" }
elseif (Test-Path (Join-Path $PSScriptRoot "exiftool.exe")) { $exifProbe = Join-Path $PSScriptRoot "exiftool.exe" }

$brands = @{}
$djiCount = 0; $goproCount = 0; $sonyCount = 0; $garminCount = 0; $qtCount = 0; $unknownCount = 0
foreach ($f in $inputFiles) {
    $b = Get-TelemetryBrand $f.FullName $exifProbe
    $brands[$f.FullName] = $b
    switch ($b) {
        "dji"       { $djiCount++ }
        "gopro"     { $goproCount++ }
        "sony"      { $sonyCount++ }
        "garmin"    { $garminCount++ }
        "quicktime" { $qtCount++ }
        "unknown"   { $unknownCount++ }
    }
}

Write-Host "`n╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  TELEMETRY EXTRACTOR                         ║" -ForegroundColor Cyan
Write-Host "║  (DJI / GoPro / Sony / Garmin VIRB / QT)     ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Total : $fileCount  | DJI: $djiCount  GoPro: $goproCount  Sony: $sonyCount" -ForegroundColor White
Write-Host "║  Garmin: $garminCount  QuickTime: $qtCount  ?: $unknownCount" -ForegroundColor White
Write-Host "║  Input   : $InputDir" -ForegroundColor White
Write-Host "║  Output  : $OutputDir" -ForegroundColor White
Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  1) Standard (GPX + CSV esential)            ║" -ForegroundColor White
Write-Host "║  2) Full Data (GPX + CSV TOATE metadatele)   ║" -ForegroundColor White
Write-Host "║  3) Subtitrare (.SRT pentru VLC)             ║" -ForegroundColor White
Write-Host "║  4) Totul (GPX + CSV + SRT)                  ║" -ForegroundColor White
Write-Host "║  5) Raw streams (DJI:djmd/dbgi/tmcd/cover    ║" -ForegroundColor White
Write-Host "║      GoPro:gpmf  Sony:nmea  Garmin:fit)      ║" -ForegroundColor White
Write-Host "║  6) Elimina metadata (remux fara re-encode)  ║" -ForegroundColor White
Write-Host "║  7) Anulare                                  ║" -ForegroundColor White
Write-Host "║  Nota: QuickTime are 1 punct GPS (start)     ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
$choice = Read-Host "Alege 1-7 [implicit: 1]"
if (-not $choice) { $choice = "1" }
if ($choice -eq "7") { exit }

# Sub-dialog strip metadata (optiunea 6)
$stripMode = ""
if ($choice -eq "6") {
    Write-Host "`n╔══════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║  ELIMINA METADATA (REMUX FARA RE-ENCODE)     ║" -ForegroundColor Yellow
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Yellow
    Write-Host "║  DJI:                                         ║" -ForegroundColor White
    Write-Host "║   1) Doar debug (dbgi ~295 MB) [implicit]     ║" -ForegroundColor White
    Write-Host "║   2) GPS + debug (djmd + dbgi)                ║" -ForegroundColor White
    Write-Host "║   3) Tot (djmd + dbgi + tmcd + cover)         ║" -ForegroundColor White
    Write-Host "║  GoPro/Sony/Garmin: orice optiune sterge      ║" -ForegroundColor White
    Write-Host "║   track-ul de telemetrie (gpmd/nmea/fdsc)     ║" -ForegroundColor White
    Write-Host "║   4) Anulare                                  ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Yellow
    $stripMode = Read-Host "Alege 1-4 [implicit: 1]"
    if (-not $stripMode) { $stripMode = "1" }
    if ($stripMode -eq "4") { exit }
}

# ── Verificare dependente conditional ────────────────────────────────
$exifCmd = $null; $py3 = $null
$gpxFmt = $null; $srtFmt = $null

$needExif = (($djiCount -gt 0) -or ($qtCount -gt 0)) -and ($choice -in @("1","2","3","4"))
$needPy   = (($goproCount -gt 0) -or ($sonyCount -gt 0) -or ($garminCount -gt 0)) -and ($choice -in @("1","2","3","4"))
# Soft Python detection pentru DJI norm CSV (nu blocant)
$wantPyDjiNorm = ($djiCount -gt 0) -and ($choice -in @("1","2","4")) -and (-not $needPy)

if ($needExif) {
    if (Get-Command "exiftool" -ErrorAction SilentlyContinue) { $exifCmd = "exiftool" }
    elseif (Test-Path (Join-Path $PSScriptRoot "exiftool.exe")) { $exifCmd = Join-Path $PSScriptRoot "exiftool.exe" }
    else {
        Write-Host "[EROARE] ExifTool nu a fost gasit (necesar pentru DJI)." -ForegroundColor Red
        Write-Host "Descarca de pe https://exiftool.org/" -ForegroundColor Yellow
        Read-Host; exit
    }
    Write-Host "[OK] ExifTool gasit." -ForegroundColor Green

    $gpxFmt = Join-Path $OutputDir "gpx.fmt"
    @'
#[HEAD]<?xml version="1.0" encoding="utf-8"?>
#[HEAD]<gpx version="1.0" creator="ExifTool $[ExifToolVersion]" xmlns="http://www.topografix.com/GPX/1/0">
#[HEAD]<trk><name>$filename</name><trkseg>
#[BODY]<trkpt lat="$gpslatitude#" lon="$gpslongitude#"><ele>$gpsaltitude#</ele><time>$gpsdatetime</time></trkpt>
#[TAIL]</trkseg></trk></gpx>
'@ | Out-File $gpxFmt -Encoding ASCII

    $srtFmt = Join-Path $OutputDir "srt.fmt"
    @'
#[BODY]${self:SampleIndex}
#[BODY]${gpsdatetime} --> ${gpsdatetime}
#[BODY]Viteza: ${gpsspeed#} m/s | Alt: ${gpsaltitude#}m
#[BODY]Coord: ${gpslatitude#}, ${gpslongitude#}
#[BODY]
'@ | Out-File $srtFmt -Encoding ASCII
}

if ($needPy) {
    if (Get-Command "python3" -ErrorAction SilentlyContinue) { $py3 = "python3" }
    elseif (Get-Command "python" -ErrorAction SilentlyContinue) {
        $pyVer = & python --version 2>&1
        if ($pyVer -match "3\.") { $py3 = "python" }
    }
    if (-not $py3) {
        Write-Host "[EROARE] Python3 nu este instalat (necesar pentru parser GoPro GPMF)." -ForegroundColor Red
        Write-Host "Download: https://python.org/downloads/" -ForegroundColor Yellow
        Read-Host; exit
    }
    Write-Host "[OK] Python3 gasit ($py3)." -ForegroundColor Green
}

if ($wantPyDjiNorm) {
    if (Get-Command "python3" -ErrorAction SilentlyContinue) { $py3 = "python3" }
    elseif (Get-Command "python" -ErrorAction SilentlyContinue) {
        $pyVer = & python --version 2>&1
        if ($pyVer -match "3\.") { $py3 = "python" }
    }
    if (-not $py3) {
        Write-Host "[INFO] Python3 nu este disponibil — norm.csv (CSV unificat) va fi sarit pentru DJI." -ForegroundColor DarkYellow
    }
}

# ── GPMF parser Python — scris in temp ───────────────────────────────
$gpmfPy = $null
if ($needPy) {
    $gpmfPy = Join-Path $env:TEMP "av_gpmf_$(Get-Random).py"
    @"
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
                                fix_val = strm_state.get('fix', 0)
                                if fix_val and fix_val < 2: continue
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

# CSV normalizat (schema unificata cross-brand)
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

# FIT parser (Garmin VIRB)
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

# NMEA parser (Sony Action Cam)
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
        if sentence in ('`$GPRMC','`$GNRMC') and len(parts) >= 10:
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
        elif sentence in ('`$GPGGA','`$GNGGA') and len(parts) >= 10:
            try:
                alt = parts[9]
                if points and not points[-1].get('alt'): points[-1]['alt'] = alt
            except: pass
    return points

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
"@ | Out-File $gpmfPy -Encoding UTF8
}

# ── Process functions ────────────────────────────────────────────────
function Process-DJI {
    param([System.IO.FileInfo]$f, [string]$name)
    if ($choice -in @("1","2","4")) {
        & $exifCmd -p $gpxFmt -ee3 -api LargeFileSupport=1 $f.FullName 2>$null |
            Out-File (Join-Path $OutputDir "$name.gpx") -Encoding UTF8
        $gpxOut = Join-Path $OutputDir "$name.gpx"
        if ((Test-Path $gpxOut) -and (Get-Item $gpxOut).Length -gt 0) {
            Write-Host "  [OK] GPX: $name.gpx" -ForegroundColor Green
        } else {
            Write-Host "  [SKIP] GPX: nu s-au gasit date GPS" -ForegroundColor DarkGray
            Remove-Item $gpxOut -Force -ErrorAction SilentlyContinue
        }
    }
    if ($choice -in @("1","4")) {
        & $exifCmd -ee3 -api LargeFileSupport=1 -csv -n `
            -GPSLatitude -GPSLongitude -GPSAltitude `
            -GPSSpeed -GPSTrack -GPSDateTime `
            $f.FullName 2>$null |
            Out-File (Join-Path $OutputDir "${name}_basic.csv") -Encoding UTF8
        Write-Host "  [OK] CSV Basic: ${name}_basic.csv" -ForegroundColor Green
    }
    if ($choice -in @("2","4")) {
        & $exifCmd -ee3 -api LargeFileSupport=1 -csv -G -n `
            $f.FullName 2>$null |
            Out-File (Join-Path $OutputDir "${name}_FULL.csv") -Encoding UTF8
        Write-Host "  [OK] CSV Full: ${name}_FULL.csv" -ForegroundColor Green
    }
    if ($choice -in @("3","4")) {
        & $exifCmd -p $srtFmt -ee3 -api LargeFileSupport=1 $f.FullName 2>$null |
            Out-File (Join-Path $OutputDir "$name.srt") -Encoding UTF8
        $srtOut = Join-Path $OutputDir "$name.srt"
        if ((Test-Path $srtOut) -and (Get-Item $srtOut).Length -gt 0) {
            Write-Host "  [OK] SRT: $name.srt" -ForegroundColor Green
        } else {
            Write-Host "  [SKIP] SRT: nu s-au gasit date GPS" -ForegroundColor DarkGray
            Remove-Item $srtOut -Force -ErrorAction SilentlyContinue
        }
    }
    # CSV normalizat — derivat din basic CSV exiftool
    if ($choice -in @("1","2","4")) {
        $basicSrc = Join-Path $OutputDir "${name}_basic.csv"
        $tmpBasic = $null
        if (-not (Test-Path $basicSrc) -or (Get-Item $basicSrc).Length -eq 0) {
            $tmpBasic = Join-Path $OutputDir "${name}_basic.csv.tmp"
            & $exifCmd -ee3 -api LargeFileSupport=1 -csv -n `
                -GPSLatitude -GPSLongitude -GPSAltitude `
                -GPSSpeed -GPSTrack -GPSDateTime `
                $f.FullName 2>$null | Out-File $tmpBasic -Encoding UTF8
            if ((Test-Path $tmpBasic) -and (Get-Item $tmpBasic).Length -gt 0) { $basicSrc = $tmpBasic }
        }
        if ((Test-Path $basicSrc) -and (Get-Item $basicSrc).Length -gt 0 -and $py3) {
            $normOut = Join-Path $OutputDir "${name}_norm.csv"
            $pyDji = @"
import csv, sys
NORM=['timestamp','lat','lon','alt_m','speed_mps','speed_kmh','heading_deg','gforce_x','gforce_y','gforce_z','gyro_x','gyro_y','gyro_z','temp_c','hr_bpm','cadence_rpm','power_w','source_brand']
with open(sys.argv[1], encoding='utf-8-sig') as fi, open(sys.argv[2],'w',newline='',encoding='utf-8') as fo:
    r=csv.DictReader(fi); w=csv.writer(fo); w.writerow(NORM)
    for row in r:
        lat=(row.get('GPSLatitude') or '').strip(); lon=(row.get('GPSLongitude') or '').strip()
        if not lat or not lon: continue
        sp=(row.get('GPSSpeed') or '').strip()
        try: skmh=f'{float(sp)*3.6:.2f}' if sp else ''
        except: skmh=''
        out={c:'' for c in NORM}
        out['timestamp']=(row.get('GPSDateTime') or '').strip()
        out['lat']=lat; out['lon']=lon
        out['alt_m']=(row.get('GPSAltitude') or '').strip()
        out['speed_mps']=sp; out['speed_kmh']=skmh
        out['heading_deg']=(row.get('GPSTrack') or '').strip()
        out['source_brand']='dji'
        w.writerow([out[c] for c in NORM])
"@
            $pyTmp = Join-Path $env:TEMP "av_dji_norm_$(Get-Random).py"
            $pyDji | Out-File $pyTmp -Encoding UTF8
            & $py3 $pyTmp $basicSrc $normOut 2>$null
            Remove-Item $pyTmp -Force -ErrorAction SilentlyContinue
            if ((Test-Path $normOut) -and (Get-Item $normOut).Length -gt 0) {
                Write-Host "  [OK] CSV Norm: ${name}_norm.csv" -ForegroundColor Green
            } else { Remove-Item $normOut -Force -ErrorAction SilentlyContinue }
        }
        if ($tmpBasic) { Remove-Item $tmpBasic -Force -ErrorAction SilentlyContinue }
    }
    if ($choice -eq "5") { Process-DJIRaw $f $name }
    if ($choice -eq "6") { Process-DJIStrip $f $name }
}

function Process-DJIRaw {
    param([System.IO.FileInfo]$f, [string]$name)
    $rawIdx = 0
    $tags = & ffprobe -v error -show_entries stream=codec_tag_string,codec_name -of csv=p=0 $f.FullName 2>$null
    foreach ($tag in $tags) {
        $outFile = $null; $fmt = "data"
        if     ($tag -imatch "djmd")     { $outFile = "${name}_djmd.bin" }
        elseif ($tag -imatch "dbgi")     { $outFile = "${name}_dbgi.bin" }
        elseif ($tag -imatch "tmcd")     { $outFile = "${name}_tmcd.bin" }
        elseif ($tag -imatch "mjpeg|jpeg") { $outFile = "${name}_cover.jpg"; $fmt = "mjpeg" }
        if ($outFile) {
            $outPath = Join-Path $OutputDir $outFile
            & ffmpeg -v error -i $f.FullName -map "0:$rawIdx" -c copy -f $fmt $outPath -y 2>$null
            if ((Test-Path $outPath) -and (Get-Item $outPath).Length -gt 0) {
                Write-Host "  [OK] $outFile ($(Format-Bytes (Get-Item $outPath).Length))" -ForegroundColor Green
            } else { Remove-Item $outPath -Force -ErrorAction SilentlyContinue }
        }
        $rawIdx++
    }
}

function Process-DJIStrip {
    param([System.IO.FileInfo]$f, [string]$name)
    $ext = $f.Extension
    $tagsRaw = & ffprobe -v error -show_entries stream=codec_tag_string,codec_name -of csv=p=0 $f.FullName 2>$null
    $hasDjmd = [bool]($tagsRaw | Where-Object { $_ -imatch "djmd" })
    $hasDbgi = [bool]($tagsRaw | Where-Object { $_ -imatch "dbgi" })
    if (-not $hasDjmd -and -not $hasDbgi) {
        Write-Host "  [SKIP] Nu e fisier DJI" -ForegroundColor DarkGray; return
    }
    $stripMaps = [System.Collections.Generic.List[string]]@("-map","0")
    $stripIdx = 0
    $tagLines = & ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 $f.FullName 2>$null
    foreach ($tag in $tagLines) {
        switch ($stripMode) {
            "1" { if ($tag -imatch "dbgi")               { $stripMaps.AddRange([string[]]@("-map","-0:$stripIdx")) } }
            "2" { if ($tag -imatch "djmd|dbgi")          { $stripMaps.AddRange([string[]]@("-map","-0:$stripIdx")) } }
            "3" { if ($tag -imatch "djmd|dbgi|tmcd|mjpeg|jpeg") { $stripMaps.AddRange([string[]]@("-map","-0:$stripIdx")) } }
        }
        $stripIdx++
    }
    $outClean = Join-Path $OutputDir "${name}_clean$ext"
    & ffmpeg -v error -i $f.FullName @stripMaps -c copy -map_metadata 0 $outClean -y 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $outClean) -and (Get-Item $outClean).Length -gt 0) {
        Write-Host "  [OK] ${name}_clean$ext ($(Format-Bytes $f.Length) -> $(Format-Bytes (Get-Item $outClean).Length))" -ForegroundColor Green
    } else {
        Write-Host "  [EROARE] Remux esuat" -ForegroundColor Red
        Remove-Item $outClean -Force -ErrorAction SilentlyContinue
    }
}

function Process-GoPro {
    param([System.IO.FileInfo]$f, [string]$name)
    if ($choice -in @("1","2","3","4")) {
        $idx = Get-TelemetryTrackIdx $f.FullName "gpmd"
        if ($idx -lt 0) { Write-Host "  [SKIP] gpmd track nu a fost gasit" -ForegroundColor DarkGray; return }
        $binTmp = Join-Path $OutputDir "${name}_gpmf.bin"
        & ffmpeg -v error -i $f.FullName -map "0:$idx" -c copy -f data $binTmp -y 2>$null
        if (-not (Test-Path $binTmp) -or (Get-Item $binTmp).Length -eq 0) {
            Write-Host "  [SKIP] Extragere gpmd esuata" -ForegroundColor DarkGray
            Remove-Item $binTmp -Force -ErrorAction SilentlyContinue; return
        }
        & $py3 $gpmfPy "gpmf" $binTmp $name $OutputDir $choice "gopro"
        Remove-Item $binTmp -Force -ErrorAction SilentlyContinue
    }
    elseif ($choice -eq "5") {
        $idx = Get-TelemetryTrackIdx $f.FullName "gpmd"
        if ($idx -lt 0) { Write-Host "  [SKIP] gpmd track nu a fost gasit" -ForegroundColor DarkGray; return }
        $outPath = Join-Path $OutputDir "${name}_gpmf.bin"
        & ffmpeg -v error -i $f.FullName -map "0:$idx" -c copy -f data $outPath -y 2>$null
        if ((Test-Path $outPath) -and (Get-Item $outPath).Length -gt 0) {
            Write-Host "  [OK] gpmf: ${name}_gpmf.bin ($(Format-Bytes (Get-Item $outPath).Length))" -ForegroundColor Green
        } else {
            Write-Host "  [EROARE] Extragere gpmf esuata" -ForegroundColor Red
            Remove-Item $outPath -Force -ErrorAction SilentlyContinue
        }
    }
    elseif ($choice -eq "6") {
        $ext = $f.Extension
        $stripMaps = [System.Collections.Generic.List[string]]@("-map","0")
        $stripIdx = 0
        $tagLines = & ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 $f.FullName 2>$null
        foreach ($tag in $tagLines) {
            if ($tag -imatch "gpmd") { $stripMaps.AddRange([string[]]@("-map","-0:$stripIdx")) }
            $stripIdx++
        }
        $outClean = Join-Path $OutputDir "${name}_clean$ext"
        & ffmpeg -v error -i $f.FullName @stripMaps -c copy -map_metadata 0 $outClean -y 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $outClean) -and (Get-Item $outClean).Length -gt 0) {
            Write-Host "  [OK] ${name}_clean$ext ($(Format-Bytes $f.Length) -> $(Format-Bytes (Get-Item $outClean).Length))" -ForegroundColor Green
        } else {
            Write-Host "  [EROARE] Remux esuat" -ForegroundColor Red
            Remove-Item $outClean -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── Helpers generic: extract telemetry track + parse cu Python ───────
function Invoke-TelemExtractParse {
    param([System.IO.FileInfo]$f, [string]$name, [string]$tag, [string]$fmt, [string]$label, [string]$brand)
    $idx = Get-TelemetryTrackIdx $f.FullName $tag
    if ($idx -lt 0) { Write-Host "  [SKIP] $label track ($tag) nu a fost gasit" -ForegroundColor DarkGray; return }
    $binTmp = Join-Path $OutputDir "${name}_${fmt}.bin"
    & ffmpeg -v error -i $f.FullName -map "0:$idx" -c copy -f data $binTmp -y 2>$null
    if (-not (Test-Path $binTmp) -or (Get-Item $binTmp).Length -eq 0) {
        Write-Host "  [SKIP] Extragere $label esuata" -ForegroundColor DarkGray
        Remove-Item $binTmp -Force -ErrorAction SilentlyContinue; return
    }
    & $py3 $gpmfPy $fmt $binTmp $name $OutputDir $choice $brand
    Remove-Item $binTmp -Force -ErrorAction SilentlyContinue
}

function Invoke-TelemExtractRaw {
    param([System.IO.FileInfo]$f, [string]$name, [string]$tag, [string]$fmt)
    $idx = Get-TelemetryTrackIdx $f.FullName $tag
    if ($idx -lt 0) { Write-Host "  [SKIP] $tag track nu a fost gasit" -ForegroundColor DarkGray; return }
    $out = Join-Path $OutputDir "${name}_${fmt}.bin"
    & ffmpeg -v error -i $f.FullName -map "0:$idx" -c copy -f data $out -y 2>$null
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 0) {
        Write-Host "  [OK] ${fmt}: ${name}_${fmt}.bin ($(Format-Bytes (Get-Item $out).Length))" -ForegroundColor Green
    } else {
        Write-Host "  [EROARE] Extragere $tag esuata" -ForegroundColor Red
        Remove-Item $out -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-TelemStripTrack {
    param([System.IO.FileInfo]$f, [string]$name, [string]$tagRegex)
    $ext = $f.Extension
    $stripMaps = [System.Collections.Generic.List[string]]@("-map","0")
    $stripIdx = 0
    $tagLines = & ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 $f.FullName 2>$null
    foreach ($tag in $tagLines) {
        if ($tag -imatch $tagRegex) { $stripMaps.AddRange([string[]]@("-map","-0:$stripIdx")) }
        $stripIdx++
    }
    $outClean = Join-Path $OutputDir "${name}_clean$ext"
    & ffmpeg -v error -i $f.FullName @stripMaps -c copy -map_metadata 0 $outClean -y 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $outClean) -and (Get-Item $outClean).Length -gt 0) {
        Write-Host "  [OK] ${name}_clean$ext ($(Format-Bytes $f.Length) -> $(Format-Bytes (Get-Item $outClean).Length))" -ForegroundColor Green
    } else {
        Write-Host "  [EROARE] Remux esuat" -ForegroundColor Red
        Remove-Item $outClean -Force -ErrorAction SilentlyContinue
    }
}

function Process-Sony {
    param([System.IO.FileInfo]$f, [string]$name)
    switch ($choice) {
        { $_ -in @("1","2","3","4") } { Invoke-TelemExtractParse $f $name "nmea" "nmea" "Sony NMEA" "sony" }
        "5"                            { Invoke-TelemExtractRaw   $f $name "nmea" "nmea" }
        "6"                            { Invoke-TelemStripTrack   $f $name "nmea" }
    }
}

function Process-Garmin {
    param([System.IO.FileInfo]$f, [string]$name)
    switch ($choice) {
        { $_ -in @("1","2","3","4") } { Invoke-TelemExtractParse $f $name "fdsc" "fit" "Garmin FIT" "garmin" }
        "5"                            { Invoke-TelemExtractRaw   $f $name "fdsc" "fit" }
        "6"                            { Invoke-TelemStripTrack   $f $name "fdsc" }
    }
}

function Process-QuickTime {
    param([System.IO.FileInfo]$f, [string]$name)
    if ($choice -in @("1","2","3","4")) {
        $lat = (& $exifCmd -s3 -api LargeFileSupport=1 -n -GPSLatitude $f.FullName 2>$null) -join ''
        $lon = (& $exifCmd -s3 -api LargeFileSupport=1 -n -GPSLongitude $f.FullName 2>$null) -join ''
        $alt = (& $exifCmd -s3 -api LargeFileSupport=1 -n -GPSAltitude $f.FullName 2>$null) -join ''
        $dt  = (& $exifCmd -s3 -api LargeFileSupport=1 -CreateDate $f.FullName 2>$null) -join ''
        if (-not $lat -or -not $lon) {
            Write-Host "  [SKIP] QuickTime: fara coordonate GPS in atom ISO 6709" -ForegroundColor DarkGray; return
        }
        if (-not $alt) { $alt = "0" }
        $ts = ""
        if ($dt -match '^(\d{4}):(\d{2}):(\d{2}) (\d{2}:\d{2}:\d{2})') { $ts = "$($Matches[1])-$($Matches[2])-$($Matches[3])T$($Matches[4])Z" }
        if ($choice -in @("1","2","4")) {
            $gpx = @"
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.0" creator="AV Encoder Suite (QuickTime ISO 6709)" xmlns="http://www.topografix.com/GPX/1/0">
<wpt lat="$lat" lon="$lon"><ele>$alt</ele>
$(if ($ts) { "<time>$ts</time>" })
<name>$name</name></wpt>
</gpx>
"@
            $gpx | Out-File (Join-Path $OutputDir "$name.gpx") -Encoding UTF8
            Write-Host "  [OK] GPX: $name.gpx (1 punct)" -ForegroundColor Green
        }
        if ($choice -in @("1","4")) {
            $csv = "Latitude,Longitude,Altitude(m),Speed(m/s),DateTime,Source`n$lat,$lon,$alt,,$ts,QuickTime ISO 6709"
            $csv | Out-File (Join-Path $OutputDir "${name}_basic.csv") -Encoding UTF8
            Write-Host "  [OK] CSV Basic: ${name}_basic.csv (1 punct)" -ForegroundColor Green
        }
        if ($choice -in @("1","2","4")) {
            $normHeader = "timestamp,lat,lon,alt_m,speed_mps,speed_kmh,heading_deg,gforce_x,gforce_y,gforce_z,gyro_x,gyro_y,gyro_z,temp_c,hr_bpm,cadence_rpm,power_w,source_brand"
            $normRow    = "$ts,$lat,$lon,$alt,,,,,,,,,,,,,,quicktime"
            "$normHeader`n$normRow" | Out-File (Join-Path $OutputDir "${name}_norm.csv") -Encoding UTF8
            Write-Host "  [OK] CSV Norm: ${name}_norm.csv (1 punct)" -ForegroundColor Green
        }
        if ($choice -in @("2","4")) {
            & $exifCmd -api LargeFileSupport=1 -csv -G -n $f.FullName 2>$null |
                Out-File (Join-Path $OutputDir "${name}_FULL.csv") -Encoding UTF8
            $fullCsv = Join-Path $OutputDir "${name}_FULL.csv"
            if ((Test-Path $fullCsv) -and (Get-Item $fullCsv).Length -gt 0) {
                Write-Host "  [OK] CSV Full: ${name}_FULL.csv" -ForegroundColor Green
            } else { Remove-Item $fullCsv -Force -ErrorAction SilentlyContinue }
        }
        if ($choice -in @("3","4")) {
            $srt = "1`n00:00:00,000 --> 00:00:05,000`nGPS: $lat, $lon | Alt: ${alt}m"
            if ($ts) { $srt += "`nTime: $ts" }
            $srt += "`n"
            $srt | Out-File (Join-Path $OutputDir "$name.srt") -Encoding UTF8
            Write-Host "  [OK] SRT: $name.srt (1 punct)" -ForegroundColor Green
        }
    }
    elseif ($choice -eq "5") { Write-Host "  [INFO] QuickTime nu are stream raw — datele sunt in atom-ul mvhd/mdta" -ForegroundColor DarkGray }
    elseif ($choice -eq "6") { Write-Host "  [INFO] QuickTime: foloseste exiftool -gps:all= pentru a sterge tag-urile (fara remux)" -ForegroundColor DarkGray }
}

# ── Main loop ────────────────────────────────────────────────────────
Write-Host "`n--- Incep extractia ---" -ForegroundColor Green
$done = 0
foreach ($f in $inputFiles) {
    $done++
    $name = $f.BaseName
    $brand = $brands[$f.FullName]
    Write-Host "`n-- $done/$fileCount`: $($f.Name)  [$brand]" -ForegroundColor Yellow

    switch ($brand) {
        "dji"       { Process-DJI       $f $name }
        "gopro"     { Process-GoPro     $f $name }
        "sony"      { Process-Sony      $f $name }
        "garmin"    { Process-Garmin    $f $name }
        "quicktime" { Process-QuickTime $f $name }
        "unknown"   { Write-Host "  [SKIP] Brand telemetrie nedetectat" -ForegroundColor DarkGray }
    }
}

# ── Curatenie ────────────────────────────────────────────────────────
if ($gpxFmt) { Remove-Item $gpxFmt -Force -ErrorAction SilentlyContinue }
if ($srtFmt) { Remove-Item $srtFmt -Force -ErrorAction SilentlyContinue }
if ($gpmfPy) { Remove-Item $gpmfPy -Force -ErrorAction SilentlyContinue }

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "FINALIZAT — $done fisiere procesate" -ForegroundColor Green
Write-Host "Output: $OutputDir" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor Cyan
Read-Host
