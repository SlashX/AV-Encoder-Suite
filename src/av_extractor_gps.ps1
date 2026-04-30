# ══════════════════════════════════════════════════════════════════════
# av_extractor_gps.ps1 — Import GPS extern (GPX/FIT/KML → CSV/SRT)
# Converteste fisiere GPX, FIT si KML de la orice dispozitiv GPS
# (Garmin, Huawei, Apple Watch, Strava, Komoot, etc.)
# Necesita: python3
# ══════════════════════════════════════════════════════════════════════

# ── Verificare python3 ───────────────────────────────────────────────
$py3 = $null
if (Get-Command "python3" -ErrorAction SilentlyContinue) { $py3 = "python3" }
elseif (Get-Command "python" -ErrorAction SilentlyContinue) {
    $pyVer = & python --version 2>&1
    if ($pyVer -match "3\.") { $py3 = "python" }
}
if (-not $py3) {
    Write-Host "[EROARE] Python3 nu este instalat sau nu este in PATH." -ForegroundColor Red
    Write-Host "Download: https://python.org/downloads/" -ForegroundColor Yellow
    Read-Host; exit
}

$InputDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutputDir = Join-Path $InputDir "output"
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }

$gpsFiles = Get-ChildItem -Path $InputDir -Include "*.gpx","*.fit","*.kml" -File -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  GPS EXTRACTOR (GPX/FIT/KML)                 ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Fisiere gasite : $($gpsFiles.Count)" -ForegroundColor White
Write-Host "║  Input  : $InputDir" -ForegroundColor White
Write-Host "║  Output : $OutputDir" -ForegroundColor White
Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  1) CSV esential (Lat, Lon, Alt, Speed, Time)║" -ForegroundColor White
Write-Host "║  2) CSV complet (toate metadatele)            ║" -ForegroundColor White
Write-Host "║  3) Subtitrare SRT (overlay in VLC)           ║" -ForegroundColor White
Write-Host "║  4) Totul (CSV basic + CSV full + SRT)        ║" -ForegroundColor White
Write-Host "║  5) GPX & KML (conversie intre formate)       ║" -ForegroundColor White
Write-Host "║  6) Anulare                                   ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
$gpsChoice = Read-Host "Alege 1-6 [implicit: 1]"
if (-not $gpsChoice) { $gpsChoice = "1" }
if ($gpsChoice -eq "6") { exit }

if (-not $gpsFiles -or $gpsFiles.Count -eq 0) {
    Write-Host "Nu am gasit fisiere .gpx, .fit sau .kml in $InputDir" -ForegroundColor Red
    Read-Host; exit
}

# Generate Python script as temp file
$pyScript = Join-Path $env:TEMP "av_gps_extract_$(Get-Random).py"
@"
import xml.etree.ElementTree as ET
import csv, sys, os, math, struct, re
from datetime import datetime, timedelta

