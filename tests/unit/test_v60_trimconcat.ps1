# v60: av_encode.ps1 HDR/LOG awareness pentru Trim/Concat — labels, reset, builder, env policy.
# Encoder-ele oferite la trim/concat sunt libx265/libx264 (NU svtav1).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$PROJECT_ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$ENCODE_PS1   = Join-Path $PROJECT_ROOT "src\av_encode.ps1"
$ENCODE_TXT   = Get-Content $ENCODE_PS1 -Raw
$InputDir     = Join-Path $PROJECT_ROOT "src"

# ── 1. AST parse + functii definite ────────────────────────────────
$astErrs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ENCODE_PS1, [ref]$null, [ref]$astErrs)
Assert-Eq 0 $astErrs.Count "av_encode.ps1 AST parse fara erori"

$expectedFns = @("Get-TcModeLabel", "Reset-TcHdrState", "Show-TcHdrDialog", "Build-TcVideoArgs")
foreach ($fn in $expectedFns) {
    $found = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true)
    Assert-Eq $true ($found -ne $null) "AST: function $fn definita"
}

# ── Import functii in global scope (fara a rula meniul av_encode.ps1) ──
Import-AvEncodeFunctions -ScriptPath $ENCODE_PS1 -Names @(
    "Get-TcModeLabel","Reset-TcHdrState","Show-TcHdrDialog","Build-TcVideoArgs",
    "Find-LutForBrand","Get-LogProfileLabel") | Out-Null

# ── 2. Get-TcModeLabel ─────────────────────────────────────────────
Assert-Eq "SDR (no transform)"            (Get-TcModeLabel "sdr")            "label sdr"
Assert-Eq "Preserve HDR10"                (Get-TcModeLabel "preserve_hdr10") "label preserve_hdr10"
Assert-Eq "Preserve HLG"                  (Get-TcModeLabel "preserve_hlg")   "label preserve_hlg"
Assert-Eq "Tonemap -> SDR"                (Get-TcModeLabel "tonemap")        "label tonemap"
Assert-Eq "Apply LUT (LOG -> Rec.709)"    (Get-TcModeLabel "lut_rec709")     "label lut_rec709"
Assert-Eq "Keep LOG (no color transform)" (Get-TcModeLabel "keep_log")       "label keep_log"
Assert-Eq "Skip"                          (Get-TcModeLabel "skip")           "label skip"

# ── 3. Reset-TcHdrState ────────────────────────────────────────────
$script:tcSourceType = "dv"; $script:tcMode = "tonemap"; $script:tcVfPrepend = "x"
$script:tcEncExtraArgs = @("a","b"); $script:tcLutFile = "y"; $script:tcDowngradeReason = "w"
Reset-TcHdrState
Assert-Eq "sdr" $script:tcSourceType     "reset: tcSourceType -> sdr"
Assert-Eq "sdr" $script:tcMode           "reset: tcMode -> sdr"
Assert-Eq ""    $script:tcVfPrepend      "reset: tcVfPrepend -> empty"
Assert-Eq 0     $script:tcEncExtraArgs.Count "reset: tcEncExtraArgs -> []"
Assert-Eq ""    $script:tcLutFile        "reset: tcLutFile -> empty"
Assert-Eq ""    $script:tcDowngradeReason "reset: tcDowngradeReason -> empty"

# ── 4. Build-TcVideoArgs — skip → false ───────────────────────────
Reset-TcHdrState; $script:tcMode = "skip"
Assert-Eq $false (Build-TcVideoArgs "/tmp/fake.mkv" "libx265") "build skip → false"

# ── 5. sdr / keep_log → true, no args ─────────────────────────────
Reset-TcHdrState; $script:tcMode = "sdr"
Assert-Eq $true (Build-TcVideoArgs "/tmp/fake.mkv" "libx265") "build sdr → true"
Assert-Eq "" $script:tcVfPrepend "sdr → no vf"
Assert-Eq 0 $script:tcEncExtraArgs.Count "sdr → no extra args"
Reset-TcHdrState; $script:tcMode = "keep_log"
Assert-Eq $true (Build-TcVideoArgs "/tmp/fake.mkv" "libx265") "build keep_log → true"
Assert-Eq "" $script:tcVfPrepend "keep_log → no vf"

# ── 6. tonemap → tcVfPrepend zscale + tonemap ─────────────────────
Reset-TcHdrState; $script:tcMode = "tonemap"
Build-TcVideoArgs "/tmp/fake.mkv" "libx265" | Out-Null
Assert-Contains $script:tcVfPrepend "zscale=transfer=linear" "tonemap: zscale linearization"
Assert-Contains $script:tcVfPrepend "tonemap=hable"          "tonemap: Hable"
Assert-Contains $script:tcVfPrepend "format=yuv420p"         "tonemap: final format yuv420p"

# ── 7. lut_rec709 → tcVfPrepend lut3d= ────────────────────────────
Reset-TcHdrState; $script:tcMode = "lut_rec709"; $script:tcLutFile = "C:\tmp\test_lut.cube"
Build-TcVideoArgs "/tmp/fake.mkv" "libx265" | Out-Null
Assert-Contains $script:tcVfPrepend "lut3d=" "lut_rec709: filter contine lut3d="

