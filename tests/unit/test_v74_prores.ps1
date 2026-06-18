# v74: ProRes polish (mirror PS1 al test_v74_prores.sh) — (B) av_check profil din codec_tag,
#   (A) 4444/XQ alpha-aware, (C) container mov/mxf. Source-level + functional (guarded pe ffmpeg).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT "src"
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$CHK = Get-Content (Join-Path $SRC "av_check.ps1") -Raw
$ENC = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw

# ── B: av_check — profil ProRes din codec_tag ───────────────────────────
Assert-Match $CHK ([regex]::Escape('if ($codec -eq "prores")'))          "B: codec_tag probat doar pe prores"
Assert-Match $CHK ([regex]::Escape('"apco"  { "Apple ProRes Proxy" }'))  "B: apco -> Proxy"
Assert-Match $CHK ([regex]::Escape('"apch"  { "Apple ProRes HQ" }'))     "B: apch -> HQ"
Assert-Match $CHK ([regex]::Escape('"ap4x"  { "Apple ProRes 4444 XQ" }')) "B: ap4x -> 4444 XQ"

# ── A: encoder — 4444/XQ alpha-aware ────────────────────────────────────
Assert-Match $ENC ([regex]::Escape('$proresPixFmt = "yuv422p10le"; $proresAlphaNote = ""')) "A: default FARA alpha"
Assert-Match $ENC ([regex]::Escape('$proresProfile -in @("4444","xq","4444xq")'))           "A: gate pe 4444/XQ"
Assert-Match $ENC ([regex]::Escape('$proresPixFmt = "yuva444p10le"; $proresAlphaNote = ", alpha"')) "A: alpha pastrat doar daca sursa o are"

# ── C: av_encode — ProRes ofera mov/mxf ─────────────────────────────────
Assert-Match $ENC ([regex]::Escape('Container ProRes'))                              "C: ProRes dialog container"
Assert-Match $ENC ([regex]::Escape('$container -eq "mxf" -and $audioCodec -ne "pcm"')) "C: MXF=PCM gardat pe container (acopera ProRes)"

# ── A logic: decizie alpha pe pix_fmt (determinist) ─────────────────────
function _AlphaPf($pf) { if ($pf -match '^yuva|^ya8|^ya16|rgba|argb|abgr|bgra|gbrap|^pal8') { "alpha" } else { "noalpha" } }
Assert-Eq "noalpha" (_AlphaPf "yuv420p")      "A logic: yuv420p -> no alpha"
Assert-Eq "noalpha" (_AlphaPf "yuv444p10le")  "A logic: yuv444p10le -> no alpha"
Assert-Eq "noalpha" (_AlphaPf "gray")         "A logic: gray -> no alpha"
Assert-Eq "alpha"   (_AlphaPf "yuva444p10le") "A logic: yuva444p10le -> alpha"
Assert-Eq "alpha"   (_AlphaPf "rgba")         "A logic: rgba -> alpha"

# ── Functional (guarded): codec_tag profil + ProRes->MXF + 4444 no-alpha ──
if ((Get-Command ffmpeg -ErrorAction SilentlyContinue) -and (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    $td = Join-Path ([IO.Path]::GetTempPath()) ("v74pr_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $td | Out-Null
    & ffmpeg -y -v error -f lavfi -i "testsrc=size=320x240:rate=25" -t 1 -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -vendor apl0 -an "$td\hq.mov" 2>$null
    $tag = (& ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=noprint_wrappers=1:nokey=1 "$td\hq.mov" 2>$null | Select-Object -First 1)
    if ($tag) { $tag = $tag.Trim() }
    Assert-Eq "apch" $tag "functional B: ProRes HQ -> codec_tag apch"
    & ffmpeg -y -v error -f lavfi -i "testsrc=size=320x240:rate=25" -t 1 -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -an "$td\hq.mxf" 2>$null
    Assert-Eq $true ((Test-Path "$td\hq.mxf") -and ((Get-Item "$td\hq.mxf").Length -gt 0)) "functional C: ProRes -> MXF reuseste"
    & ffmpeg -y -v error -f lavfi -i "testsrc=size=320x240:rate=25" -t 1 -c:v prores_ks -profile:v 4 -pix_fmt yuv444p10le -vendor apl0 -an "$td\4444.mov" 2>$null
    $opf = (& ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$td\4444.mov" 2>$null | Select-Object -First 1)
    if ($opf) { $opf = $opf.Trim() }
    Assert-Eq $false ([bool]($opf -match '^yuva')) "functional A: 4444 sursa fara alpha -> output $opf (fara alpha)"
    Remove-Item -Recurse -Force $td -ErrorAction SilentlyContinue
} else {
    Write-Host "  (info: ffmpeg/ffprobe indisponibil — sar functionalul)"
}

Invoke-TestSummary