def parse_gpx(file_path):
    tree = ET.parse(file_path)
    root = tree.getroot()
    ns = root.tag.split('}')[0] + '}' if root.tag.startswith('{') else ''
    points = []
    for trkpt in list(root.iter(f'{ns}trkpt')) or list(root.iter(f'{ns}wpt')):
        p = {'lat': trkpt.get('lat',''), 'lon': trkpt.get('lon','')}
        ele = trkpt.find(f'{ns}ele')
        p['alt'] = ele.text.strip() if ele is not None and ele.text else ''
        t = trkpt.find(f'{ns}time')
        p['time'] = t.text.strip() if t is not None and t.text else ''
        p['speed'] = ''
        for ext_tag in [f'{ns}extensions', 'extensions']:
            ext_el = trkpt.find(ext_tag)
            if ext_el is not None:
                for child in ext_el.iter():
                    tag = child.tag.split('}')[-1].lower() if '}' in child.tag else child.tag.lower()
                    if 'speed' in tag and child.text: p['speed'] = child.text.strip()
                    if ('hr' in tag or 'heartrate' in tag) and child.text: p['hr'] = child.text.strip()
                    if ('cad' in tag or 'cadence' in tag) and child.text: p['cad'] = child.text.strip()
                    if 'power' in tag and child.text: p['power'] = child.text.strip()
                    if ('temp' in tag or 'atemp' in tag) and child.text: p['temp'] = child.text.strip()
        points.append(p)
    # Calculate speed if missing
    for i in range(1, len(points)):
        if not points[i].get('speed') and points[i]['lat'] and points[i-1]['lat']:
            try:
                lat1,lon1 = float(points[i-1]['lat']),float(points[i-1]['lon'])
                lat2,lon2 = float(points[i]['lat']),float(points[i]['lon'])
                dlat,dlon = math.radians(lat2-lat1),math.radians(lon2-lon1)
                a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1))*math.cos(math.radians(lat2))*math.sin(dlon/2)**2
                dist = 6371000*2*math.atan2(math.sqrt(a),math.sqrt(1-a))
                if points[i].get('time') and points[i-1].get('time'):
                    for fmt in ['%Y-%m-%dT%H:%M:%SZ','%Y-%m-%dT%H:%M:%S.%fZ','%Y-%m-%dT%H:%M:%S%z']:
                        try:
                            t1=datetime.strptime(points[i-1]['time'],fmt); t2=datetime.strptime(points[i]['time'],fmt)
                            dt=(t2-t1).total_seconds()
                            if dt>0: points[i]['speed']=f"{dist/dt:.2f}"
                            break
                        except: continue
            except: pass
    return points

def parse_kml(file_path):
    tree = ET.parse(file_path)
    root = tree.getroot()
    ns = root.tag.split('}')[0]+'}' if root.tag.startswith('{') else ''
    points = []
    for coords_el in list(root.iter(f'{ns}coordinates'))+list(root.iter('coordinates')):
        if coords_el.text:
            for token in re.split(r'[\s]+', coords_el.text.strip()):
                token = token.strip()
                if not token: continue
                parts = token.split(',')
                if len(parts)>=2:
                    p = {'lon':parts[0].strip(),'lat':parts[1].strip(),'alt':parts[2].strip() if len(parts)>=3 else '','speed':'','time':''}
                    points.append(p)
    return points

def parse_fit(file_path):
    FIT_EPOCH = datetime(1989,12,31)
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
                gm=struct.unpack('<H' if arch==0 else '>H',data[pos:pos+2])[0]; pos+=2
                nf=data[pos]; pos+=1; flds=[]
                for _ in range(nf): flds.append((data[pos],data[pos+1],data[pos+2])); pos+=3
                field_defs[lm]=(flds,arch); mesg_nums[lm]=gm
                if rh&0x20: nd=data[pos]; pos+=1; pos+=nd*3
            elif rh&0x80:
                lm=(rh>>5)&0x03
                if lm not in field_defs: break
                for _,fs,_ in field_defs[lm][0]: pos+=fs
            else:
                lm=rh&0x0F
                if lm not in field_defs: break
                flds,arch=field_defs[lm]; gm=mesg_nums.get(lm,0); fv={}
                for fdn,fs,fbt in flds:
                    raw=data[pos:pos+fs]; pos+=fs; val=None
                    if fs==1: val=raw[0]; val=None if val==0xFF else val
                    elif fs==2: val=struct.unpack('<H' if arch==0 else '>H',raw)[0]; val=None if val==0xFFFF else val
                    elif fs==4:
                        val=struct.unpack('<I' if arch==0 else '>I',raw)[0]; val=None if val==0xFFFFFFFF else val
                        if fbt&0x1F==0x85: val=struct.unpack('<i' if arch==0 else '>i',raw)[0]; val=None if val==0x7FFFFFFF else val
                    if val is not None: fv[fdn]=val
                if gm==20 and 0 in fv and 1 in fv:
                    lat_sc,lon_sc=fv[0],fv[1]
                    if lat_sc>0x7FFFFFFF: lat_sc-=0x100000000
                    if lon_sc>0x7FFFFFFF: lon_sc-=0x100000000
                    p={'lat':f"{lat_sc*(180.0/2**31):.8f}",'lon':f"{lon_sc*(180.0/2**31):.8f}"}
                    p['alt']=f"{(fv[2]/5.0)-500:.1f}" if 2 in fv and fv[2]!=0xFFFF else ''
                    p['speed']=f"{fv[6]/1000.0:.2f}" if 6 in fv else ''
                    p['time']=(FIT_EPOCH+timedelta(seconds=fv[253])).strftime('%Y-%m-%d %H:%M:%S') if 253 in fv else ''
                    if 3 in fv: p['hr']=str(fv[3])
                    if 4 in fv: p['cad']=str(fv[4])
                    if 7 in fv: p['power']=str(fv[7])
                    if 23 in fv: p['temp']=str(fv[23])
                    if -90<=float(p['lat'])<=90 and float(p['lat'])!=0: points.append(p)
        except: break
    return points

