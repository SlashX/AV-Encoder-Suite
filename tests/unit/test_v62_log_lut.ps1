# v62 — flux LOG + LUT (Faza A): detectie + dialog.
#   Bug 1  — fallback bit-depth pe pix_fmt (bits_per_raw_sample e N/A pe HEVC 10-bit).
#   Finding 4 — exclude HLG (arib-std-b67) din ramurile Log (samsung/dji/unknown).
#   Bug 2  — culoarea bt709 in params encoder (x265-params/x264-params) pe LUT/Creative.
#   Bug 3  — conversia fara-LUT (zscale tonemap) ELIMINATA din ramura LOG (main+burnin+tc).
#   + fallback LUT relaxat (orice .cube cand nu exista prefix de brand).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
# ffmpeg: global (PATH) sau bundle-uit in src/ (Windows testing) — ca la run_tests.ps1 / v55-v56
$src = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$src;$env:PATH" }
$ENC = Get-Content (Join-Path $ROOT "src\av_encode.ps1") -Raw
$CHK = Get-Content (Join-Path $ROOT "src\av_check.ps1") -Raw
$BRN = Get-Content (Join-Path $ROOT "src\av_burnin.ps1") -Raw

# ── 1. Bug 3 — conversiile fara-LUT scoase din dialogul LOG ──
$sld = [regex]::Match($ENC, 'function Show-LogDialog.*?\n}', 'Singleline').Value
Assert-Nonzero $sld.Length "Show-LogDialog gasit"
Assert-NotContains $sld 'Convert SDR (fara LUT)'   "Show-LogDialog: scos Convert SDR fara-LUT"
Assert-NotContains $sld 'Convert HDR10 (fara LUT)' "Show-LogDialog: scos Convert HDR10 fara-LUT"
Assert-NotContains $sld 'Convert HLG (fara LUT)'   "Show-LogDialog: scos Convert HLG fara-LUT"
Assert-Match $sld 'NU poate fi transformat' "Show-LogDialog: mesaj onest cand nu exista LUT"

# ── 2. Bug 2 — culoare in params encoder pe calea LUT ──
Assert-Match $sld 'logExtraX265 = "colorprim=bt709:transfer=bt709:colormatrix=bt709"' "Show-LogDialog: LUT seteaza logExtraX265 bt709"
Assert-Match $sld 'logExtraX264 = "colorprim=bt709:transfer=bt709:colormatrix=bt709"' "Show-LogDialog: LUT seteaza logExtraX264 bt709"
# plumbing x264-params
Assert-Match $ENC 'if \(\$script:logExtraX264\) \{ \$x264Parts \+= \$script:logExtraX264 \}' "x264: logExtraX264 injectat in x264-params"

# ── 3. Bug 1 + Finding 4 — bit-depth fallback + arib exclus in Get-SourceInfoExtended ──
$gse = [regex]::Match($ENC, 'function Get-SourceInfoExtended.*?\n}', 'Singleline').Value
Assert-Match $gse "pfBd" "Get-SourceInfoExtended: fallback bit-depth pe pix_fmt"
Assert-Match $gse 'transfer -ne "arib-std-b67"' "Get-SourceInfoExtended: HLG exclus din ramura Log"
# av_check Get-LogProfile arib exclus
$glp = [regex]::Match($CHK, 'function Get-LogProfile.*?\n}', 'Singleline').Value
Assert-Match $glp 'arib-std-b67' "av_check Get-LogProfile: arib exclus"

# ── 4. Burn-in — tonemap-for-LOG scos ──
Assert-Match $BRN 'conversia fara-LUT \(tonemap\) ELIMINATA pe LOG' "Burn-in: tonemap LOG eliminat"

# ── 4b. v62 audit FIX — logExtraX264 resetat in Show-LogDialog SI in run-loop (anti-leak x264) ──
# x264 consuma $script:logExtraX264 neconditionat (linia ~6859) → fara reset per-fisier in
# run-loop, un fisier LOG (x264+LUT) contamina culoarea fisierului NE-LOG urmator.
$x264ResetCount = ([regex]::Matches($ENC, '\$script:logExtraX264\s*=\s*""')).Count
Assert-Eq $true ($x264ResetCount -ge 2) "logExtraX264 resetat in Show-LogDialog + run-loop (anti-leak x264)"

# ── 4c. v62 audit FIX — setparams re-eticheteaza culoarea dupa lut3d (MKV mis-tag) ──
# lut3d NU actualizeaza metadata de culoare a frame-urilor → pe MKV (Matroska Colour din
# frame, nu VUI/SPS) iesirea LUT ramanea bt2020/unknown. setparams o forteaza la tinta.
Assert-Match $ENC ',setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709' "av_encode: setparams bt709 dupa lut3d (Show-LogDialog Rec.709/Creative + Trim/Concat)"
Assert-Match $ENC ',setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc' "av_encode: setparams bt2020/arib dupa lut3d (Log→HLG)"
Assert-Match $BRN ',setparams=color_primaries=bt709' "Burn-in lut_rec709: setparams bt709 dupa lut3d"

# ── 5. Functional — Finding 4: sursa HLG (arib) NU e clasificata Log ──
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Skip-Test "ffmpeg lipseste" }
Import-AvEncodeFunctions -Names @('Get-FFprobeValue','Get-SourceInfoExtended') | Out-Null
$script:forceLogDetection = $false
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("v62hlg_" + [guid]::NewGuid().ToString('N') + ".mp4")
& ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=30" `
    -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast -tag:v hvc1 `
    -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc `
    -x265-params "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:log-level=none" `
    -an $tmp 2>$null | Out-Null
if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -eq 0) { Skip-Test "nu am putut genera clip HLG" }
$ext = Get-SourceInfoExtended $tmp @{ isDji = $false }
Assert-Eq "" $ext.logProfile "HLG (arib) 10-bit bt2020 NU e clasificat Log (Finding 4)"
Assert-Eq $true $ext.isHLG "HLG (arib) detectat ca HLG"
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
Invoke-TestSummary