# ── 8. preserve_hdr10 + libx265 → 10-bit + x265-params ────────────
# Mock Resolve-Hdr10Static (nu lovim ffprobe pe fake file)
function Resolve-Hdr10Static { param([string]$File)
    $script:hdr10StaticAvailable = $true
    $script:hdr10MasterDisplayX265 = "G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1)"
    $script:hdr10MaxCll = "1000,400"
}
Reset-TcHdrState; $script:tcMode = "preserve_hdr10"
Build-TcVideoArgs "/tmp/fake.mkv" "libx265" | Out-Null
$argStr = $script:tcEncExtraArgs -join " "
Assert-Contains $argStr "yuv420p10le"      "preserve_hdr10 x265: pix_fmt 10-bit"
Assert-Contains $argStr "bt2020"           "preserve_hdr10 x265: bt2020"
Assert-Contains $argStr "smpte2084"        "preserve_hdr10 x265: smpte2084"
Assert-Contains $argStr "-x265-params"     "preserve_hdr10 x265: x265-params flag"
Assert-Contains $argStr "hdr10=1"          "preserve_hdr10 x265: hdr10=1"
Assert-Contains $argStr "master-display="  "preserve_hdr10 x265: master-display inject"
Assert-Contains $argStr "max-cll=1000,400" "preserve_hdr10 x265: max-cll inject"

# ── 9. preserve_hdr10 + libx264 → fallback tonemap ────────────────
Reset-TcHdrState; $script:tcMode = "preserve_hdr10"
Build-TcVideoArgs "/tmp/fake.mkv" "libx264" | Out-Null
Assert-Contains $script:tcVfPrepend "tonemap=hable" "preserve_hdr10 x264: auto-tonemap"
Assert-Contains $script:tcDowngradeReason "libx264" "preserve_hdr10 x264: downgrade reason"
Assert-Eq 0 $script:tcEncExtraArgs.Count "preserve_hdr10 x264: NO 10-bit args"

# ── 10. preserve_hlg + libx265 → arib-std-b67, NO hdr10=1 ─────────
Reset-TcHdrState; $script:tcMode = "preserve_hlg"
Build-TcVideoArgs "/tmp/fake.mkv" "libx265" | Out-Null
$argStr = $script:tcEncExtraArgs -join " "
Assert-Contains $argStr "arib-std-b67" "preserve_hlg x265: transfer arib-std-b67"
Assert-Contains $argStr "-x265-params" "preserve_hlg x265: x265-params flag"
Assert-Eq $false ($argStr -match "hdr10=1") "preserve_hlg x265: NO hdr10=1"

# ── 11. preserve_hlg + libx264 → fallback tonemap ─────────────────
Reset-TcHdrState; $script:tcMode = "preserve_hlg"
Build-TcVideoArgs "/tmp/fake.mkv" "libx264" | Out-Null
Assert-Contains $script:tcVfPrepend "tonemap=hable" "preserve_hlg x264: auto-tonemap"
Assert-Contains $script:tcDowngradeReason "libx264" "preserve_hlg x264: downgrade reason"

# ── 12. Show-TcHdrDialog env policy bypass ────────────────────────
# Mock detectoarele ffprobe-dependente (returneaza hashtable controlat)
$script:tcMockDji = @{ isDji = $false }
$script:tcMockSi  = @{ isHDRPlus = $false; transfer = ""; isHLG = $false }
$script:tcMockExt = @{ isDV = $false; logProfile = ""; cameraMake = "unknown"; isHLG = $false }
function Get-DJITracks { param([string]$file) return $script:tcMockDji }
function Get-SourceInfo { param([string]$file) return $script:tcMockSi }
function Get-SourceInfoExtended { param([string]$file, [hashtable]$djiInfo) return $script:tcMockExt }

# preserve + hdr10 → preserve_hdr10
$script:tcMockSi  = @{ isHDRPlus = $false; transfer = "smpte2084"; isHLG = $false }
$script:tcMockExt = @{ isDV = $false; logProfile = ""; cameraMake = "unknown"; isHLG = $false }
$env:TC_HDR_POLICY = "preserve"
Show-TcHdrDialog "/tmp/fake.mkv" "libx265" | Out-Null
Assert-Eq "preserve_hdr10" $script:tcMode "policy=preserve + hdr10 → preserve_hdr10"

# preserve + hlg → preserve_hlg
$script:tcMockSi  = @{ isHDRPlus = $false; transfer = "arib-std-b67"; isHLG = $true }
$script:tcMockExt = @{ isDV = $false; logProfile = ""; cameraMake = "unknown"; isHLG = $true }
Show-TcHdrDialog "/tmp/fake.mkv" "libx265" | Out-Null
Assert-Eq "preserve_hlg" $script:tcMode "policy=preserve + hlg → preserve_hlg"

