# v61 audit: Get-FFprobeValue / Get-SourceCodec robustete.
# Doua bug-uri pe surse reale (descoperite la auditul pre-productie):
#   (A) csv=p=0 single-field emite trailing comma pe surse cu [SIDE_DATA]
#       (HDR10/HDR10+/DV/HEVC HDR): "smpte2084," / "hevc," / "1920," → -eq/switch esueaza,
#       -match '^\d+$' pe width/bitrate corupte. .Trim() NU scoate virgula.
#   (B) DJI Action 6: -select_streams v:0 raporteaza streamul de 2 ori → `-join ""` /
#       Out-String / array.Trim() concatena valorile ("hevchevc" / "26882688x15121512").
# Fix: default=noprint_wrappers=1:nokey=1 + prima linie ([0] / Select -First 1).
# Paritate cu bash (default= + head -1 / awk '...{exit}').
# Trigger-ul trailing-comma cere side_data real (HDR10+ dinamic) — nu se reproduce cu
# testsrc sintetic → garda principala = assertion la nivel de sursa (pattern fix prezent).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$PROJECT_ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$ENCODE_PS1 = Join-Path $PROJECT_ROOT "src\av_encode.ps1"
$CHECK_PS1  = Join-Path $PROJECT_ROOT "src\av_check.ps1"
$MUX_PS1    = Join-Path $PROJECT_ROOT "src\av_mux.ps1"
$ENCODE_TXT = Get-Content $ENCODE_PS1 -Raw
$CHECK_TXT  = Get-Content $CHECK_PS1 -Raw
$MUX_TXT    = Get-Content $MUX_PS1 -Raw

# ── 1. Source-level: helperii single-value folosesc default= + prima linie ──
# (NotContains pe '-of csv=p=0' — patternul buggy exact; comentariile mentioneaza
#  "csv=p=0" fara "-of", deci nu produc fals-pozitiv.)
$gfp = [regex]::Match($ENCODE_TXT, 'function Get-FFprobeValue\s*\{.*?\n\}', 'Singleline').Value
Assert-Nonzero $gfp.Length "av_encode Get-FFprobeValue gasit"
Assert-Match $gfp 'default=noprint_wrappers=1:nokey=1' "av_encode Get-FFprobeValue foloseste default="
Assert-NotContains $gfp '-of csv=p=0' "av_encode Get-FFprobeValue NU mai foloseste -of csv=p=0"
Assert-Match $gfp '\$v\[0\]' "av_encode Get-FFprobeValue ia prima linie (\$v[0])"

$gfpc = [regex]::Match($CHECK_TXT, 'function Get-FFprobeValue\s*\{.*?\n\}', 'Singleline').Value
Assert-Nonzero $gfpc.Length "av_check Get-FFprobeValue gasit"
Assert-Match $gfpc 'default=noprint_wrappers=1:nokey=1' "av_check Get-FFprobeValue foloseste default="
Assert-NotContains $gfpc '-of csv=p=0' "av_check Get-FFprobeValue NU mai foloseste -of csv=p=0"
Assert-Match $gfpc '\$v\[0\]' "av_check Get-FFprobeValue ia prima linie"

$gsc = [regex]::Match($ENCODE_TXT, 'function Get-SourceCodec\s*\{.*?\n\}', 'Singleline').Value
Assert-Match $gsc '\[0\]' "av_encode Get-SourceCodec ia prima linie [0]"
Assert-NotContains $gsc '-of csv=p=0' "av_encode Get-SourceCodec foloseste default="
$gscm = [regex]::Match($MUX_TXT, 'function Get-SourceCodec\s*\{.*?\n\}', 'Singleline').Value
Assert-Match $gscm '\[0\]' "av_mux Get-SourceCodec ia prima linie [0]"

# ── 2. Functional sanity: Get-FFprobeValue pe o sursa HDR10 reala → valori curate ──
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue) -or -not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Skip-Test "ffmpeg/ffprobe lipsesc — sar testul functional"
}

Import-AvEncodeFunctions -Names @('Get-FFprobeValue') | Out-Null

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("v61ffp_" + [guid]::NewGuid().ToString('N') + ".mp4")
& ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=30" `
    -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast -tag:v hvc1 `
    -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc `
    -x265-params "hdr10=1:hdr10-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" `
    -an $tmp 2>$null | Out-Null

if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -eq 0) {
    Skip-Test "nu am putut genera sample HDR10 (libx265?)"
}

$codec    = Get-FFprobeValue $tmp "v:0" "codec_name"
$transfer = Get-FFprobeValue $tmp "v:0" "color_transfer"
$width    = Get-FFprobeValue $tmp "v:0" "width"

Assert-Eq 'hevc' $codec "codec_name curat (fara trailing comma, fara dublare)"
Assert-NotContains $codec ',' "codec_name NU contine virgula"
Assert-Eq 'smpte2084' $transfer "color_transfer = smpte2084 (comma ar fi spart -eq)"
Assert-Match $width '^\d+$' "width pur numeric (fara comma, fara dublare)"
Assert-Eq '320' $width "width = 320 exact"

Remove-Item $tmp -Force -ErrorAction SilentlyContinue
Invoke-TestSummary
