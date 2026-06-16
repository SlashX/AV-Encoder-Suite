# ══════════════════════════════════════════════════════════════════════
# av_telemetry.ps1 — Extractor unificat de telemetrie (Windows/PowerShell)
# v40: Suport DJI + GoPro (GPMF). Sony/Garmin VIRB/QuickTime — chunk-uri ulterioare.
# Rulare: powershell -ExecutionPolicy Bypass -File av_telemetry.ps1
# ══════════════════════════════════════════════════════════════════════

# ── Binare locale: folderul scriptului (src/) are prioritate in PATH ──
#    Permite ffmpeg/ffprobe/exiftool .exe puse langa script, fara PATH global.
$env:PATH = "$PSScriptRoot;$env:PATH"

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
$TempBase  = Join-Path $InputDir "Temp"   # v63: temp-ul nostru (scripturi Python temporare), nu $env:TEMP
if (-not (Test-Path $TempBase)) { New-Item -ItemType Directory -Force -Path $TempBase | Out-Null }

# v69: rezolvare exiftool — SURSA UNICA pt nume (env AV_TOOL_EXIFTOOL, mirror
# av_common.sh; accepta si cale absoluta) + fallback pe .exe de langa script.
# Inainte lantul PATH→PSScriptRoot era duplicat in 3 locuri.
function Get-ExifCmd {
    $name = if ($env:AV_TOOL_EXIFTOOL) { $env:AV_TOOL_EXIFTOOL } else { "exiftool" }
    $cmd = (Get-Command $name -ErrorAction SilentlyContinue).Source
    if ($cmd) { return $cmd }
    if ($name -notmatch '[\\/]') {
        $cand = Join-Path $PSScriptRoot "$name.exe"
        if (Test-Path $cand) { return $cand }
    }
    return $null
}

