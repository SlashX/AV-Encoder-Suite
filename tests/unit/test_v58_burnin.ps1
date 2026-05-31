# v58: av_burnin.ps1 HDR awareness — dialog, classifier, video chain builder, integration
. "$PSScriptRoot\..\framework.ps1"

$PROJECT_ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$BURNIN_PS1   = Join-Path $PROJECT_ROOT "src\av_burnin.ps1"
$BURNIN_TXT   = Get-Content $BURNIN_PS1 -Raw

# ── Dot-source av_burnin.ps1 in test mode (skip main menu) ──────────
$env:AV_BURNIN_TEST_MODE = "1"
try {
    . $BURNIN_PS1
} catch {
    Write-Host "WARN dot-source: $($_.Exception.Message)" -ForegroundColor Yellow
}
$env:AV_BURNIN_TEST_MODE = $null

# ── 1. Helpers exista (AST) ────────────────────────────────────────
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($BURNIN_PS1, [ref]$null, [ref]$errs)
Assert-Eq 0 $errs.Count "av_burnin.ps1 AST parse fara erori"

$expectedFns = @(
    "Get-BurninModeLabel", "Get-LogProfileLabel", "Get-BurninSourceInfo",
    "Get-BurninLutFiles", "Get-BurninHdr10Static", "Get-BurninHdr10PlusJson",
    "Reset-BurninState", "Show-BurninHdrDialog", "Build-BurninVideoChain"
)
foreach ($fn in $expectedFns) {
    $found = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true)
    Assert-Eq $true ($found -ne $null) "AST: function $fn definita"
}

# ── 2. Get-BurninModeLabel ─────────────────────────────────────────
Assert-Eq "SDR (no transform)"           (Get-BurninModeLabel "sdr")                "label sdr"
Assert-Eq "Preserve HDR10"               (Get-BurninModeLabel "preserve_hdr10")     "label preserve_hdr10"
Assert-Eq "Preserve HDR10+"              (Get-BurninModeLabel "preserve_hdr10plus") "label preserve_hdr10plus"
Assert-Eq "Preserve HLG"                 (Get-BurninModeLabel "preserve_hlg")       "label preserve_hlg"
Assert-Eq "Tonemap -> SDR"               (Get-BurninModeLabel "tonemap")            "label tonemap"
Assert-Eq "Apply LUT (LOG -> Rec.709)"   (Get-BurninModeLabel "lut_rec709")         "label lut_rec709"
Assert-Eq "Burn-in raw (no color transform)" (Get-BurninModeLabel "burnin_raw")     "label burnin_raw"
Assert-Eq "Skip"                         (Get-BurninModeLabel "skip")               "label skip"

# ── 3. Reset-BurninState ───────────────────────────────────────────
$script:BurninSourceType = "dv"; $script:BurninMode = "tonemap"; $script:BurninPreFilter = "x"
$script:BurninEncExtraArgs = @("a"); $script:BurninLutFile = "y"; $script:BurninHdr10PlusJson = "z"
$script:BurninDowngradeReason = "w"
Reset-BurninState
Assert-Eq "sdr" $script:BurninSourceType     "reset: SourceType -> sdr"
Assert-Eq "sdr" $script:BurninMode           "reset: Mode -> sdr"
Assert-Eq ""    $script:BurninPreFilter      "reset: PreFilter -> empty"
Assert-Eq 0     $script:BurninEncExtraArgs.Count "reset: EncExtraArgs -> []"
Assert-Eq ""    $script:BurninLutFile        "reset: LutFile -> empty"
Assert-Eq ""    $script:BurninHdr10PlusJson  "reset: Hdr10PlusJson -> empty"
Assert-Eq ""    $script:BurninDowngradeReason "reset: DowngradeReason -> empty"

# ── 4. Build-BurninVideoChain — mode = skip → return false ────────
$enc = @{ Name = "libx265"; CodecKey = "hevc"; Crf = 23; Preset = "medium" }
$src = @{ SourceType = "hdr10"; Codec = "hevc"; CameraMake = "unknown"; LogProfile = ""; DoviProfile = "" }
$script:BurninMode = "skip"
$rc = Build-BurninVideoChain -File "/tmp/fake.mkv" -EncInfo $enc -SourceInfo $src
Assert-Eq $false $rc "Build skip → false"

# ── 5. mode = sdr → return true, no args ──────────────────────────
Reset-BurninState
$script:BurninMode = "sdr"
$rc = Build-BurninVideoChain -File "/tmp/fake.mkv" -EncInfo $enc -SourceInfo $src
Assert-Eq $true $rc "Build sdr → true"
Assert-Eq "" $script:BurninPreFilter "sdr → no pre_filter"
Assert-Eq 0 $script:BurninEncExtraArgs.Count "sdr → no extra args"

