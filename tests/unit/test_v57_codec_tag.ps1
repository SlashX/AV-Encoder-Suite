# v57: helper Get-CodecTagForContainer + integrare in 3 scripturi PS1
. "$PSScriptRoot\..\framework.ps1"

$PROJECT_ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$ENCODE_PS1   = Join-Path $PROJECT_ROOT "src\av_encode.ps1"
$BURNIN_PS1   = Join-Path $PROJECT_ROOT "src\av_burnin.ps1"
$TELEM_PS1    = Join-Path $PROJECT_ROOT "src\av_telemetry.ps1"

$ENCODE_TXT   = Get-Content $ENCODE_PS1 -Raw
$BURNIN_TXT   = Get-Content $BURNIN_PS1 -Raw
$TELEM_TXT    = Get-Content $TELEM_PS1  -Raw

# ── Helper definit ────────────────────────────────────────────────
Assert-Contains $ENCODE_TXT "function Get-CodecTagForContainer" "Get-CodecTagForContainer in av_encode.ps1"
Assert-Contains $BURNIN_TXT "function Get-CodecTagForContainer" "Get-CodecTagForContainer in av_burnin.ps1 (standalone)"
Assert-Contains $TELEM_TXT  "function Get-CodecTagForContainer" "Get-CodecTagForContainer in av_telemetry.ps1 (standalone)"

# ── Helper functional pe av_encode.ps1 ───────────────────────────
# Extract function via AST + invoke
$astTokens = $null; $astErrs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ENCODE_PS1, [ref]$astTokens, [ref]$astErrs)
Assert-Eq 0 $astErrs.Count "av_encode.ps1 AST parse fara erori"

$fnAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CodecTagForContainer' }, $true)
Assert-Eq $true ($fnAst -ne $null) "Get-CodecTagForContainer AST gasita"
if ($fnAst) {
    Set-Item function:Global:Get-CodecTagForContainer $fnAst.Body.GetScriptBlock()
    $r1 = Get-CodecTagForContainer "hevc" "mp4"
    Assert-Eq "-tag:v" $r1[0] "hevc/mp4 → '-tag:v'"
    Assert-Eq "hvc1"   $r1[1] "hevc/mp4 → 'hvc1'"
    $r2 = Get-CodecTagForContainer "av1" "mov"
    Assert-Eq "av01"   $r2[1] "av1/mov → 'av01'"
    $r3 = Get-CodecTagForContainer "hevc" "mkv"
    Assert-Eq 0 $r3.Count "hevc/mkv → empty"
    $r4 = Get-CodecTagForContainer "hevc" "MP4"
    Assert-Eq "hvc1"   $r4[1] "case-insensitive MP4 → hvc1"
    $r5 = Get-CodecTagForContainer "prores" "mov"
    Assert-Eq 0 $r5.Count "prores/mov → empty (ffmpeg default OK)"
}

# ── Integrare in main encode flow ────────────────────────────────
# 5 site-uri encode: libx264 (single + 2pass) + libsvtav1 + libaom + libx265 + HW + prores
# Pentru tag-uri: HEVC/H264/AV1 in MP4/MOV → 5 sites with codecTag
$codecTagUses = ([regex]::Matches($ENCODE_TXT, '\$codecTag\s*=\s*Get-CodecTagForContainer')).Count
Assert-Eq $true ($codecTagUses -ge 4) "av_encode.ps1: >=4 site-uri single-pass codecTag (libx264/libx265/svtav1/libaom/HW)"
$codecTagKeyUses = ([regex]::Matches($ENCODE_TXT, '\$script:codecTagKey\s*=')).Count
Assert-Eq $true ($codecTagKeyUses -ge 3) "av_encode.ps1: >=3 set-uri \$script:codecTagKey pentru 2-pass (h264/av1/hevc)"
Assert-Contains $ENCODE_TXT "Get-CodecTagForContainer `$script:codecTagKey `$container" "trailing 2-pass codecTag2"

# ── av_burnin.ps1 ────────────────────────────────────────────────
Assert-Contains $BURNIN_TXT 'CodecKey = "hevc"' "Get-Encoder seteaza CodecKey=hevc"
Assert-Contains $BURNIN_TXT 'CodecKey = "h264"' "Get-Encoder seteaza CodecKey=h264"
Assert-Contains $BURNIN_TXT 'CodecKey = "av1"'  "Get-Encoder seteaza CodecKey=av1"
$burninUses = ([regex]::Matches($BURNIN_TXT, '\$codecTag\s*=\s*Get-CodecTagForContainer')).Count
Assert-Eq $true ($burninUses -ge 4) "av_burnin.ps1: >=4 declaratii codecTag (4 flows; img shared)"

# ── av_telemetry.ps1 ─────────────────────────────────────────────
Assert-Contains $TELEM_TXT '$telemTag = Get-CodecTagForContainer' "av_telemetry.ps1: telemTag aplicat"

# ── av_encode.ps1 audio-only (Tier 2) ────────────────────────────
Assert-Contains $ENCODE_TXT '$eaCodecTag = Get-CodecTagForContainer' "av_encode.ps1: eaCodecTag in audio-only flow"

Invoke-TestSummary
