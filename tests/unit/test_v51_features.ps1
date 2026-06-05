# v51 PS1 mirror: 2-pass + VBV/Level + HDR10 static metadata
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$srcPath = Join-Path $root 'src\av_encode.ps1'
$srcText = Get-Content -LiteralPath $srcPath -Raw

Import-AvEncodeFunctions -Names @(
    'Get-VbvCaps','Get-MinLevelForResolution','Suggest-VbvForTarget','Get-BitrateKbps',
    'Set-Hdr10StaticDefaults','Get-Hdr10StaticMetadata','Resolve-Hdr10Static',
    'Initialize-2PassState','Clear-2PassState','Test-SvtAv1TwoPassCaps','Ensure-TempDir'
)

# v63: Initialize-2PassState foloseste $AV_TEMP_DIR + Ensure-TempDir (runtime-only, nesetate la
# importul AST de functii). Setam un temp real (testele pot folosi OS temp prin conventie).
$AV_TEMP_DIR = Join-Path ([IO.Path]::GetTempPath()) ("v51stats_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $AV_TEMP_DIR | Out-Null

# ══════════════════════════════════════════════════════════════════════
# Faza C: VBV / Level helpers
# ══════════════════════════════════════════════════════════════════════
$c = Get-VbvCaps -Codec 'hevc' -Level '4.0' -Tier 'main'
Assert-Eq 12000  $c.MaxBR  "HEVC 4.0 Main MaxBR=12000"
$c = Get-VbvCaps -Codec 'hevc' -Level '4.0' -Tier 'high'
Assert-Eq 30000  $c.MaxBR  "HEVC 4.0 High MaxBR=30000"
$c = Get-VbvCaps -Codec 'hevc' -Level '5.2' -Tier 'high'
Assert-Eq 240000 $c.MaxBR  "HEVC 5.2 High MaxBR=240000"
$c = Get-VbvCaps -Codec 'h264' -Level '4.1'
Assert-Eq 62500  $c.MaxBR  "H.264 4.1 MaxBR=62500"
$c = Get-VbvCaps -Codec 'av1'  -Level '5.0'
Assert-Eq 30000  $c.MaxBR  "AV1 5.0 MaxBR=30000"
Assert-Eq 100000 $c.MaxCPB "AV1 5.0 MaxCPB=100000"

# Get-MinLevelForResolution
Assert-Eq "4.0" (Get-MinLevelForResolution -Codec 'hevc' -Width 1920 -Height 1080 -Fps 30) "HEVC 1080p30 min 4.0"
Assert-Eq "4.1" (Get-MinLevelForResolution -Codec 'hevc' -Width 1920 -Height 1080 -Fps 60) "HEVC 1080p60 min 4.1"
Assert-Eq "5.0" (Get-MinLevelForResolution -Codec 'hevc' -Width 3840 -Height 2160 -Fps 30) "HEVC 4K30 min 5.0"
Assert-Eq "5.1" (Get-MinLevelForResolution -Codec 'hevc' -Width 3840 -Height 2160 -Fps 60) "HEVC 4K60 min 5.1"
Assert-Eq "4.1" (Get-MinLevelForResolution -Codec 'h264' -Width 1920 -Height 1080 -Fps 30) "H.264 1080p min 4.1"

# Suggest-VbvForTarget — escaladare Main → High Tier
$s = Suggest-VbvForTarget -Codec 'hevc' -TargetKbps 4000 -Width 1920 -Height 1080 -Fps 30
Assert-Eq "4.0" $s.Level "HEVC 4Mbps 1080p30 → 4.0"
Assert-Eq "main" $s.Tier  "HEVC 4Mbps → Main Tier"

$s = Suggest-VbvForTarget -Codec 'hevc' -TargetKbps 25000 -Width 3840 -Height 2160 -Fps 30
Assert-Eq "5.0"  $s.Level   "HEVC 25Mbps 4K30 → 5.0"
Assert-Eq "high" $s.Tier    "HEVC 25Mbps 4K30 → High Tier"
Assert-Eq 37500  $s.Maxrate "HEVC 25Mbps → maxrate 37500"
Assert-Eq 50000  $s.Bufsize "HEVC 25Mbps → bufsize 50000"

$s = Suggest-VbvForTarget -Codec 'h264' -TargetKbps 10000 -Width 1920 -Height 1080 -Fps 30
Assert-Eq "4.1" $s.Level "H.264 10Mbps 1080p30 → 4.1"
Assert-Eq "main" $s.Tier  "H.264 → Main (no High Tier concept)"

# Get-BitrateKbps
Assert-Eq 4000 (Get-BitrateKbps '4000k') "4000k → 4000"
Assert-Eq 4000 (Get-BitrateKbps '4M')    "4M → 4000"
Assert-Eq 8000 (Get-BitrateKbps '8000')  "8000 → 8000"
Assert-Eq 0    (Get-BitrateKbps 'abc')   "invalid → 0"
Assert-Eq 0    (Get-BitrateKbps '')      "empty → 0"

# ══════════════════════════════════════════════════════════════════════
# Faza D: HDR10 static defaults
# ══════════════════════════════════════════════════════════════════════
Set-Hdr10StaticDefaults
if ($script:hdr10StaticAvailable) { _pass } else { _fail "defaults set hdr10StaticAvailable" }
Assert-Match $script:hdr10MasterDisplayX265   'G\(8500,39850\)' "X265 defaults BT.2020 green"
Assert-Match $script:hdr10MasterDisplayX265   'L\(10000000,1\)' "X265 defaults 1000nit peak"
Assert-Match $script:hdr10MasterDisplaySvtAv1 'G\(0\.1700,0\.7970\)' "SVTAV1 defaults BT.2020 green float"
Assert-Match $script:hdr10MasterDisplaySvtAv1 'L\(1000\.0000,0\.0001\)' "SVTAV1 defaults 1000nit peak float"
Assert-Eq "1000,400" $script:hdr10MaxCll "defaults MaxCLL 1000,400"

# Get-Hdr10StaticMetadata on missing file → false
$ok = Get-Hdr10StaticMetadata -File "C:\nonexistent_v51.mp4"
if (-not $ok) { _pass } else { _fail "missing file → return false" }
if (-not $script:hdr10StaticAvailable) { _pass } else { _fail "missing file → hdr10StaticAvailable=false" }

# Resolve fallback
Resolve-Hdr10Static -File "C:\nonexistent_v51.mp4"
if ($script:hdr10StaticAvailable) { _pass } else { _fail "resolve fallback → available=true" }
Assert-Eq "default-bt2020-1000nit" $script:hdr10StaticSource "resolve fallback source label"

# ══════════════════════════════════════════════════════════════════════
# Faza A: 2-pass state
# ══════════════════════════════════════════════════════════════════════
Initialize-2PassState -File "C:\test video!@#.mp4"
if ($script:use2Pass) { _pass } else { _fail "Initialize-2PassState sets use2Pass=true" }
if (Test-Path $script:statsDir) { _pass } else { _fail "statsDir exists" }
# v63: v61 a adaugat _<guid8> in statsBase ("${name}_${guid}.passlog") → name = "test_video___"
# (space + !@# = 4 underscores dupa "test_video"), apoi separator _ + 8 hex.
Assert-Match $script:statsFile 'test_video____[0-9a-f]{8}\.passlog$' "statsFile sanitized name (4 underscores: space+!@#) + guid"

Clear-2PassState
if (-not $script:use2Pass) { _pass } else { _fail "Clear-2PassState resets use2Pass" }
Assert-Eq "" "$($script:statsFile)" "Clear clears statsFile"
Assert-Eq 0 $script:ffmpegCmdPass1.Count "Clear clears Pass1 array"
Assert-Eq 0 $script:ffmpegCmdPass2.Count "Clear clears Pass2 array"

# ══════════════════════════════════════════════════════════════════════
# Source inspection markers — Faza B/C/D integration
# ══════════════════════════════════════════════════════════════════════
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($srcPath, [ref]$tokens, [ref]$errors)
$funcs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

# Helpers existence
$names = @('Invoke-2PassEncode','Initialize-2PassState','Clear-2PassState',
           'Test-SvtAv1TwoPassCaps','Get-VbvCaps','Get-MinLevelForResolution',
           'Suggest-VbvForTarget','Get-BitrateKbps','Get-Hdr10StaticMetadata',
           'Set-Hdr10StaticDefaults','Resolve-Hdr10Static')
foreach ($n in $names) {
    $f = $funcs | Where-Object { $_.Name -eq $n } | Select-Object -First 1
    if ($f) { _pass } else { _fail "$n defined" }
}

# Mode selection: 3 options + HW gate
Assert-Match $srcText 'VBR 2-pass'                          "menu 2-pass option"
Assert-Match $srcText '\$isHwActive = \$useHWEnc'           "HW gate flag"
Assert-Match $srcText 'fallback la VBR 1-pass'              "HW fallback message"

# x265 branch: level + HDR10 static + 2-pass markers
Assert-Match $srcText 'x265LevelParams'                     "x265 level params"
Assert-Match $srcText 'high-tier='                          "x265 high-tier inject"
Assert-Match $srcText 'hrd=1'                               "x265 HRD on VBR/2-pass"
Assert-Match $srcText 'pass=1:stats='                       "x265 inline pass=1"
Assert-Match $srcText 'pass=2:stats='                       "x265 inline pass=2"
Assert-Match $srcText 'master-display=\$\(\$script:hdr10MasterDisplayX265\)' "x265 master-display inject"
Assert-Match $srcText 'max-cll=\$\(\$script:hdr10MaxCll\)'  "x265 max-cll inject"

# x264 branch
Assert-Match $srcText '-pass","1"'                          "x264 pass 1 array"
Assert-Match $srcText '-pass","2"'                          "x264 pass 2 array"
Assert-Match $srcText 'nal-hrd=vbr'                         "x264 nal-hrd=vbr"
Assert-Match $srcText 'Suggest-VbvForTarget -Codec'         "x264 calls VBV suggest"

# AV1 branch
Assert-Match $srcText 'mastering-display=\$\(\$script:hdr10MasterDisplaySvtAv1\)' "AV1 mastering-display inject"
Assert-Match $srcText 'content-light=\$\(\$script:hdr10MaxCll\)' "AV1 content-light inject"
Assert-Match $srcText '"-level",\$script:autoLevel'         "AV1 -level flag"
Assert-Match $srcText 'Test-SvtAv1TwoPassCaps'              "AV1 calls SVT-AV1 caps check"

# Schema + smart-copy
Assert-Match $srcText "'enum:1,2,3'"                        "schema ENCODE_MODE enum 1,2,3"
Assert-Match $srcText '\$encMode -ne "3"'                   "smart-copy guard skips mode=3"

# Dispatcher branch
Assert-Match $srcText 'if \(\$script:use2Pass\)'            "dispatcher branches on use2Pass"
Assert-Match $srcText 'Invoke-2PassEncode -File'            "dispatcher invokes 2-pass helper"

# v63: cleanup temp mock + sumar real (inlocuit `exit 0` hardcodat care mascha esecurile)
Remove-Item $AV_TEMP_DIR -Recurse -Force -ErrorAction SilentlyContinue
Invoke-TestSummary