# ── 6. mode = tonemap → BurninPreFilter contine zscale + tonemap ──
Reset-BurninState
$script:BurninMode = "tonemap"
Build-BurninVideoChain -File "/tmp/fake.mkv" -EncInfo $enc -SourceInfo $src | Out-Null
Assert-Contains $script:BurninPreFilter "zscale=transfer=linear" "tonemap: zscale linearization"
Assert-Contains $script:BurninPreFilter "tonemap=hable"          "tonemap: Hable"
Assert-Contains $script:BurninPreFilter "format=yuv420p"         "tonemap: final format yuv420p"

# ── 7. mode = lut_rec709 → BurninPreFilter = lut3d=... ────────────
Reset-BurninState
$script:BurninMode = "lut_rec709"
$script:BurninLutFile = "/tmp/test_lut.cube"
Build-BurninVideoChain -File "/tmp/fake.mkv" -EncInfo $enc -SourceInfo $src | Out-Null
Assert-Contains $script:BurninPreFilter "lut3d=" "lut_rec709: filter contine lut3d="

# ── 8. mode = preserve_hdr10 + libx265 → 10-bit + x265-params ─────
Reset-BurninState
$script:BurninMode = "preserve_hdr10"
# Mock Get-BurninHdr10Static
function Get-BurninHdr10Static { param([string]$File) return @{
    Available = $true
    MasterDisplayX265 = "G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1)"
    MasterDisplaySvtav1 = "G(0.1700,0.7970)B(0.1310,0.0460)R(0.7080,0.2920)WP(0.3127,0.3290)L(1000.0000,0.0001)"
    MaxCll = "1000,400"
}}
$enc265 = @{ Name = "libx265"; CodecKey = "hevc"; Crf = 23; Preset = "medium" }
Build-BurninVideoChain -File "/tmp/fake.mkv" -EncInfo $enc265 -SourceInfo $src | Out-Null
$argStr = $script:BurninEncExtraArgs -join " "
Assert-Contains $argStr "yuv420p10le"   "preserve_hdr10 x265: pix_fmt 10-bit"
Assert-Contains $argStr "bt2020"        "preserve_hdr10 x265: color_primaries bt2020"
Assert-Contains $argStr "smpte2084"     "preserve_hdr10 x265: color_trc smpte2084"
Assert-Contains $argStr "-x265-params"  "preserve_hdr10 x265: x265-params flag"
Assert-Contains $argStr "hdr10=1"       "preserve_hdr10 x265: hdr10=1"
Assert-Contains $argStr "master-display=" "preserve_hdr10 x265: master-display inject"
Assert-Contains $argStr "max-cll=1000,400" "preserve_hdr10 x265: max-cll inject"

# ── 9. mode = preserve_hdr10 + libsvtav1 → svtav1-params ──────────
Reset-BurninState
$script:BurninMode = "preserve_hdr10"
$encAv1 = @{ Name = "libsvtav1"; CodecKey = "av1"; Crf = 30; Preset = "6" }
Build-BurninVideoChain -File "/tmp/fake.mkv" -EncInfo $encAv1 -SourceInfo $src | Out-Null
$argStr = $script:BurninEncExtraArgs -join " "
Assert-Contains $argStr "yuv420p10le"      "preserve_hdr10 svtav1: pix_fmt 10-bit"
Assert-Contains $argStr "-svtav1-params"   "preserve_hdr10 svtav1: svtav1-params flag"
Assert-Contains $argStr "enable-hdr=1"     "preserve_hdr10 svtav1: enable-hdr=1"
Assert-Contains $argStr "mastering-display=" "preserve_hdr10 svtav1: mastering-display inject"
Assert-Contains $argStr "content-light="   "preserve_hdr10 svtav1: content-light inject"

# ── 10. mode = preserve_hdr10 + libx264 → fallback la tonemap ─────
Reset-BurninState
$script:BurninMode = "preserve_hdr10"
$enc264 = @{ Name = "libx264"; CodecKey = "h264"; Crf = 20; Preset = "medium" }
Build-BurninVideoChain -File "/tmp/fake.mkv" -EncInfo $enc264 -SourceInfo $src | Out-Null
Assert-Contains $script:BurninPreFilter "tonemap=hable" "preserve_hdr10 x264: auto-tonemap"
Assert-Contains $script:BurninDowngradeReason "libx264" "preserve_hdr10 x264: downgrade reason setat"

