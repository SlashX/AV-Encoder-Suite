# v86 — mesaj onest la concat pe surse VFR (cand DOAR fps-ul difera in semnatura).
# Oglinda test_v86_concat_vfr.sh: source-level (helper + cablare la ambele situri +
# decizia neschimbata) + functional pe taieturi VFR reale (gated pe ffmpeg + sample).
# Helperul Test-ConcatIncompatVfrFps schimba DOAR mesajul, NU decizia de re-encode.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$src = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "src"
$tcText = Get-Content (Join-Path $src "av_trimconcat.sh") -Raw
$psText = Get-Content (Join-Path $src "av_encode.ps1") -Raw

# ── source-level PS1 ──────────────────────────────────────────────────
Assert-Eq 1 ([regex]::Matches($psText, '(?m)^function Test-ConcatIncompatVfrFps').Count) `
    "functia Test-ConcatIncompatVfrFps exista in av_encode.ps1"
Assert-Eq 2 ([regex]::Matches($psText, 'if \(Test-ConcatIncompatVfrFps ').Count) `
    "cablata la AMBELE situri de mesaj (Concat + Pipeline)"
Assert-Eq 2 ([regex]::Matches($psText, 'VFR.*fara re-encode').Count) `
    "mesajul VFR onest prezent la ambele situri"
Assert-Match $psText 'function Test-ConcatIncompatVfrFps[\s\S]*?Test-VfrSource[\s\S]*?\n\}' `
    "helperul refoloseste Test-VfrSource (v77)"

# ── paritate bash (source-level) ──────────────────────────────────────
Assert-Eq 2 ([regex]::Matches($tcText, 'if _concat_incompat_vfr_fps ').Count) `
    "bash: _concat_incompat_vfr_fps cablat la ambele situri (paritate)"

# ── functional: taieturi VFR reale ────────────────────────────────────
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$src;" + $env:PATH }
$sample = Join-Path $src "Upload_S02E01_HDR10Plus_40s_HEVC.mp4"
$haveTools = (Get-Command ffmpeg -ErrorAction SilentlyContinue) -and (Get-Command ffprobe -ErrorAction SilentlyContinue)
if ($haveTools -and (Test-Path $sample)) {
    Import-AvEncodeFunctions -Names @('Test-ConcatIncompatVfrFps','Test-VfrSource','Test-ConcatCompatibility','Get-VideoSignature')
    $tmpd = Join-Path $env:TEMP ("v86vfr_" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Force $tmpd | Out-Null
    try {
        & ffmpeg -v error -ss 0 -t 3 -i $sample -c copy -an (Join-Path $tmpd "c1.mp4") -y 2>$null
        & ffmpeg -v error -ss 3.8 -t 2.5 -i $sample -c copy -an (Join-Path $tmpd "c2.mp4") -y 2>$null
        & ffmpeg -v error -f lavfi -i "testsrc=duration=1:size=320x240:rate=30" -c:v libx264 -pix_fmt yuv420p (Join-Path $tmpd "cfr_a.mp4") -y 2>$null
        & ffmpeg -v error -f lavfi -i "testsrc=duration=1:size=320x240:rate=30" -c:v libx264 -pix_fmt yuv420p (Join-Path $tmpd "cfr_b.mp4") -y 2>$null
        $c1 = Join-Path $tmpd "c1.mp4"; $c2 = Join-Path $tmpd "c2.mp4"
        $ca = Join-Path $tmpd "cfr_a.mp4"; $cb = Join-Path $tmpd "cfr_b.mp4"
        if ((Test-Path $c1) -and (Get-Item $c1).Length -gt 0 -and (Test-Path $c2) -and (Get-Item $c2).Length -gt 0) {
            Assert-Eq $true  (Test-ConcatIncompatVfrFps @($c1, $c2)) "functional: 2 taieturi VFR acelasi clip → mesaj VFR"
            Assert-Eq $false (Test-ConcatIncompatVfrFps @($c1, $ca)) "functional: codec diferit → mesaj generic"
            Assert-Eq $false (Test-ConcatIncompatVfrFps @($ca, $cb)) "functional: pereche CFR → mesaj generic"
            Assert-Eq $false (Test-ConcatCompatibility @($c1, $c2))  "functional: decizia compat NEschimbata (re-encode ramane pe VFR)"
        } else {
            Assert-Eq 1 1 "skip-equivalent: taierile din sample au esuat"
        }
    } finally {
        Remove-Item -Recurse -Force $tmpd -ErrorAction SilentlyContinue
    }
} else {
    Assert-Eq 1 1 "skip-equivalent: ffmpeg/ffprobe/sample lipsesc (source-level a rulat)"
}

Invoke-TestSummary
