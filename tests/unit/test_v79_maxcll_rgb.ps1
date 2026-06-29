# v79 — MaxCLL/MaxFALL RGB-precis (CTA-861.3). PS1 mirror al test_v79_maxcll_rgb.sh.
#   max(R,G,B) per pixel via extractplanes+blend lighten (NU luma). Source-level + functional real.
. "$PSScriptRoot\..\framework.ps1"

$src    = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src'
$common = Get-Content (Join-Path $src 'av_common.sh') -Raw
$encPs  = Get-Content (Join-Path $src 'av_encode.ps1') -Raw

# ── 1. Source-level: lant RGB-precis prezent in AMBELE (santinela anti-revert la luma) ──
Assert-Eq $true  ($common.Contains('extractplanes=r+g+b'))   "bash: extractplanes R/G/B"
Assert-Eq $true  ($common.Contains('blend=all_mode=lighten')) "bash: blend lighten = max(R,G,B)"
Assert-Eq $true  ($common.Contains('format=gbrp16le'))        "bash: liniarizare RGB 16-bit"
Assert-Eq $false ($common.Contains('format=yuv444p16le'))     "bash: luma-based scos (anti-revert)"
Assert-Eq $true  ($encPs.Contains('extractplanes=r+g+b'))     "PS1: extractplanes R/G/B"
Assert-Eq $true  ($encPs.Contains('blend=all_mode=lighten'))  "PS1: blend lighten = max(R,G,B)"
Assert-Eq $true  ($encPs.Contains('format=gbrp16le'))         "PS1: liniarizare RGB 16-bit"
Assert-Eq $false ($encPs.Contains('format=yuv444p16le'))      "PS1: luma-based scos (anti-revert)"

# ── 2. Paritate: signalstats neschimbat (vede planul max(R,G,B) ca "luma") ──
Assert-Eq $true ($common.Contains('signalstats,metadata=print')) "bash: signalstats pe planul max(R,G,B)"
Assert-Eq $true ($encPs.Contains('signalstats,metadata=print'))  "PS1: signalstats pe planul max(R,G,B)"

# ── 3. Functional: albastru saturat PQ → RGB-precis > luma (dovada ca NU e luma) ──
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$src;$env:PATH" }
if ((Get-Command ffmpeg -ErrorAction SilentlyContinue) -and (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'av_encode.ps1'), [ref]$null, [ref]$null)
    $fn = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Measure-Hdr10Cll'}, $true) | Select-Object -First 1
    Invoke-Expression $fn.Extent.Text
    $g = [guid]::NewGuid().ToString('N').Substring(0,8)
    $blue = Join-Path $env:TEMP "blue_pq_$g.mp4"
    & ffmpeg -v error -y -f lavfi -i "color=c=blue:s=320x240:r=10:d=1" `
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast `
        -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:log-level=none" `
        -an $blue 2>$null | Out-Null
    if (Test-Path $blue) {
        $null = Measure-Hdr10Cll -File $blue
        $rgbCll = 0; if ($script:hdr10MeasuredCll -match '^(\d+),') { $rgbCll = [int]$Matches[1] }
        $ymax = 0.0
        & ffmpeg -hide_banner -v error -i $blue `
            -vf "zscale=t=linear:npl=10000,format=yuv444p16le,signalstats,metadata=print:file=-" `
            -an -f null - 2>$null | ForEach-Object {
            if ($_ -match 'YMAX=([\d.]+)') { $v = [double]$Matches[1]; if ($v -gt $ymax) { $ymax = $v } }
        }
        $lumaCll = [int][math]::Round($ymax / 65535.0 * 10000)
        if ($rgbCll -gt 0 -and $lumaCll -gt 0) {
            Assert-Eq $true ($rgbCll -gt $lumaCll) "functional: RGB-precis ($rgbCll) > luma ($lumaCll) pe albastru saturat"
        }
        Remove-Item $blue -Force -ErrorAction SilentlyContinue
    }
}

Invoke-TestSummary