# ── 11. mode = preserve_hlg + libx265 → arib-std-b67 ───────────────
Reset-BurninState
$script:BurninMode = "preserve_hlg"
Build-BurninVideoChain -File "/tmp/fake.mkv" -EncInfo $enc265 -SourceInfo $src | Out-Null
$argStr = $script:BurninEncExtraArgs -join " "
Assert-Contains $argStr "arib-std-b67" "preserve_hlg x265: transfer arib-std-b67"
Assert-Contains $argStr "-x265-params" "preserve_hlg x265: x265-params flag"
Assert-NotContains $argStr "hdr10=1" "preserve_hlg: NO hdr10=1"

# ── 12. mode = preserve_hlg + libsvtav1 → svtav1-params HLG ───────
Reset-BurninState
$script:BurninMode = "preserve_hlg"
Build-BurninVideoChain -File "/tmp/fake.mkv" -EncInfo $encAv1 -SourceInfo $src | Out-Null
$argStr = $script:BurninEncExtraArgs -join " "
Assert-Contains $argStr "transfer-characteristics=18" "preserve_hlg svtav1: HLG transfer (18)"
Assert-Contains $argStr "color-primaries=9"           "preserve_hlg svtav1: BT.2020 (9)"

# ── 13. BURNIN_HDR_POLICY env override (preserve) ──────────────────
# Mock Get-BurninSourceInfo to skip ffprobe on fake file
function Get-BurninSourceInfo { param([string]$File) return $script:BurninTestSourceInfo }

# preserve on HDR10
$script:BurninTestSourceInfo = @{ SourceType = "hdr10"; Codec = "hevc"; CameraMake = "unknown"; LogProfile = ""; DoviProfile = "" }
$env:BURNIN_HDR_POLICY = "preserve"
Show-BurninHdrDialog -File "/tmp/fake.mkv" -EncInfo $enc265 | Out-Null
Assert-Eq "preserve_hdr10" $script:BurninMode "policy=preserve + hdr10 → preserve_hdr10"

# tonemap on HLG
$script:BurninTestSourceInfo = @{ SourceType = "hlg"; Codec = "hevc"; CameraMake = "unknown"; LogProfile = ""; DoviProfile = "" }
$env:BURNIN_HDR_POLICY = "tonemap"
Show-BurninHdrDialog -File "/tmp/fake.mkv" -EncInfo $enc265 | Out-Null
Assert-Eq "tonemap" $script:BurninMode "policy=tonemap + hlg → tonemap"

# skip on DV
$script:BurninTestSourceInfo = @{ SourceType = "dv"; Codec = "hevc"; CameraMake = "unknown"; LogProfile = ""; DoviProfile = "dvhe" }
$env:BURNIN_HDR_POLICY = "skip"
Show-BurninHdrDialog -File "/tmp/fake.mkv" -EncInfo $enc265 | Out-Null
Assert-Eq "skip" $script:BurninMode "policy=skip + dv → skip"

# preserve on DV → skip (DV preserve incompatibil)
$env:BURNIN_HDR_POLICY = "preserve"
Show-BurninHdrDialog -File "/tmp/fake.mkv" -EncInfo $enc265 | Out-Null
Assert-Eq "skip" $script:BurninMode "policy=preserve + dv → skip (RPU break)"

$env:BURNIN_HDR_POLICY = $null

# ── 14. Integrare: flow loops cheama Show-BurninHdrDialog ──────────
$dlgCount = ([regex]'Show-BurninHdrDialog -File \$p\.Video').Matches($BURNIN_TXT).Count
Assert-Eq 4 $dlgCount "Show-BurninHdrDialog apelata in 4 flow-uri"
$bldCount = ([regex]'Build-BurninVideoChain -File \$p\.Video').Matches($BURNIN_TXT).Count
Assert-Eq 4 $bldCount "Build-BurninVideoChain apelata in 4 flow-uri"

# Verifica ca $script:BurninEncExtraArgs e injectat in toate 5 ffmpeg sites
$extraUses = ([regex]'@extraArgs').Matches($BURNIN_TXT).Count
Assert-Eq 5 $extraUses "@extraArgs injectat in 5 ffmpeg sites (HUD/SRT/ASS + img ext + img emb)"

# DV refuse text
Assert-Contains $BURNIN_TXT "Dolby Vision detectata" "Mesaj DV refuse prezent"
Assert-Contains $BURNIN_TXT "RPU references"        "DV refuse explica RPU breakage"
Assert-Contains $BURNIN_TXT "av_hdr_dv_tools"       "DV refuse sugereaza av_hdr_dv_tools"

Invoke-TestSummary