def write_csv_basic(points, path):
    with open(path,'w',newline='') as f:
        w=csv.writer(f); w.writerow(['Latitude','Longitude','Altitude(m)','Speed(m/s)','DateTime'])
        for p in points: w.writerow([p['lat'],p['lon'],p.get('alt',''),p.get('speed',''),p.get('time','')])

def write_csv_full(points, path):
    keys=sorted(set(k for p in points for k in p.keys()))
    with open(path,'w',newline='') as f:
        w=csv.writer(f); w.writerow(keys)
        for p in points: w.writerow([p.get(k,'') for k in keys])

NORM_COLUMNS = ['timestamp','lat','lon','alt_m','speed_mps','speed_kmh','heading_deg',
                'gforce_x','gforce_y','gforce_z','gyro_x','gyro_y','gyro_z',
                'temp_c','hr_bpm','cadence_rpm','power_w','source_brand']

def write_csv_normalized(points, path, brand):
    with open(path,'w',newline='') as f:
        w=csv.writer(f); w.writerow(NORM_COLUMNS)
        for p in points:
            sp=p.get('speed','')
            try: skmh=f"{float(sp)*3.6:.2f}" if sp else ''
            except: skmh=''
            row={c:'' for c in NORM_COLUMNS}
            row['timestamp']=p.get('time','')
            row['lat']=p.get('lat',''); row['lon']=p.get('lon','')
            row['alt_m']=p.get('alt','')
            row['speed_mps']=sp; row['speed_kmh']=skmh
            row['temp_c']=p.get('temp','')
            row['hr_bpm']=p.get('hr','')
            row['cadence_rpm']=p.get('cad','')
            row['power_w']=p.get('power','')
            row['source_brand']=brand
            w.writerow([row[c] for c in NORM_COLUMNS])

def write_srt(points, path):
    with open(path,'w') as f:
        for i,p in enumerate(points):
            sv=p.get('speed','0')
            try: sk=f"{float(sv)*3.6:.1f}" if sv else "0.0"
            except: sk="0.0"
            s1,s2=i,i+1
            f.write(f"{i+1}\n{s1//3600:02d}:{(s1%3600)//60:02d}:{s1%60:02d},000 --> {s2//3600:02d}:{(s2%3600)//60:02d}:{s2%60:02d},000\n")
            f.write(f"Speed: {sk} km/h | Alt: {p.get('alt','N/A')}m\nGPS: {p['lat']}, {p['lon']}\n")
            hr=f" | HR: {p['hr']}bpm" if p.get('hr') else ""
            cad=f" | Cad: {p['cad']}rpm" if p.get('cad') else ""
            if hr or cad: f.write(f"{hr}{cad}\n")
            f.write("\n")