# preserve + dv → skip
$script:tcMockSi  = @{ isHDRPlus = $false; transfer = ""; isHLG = $false }
$script:tcMockExt = @{ isDV = $true; logProfile = ""; cameraMake = "unknown"; isHLG = $false }
Show-TcHdrDialog "/tmp/fake.mkv" "libx265" | Out-Null
Assert-Eq "skip" $script:tcMode "policy=preserve + dv → skip"

# preserve + log → keep_log
$script:tcMockSi  = @{ isHDRPlus = $false; transfer = ""; isHLG = $false }
$script:tcMockExt = @{ isDV = $false; logProfile = "apple_log"; cameraMake = "apple"; isHLG = $false }
Show-TcHdrDialog "/tmp/fake.mkv" "libx265" | Out-Null
Assert-Eq "keep_log" $script:tcMode "policy=preserve + log → keep_log"

# tonemap policy
$script:tcMockSi  = @{ isHDRPlus = $false; transfer = "smpte2084"; isHLG = $false }
$script:tcMockExt = @{ isDV = $false; logProfile = ""; cameraMake = "unknown"; isHLG = $false }
$env:TC_HDR_POLICY = "tonemap"
Show-TcHdrDialog "/tmp/fake.mkv" "libx265" | Out-Null
Assert-Eq "tonemap" $script:tcMode "policy=tonemap → tonemap"

# skip policy
$env:TC_HDR_POLICY = "skip"
Show-TcHdrDialog "/tmp/fake.mkv" "libx265" | Out-Null
Assert-Eq "skip" $script:tcMode "policy=skip → skip"

# sdr source → ramane sdr (no dialog) chiar cu policy preserve
$script:tcMockSi  = @{ isHDRPlus = $false; transfer = ""; isHLG = $false }
$script:tcMockExt = @{ isDV = $false; logProfile = ""; cameraMake = "unknown"; isHLG = $false }
$env:TC_HDR_POLICY = "preserve"
Show-TcHdrDialog "/tmp/fake.mkv" "libx265" | Out-Null
Assert-Eq "sdr" $script:tcMode "sursa sdr → ramane sdr (no transform)"
$env:TC_HDR_POLICY = $null

# ── 13. HDR10+ classified ca hdr10plus, preserve → preserve_hdr10 ──
$script:tcMockSi  = @{ isHDRPlus = $true; transfer = "smpte2084"; isHLG = $false }
$script:tcMockExt = @{ isDV = $false; logProfile = ""; cameraMake = "unknown"; isHLG = $false }
$env:TC_HDR_POLICY = "preserve"
Show-TcHdrDialog "/tmp/fake.mkv" "libx265" | Out-Null
Assert-Eq "hdr10plus" $script:tcSourceType "classify: HDR10+ → hdr10plus"
Assert-Eq "preserve_hdr10" $script:tcMode "HDR10+ preserve → preserve_hdr10 base"
$env:TC_HDR_POLICY = $null

# ── 14. Integrare: fluxurile cheama Show-TcHdrDialog (trim/batch/concat) ──
$dlgCount = ([regex]'Show-TcHdrDialog').Matches($ENCODE_TXT).Count
Assert-Eq $true ($dlgCount -ge 4) "Show-TcHdrDialog: definitie + >=3 call-site (trim/batch/concat)"
Assert-Contains $ENCODE_TXT "Build-TcVideoArgs" "Build-TcVideoArgs integrat in fluxuri"
Assert-Contains $ENCODE_TXT "Get-PipelineHdrMode" "Concat foloseste Get-PipelineHdrMode (agregat)"

# ── 15. v60 audit FIX: Get-PipelineHdrMode foloseste side_data_type ──
$gpmAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-PipelineHdrMode' }, $true)
Assert-Eq $true ($gpmAst -ne $null) "Get-PipelineHdrMode AST gasita"
if ($gpmAst) {
    $gpmBody = $gpmAst.Extent.Text
    Assert-Contains $gpmBody 'side_data_type'        "Get-PipelineHdrMode: side_data_type (NU list)"
    Assert-Contains $gpmBody 'Dolby Vision Metadata' "Get-PipelineHdrMode: DV AV1 via side_data"
    Assert-Eq $false ([bool]($gpmBody -match 'frame=side_data_list')) "Get-PipelineHdrMode NU mai foloseste side_data_list"
}

# ── 16. v61: pipeline pastreaza HDR10+ inline (degrade-guard v60 inlocuit cu preserve) ──
# Pe Windows JSON-ul e referit prin nume gol (Get-InlineParamName) + ffmpeg cu CWD=$AV_TEMP_DIR,
# deci nu mai cade pe HDR10 static. Vezi test_v61_colon_paths pentru mecanismul complet.
Assert-Contains    $ENCODE_TXT 'dhdr10-info=$(Get-InlineParamName'   "pipeline x265: preserve HDR10+ (nume gol)"
Assert-Contains    $ENCODE_TXT 'hdr10plus-json=$(Get-InlineParamName' "pipeline svtav1: preserve HDR10+ (nume gol)"
Assert-NotContains $ENCODE_TXT 'incompatibil cu x265-params'        "pipeline: degrade-guard v60 eliminat (x265)"
