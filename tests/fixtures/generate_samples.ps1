# ═══════════════════════════════════════════════════════════════
#  generate_samples.ps1 — synthesize tiny test media files via ffmpeg
#  Idempotent: skips files that already exist (override with -Force)
#  Outputs to .\samples\
# ═══════════════════════════════════════════════════════════════
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptDir   = $PSScriptRoot
$SamplesDir  = Join-Path $ScriptDir 'samples'
New-Item -ItemType Directory -Force -Path $SamplesDir | Out-Null

$haveFfmpeg = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)
if (-not $haveFfmpeg) {
    Write-Host "  WARN: ffmpeg not found - generez doar sample-urile non-video (GPX/KML)" -ForegroundColor Yellow
}

function Skip-IfExists([string]$Path) {
    if ($Force) { return $false }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Write-Host "  ~ exists: $([System.IO.Path]::GetFileName($Path))"
        return $true
    }
    return $false
}

function Invoke-Ff([string]$OutFile, [string[]]$Args) {
    $allArgs = @('-y','-hide_banner','-loglevel','error') + $Args + @($OutFile)
    & ffmpeg @allArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    FAIL: $OutFile" -ForegroundColor Red
        return $false
    }
    $size = [int]((Get-Item -LiteralPath $OutFile).Length / 1024)
    Write-Host ("  + {0} ({1} KB)" -f [System.IO.Path]::GetFileName($OutFile), $size)
    return $true
}

Write-Host "Generating synthetic samples in: $SamplesDir"

if ($haveFfmpeg) {

# 1) SDR
$out = Join-Path $SamplesDir 'sdr_320p.mp4'
if (-not (Skip-IfExists $out)) {
    Invoke-Ff $out @(
        '-f','lavfi','-i','testsrc2=duration=2:size=320x240:rate=30',
        '-f','lavfi','-i','sine=frequency=440:duration=2',
        '-c:v','libx264','-pix_fmt','yuv420p','-preset','ultrafast',
        '-c:a','aac','-b:a','64k','-shortest'
    ) | Out-Null
}

# 2) HDR10
$out = Join-Path $SamplesDir 'hdr10_320p.mkv'
if (-not (Skip-IfExists $out)) {
    Invoke-Ff $out @(
        '-f','lavfi','-i','testsrc2=duration=2:size=320x240:rate=30',
        '-c:v','libx265','-pix_fmt','yuv420p10le','-preset','ultrafast',
        '-color_primaries','bt2020','-color_trc','smpte2084','-colorspace','bt2020nc',
        '-x265-params','hdr10=1:hdr10-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400',
        '-an'
    ) | Out-Null
}

# 3) HLG
$out = Join-Path $SamplesDir 'hlg_320p.mkv'
if (-not (Skip-IfExists $out)) {
    Invoke-Ff $out @(
        '-f','lavfi','-i','testsrc2=duration=2:size=320x240:rate=30',
        '-c:v','libx265','-pix_fmt','yuv420p10le','-preset','ultrafast',
        '-color_primaries','bt2020','-color_trc','arib-std-b67','-colorspace','bt2020nc',
        '-x265-params','transfer=arib-std-b67:colormatrix=bt2020nc:colorprim=bt2020:repeat-headers=1',
        '-an'
    ) | Out-Null
}

# 4) Audio
$out = Join-Path $SamplesDir 'audio_440hz.wav'
if (-not (Skip-IfExists $out)) {
    Invoke-Ff $out @(
        '-f','lavfi','-i','sine=frequency=440:duration=1:sample_rate=48000',
        '-c:a','pcm_s16le','-ac','1'
    ) | Out-Null
}

# 5) 4s SDR for trim/concat
$out = Join-Path $SamplesDir 'sdr_4s.mp4'
if (-not (Skip-IfExists $out)) {
    Invoke-Ff $out @(
        '-f','lavfi','-i','testsrc2=duration=4:size=320x240:rate=30',
        '-f','lavfi','-i','sine=frequency=440:duration=4',
        '-c:v','libx264','-pix_fmt','yuv420p','-preset','ultrafast',
        '-c:a','aac','-b:a','64k','-shortest'
    ) | Out-Null
}

}  # if $haveFfmpeg

# 6) GPX
$out = Join-Path $SamplesDir 'sample.gpx'
if (-not (Skip-IfExists $out)) {
    @'
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="av-encoder-suite-test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>test-track</name>
    <trkseg>
      <trkpt lat="44.4268" lon="26.1025"><ele>85.0</ele><time>2025-01-01T10:00:00Z</time></trkpt>
      <trkpt lat="44.4270" lon="26.1027"><ele>86.0</ele><time>2025-01-01T10:00:01Z</time></trkpt>
      <trkpt lat="44.4272" lon="26.1029"><ele>87.0</ele><time>2025-01-01T10:00:02Z</time></trkpt>
    </trkseg>
  </trk>
</gpx>
'@ | Set-Content -LiteralPath $out -Encoding UTF8
    $size = [int]((Get-Item -LiteralPath $out).Length / 1024)
    Write-Host "  + sample.gpx ($size KB)"
}

# 7) KML
$out = Join-Path $SamplesDir 'sample.kml'
if (-not (Skip-IfExists $out)) {
    @'
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>test-track</name>
    <Placemark>
      <LineString>
        <coordinates>26.1025,44.4268,85 26.1027,44.4270,86 26.1029,44.4272,87</coordinates>
      </LineString>
    </Placemark>
  </Document>
</kml>
'@ | Set-Content -LiteralPath $out -Encoding UTF8
    $size = [int]((Get-Item -LiteralPath $out).Length / 1024)
    Write-Host "  + sample.kml ($size KB)"
}

Write-Host ""
Write-Host "Done. Samples directory: $SamplesDir"
Get-ChildItem -LiteralPath $SamplesDir | Format-Table Name, Length, LastWriteTime