def write_kml(points, name, path):
    with open(path,'w') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<kml xmlns="http://www.opengis.net/kml/2.2">\n')
        f.write(f'<Document><name>{name}</name>\n<Style id="t"><LineStyle><color>ff0000ff</color><width>3</width></LineStyle></Style>\n')
        f.write('<Placemark><name>Track</name><styleUrl>#t</styleUrl><LineString><altitudeMode>absolute</altitudeMode><coordinates>\n')
        for p in points: f.write(f"{p['lon']},{p['lat']},{p.get('alt','0') or '0'}\n")
        f.write('</coordinates></LineString></Placemark></Document></kml>\n')

def write_gpx(points, name, path):
    with open(path,'w') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="AV Encoder Suite">\n')
        f.write(f'<trk><name>{name}</name><trkseg>\n')
        for p in points:
            f.write(f'<trkpt lat="{p["lat"]}" lon="{p["lon"]}"><ele>{p.get("alt","0") or "0"}</ele>')
            if p.get('time'): f.write(f'<time>{p["time"]}</time>')
            f.write('</trkpt>\n')
        f.write('</trkseg></trk></gpx>\n')

# Main
files = sys.argv[1:-1]
choice = sys.argv[-1]

for fp in files:
    name = os.path.splitext(os.path.basename(fp))[0]
    ext = os.path.splitext(fp)[1].lower()
    out = os.environ.get('AV_OUTPUT_DIR', os.path.dirname(fp))
    os.makedirs(out, exist_ok=True)
    print(f"\n-- {os.path.basename(fp)}")
    try:
        if ext=='.gpx': pts=parse_gpx(fp)
        elif ext=='.fit': pts=parse_fit(fp)
        elif ext=='.kml': pts=parse_kml(fp)
        else: print(f"  [SKIP] Format necunoscut: {ext}"); continue
    except Exception as e: print(f"  [EROARE] {e}"); continue
    if not pts: print("  [SKIP] Nu am gasit puncte GPS"); continue
    print(f"  Puncte GPS: {len(pts)}")
    brand = 'external_gpx' if ext=='.gpx' else ('external_fit' if ext=='.fit' else 'external_kml')
    if choice in ('1','4'): write_csv_basic(pts,os.path.join(out,f"{name}_gps_basic.csv")); print(f"  [OK] CSV basic: {name}_gps_basic.csv")
    if choice in ('2','4'): write_csv_full(pts,os.path.join(out,f"{name}_gps_full.csv")); print(f"  [OK] CSV full: {name}_gps_full.csv")
    if choice in ('3','4'): write_srt(pts,os.path.join(out,f"{name}_gps.srt")); print(f"  [OK] SRT: {name}_gps.srt")
    if choice in ('1','2','4'): write_csv_normalized(pts,os.path.join(out,f"{name}_norm.csv"),brand); print(f"  [OK] CSV Norm: {name}_norm.csv")
    if choice=='5':
        if ext!='.kml': write_kml(pts,name,os.path.join(out,f"{name}.kml")); print(f"  [OK] KML: {name}.kml")
        if ext!='.gpx': write_gpx(pts,name,os.path.join(out,f"{name}.gpx")); print(f"  [OK] GPX: {name}.gpx")
"@ | Out-File $pyScript -Encoding UTF8

# Execute Python with file list + choice
$env:AV_OUTPUT_DIR = $OutputDir
$gpsArgs = @($pyScript) + ($gpsFiles | ForEach-Object { $_.FullName }) + @($gpsChoice)
& $py3 @gpsArgs
Remove-Item $pyScript -Force -ErrorAction SilentlyContinue
Remove-Item Env:AV_OUTPUT_DIR -ErrorAction SilentlyContinue

Write-Host "`nFINALIZAT — $($gpsFiles.Count) fisiere procesate" -ForegroundColor Green
Write-Host "Output: $OutputDir" -ForegroundColor White
Read-Host "Apasa Enter"