function Format-Bytes {
    param([long]$bytes)
    if ($bytes -ge 1GB) { "{0:N2} GB" -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { "{0:N2} MB" -f ($bytes / 1MB) }
    elseif ($bytes -ge 1KB) { "{0:N2} KB" -f ($bytes / 1KB) }
    else { "$bytes B" }
}

# v57: codec FourCC tag pentru MP4/MOV/M4V — copie locala (telemetry standalone).
# Paritate cu bash codec_tag_for_container.
function Get-CodecTagForContainer {
    param([string]$Codec, [string]$Container)
    $ext = $Container.ToLowerInvariant()
    if ($ext -in @("mp4","mov","m4v")) {
        switch ($Codec) {
            "hevc" { return @("-tag:v","hvc1") }
            "av1"  { return @("-tag:v","av01") }
            "h264" { return @("-tag:v","avc1") }
        }
    }
    return @()
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
    if (-not $exifCmd) { $exifCmd = Get-ExifCmd }
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
$inputFiles = Get-ChildItem -Path (Join-Path $InputDir '*') -Include $videoExt -File -ErrorAction SilentlyContinue
$fileCount = ($inputFiles | Measure-Object).Count
if ($fileCount -eq 0) {
    Write-Host "Nu am gasit fisiere video in $InputDir" -ForegroundColor Red
    Read-Host; exit
}

# ── Pre-scan: clasificare brand ──────────────────────────────────────
Write-Host "`nScanare brand telemetrie..." -ForegroundColor Yellow
# Pre-resolve exiftool to use during pre-scan (for QuickTime fallback detection)
$exifProbe = Get-ExifCmd

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
Write-Host "║  7) Extract + embed lossless                 ║" -ForegroundColor White
Write-Host "║     SRT track + CSV/GPX attachments in MKV   ║" -ForegroundColor White
Write-Host "║  8) Anulare                                  ║" -ForegroundColor White
Write-Host "║  Nota: QuickTime are 1 punct GPS (start)     ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
$choice = Read-Host "Alege 1-8 [implicit: 1]"
if (-not $choice) { $choice = "1" }
if ($choice -eq "8") { exit }

# opt 7 (embed) — submenu pentru continut embed
$EmbedAfter = $false
$EmbedProfile = ""
if ($choice -eq "7") {
    Write-Host "`n╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  EMBED LOSSLESS — selecteaza continut         ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  1) SRT only (compatibil MKV/MP4/MOV)         ║" -ForegroundColor White
    Write-Host "║  2) SRT + norm CSV (MKV preferred)            ║" -ForegroundColor White
    Write-Host "║  3) SRT + norm CSV + GPX (MKV preferred)      ║" -ForegroundColor White
    Write-Host "║     [implicit]                                ║" -ForegroundColor White
    Write-Host "║  4) Toate (SRT + toate CSV + GPX + KML,       ║" -ForegroundColor White
    Write-Host "║     MKV mandatory)                            ║" -ForegroundColor White
    Write-Host "║  5) Anulare                                   ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $embProf = Read-Host "Alege 1-5 [implicit: 3]"
    if (-not $embProf) { $embProf = "3" }
    switch ($embProf) {
        "1" { $EmbedProfile = "srt";         $choice = "3" }
        "2" { $EmbedProfile = "srt_csv";     $choice = "4" }
        "3" { $EmbedProfile = "srt_csv_gpx"; $choice = "4" }
        "4" { $EmbedProfile = "all";         $choice = "4" }
        "5" { Write-Host "Anulat."; exit }
        default { $EmbedProfile = "srt_csv_gpx"; $choice = "4" }
    }
    $EmbedAfter = $true
}

# Sub-dialog strip metadata (optiunea 6)
$stripMode = ""
if ($choice -eq "6") {
    Write-Host "`n╔══════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║  ELIMINA METADATA (REMUX FARA RE-ENCODE)     ║" -ForegroundColor Yellow
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Yellow
    Write-Host "║  DJI (GPS-ul djmd NU poate ramane la re-mux): ║" -ForegroundColor White
    Write-Host "║   1) Sterge telemetria (djmd/dbgi/tmcd)       ║" -ForegroundColor White
    Write-Host "║   2) Sterge telemetria + cover (mjpeg)        ║" -ForegroundColor White
    Write-Host "║  GoPro/Sony/Garmin: orice optiune sterge      ║" -ForegroundColor White
    Write-Host "║   track-ul de telemetrie (gpmd/nmea/fdsc)     ║" -ForegroundColor White
    Write-Host "║   3) Anulare                                  ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host "  Nota DJI: ffmpeg nu poate re-muxa pistele de date proprietare" -ForegroundColor DarkGray
    Write-Host "  (djmd/dbgi/tmcd, codec none) -> sunt eliminate. Pentru GPS," -ForegroundColor DarkGray
    Write-Host "  extrage-l intai cu optiunile 1-5 din meniul telemetrie." -ForegroundColor DarkGray
    $stripMode = Read-Host "Alege 1-3 [implicit: 1]"
    if (-not $stripMode) { $stripMode = "1" }
    if ($stripMode -eq "3") { exit }
}

# ── Verificare dependente conditional ────────────────────────────────
$exifCmd = $null; $py3 = $null
$gpxFmt = $null; $srtFmt = $null; $djiBasicFmt = $null; $djiNormFmt = $null

$needExif = (($djiCount -gt 0) -or ($qtCount -gt 0)) -and ($choice -in @("1","2","3","4"))
$needPy   = (($goproCount -gt 0) -or ($sonyCount -gt 0) -or ($garminCount -gt 0)) -and ($choice -in @("1","2","3","4"))
# Soft Python detection pentru DJI norm CSV (nu blocant)
$wantPyDjiNorm = ($djiCount -gt 0) -and ($choice -in @("1","2","4")) -and (-not $needPy)

if ($needExif) {
    $exifCmd = Get-ExifCmd
    if (-not $exifCmd) {
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

    # Basic CSV per-sample (track complet, nu doar 1 punct ca -csv) — mirror campuri GPX
    $djiBasicFmt = Join-Path $OutputDir "djibasic.fmt"
    @'
#[HEAD]GPSDateTime,GPSLatitude,GPSLongitude,GPSAltitude
#[BODY]$gpsdatetime,$gpslatitude#,$gpslongitude#,$gpsaltitude#
'@ | Out-File $djiBasicFmt -Encoding ASCII

    # Norm source per-sample (pipe-delim, -f forteaza '-' pe lipsa); Python normalizeaza la 24 col
    $djiNormFmt = Join-Path $OutputDir "djinorm.fmt"
    @'
#[BODY]$sampletime#|$gpsdatetime|$gpslatitude#|$gpslongitude#|$gpsaltitude#|$accelerometerx#|$accelerometery#|$accelerometerz#|$pitch#|$roll#|$yaw#|$gimbalpitchdegree#|$gimbalrolldegree#|$gimbalyawdegree#
'@ | Out-File $djiNormFmt -Encoding ASCII
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
    $gpmfPy = Join-Path $TempBase "av_gpmf_$(Get-Random).py"
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

def _sensor_3axis_mean(strm_klvs, fourcc):
    # ACCL/GYRO: 3 valori per sample (ordine GoPro: z,x,y), scalate de SCAL.
    # Rata sample (~200Hz) >> rata GPS → returnam media pe STRM-ul DEVC.
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
    # GPS9 (Hero11+): per-sample struct 7xint32 + 2xuint16 = 32 bytes.
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
                    if 'GPS9' in fourccs:
                        devc_points.extend(_gps9_points(strm_klvs, strm_state))
                    else:
                        devc_points.extend(_gps5_points(strm_klvs, strm_state))
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

# CSV normalizat (schema unificata cross-brand)
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
        elif sentence in ('`$GPVTG','`$GNVTG') and len(parts) >= 8:
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
        # Track complet per-sample (DJI protobuf): -p template, NU -csv (care colapseaza la 1 rand)
        & $exifCmd -p $djiBasicFmt -ee3 -api LargeFileSupport=1 $f.FullName 2>$null |
            Out-File (Join-Path $OutputDir "${name}_basic.csv") -Encoding UTF8
        $basicOut = Join-Path $OutputDir "${name}_basic.csv"
        if ((Test-Path $basicOut) -and (Get-Item $basicOut).Length -gt 0) {
            Write-Host "  [OK] CSV Basic: ${name}_basic.csv" -ForegroundColor Green
        } else { Remove-Item $basicOut -Force -ErrorAction SilentlyContinue }
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
    # CSV normalizat — extractie per-sample (track complet protobuf): GPS + accelerometru (g) +
    # orientare (modele care o expun). Viteza/heading calculate din delta GPS cu sampletime sub-secunda.
    if ($choice -in @("1","2","4")) {
        $normSrc = Join-Path $OutputDir "${name}_normsrc.csv.tmp"
        & $exifCmd -p $djiNormFmt -f -ee3 -api LargeFileSupport=1 $f.FullName 2>$null | Out-File $normSrc -Encoding UTF8
        if ((Test-Path $normSrc) -and (Get-Item $normSrc).Length -gt 0 -and $py3) {
            $normOut = Join-Path $OutputDir "${name}_norm.csv"
            $pyDji = @"
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
with open(sys.argv[1], encoding='utf-8-sig', errors='replace') as fi, open(sys.argv[2],'w',newline='',encoding='utf-8') as fo:
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
        if not wrote: w.writerow(NORM); wrote=True
        w.writerow([out[c] for c in NORM])
"@
            $pyTmp = Join-Path $TempBase "av_dji_norm_$(Get-Random).py"
            $pyDji | Out-File $pyTmp -Encoding UTF8
            & $py3 $pyTmp $normSrc $normOut 2>$null
            Remove-Item $pyTmp -Force -ErrorAction SilentlyContinue
            if ((Test-Path $normOut) -and (Get-Item $normOut).Length -gt 0) {
                Write-Host "  [OK] CSV Norm: ${name}_norm.csv" -ForegroundColor Green
            } else { Remove-Item $normOut -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item $normSrc -Force -ErrorAction SilentlyContinue
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
    # -dn: pistele de date DJI (djmd/dbgi/tmcd) sunt codec=none -> ffmpeg NU le poate
    # re-muxa (-c copy esueaza). Le eliminam mereu; GPS-ul se extrage separat (opt 1-5).
    # v71 audit: inainte modurile care PASTRAU date (1=keep djmd, 2=keep tmcd) esuau pe DJI.
    $stripMaps = [System.Collections.Generic.List[string]]@("-map","0","-dn")
    if ($stripMode -eq "2") {
        # mode 2: elimina si cover-ul (mjpeg/jpeg). codec_tag al cover-ului DJI e
        # [0][0][0][0] -> detectam dupa codec_NAME, nu tag. Index ABSOLUT din ffprobe.
        $vidLines = & ffprobe -v error -select_streams v -show_entries stream=index,codec_name -of csv=p=0 $f.FullName 2>$null
        foreach ($vl in $vidLines) {
            $parts = "$vl".Trim() -split ','
            if ($parts.Count -ge 2 -and $parts[1] -imatch '^(mjpeg|jpeg|png)$') {
                $stripMaps.AddRange([string[]]@("-map","-0:$($parts[0])"))
            }
        }
    }
    $outClean = Join-Path $OutputDir "${name}_clean$ext"
    & ffmpeg -v error -i $f.FullName @stripMaps -c copy -map_metadata 0 $outClean -y 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $outClean) -and (Get-Item $outClean).Length -gt 0) {
        Write-Host "  [OK] ${name}_clean$ext ($(Format-Bytes $f.Length) -> $(Format-Bytes (Get-Item $outClean).Length))" -ForegroundColor Green
        Write-Host "  Nota: telemetria DJI (djmd/dbgi/tmcd) eliminata (ffmpeg nu o re-muxeaza); GPS via opt 1-5." -ForegroundColor DarkGray
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
        # -dn: data proprietar (gpmd) e codec=none -> ne-re-muxabil de ffmpeg
        $stripMaps = [System.Collections.Generic.List[string]]@("-map","0","-dn")
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
    # -dn: data codec=none ne-re-muxabil de ffmpeg
    $stripMaps = [System.Collections.Generic.List[string]]@("-map","0","-dn")
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

# ── Embed lossless — atașeaza telemetria in container ───────────────
# Profile ($EmbedProfile): srt | srt_csv | srt_csv_gpx | all
# Output: $OutputDir/<name>_telem.<ext>; sursa neatinsa.
# Genereaza KML din _norm.csv (toate brandurile)
function New-KmlFromNormCsv {
    param([string]$CsvPath, [string]$KmlPath, [string]$TrackName)
    if (-not (Test-Path $CsvPath) -or (Get-Item $CsvPath).Length -eq 0) { return $false }
    $rows = Import-Csv -LiteralPath $CsvPath
    $coords = foreach ($r in $rows) {
        if ($r.lat -and $r.lon) {
            $alt = if ($r.alt_m) { $r.alt_m } else { '0' }
            "$($r.lon),$($r.lat),$alt"
        }
    }
    if (-not $coords) { return $false }
    $safeName = [System.Net.WebUtility]::HtmlEncode($TrackName)
    $kml = @"
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document><name>$safeName</name>
<Style id="track"><LineStyle><color>ff0000ff</color><width>3</width></LineStyle></Style>
<Placemark><name>$safeName</name><styleUrl>#track</styleUrl>
<LineString><altitudeMode>absolute</altitudeMode><coordinates>
$($coords -join ' ')
</coordinates></LineString></Placemark></Document></kml>
"@
    Set-Content -LiteralPath $KmlPath -Value $kml -Encoding UTF8
    return (Test-Path $KmlPath) -and (Get-Item $KmlPath).Length -gt 0
}

function Invoke-EmbedTelemetryLossless {
    param([System.IO.FileInfo]$f, [string]$name)

    $srcExt = $f.Extension.TrimStart('.').ToLowerInvariant()
    $profile = if ($EmbedProfile) { $EmbedProfile } else { "srt_csv_gpx" }

    $srtFile  = Join-Path $OutputDir "${name}.srt"
    $csvNorm  = Join-Path $OutputDir "${name}_norm.csv"
    $csvBasic = Join-Path $OutputDir "${name}_basic.csv"
    $csvFull  = Join-Path $OutputDir "${name}_FULL.csv"
    $gpxFile  = Join-Path $OutputDir "${name}.gpx"
    $kmlFile  = Join-Path $OutputDir "${name}.kml"

    # Pentru profilul `all`: genereaza KML din norm CSV daca lipseste
    if ($profile -eq "all" -and (-not (Test-Path $kmlFile) -or (Get-Item $kmlFile).Length -eq 0)) {
        if ((Test-Path $csvNorm) -and (Get-Item $csvNorm).Length -gt 0) {
            [void](New-KmlFromNormCsv -CsvPath $csvNorm -KmlPath $kmlFile -TrackName $name)
        }
    }

    # Selecteaza artefactele
    $hasSrt = (Test-Path $srtFile) -and (Get-Item $srtFile).Length -gt 0
    $wantCsvNorm = $false; $wantCsvBasic = $false; $wantCsvFull = $false; $wantGpx = $false; $wantKml = $false
    switch ($profile) {
        "srt"         { }
        "srt_csv"     {
            $wantCsvNorm = (Test-Path $csvNorm) -and (Get-Item $csvNorm).Length -gt 0
        }
        "srt_csv_gpx" {
            $wantCsvNorm = (Test-Path $csvNorm) -and (Get-Item $csvNorm).Length -gt 0
            $wantGpx     = (Test-Path $gpxFile) -and (Get-Item $gpxFile).Length -gt 0
        }
        "all" {
            $wantCsvNorm  = (Test-Path $csvNorm)  -and (Get-Item $csvNorm).Length  -gt 0
            $wantCsvBasic = (Test-Path $csvBasic) -and (Get-Item $csvBasic).Length -gt 0
            $wantCsvFull  = (Test-Path $csvFull)  -and (Get-Item $csvFull).Length  -gt 0
            $wantGpx      = (Test-Path $gpxFile)  -and (Get-Item $gpxFile).Length  -gt 0
            $wantKml      = (Test-Path $kmlFile)  -and (Get-Item $kmlFile).Length  -gt 0
        }
    }
    $totalArtifacts = @($hasSrt,$wantCsvNorm,$wantCsvBasic,$wantCsvFull,$wantGpx,$wantKml) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count
    if ($totalArtifacts -eq 0) {
        Write-Host "  [SKIP] Embed: nu exista artefacte de embed pentru profilul '$profile'" -ForegroundColor DarkGray
        return
    }

    # Container decision (per profil)
    $targetExt = "mkv"
    switch ($profile) {
        "srt" {
            if ($srcExt -in @("mkv","mp4","mov","m4v")) { $targetExt = $srcExt } else { $targetExt = "mkv" }
        }
        "all" { $targetExt = "mkv" }
        default {
            switch -Regex ($srcExt) {
                '^mkv$' { $targetExt = "mkv"; break }
                '^(mp4|mov|m4v)$' {
                    Write-Host ""
                    Write-Host "  Sursa este .$srcExt - MP4/MOV nu suporta attachments (CSV/GPX)." -ForegroundColor Yellow
                    Write-Host "    1) Convert la MKV - embed total [recomandat]" -ForegroundColor White
                    Write-Host "    2) Pastreaza .$srcExt - doar SRT (mov_text); CSV/GPX raman side-files" -ForegroundColor White
                    Write-Host "    3) Skip embed pentru acest fisier" -ForegroundColor White
                    $embCh = Read-Host "  Alege 1-3 [implicit: 1]"
                    if (-not $embCh) { $embCh = "1" }
                    switch ($embCh) {
                        "1" { $targetExt = "mkv" }
                        "2" { $targetExt = $srcExt }
                        "3" { Write-Host "  Embed sarit" -ForegroundColor DarkGray; return }
                        default { $targetExt = "mkv" }
                    }
                    break
                }
                default { $targetExt = "mkv" }
            }
        }
    }

    $out = Join-Path $OutputDir "${name}_telem.${targetExt}"

    # Build ffmpeg args
    $ffArgs = [System.Collections.Generic.List[string]]@("-v","error","-i",$f.FullName)
    # NU mapam pista de date sursa (djmd/dbgi/tmcd/gpmd): ffmpeg le vede ca
    # codec=none (proprietare) -> -c copy esueaza (MP4: "tag for codec none";
    # MKV: "Only audio/video/subtitles") -> embed pica. -dn (mai jos) le elimina;
    # telemetria e re-exprimata ca SRT + CSV + GPX + KML. Raw-ul brut via opt 5/Raw.
    $ffMaps = [System.Collections.Generic.List[string]]@("-map","0:v","-map","0:a?")
    $ffMeta = [System.Collections.Generic.List[string]]@()
    $subsCodec = "copy"

    if ($hasSrt) {
        $ffArgs.AddRange([string[]]@("-i",$srtFile))
        $ffMaps.AddRange([string[]]@("-map","1:s"))
        $subsCodec = if ($targetExt -eq "mkv") { "srt" } else { "mov_text" }
        $ffMeta.AddRange([string[]]@("-metadata:s:s:0","title=Telemetry"))
        $ffMeta.AddRange([string[]]@("-metadata:s:s:0","language=eng"))
    }

    if ($targetExt -eq "mkv") {
        $attIdx = 0
        if ($wantCsvNorm) {
            $ffArgs.AddRange([string[]]@("-attach",$csvNorm))
            $ffMeta.AddRange([string[]]@("-metadata:s:t:${attIdx}","mimetype=text/csv"))
            $attIdx++
        }
        if ($wantCsvBasic) {
            $ffArgs.AddRange([string[]]@("-attach",$csvBasic))
            $ffMeta.AddRange([string[]]@("-metadata:s:t:${attIdx}","mimetype=text/csv"))
            $attIdx++
        }
        if ($wantCsvFull) {
            $ffArgs.AddRange([string[]]@("-attach",$csvFull))
            $ffMeta.AddRange([string[]]@("-metadata:s:t:${attIdx}","mimetype=text/csv"))
            $attIdx++
        }
        if ($wantGpx) {
            $ffArgs.AddRange([string[]]@("-attach",$gpxFile))
            $ffMeta.AddRange([string[]]@("-metadata:s:t:${attIdx}","mimetype=application/gpx+xml"))
            $attIdx++
        }
        if ($wantKml) {
            $ffArgs.AddRange([string[]]@("-attach",$kmlFile))
            $ffMeta.AddRange([string[]]@("-metadata:s:t:${attIdx}","mimetype=application/vnd.google-earth.kml+xml"))
            $attIdx++
        }
    }

    $ffArgs.AddRange($ffMaps)
    $ffArgs.AddRange([string[]]@("-dn","-c:v","copy","-c:a","copy"))
    if ($hasSrt) { $ffArgs.AddRange([string[]]@("-c:s",$subsCodec)) }
    $ffArgs.AddRange($ffMeta)
    if ($targetExt -in @("mp4","mov","m4v")) {
        # v57: tag codec_tag pe MP4/MOV — stream copy pastreaza tag-ul sursei
        # (adesea hev1) → DV-aware players nu engaja. Detectam codec sursa.
        # v61 audit: [0] prima linie — DJI Action 6 v:0 dublu-listat → array.Trim()
        # ar da ["hevc","hevc"] → Get-CodecTagForContainer dubla -tag:v.
        $srcCodec = "$(@(& ffprobe -v error -select_streams v:0 `
            -show_entries stream=codec_name `
            -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null)[0])".Trim()
        $telemTag = Get-CodecTagForContainer $srcCodec $targetExt
        if ($telemTag.Count -gt 0) { $ffArgs.AddRange([string[]]$telemTag) }
        $ffArgs.AddRange([string[]]@("-movflags","+faststart"))
    }
    $ffArgs.AddRange([string[]]@($out,"-y"))

    & ffmpeg @ffArgs 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
        $sizeStr = Format-Bytes (Get-Item $out).Length
        $embStr = ""
        if ($hasSrt) { $embStr += " SRT" }
        if ($targetExt -eq "mkv") {
            if ($wantCsvNorm)  { $embStr += " norm" }
            if ($wantCsvBasic) { $embStr += " basic" }
            if ($wantCsvFull)  { $embStr += " FULL" }
            if ($wantGpx)      { $embStr += " GPX" }
            if ($wantKml)      { $embStr += " KML" }
        }
        Write-Host "  [OK] Embed [$profile]: ${name}_telem.${targetExt} ($sizeStr) -${embStr}" -ForegroundColor Green
    } else {
        Write-Host "  [EROARE] Embed esuat" -ForegroundColor Red
        Remove-Item $out -Force -ErrorAction SilentlyContinue
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
            $normHeader = "timestamp,lat,lon,alt_m,speed_mps,speed_kmh,heading_deg,gforce_x,gforce_y,gforce_z,gyro_x,gyro_y,gyro_z,temp_c,hr_bpm,cadence_rpm,power_w,pitch_deg,roll_deg,yaw_deg,fix_quality,num_sats,hdop,source_brand"
            $normRow    = "$ts,$lat,$lon,$alt,,,,,,,,,,,,,,,,,,,,quicktime"
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
    elseif ($choice -eq "6") { Write-Host "  [INFO] QuickTime: foloseste $(if ($env:AV_TOOL_EXIFTOOL) { $env:AV_TOOL_EXIFTOOL } else { "exiftool" }) -gps:all= pentru a sterge tag-urile (fara remux)" -ForegroundColor DarkGray }
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

    # dupa extractie, embed in container daca user a ales opt 7
    if ($EmbedAfter -and $brand -ne "unknown") {
        Invoke-EmbedTelemetryLossless $f $name
    }
}

# ── Curatenie ────────────────────────────────────────────────────────
if ($gpxFmt) { Remove-Item $gpxFmt -Force -ErrorAction SilentlyContinue }
if ($srtFmt) { Remove-Item $srtFmt -Force -ErrorAction SilentlyContinue }
if ($djiBasicFmt) { Remove-Item $djiBasicFmt -Force -ErrorAction SilentlyContinue }
if ($djiNormFmt) { Remove-Item $djiNormFmt -Force -ErrorAction SilentlyContinue }
if ($gpmfPy) { Remove-Item $gpmfPy -Force -ErrorAction SilentlyContinue }

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "FINALIZAT — $done fisiere procesate" -ForegroundColor Green
Write-Host "Output: $OutputDir" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor Cyan
Read-Host
