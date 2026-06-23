# Test v46 features (PS1 mirror):
# - HW DV preserve dialog in HW encode branch (NVENC/QSV/AMF)
# - hw_preserve added to HW_HDR_POLICY + MEDIACODEC_HDR_POLICY schemas
# - Integration markers ($tripleLayerMode, $doviRpuFile setup from HW branch)
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$srcPath = Join-Path $root 'src\av_encode.ps1'
$srcText = Get-Content -LiteralPath $srcPath -Raw

# ─────────────────────────────────────────────────────────────────
# 1) Schema: HW_HDR_POLICY + MEDIACODEC_HDR_POLICY contain hw_preserve
# ─────────────────────────────────────────────────────────────────
Import-AvEncodeFunctions -Names @('Get-ProfileSchema','Test-ProfileFile')

$schemaHw = Get-ProfileSchema -Key "HW_HDR_POLICY"
Assert-Match $schemaHw 'hw_preserve' "HW_HDR_POLICY schema contains hw_preserve"

$schemaMc = Get-ProfileSchema -Key "MEDIACODEC_HDR_POLICY"
Assert-Match $schemaMc 'hw_preserve' "MEDIACODEC_HDR_POLICY schema contains hw_preserve"

# Validare profil cu hw_preserve valid
$testProf = New-TemporaryFile
'HW_HDR_POLICY="hw_preserve"' | Out-File -LiteralPath $testProf.FullName -Encoding ASCII
$res = Test-ProfileFile -Path $testProf.FullName
if ($res.ok) { _pass } else { _fail "HW_HDR_POLICY=hw_preserve valid" }

'MEDIACODEC_HDR_POLICY="hw_preserve"' | Out-File -LiteralPath $testProf.FullName -Encoding ASCII
$res = Test-ProfileFile -Path $testProf.FullName
if ($res.ok) { _pass } else { _fail "MEDIACODEC_HDR_POLICY=hw_preserve valid" }

'HW_HDR_POLICY="bogus"' | Out-File -LiteralPath $testProf.FullName -Encoding ASCII
$res = Test-ProfileFile -Path $testProf.FullName
if (-not $res.ok) { _pass } else { _fail "HW_HDR_POLICY=bogus rejected" }
Remove-Item -LiteralPath $testProf.FullName -Force

# ─────────────────────────────────────────────────────────────────
# 2) HW branch DV detection + dialog markers
# ─────────────────────────────────────────────────────────────────
Assert-Match $srcText 'v46: DV source detection \+ DV preserve via HW' "HW branch has v46 DV detection marker"
Assert-Match $srcText '\$hwDoVi' "HW branch detects DV via codec_tag_string"
Assert-Match $srcText 'hwCanDvPreserve' "HW branch has DV preserve gate variable"
Assert-Match $srcText 'v46 HW DV preserve' "HW branch has v46 DV preserve dialog text"

# ─────────────────────────────────────────────────────────────────
# 3) Gate logic: HEVC/AV1 target only + tool availability
# ─────────────────────────────────────────────────────────────────
Assert-Match $srcText '\$hwTargetCodec\s+-in\s+@\("hevc","av1"\)' "Gate restricts to hevc/av1 target codecs"
Assert-Match $srcText 'Test-DoviToolFor\s+-Codec\s+\$hwSrcCodec' "Gate checks source codec tool"
Assert-Match $srcText 'Test-DoviToolFor\s+-Codec\s+\$hwTargetCodec' "Gate checks target codec tool"

# ─────────────────────────────────────────────────────────────────
# 4) DV preserve branch sets triple-layer state
# ─────────────────────────────────────────────────────────────────
Assert-Match $srcText 'Get-PreserveRpu\s+-File\s+\$f\.FullName\s+-RpuOut\s+\$srcRpu\s+-Codec\s+\$hwSrcCodec' "HW DV preserve extracts RPU via Get-PreserveRpu (P7-aware, v76)"
Assert-Match $srcText '\$tripleLayerMode\s*=\s*\$true' "HW DV preserve sets tripleLayerMode"
Assert-Match $srcText '\$tripleLayerTargetCodec\s*=\s*\$hwTargetCodec' "HW DV preserve sets tripleLayerTargetCodec from HW target"

# ─────────────────────────────────────────────────────────────────
# 5) HW_HDR_POLICY bypass for hw_preserve in HW branch
# ─────────────────────────────────────────────────────────────────
Assert-Match $srcText '\$env:HW_HDR_POLICY' "HW branch honors HW_HDR_POLICY env"
Assert-Match $srcText '"hw_preserve"\s*\{' "Policy switch handles hw_preserve"

# ─────────────────────────────────────────────────────────────────
# 6) Fallback behavior when tool unavailable
# ─────────────────────────────────────────────────────────────────
Assert-Match $srcText 'hw_preserve dar tool indisponibil' "Fallback path when DV tool missing"

# ─────────────────────────────────────────────────────────────────
# 7) Triple-layer handler still inject works post-encode
# Existing code at ~line 5839 — verify it gates on tripleLayerMode + doviRpuFile
# ─────────────────────────────────────────────────────────────────
Assert-Match $srcText 'if\s*\(\$tripleLayerMode\s+-and\s+\$doviRpuFile\)' "Post-encode inject handler gates on triple-layer + RPU"
# v76 F3: input redenumit $rawTemp -> $dvSrc (raw direct, sau raw+HDR10+ injectat in lantul hibrid)
Assert-Match $srcText 'Inject-DvRpu\s+\$dvSrc\s+\$doviRpuFile\s+\$injectedTemp\s+-TargetCodec\s+\$tlCodec' "Post-encode handler calls Inject-DvRpu with target codec"

Invoke-TestSummary
