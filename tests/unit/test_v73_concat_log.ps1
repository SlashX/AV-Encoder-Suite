# v73: Concat LOG awareness (mirror PS1 al test_v73_concat_log.sh). Get-PipelineHdrMode NU
#   clasifica LOG (cade pe sdr) → pana acum LOG la Concat re-encode trecea TACUT (fara LUT,
#   fara nota, culoare mis-tagged). Acum: Get-ConcatLogMode (agregat N→1, autoritar via
#   Get-SourceInfoExtended) + hook pe ramura sdr din Invoke-ConcatFlow → LUT / Keep LOG / Skip.
#   Functional pe Get-ConcatLogMode prin AST + mock (determinist, fara ffprobe/python).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$ENC  = Get-Content (Join-Path $ROOT "src\av_encode.ps1") -Raw

# ── 1. Source-level: helper definit + hook in Concat (ramura sdr) ──
Assert-Match $ENC 'function Get-ConcatLogMode' "Get-ConcatLogMode definit"
Assert-Match $ENC ([regex]::Escape('$logAgg = Get-ConcatLogMode')) "concat: hook LOG pe agregat sdr"
Assert-Match $ENC ([regex]::Escape('Get-PipelineHdrMode nu clasifica LOG')) "concat: comentariu hook v73"

# ── 2. Build-TcVideoArgs: lut_rec709 = lut3d + setparams (repara mis-tag); keep_log = no-transform ──
$btv = [regex]::Match($ENC, '(?s)function Build-TcVideoArgs.*?\n(?=function )').Value
Assert-Match $btv ([regex]::Escape('"keep_log" { return $true }')) "Build-TcVideoArgs keep_log -> fara transform"
Assert-Match $btv 'lut3d='                              "Build-TcVideoArgs lut_rec709 -> lut3d"
Assert-Match $btv 'setparams=color_primaries=bt709'     "Build-TcVideoArgs lut_rec709 -> setparams (repara mis-tag bt709)"

# ── 3. Agregare N→1 via AST import + mock (determinist) ──
. "$PSScriptRoot\..\_helpers.ps1"
Import-AvEncodeFunctions -Names @('Get-ConcatLogMode') | Out-Null

$global:InputDir = ""
function global:Get-DJITracks { param($f) @() }
function global:Get-SourceInfoExtended {
    param($f, $dji)
    if ($f -like '*_dlogdji*') { return [pscustomobject]@{ logProfile = 'dlog_m';      cameraMake = 'dji' } }
    if ($f -like '*_logsam*')  { return [pscustomobject]@{ logProfile = 'samsung_log'; cameraMake = 'samsung' } }
    return [pscustomobject]@{ logProfile = ''; cameraMake = '' }
}
$global:LutPresent = $false
function global:Find-LutForBrand {
    param($b, $d1, $d2)
    if ($global:LutPresent) {
        return [pscustomobject]@{ files = @([pscustomobject]@{ Name = "${b}_rec709.cube"; FullName = "/fake/$b.cube" }) }
    }
    return [pscustomobject]@{ files = @() }
}

Assert-Eq "none"    (Get-ConcatLogMode @('a_sdr.mp4','b_sdr.mp4'))          "agregat: 0 surse LOG -> none"
$global:LutPresent = $false
Assert-Eq "keep"    (Get-ConcatLogMode @('a_dlogdji.mp4','b_dlogdji.mp4')) "agregat: LOG dji fara LUT -> keep"
$global:LutPresent = $true
Assert-Eq "lut:dji" (Get-ConcatLogMode @('a_dlogdji.mp4','b_dlogdji.mp4')) "agregat: LOG dji + LUT -> lut:dji"
Assert-Eq "keep"    (Get-ConcatLogMode @('a_dlogdji.mp4','b_logsam.mp4'))  "agregat: branduri mixte -> keep"
Assert-Eq "keep"    (Get-ConcatLogMode @('a_dlogdji.mp4','b_sdr.mp4'))     "agregat: LOG+SDR mixt -> keep"

Invoke-TestSummary
