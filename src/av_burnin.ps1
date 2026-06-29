# av_burnin.ps1 — Burn-in overlay (HUD + SRT + ASS) — PS1 mirror al av_burnin.sh
# 3 flow-uri: 1) HUD telemetrie (Python+matplotlib) 2) SRT 3) ASS
# Output: OutputVideos/<name>_hud.<ext> sau <name>_subs.<ext>

$ErrorActionPreference = "Stop"

# Binare locale (src/) au prioritate in PATH — ffmpeg/ffprobe langa script
$env:PATH = "$PSScriptRoot;$env:PATH"

$ScriptDir   = $PSScriptRoot
$InputDir    = Join-Path $ScriptDir "InputVideos"
$OutputDir   = Join-Path $ScriptDir "OutputVideos"
$TempBase    = Join-Path $ScriptDir "Temp"
$PresetsDir  = Join-Path $ScriptDir "burnin_presets"
$RenderPy    = Join-Path $ScriptDir "burnin_render.py"

New-Item -ItemType Directory -Force -Path $InputDir, $OutputDir, $TempBase | Out-Null

# ── Dependenta comuna ────────────────────────────────────────────────
if (-not (Get-Command "ffmpeg" -ErrorAction SilentlyContinue)) {
    Write-Host "EROARE: ffmpeg nu este in PATH." -ForegroundColor Red
    exit 1
}

# ── Helpers ──────────────────────────────────────────────────────────
function Get-EscapedFfmpegFilterPath {
    param([string]$Path)
    $p = $Path -replace '\\', '/'
    $p = $p -replace ':', '\:'
    $p = $p -replace "'", "\'"
    return $p
}

# ── Preview mode helpers (shared) ────────────────────────────────────
$script:PreviewMode = $false
$script:PreviewStill = $false
$script:PreviewGrid = $false

# Get-PreviewMode [-AllowStill]
#   -AllowStill (doar HUD): meniu 3-cai (niciunul / still layout 1 cadru / clip 5s).
#   fara -AllowStill (SRT/Image): comportamentul clasic y/N pt clip 5s (NEschimbat).
function Get-PreviewMode {
    param([switch]$AllowStill)
    $script:PreviewMode = $false
    $script:PreviewStill = $false
    $script:PreviewGrid = $false
    Write-Host ""
    if ($AllowStill) {
        Write-Host "  Preview:  0) niciunul (render complet)   1) still layout (1 cadru, rapid)   2) clip 5s"
        $ans = Read-Host "  Alege 0-2 [implicit 0]"
        switch ($ans) {
            '1' {
                $script:PreviewStill = $true
                $g = Read-Host "  Grila de pozitionare peste HUD? [y/N]"
                if ($g -match '^[yY]') { $script:PreviewGrid = $true }
                $gridTxt = if ($script:PreviewGrid) { " + grila" } else { "" }
                Write-Host "  -> Still layout$gridTxt la 50% din durata. Output: <name>_preview.png" -ForegroundColor Yellow
            }
            '2' {
                $script:PreviewMode = $true
                Write-Host "  -> Preview clip 5s la 50% din durata. Output: <name>_preview.<ext>" -ForegroundColor Yellow
            }
            default { }
        }
    } else {
        $ans = Read-Host "Preview mode (5s clip la mid-point pentru verificare rapida) [y/N]"
        if ($ans -match '^[yY]') {
            $script:PreviewMode = $true
            Write-Host "  -> Preview activ: 5s la 50% din durata. Output: <name>_preview.<ext>" -ForegroundColor Yellow
        } else {
            $script:PreviewMode = $false
        }
    }
}

# Formateaza un double cu InvariantCulture (decimal "." nu ",") pentru ffmpeg args.
# Pe PS 5.1 + locale EU (de-DE, fr-FR, ro-RO etc.) default culture pune virgula
# ca decimal separator → ffmpeg respinge "2,5" → preview esueaza silent.
function Format-Inv {
    param([double]$Value)
    return $Value.ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture)
}

# Returneaza fereastra preview ca string-uri InvariantCulture.
# Daca Duration <= 0.05 (ffprobe a esuat sau N/A), Valid=$false → caller fall-back.
function Get-PreviewWindow {
    param([double]$Duration)
    if ($Duration -le 0.05) {
        return @{ Valid = $false; Start = "0"; Duration = "0"; StartNum = 0.0; DurationNum = 0.0 }
    }
    $m = $Duration / 2.0 - 2.5
    if ($m -lt 0) { $m = 0.0 }
    $d = if ($Duration -lt 5) { $Duration } else { 5.0 }
    return @{
        Valid       = $true
        Start       = (Format-Inv $m)
        Duration    = (Format-Inv $d)
        StartNum    = $m
        DurationNum = $d
    }
}

# v57: codec FourCC tag pentru MP4/MOV/M4V — copie locala (av_burnin standalone,
# nu sourceaza av_encode.ps1). Paritate cu bash codec_tag_for_container.
function Get-CodecTagForContainer {
    param([string]$Codec, [string]$Container)
    $ext = $Container.ToLowerInvariant()
    if ($ext -in @("mp4","mov","m4v")) {
        switch ($Codec) {
            "hevc" { return @("-tag:v","hvc1") }
            "av1"  { return @("-tag:v","av01") }
            "h264" { return @("-tag:v","avc1") }
        }
    }
    return @()
}

# ── v58: HDR/LOG awareness ──────────────────────────────────────────
# State script-scope (reset in Show-BurninHdrDialog):
#   $script:BurninSourceType = sdr|dv|hdr10|hdr10plus|hlg|log
#   $script:BurninMode       = sdr|preserve_hdr10|preserve_hdr10plus|preserve_hlg|tonemap|lut_rec709|burnin_raw|skip
#   $script:BurninPreFilter  = filter chain prepended
#   $script:BurninEncExtraArgs = array de args ffmpeg extra
#   $script:BurninLutFile          = path LUT cand mode=lut_rec709
#   $script:BurninHdr10PlusJson    = path JSON HDR10+ cand mode=preserve_hdr10plus
#   $script:BurninDowngradeReason  = mesaj cand un mod e auto-fallback
$script:BurninSourceType = "sdr"
$script:BurninMode = "sdr"
$script:BurninPreFilter = ""
$script:BurninEncExtraArgs = @()
$script:BurninLutFile = ""
$script:BurninHdr10PlusJson = ""
$script:BurninDowngradeReason = ""
# v61: CWD ffmpeg cand HDR10+ JSON e referit prin nume gol in svtav1-params
# (drive-colon din calea absoluta sparge string-ul `:`-separat pe Windows).
$script:BurninWorkDir = ""

# v61: wrapper care ruleaza ffmpeg cu CWD=$script:BurninWorkDir cand e setat, ca
# parametrul svtav1 hdr10plus-json sa poata referi JSON-ul prin NUME GOL (colon-free).
# Toate celelalte cai din comenzile de burn-in sunt absolute (video, secventa PNG,
# subtitrare, output), deci schimbarea CWD nu afecteaza nimic. Fara param block →
# $args capteaza verbatim toate argumentele (inclusiv flag-urile `-...`).
function Invoke-BurninEncode {
    if ($script:BurninWorkDir) { Push-Location $script:BurninWorkDir }
    try { & ffmpeg @args } finally { if ($script:BurninWorkDir) { Pop-Location } }
}

function Get-BurninModeLabel {
    param([string]$Mode)
    switch ($Mode) {
        "sdr"                { return "SDR (no transform)" }
        "preserve_hdr10"     { return "Preserve HDR10" }
        "preserve_hdr10plus" { return "Preserve HDR10+" }
        "preserve_hlg"       { return "Preserve HLG" }
        "tonemap"            { return "Tonemap -> SDR" }
        "lut_rec709"         { return "Apply LUT (LOG -> Rec.709)" }
        "burnin_raw"         { return "Burn-in raw (no color transform)" }
        "skip"               { return "Skip" }
        default              { return $Mode }
    }
}

function Get-LogProfileLabel {
    param([string]$Profile)
    switch ($Profile) {
        "apple_log"   { return "Apple Log (iPhone)" }
        "samsung_log" { return "Samsung Log (S24 Ultra)" }
        "dlog_m"      { return "D-Log M (DJI)" }
        "forced_log"  { return "LOG (fortat manual)" }
        "unknown_log" { return "LOG (brand necunoscut)" }
        default       { return "LOG" }
    }
}

# v63: port din av_check.ps1 — D-Log M pe DJI Osmo Action 6 (AC006) e invizibil in container
# (bt709 identic Normal/D-Log M); singura cale e protobuf-ul djmd (.2.4.1==19), engine partajat
# src/dji_djmd_dlogm.py (model-gate intern pe dvtm_ac206.proto). Soft-fail → "unknown".
function _Get-AvPython {
    if (Get-Command python3 -ErrorAction SilentlyContinue) { return "python3" }
    $p = Get-Command python -ErrorAction SilentlyContinue
    if ($p -and ((& python --version 2>&1) -match "3\.")) { return "python" }
    return $null
}
function Test-DjiDLogM {
    param([string]$File)
    $engine = Join-Path $PSScriptRoot "dji_djmd_dlogm.py"
    if (-not (Test-Path $engine)) { return "unknown" }
    $py = _Get-AvPython
    if (-not $py) { return "unknown" }
    $idxLine = @(& ffprobe -v error -show_entries stream=index,codec_tag_string -of csv=p=0 -- $File 2>$null) |
        Where-Object { ($_ -split ',')[1] -eq 'djmd' } | Select-Object -First 1
    if (-not $idxLine) { return "unknown" }
    $djmdIdx = ($idxLine -split ',')[0].Trim()
    if ($djmdIdx -notmatch '^\d+$') { return "unknown" }
    $dump = Join-Path $TempBase ("djmd_" + [guid]::NewGuid().ToString("N") + ".djmd")
    & ffmpeg -v error -y -i $File -map "0:$djmdIdx" -c copy -f data $dump 2>$null | Out-Null
    $mode = "unknown"
    if ((Test-Path $dump) -and (Get-Item $dump).Length -gt 0) {
        $out = (& $py $engine $dump 2>$null | Select-Object -First 1)
        if ($out -eq "dlog_m" -or $out -eq "normal") { $mode = $out }
    }
    Remove-Item $dump -Force -ErrorAction SilentlyContinue
    return $mode
}

# Detecteaza sursa via ffprobe. Returneaza hashtable cu:
#   SourceType (sdr|dv|hdr10|hdr10plus|hlg|log)
#   Codec (av1|hevc|h264|...)
#   CameraMake (apple|samsung|dji|unknown)
#   LogProfile (apple_log|samsung_log|dlog_m|"")
#   DoviProfile ("" sau "5"/"7"/"8.1"/etc.)
function Get-BurninSourceInfo {
    param([string]$File)
    $info = @{
        SourceType  = "sdr"
        Codec       = ""
        CameraMake  = "unknown"
        LogProfile  = ""
        DoviProfile = ""
    }

    # Codec sursa
    $info.Codec = (& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name `
        -of default=noprint_wrappers=1:nokey=1 $File 2>$null | Select-Object -First 1) -as [string]
    if ($info.Codec) { $info.Codec = $info.Codec.Trim() }

    # Color transfer + primaries + bit depth
    $colorTrc = (& ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer `
        -of default=noprint_wrappers=1:nokey=1 $File 2>$null | Select-Object -First 1) -as [string]
    if ($colorTrc) { $colorTrc = $colorTrc.Trim() }
    $colorPrim = (& ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries `
        -of default=noprint_wrappers=1:nokey=1 $File 2>$null | Select-Object -First 1) -as [string]
    if ($colorPrim) { $colorPrim = $colorPrim.Trim() }
    $bpsRaw = (& ffprobe -v error -select_streams v:0 -show_entries stream=bits_per_raw_sample `
        -of default=noprint_wrappers=1:nokey=1 $File 2>$null | Select-Object -First 1) -as [string]
    $srcBps = 8
    if ($bpsRaw -and $bpsRaw -match '^\d+$') { $srcBps = [int]$bpsRaw }
    else {
        # v63 (v62 Bug-1): bits_per_raw_sample e N/A pe multe surse HEVC 10-bit → cadea pe 8
        # → gate-ul LOG (>=10) esua → Samsung/Apple/D-Log nedetectate. Fallback pe pix_fmt.
        $pfBd = (& ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt `
            -of default=noprint_wrappers=1:nokey=1 $File 2>$null | Select-Object -First 1) -as [string]
        if     ($pfBd -match 'p16|p016') { $srcBps = 16 }
        elseif ($pfBd -match 'p12|p012') { $srcBps = 12 }
        elseif ($pfBd -match 'p10|p010') { $srcBps = 10 }
    }
    $codecTag = (& ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string `
        -of default=noprint_wrappers=1:nokey=1 $File 2>$null | Select-Object -First 1) -as [string]

    # Frame side data — v57 fix: side_data_type, NU type
    $sideData = & ffprobe -v error -read_intervals "0%+#5" -select_streams v:0 `
        -show_entries frame_side_data=side_data_type -show_frames $File 2>$null
    $sideDataText = if ($sideData) { ($sideData -join "`n") } else { "" }

    # DV detection: codec_tag (HEVC) sau Dolby Vision Metadata in side_data (AV1)
    $isDV = $false
    if ($codecTag -and ($codecTag -match '(?i)dovi|dvhe|dvh1')) { $isDV = $true }
    if (-not $isDV -and ($sideDataText -match "Dolby Vision Metadata")) { $isDV = $true }

    # HDR10+ detection
    $isHdr10Plus = ($sideDataText -match "HDR Dynamic Metadata SMPTE2094-40|HDR10\+")

    # HDR10 / HLG
    $isHdr10 = ($colorTrc -match "smpte2084")
    $isHlg = ($colorTrc -match "arib-std-b67")

    # Camera make
    $tags = & ffprobe -v error -show_entries format_tags `
        -of default=noprint_wrappers=1 $File 2>$null
    $tagsText = if ($tags) { ($tags -join "`n") } else { "" }
    if ($tagsText -match "(?i)com\.samsung\.android\.logvideo") {
        $info.CameraMake = "samsung"
    } elseif ($tagsText -match "(?i)make=.*apple") {
        $info.CameraMake = "apple"
    } elseif ($tagsText -match "(?i)make=.*dji|encoder=.*dji") {
        $info.CameraMake = "dji"
    } elseif ($tagsText -match "(?i)manufacturer=.*samsung|make=.*samsung|com\.samsung\.android") {
        $info.CameraMake = "samsung"
    }

    # LOG detection (10-bit + BT.2020 + brand context, exclud HDR)
    if (-not $isDV -and -not $isHdr10Plus -and -not $isHdr10 -and $srcBps -ge 10 -and ($colorPrim -match "bt2020" -or $colorTrc -match "arib|log")) {
        switch ($info.CameraMake) {
            "apple"   { $info.LogProfile = "apple_log" }
            "samsung" { if (-not $isHlg) { $info.LogProfile = "samsung_log" } }
            "dji"     { $info.LogProfile = "dlog_m" }
            # v63 (v62 Finding 4): exclud arib (HLG) — o sursa HLG brandless (bt2020+arib) nu mai
            # devine unknown_log dupa fix-ul bit-depth; cade corect pe hlg mai jos.
            default   { if ($colorPrim -match "bt2020" -and $colorTrc -notmatch "arib") { $info.LogProfile = "unknown_log" } }
        }
    }
    # v63 (v62 Faza B): DJI Osmo Action 6 D-Log M — bt709 10-bit (invizibil in container, NU prins
    # de gate-ul bt2020 de mai sus), discriminat din djmd protobuf. DJI vechi D-Log Wide e bt2020.
    if (-not $info.LogProfile -and $info.CameraMake -eq "dji" -and $srcBps -ge 10 `
        -and -not $isDV -and -not $isHdr10Plus -and -not $isHdr10 -and -not $isHlg `
        -and ((Test-DjiDLogM $File) -eq "dlog_m")) {
        $info.LogProfile = "dlog_m"
    }

    # Classify (HLG e mutual exclusiv cu LOG; LOG suprascrie HLG cand brand+bps confirma)
    if ($isDV) {
        $info.SourceType = "dv"
        if ($codecTag -match '(?i)dvhe') { $info.DoviProfile = "dvhe" }
        elseif ($codecTag -match '(?i)dvh1') { $info.DoviProfile = "dvh1" }
    } elseif ($isHdr10Plus) {
        $info.SourceType = "hdr10plus"
    } elseif ($isHdr10) {
        $info.SourceType = "hdr10"
    } elseif ($info.LogProfile) {
        $info.SourceType = "log"
    } elseif ($isHlg) {
        $info.SourceType = "hlg"
    } else {
        $info.SourceType = "sdr"
    }

    return $info
}

# Cauta LUT-uri brand-specifice in Luts/. Returneaza array de paths sau @().
function Get-BurninLutFiles {
    param([string]$Brand)
    $lutsDir = Join-Path $ScriptDir "Luts"
    if (-not (Test-Path $lutsDir)) { return @() }
    $prefix = switch ($Brand) {
        "apple"   { "apple_log_" }
        "samsung" { "samsung_log_" }
        "dji"     { "dji_dlog_m_" }
        default   { "" }
    }
    if (-not $prefix) {
        # Cazul "unknown" sau gol — accepta orice .cube
        return @(Get-ChildItem -Path $lutsDir -Filter "*.cube" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    return @(Get-ChildItem -Path $lutsDir -Filter "${prefix}*.cube" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

# Extrage master-display + max-cll/max-fall din side_data; format X265 (integer ×50000/×10000) + SVTAV1 (float).
# Returneaza @{ Available; MasterDisplayX265; MasterDisplaySvtav1; MaxCll }
function Get-BurninHdr10Static {
    param([string]$File)
    $ret = @{
        Available           = $false
        MasterDisplayX265   = ""
        MasterDisplaySvtav1 = ""
        MaxCll              = ""
    }
    # v63: `frame_side_data` (robust) in loc de `frame=side_data_list` (selector fragil —
    # gol fara -show_frames; vezi fix-ul din extract_hdr10_static_metadata). Aici mergea (avea
    # -show_frames) dar uniformizam pe forma proof-uita din av_check.
    $sd = & ffprobe -v error -read_intervals "0%+#5" -select_streams v:0 `
        -show_entries frame_side_data -show_frames $File 2>$null
    if (-not $sd) {
        # Defaults BT.2020 1000-nit
        $ret.Available = $true
        $ret.MasterDisplayX265   = "G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1)"
        $ret.MasterDisplaySvtav1 = "G(0.1700,0.7970)B(0.1310,0.0460)R(0.7080,0.2920)WP(0.3127,0.3290)L(1000.0000,0.0001)"
        $ret.MaxCll = "1000,400"
        return $ret
    }
    $text = $sd -join "`n"

    # Parse mastering display primaries (num/denom format)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    function _parseFrac($txt, $key) {
        if ($txt -match "$key=([\-0-9]+)/([0-9]+)") {
            $n = [double]::Parse($Matches[1], $inv); $d = [double]::Parse($Matches[2], $inv)
            if ($d -ne 0) { return $n / $d }
        }
        return $null
    }
    $gx = _parseFrac $text "green_x"
    $gy = _parseFrac $text "green_y"
    $bx = _parseFrac $text "blue_x"
    $by = _parseFrac $text "blue_y"
    $rx = _parseFrac $text "red_x"
    $ry = _parseFrac $text "red_y"
    $wx = _parseFrac $text "white_point_x"
    $wy = _parseFrac $text "white_point_y"
    $maxL = _parseFrac $text "max_luminance"
    $minL = _parseFrac $text "min_luminance"

    if ($gx -and $gy -and $bx -and $by -and $rx -and $ry -and $wx -and $wy -and $maxL -and $minL) {
        $fmtI = { param($v, $mul) ([int][math]::Round($v * $mul)).ToString($inv) }
        $fmtF = { param($v, $dig) ([math]::Round($v, $dig)).ToString("0.$('0'*$dig)", $inv) }
        $ret.MasterDisplayX265 = ("G({0},{1})B({2},{3})R({4},{5})WP({6},{7})L({8},{9})" -f `
            (& $fmtI $gx 50000), (& $fmtI $gy 50000),
            (& $fmtI $bx 50000), (& $fmtI $by 50000),
            (& $fmtI $rx 50000), (& $fmtI $ry 50000),
            (& $fmtI $wx 50000), (& $fmtI $wy 50000),
            (& $fmtI $maxL 10000), (& $fmtI $minL 10000))
        $ret.MasterDisplaySvtav1 = ("G({0},{1})B({2},{3})R({4},{5})WP({6},{7})L({8},{9})" -f `
            (& $fmtF $gx 4), (& $fmtF $gy 4),
            (& $fmtF $bx 4), (& $fmtF $by 4),
            (& $fmtF $rx 4), (& $fmtF $ry 4),
            (& $fmtF $wx 4), (& $fmtF $wy 4),
            (& $fmtF ($maxL/10000.0) 4), (& $fmtF ($minL/10000.0) 4))
        $ret.Available = $true
    } else {
        # Fallback BT.2020 1000-nit
        $ret.MasterDisplayX265   = "G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1)"
        $ret.MasterDisplaySvtav1 = "G(0.1700,0.7970)B(0.1310,0.0460)R(0.7080,0.2920)WP(0.3127,0.3290)L(1000.0000,0.0001)"
        $ret.Available = $true
    }

    # MaxCLL / MaxFALL
    if ($text -match "max_content=(\d+).*?max_average=(\d+)") {
        $ret.MaxCll = "$($Matches[1]),$($Matches[2])"
    } else {
        $ret.MaxCll = "1000,400"
    }
    return $ret
}

# Extrage HDR10+ JSON via hdr10plus_tool / av1hdr10plus_tool.
# Returneaza path JSON sau "" la esec.
function Get-BurninHdr10PlusJson {
    param([string]$File, [string]$SrcCodec)
    # v69: nume env-overridable (AV_TOOL_*, mirror av_common.sh) — copie standalone
    $tool = if ($SrcCodec -eq "av1") {
        if ($env:AV_TOOL_AV1HDR10PLUS) { $env:AV_TOOL_AV1HDR10PLUS } else { "av1hdr10plus_tool" }
    } else {
        if ($env:AV_TOOL_HDR10PLUS) { $env:AV_TOOL_HDR10PLUS } else { "hdr10plus_tool" }
    }
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { return "" }
    $rawTmp = Join-Path $TempBase ("burnin_hp_{0}_{1}" -f $PID, [guid]::NewGuid().ToString().Substring(0,8))   # v63: temp-ul nostru, nu OS temp
    # v61: JSON in $TempBase (NU OS temp) — referit prin nume gol in svtav1-params
    # cu ffmpeg rulat cu CWD=$TempBase (drive-colon ar sparge string-ul `:`-separat).
    $jsonTmp = Join-Path $TempBase ("burnin_hp_{0}_{1}.json" -f $PID, [guid]::NewGuid().ToString().Substring(0,8))
    if ($SrcCodec -eq "av1") {
        $rawTmp = $rawTmp + ".ivf"
        & ffmpeg -y -v error -i $File -c:v copy -f ivf $rawTmp 2>$null | Out-Null
    } else {
        $rawTmp = $rawTmp + ".hevc"
        & ffmpeg -y -v error -i $File -c:v copy -bsf:v hevc_mp4toannexb -f hevc $rawTmp 2>$null | Out-Null
    }
    if (-not (Test-Path $rawTmp) -or (Get-Item $rawTmp).Length -eq 0) {
        if (Test-Path $rawTmp) { Remove-Item $rawTmp -Force -ErrorAction SilentlyContinue }
        return ""
    }
    & $tool extract -i $rawTmp -o $jsonTmp 2>$null | Out-Null
    Remove-Item $rawTmp -Force -ErrorAction SilentlyContinue
    if ((Test-Path $jsonTmp) -and (Get-Item $jsonTmp).Length -gt 0) {
        return $jsonTmp
    }
    if (Test-Path $jsonTmp) { Remove-Item $jsonTmp -Force -ErrorAction SilentlyContinue }
    return ""
}

# Reset state inainte de dialog per-fisier
function Reset-BurninState {
    $script:BurninSourceType = "sdr"
    $script:BurninMode = "sdr"
    $script:BurninPreFilter = ""
    $script:BurninEncExtraArgs = @()
    $script:BurninLutFile = ""
    $script:BurninHdr10PlusJson = ""
    $script:BurninDowngradeReason = ""
    $script:BurninWorkDir = ""   # v61
}

# Dialog per fisier. Foloseste $encInfo.Name pentru encoder picked din Get-Encoder.
# BURNIN_HDR_POLICY env override (preserve|tonemap|skip|lut)
function Show-BurninHdrDialog {
    param([string]$File, [hashtable]$EncInfo)
    Reset-BurninState
    $info = Get-BurninSourceInfo -File $File
    $script:BurninSourceType = $info.SourceType

    if ($info.SourceType -eq "sdr") { return $info }

    # Env policy bypass
    $policy = $env:BURNIN_HDR_POLICY
    if ($policy) {
        switch ($policy) {
            "preserve" {
                switch ($info.SourceType) {
                    "dv"        { $script:BurninMode = "skip" }
                    "hdr10plus" { $script:BurninMode = "preserve_hdr10plus" }
                    "hdr10"     { $script:BurninMode = "preserve_hdr10" }
                    "hlg"       { $script:BurninMode = "preserve_hlg" }
                    "log"       { $script:BurninMode = "burnin_raw" }
                }
            }
            "tonemap" { $script:BurninMode = "tonemap" }
            "skip"    { $script:BurninMode = "skip" }
            "lut" {
                if ($info.SourceType -eq "log") {
                    $luts = Get-BurninLutFiles -Brand $info.CameraMake
                    if ($luts.Count -gt 0) {
                        $script:BurninMode = "lut_rec709"
                        $script:BurninLutFile = $luts[0]
                    } else {
                        $script:BurninMode = "tonemap"
                    }
                } else {
                    $script:BurninMode = "tonemap"
                }
            }
            default { $script:BurninMode = "sdr" }
        }
        return $info
    }

    # Interactive
    switch ($info.SourceType) {
        "dv" {
            Write-Host ""
            Write-Host "  ⚠  Sursa Dolby Vision detectata (profil $($info.DoviProfile))" -ForegroundColor Yellow
            Write-Host "     Burn-in pe DV distruge RPU references vizual — overlay-ul"
            Write-Host "     rasters peste base layer, dar metadata RPU presupune un BL"
            Write-Host "     neatins -> playere DV vad imagine corupta."
            Write-Host "     Recomandare: tonemap -> SDR pentru burn-in, sau av_hdr_dv_tools"
            Write-Host "     pentru transformari DV (fara overlay)."
            Write-Host ""
            Write-Host "  1) Tonemap -> SDR (recomandat)"
            Write-Host "  2) Skip [implicit]"
            $c = Read-Host "  Alege 1-2 [implicit: 2]"
            if (-not $c) { $c = "2" }
            switch ($c) {
                "1"     { $script:BurninMode = "tonemap" }
                default { $script:BurninMode = "skip" }
            }
        }
        "hdr10" {
            Write-Host ""
            Write-Host "  Sursa HDR10 detectata (color_transfer=smpte2084)"
            Write-Host "  1) Preserve HDR10 (pix_fmt p010le + master-display + max-cll) [implicit]"
            Write-Host "  2) Tonemap -> SDR"
            Write-Host "  3) Skip"
            $c = Read-Host "  Alege 1-3 [implicit: 1]"
            if (-not $c) { $c = "1" }
            switch ($c) {
                "2"     { $script:BurninMode = "tonemap" }
                "3"     { $script:BurninMode = "skip" }
                default { $script:BurninMode = "preserve_hdr10" }
            }
        }
        "hdr10plus" {
            Write-Host ""
            Write-Host "  Sursa HDR10+ detectata (src codec=$($info.Codec))"
            if ($info.Codec -eq "av1" -and $EncInfo.Name -eq "libsvtav1") {
                Write-Host "  1) Preserve HDR10+ inline (svtav1-params hdr10plus-json) [implicit]"
                Write-Host "  2) Preserve HDR10 base (HDR10+ -> HDR10 static, lossy)"
                Write-Host "  3) Tonemap -> SDR"
                Write-Host "  4) Skip"
                $c = Read-Host "  Alege 1-4 [implicit: 1]"
                if (-not $c) { $c = "1" }
                switch ($c) {
                    "2"     { $script:BurninMode = "preserve_hdr10" }
                    "3"     { $script:BurninMode = "tonemap" }
                    "4"     { $script:BurninMode = "skip" }
                    default { $script:BurninMode = "preserve_hdr10plus" }
                }
            } else {
                Write-Host "  Nota: HDR10+ inline disponibil doar pe libsvtav1 + sursa AV1."
                Write-Host "        Cazul HEVC HDR10+ preserve complet via av_hdr_dv_tools."
                Write-Host "  1) Preserve HDR10 base (HDR10+ -> HDR10 static) [implicit]"
                Write-Host "  2) Tonemap -> SDR"
                Write-Host "  3) Skip"
                $c = Read-Host "  Alege 1-3 [implicit: 1]"
                if (-not $c) { $c = "1" }
                switch ($c) {
                    "2"     { $script:BurninMode = "tonemap" }
                    "3"     { $script:BurninMode = "skip" }
                    default { $script:BurninMode = "preserve_hdr10" }
                }
            }
        }
        "hlg" {
            Write-Host ""
            Write-Host "  Sursa HLG (BT.2100 HLG) detectata"
            Write-Host "  1) Preserve HLG (pix_fmt p010le + transfer arib-std-b67) [implicit]"
            Write-Host "  2) Tonemap -> SDR"
            Write-Host "  3) Skip"
            $c = Read-Host "  Alege 1-3 [implicit: 1]"
            if (-not $c) { $c = "1" }
            switch ($c) {
                "2"     { $script:BurninMode = "tonemap" }
                "3"     { $script:BurninMode = "skip" }
                default { $script:BurninMode = "preserve_hlg" }
            }
        }
        "log" {
            $logLabel = Get-LogProfileLabel -Profile $info.LogProfile
            $luts = Get-BurninLutFiles -Brand $info.CameraMake
            Write-Host ""
            Write-Host "  Sursa LOG: $logLabel (brand=$($info.CameraMake))"
            # v62: conversia fara-LUT (tonemap) ELIMINATA pe LOG — Log→Rec.709 cere LUT.
            if ($luts.Count -gt 0) {
                $lutName = Split-Path $luts[0] -Leaf
                Write-Host "  1) Apply LUT Rec.709 ($lutName) [implicit]"
                Write-Host "  2) Burn-in raw (pastreaza LOG look)"
                Write-Host "  3) Skip"
                $c = Read-Host "  Alege 1-3 [implicit: 1]"
                if (-not $c) { $c = "1" }
                switch ($c) {
                    "2"     { $script:BurninMode = "burnin_raw" }
                    "3"     { $script:BurninMode = "skip" }
                    default { $script:BurninMode = "lut_rec709"; $script:BurninLutFile = $luts[0] }
                }
            } else {
                Write-Host "  (Fara LUT in Luts/ — conversia corecta Log->Rec.709 nu e posibila.)"
                Write-Host "  1) Burn-in raw (pastreaza LOG look) [implicit]"
                Write-Host "  2) Skip"
                $c = Read-Host "  Alege 1-2 [implicit: 1]"
                if (-not $c) { $c = "1" }
                switch ($c) {
                    "2"     { $script:BurninMode = "skip" }
                    default { $script:BurninMode = "burnin_raw" }
                }
            }
        }
    }
    return $info
}

# Build pre-filter + extra args pe baza $script:BurninMode + encoder.
# Returneaza $true daca OK, $false daca user a ales skip (sau alt motiv).
function Build-BurninVideoChain {
    param([string]$File, [hashtable]$EncInfo, [hashtable]$SourceInfo)
    $script:BurninPreFilter = ""
    $script:BurninEncExtraArgs = @()
    $encoder = $EncInfo.Name
    $tonemapFilter = "zscale=transfer=linear:matrix=bt709:primaries=bt709,tonemap=hable:desat=0,zscale=transfer=bt709:matrix=bt709:primaries=bt709,format=yuv420p"

    switch ($script:BurninMode) {
        "skip"        { return $false }
        "sdr"         { return $true }
        "burnin_raw"  { return $true }
        "lut_rec709" {
            $lutEsc = Get-EscapedFfmpegFilterPath -Path $script:BurninLutFile
            # v62 audit: setparams re-eticheteaza culoarea pe frame (lut3d nu o atinge →
            # ramanea bt2020/unknown de la sursa, mis-tagged pe ORICE container).
            $script:BurninPreFilter = "lut3d='$lutEsc',setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
            return $true
        }
        "tonemap" {
            $script:BurninPreFilter = $tonemapFilter
            return $true
        }
        "preserve_hdr10" {
            if ($encoder -eq "libx264") {
                $script:BurninDowngradeReason = "libx264 nu suporta 10-bit HDR in builds standard — auto-tonemap aplicat"
                $script:BurninPreFilter = $tonemapFilter
                return $true
            }
            $script:BurninEncExtraArgs += @("-pix_fmt","yuv420p10le")
            $script:BurninEncExtraArgs += @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
            $hdr = Get-BurninHdr10Static -File $File
            if ($encoder -eq "libx265") {
                $x265p = "hdr10=1:hdr10-opt=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
                if ($hdr.Available -and $hdr.MasterDisplayX265) {
                    $x265p += ":master-display=$($hdr.MasterDisplayX265)"
                    if ($hdr.MaxCll) { $x265p += ":max-cll=$($hdr.MaxCll)" }
                }
                $script:BurninEncExtraArgs += @("-x265-params",$x265p)
            } elseif ($encoder -eq "libsvtav1") {
                $av1p = "enable-hdr=1"
                if ($hdr.Available -and $hdr.MasterDisplaySvtav1) {
                    $av1p += ":mastering-display=$($hdr.MasterDisplaySvtav1)"
                    if ($hdr.MaxCll) { $av1p += ":content-light=$($hdr.MaxCll)" }
                }
                $script:BurninEncExtraArgs += @("-svtav1-params",$av1p)
            }
            return $true
        }
        "preserve_hdr10plus" {
            if ($encoder -ne "libsvtav1" -or $SourceInfo.Codec -ne "av1") {
                $script:BurninDowngradeReason = "HDR10+ inline disponibil doar svtav1+av1 — fallback HDR10 base"
                $script:BurninMode = "preserve_hdr10"
                return (Build-BurninVideoChain -File $File -EncInfo $EncInfo -SourceInfo $SourceInfo)
            }
            $json = Get-BurninHdr10PlusJson -File $File -SrcCodec $SourceInfo.Codec
            if (-not $json) {
                $script:BurninDowngradeReason = "HDR10+ extract esuat — fallback HDR10 base"
                $script:BurninMode = "preserve_hdr10"
                return (Build-BurninVideoChain -File $File -EncInfo $EncInfo -SourceInfo $SourceInfo)
            }
            $script:BurninHdr10PlusJson = $json
            $script:BurninEncExtraArgs += @("-pix_fmt","yuv420p10le")
            $script:BurninEncExtraArgs += @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
            $hdr = Get-BurninHdr10Static -File $File
            # v61: nume gol + CWD=$TempBase (vechiul `\`→`/` NU scotea drive-colon `C:` →
            # svtav1-params se spargea pe Windows; acum referim JSON colon-free).
            $script:BurninWorkDir = Split-Path -Parent $json
            $av1p = "enable-hdr=1:hdr10plus-json=$(Split-Path -Leaf $json)"
            if ($hdr.Available -and $hdr.MasterDisplaySvtav1) {
                $av1p += ":mastering-display=$($hdr.MasterDisplaySvtav1)"
                if ($hdr.MaxCll) { $av1p += ":content-light=$($hdr.MaxCll)" }
            }
            $script:BurninEncExtraArgs += @("-svtav1-params",$av1p)
            return $true
        }
        "preserve_hlg" {
            if ($encoder -eq "libx264") {
                $script:BurninDowngradeReason = "libx264 nu suporta 10-bit HLG in builds standard — auto-tonemap aplicat"
                $script:BurninPreFilter = $tonemapFilter
                return $true
            }
            $script:BurninEncExtraArgs += @("-pix_fmt","yuv420p10le")
            $script:BurninEncExtraArgs += @("-color_primaries","bt2020","-color_trc","arib-std-b67","-colorspace","bt2020nc")
            if ($encoder -eq "libx265") {
                $script:BurninEncExtraArgs += @("-x265-params","transfer=arib-std-b67:colormatrix=bt2020nc:colorprim=bt2020")
            } elseif ($encoder -eq "libsvtav1") {
                $script:BurninEncExtraArgs += @("-svtav1-params","enable-hdr=1:color-primaries=9:transfer-characteristics=18:matrix-coefficients=9")
            }
            return $true
        }
    }
    return $true
}

function Get-Encoder {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  ENCODER PENTRU OUTPUT (video re-encode)      ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  1) libx265 (HEVC) CRF 23 [implicit]          ║"
    Write-Host "║  2) libx264 (H.264) CRF 20                    ║"
    Write-Host "║  3) libsvtav1 (AV1) CRF 30                    ║"
    Write-Host "║  4) Anulare                                   ║"
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $encChoice = Read-Host "Alege 1-4 [implicit: 1]"
    if (-not $encChoice) { $encChoice = "1" }
    switch ($encChoice) {
        "1" { return @{ Name = "libx265";    CodecKey = "hevc"; Crf = 23; Preset = "medium" } }
        "2" { return @{ Name = "libx264";    CodecKey = "h264"; Crf = 20; Preset = "medium" } }
        "3" { return @{ Name = "libsvtav1";  CodecKey = "av1";  Crf = 30; Preset = "6" } }
        "4" { Write-Host "Anulat."; exit 0 }
        default { return @{ Name = "libx265"; CodecKey = "hevc"; Crf = 23; Preset = "medium" } }
    }
}

function Get-PairedFiles {
    param(
        [string]$PairedSuffix,    # "_norm.csv" | ".srt" | ".ass"
        [scriptblock]$MetaFn = $null
    )
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($dir in @(@{Path=$OutputDir; Label="OUT"}, @{Path=$InputDir; Label="IN"})) {
        if (-not (Test-Path $dir.Path)) { continue }
        Get-ChildItem -Path $dir.Path -Recurse -Depth 1 -File -Include "*.mp4","*.mov","*.mkv","*.m4v" -ErrorAction SilentlyContinue | ForEach-Object {
            $name = $_.BaseName
            if ($name -like "*_hud" -or $name -like "*_telem" -or $name -like "*_subs" -or $name -like "*_preview") { return }
            $aux = Join-Path $OutputDir "${name}${PairedSuffix}"
            if (-not ((Test-Path $aux) -and (Get-Item $aux).Length -gt 0)) { return }
            $meta = ""
            if ($MetaFn) { $meta = & $MetaFn $aux }
            $labelExtra = if ($meta) { " [$meta]" } else { "" }
            $pairs.Add([PSCustomObject]@{
                Video = $_.FullName
                Aux   = $aux
                Label = "[$($dir.Label)] $($_.Name)${labelExtra}"
                Meta  = $meta
                Name  = $name
                Ext   = $_.Extension.TrimStart(".")
            })
        }
    }
    return $pairs
}

function Get-BrandFromCsv {
    param([string]$CsvPath)
    try {
        $rows = Get-Content -LiteralPath $CsvPath -TotalCount 2 -ErrorAction SilentlyContinue
        $header = $rows[0]; $row2 = $rows[1]
        if ($header -and $row2) {
            $hcols = $header.Split(",")
            $cols  = $row2.Split(",")
            # header-driven: localizeaza coloana source_brand (index variabil schema 18/24)
            $idx = -1
            for ($i = 0; $i -lt $hcols.Length; $i++) {
                if ($hcols[$i].Trim('"').Trim() -eq "source_brand") { $idx = $i; break }
            }
            if ($idx -lt 0) { $idx = $cols.Length - 1 }
            if ($idx -ge 0 -and $idx -lt $cols.Length) { return $cols[$idx].Trim('"').Trim() }
        }
    } catch {}
    return "unknown"
}

function Select-Pairs {
    param($Pairs)
    if ($Pairs.Count -eq 0) { Write-Host "Nimic de selectat."; exit 0 }
    for ($i = 0; $i -lt $Pairs.Count; $i++) {
        "  {0,2}) {1}" -f ($i+1), $Pairs[$i].Label | Write-Host
    }
    Write-Host ""
    $sel = Read-Host "Selecteaza index (ex: 1 sau 1,3,5 sau ALL) [implicit ALL]"
    if (-not $sel) { $sel = "ALL" }
    $selected = New-Object System.Collections.Generic.List[int]
    if ($sel -match '^(?i)all$') {
        for ($i = 0; $i -lt $Pairs.Count; $i++) { $selected.Add($i) }
    } else {
        foreach ($p in $sel.Split(",")) {
            $p = $p.Trim()
            if ($p -notmatch '^\d+$') { Write-Host "Index invalid: $p" -ForegroundColor Red; exit 1 }
            $idx = [int]$p - 1
            if ($idx -lt 0 -or $idx -ge $Pairs.Count) { Write-Host "Index in afara range: $p" -ForegroundColor Red; exit 1 }
            $selected.Add($idx)
        }
    }
    if ($selected.Count -eq 0) { Write-Host "Nimic selectat."; exit 0 }
    return $selected
}

# ─────────────────────────────────────────────────────────────────────
# FLOW 1: HUD
# ─────────────────────────────────────────────────────────────────────
function Invoke-HudFlow {
    $py3 = $null
    if (Get-Command "python3" -ErrorAction SilentlyContinue) { $py3 = "python3" }
    elseif (Get-Command "python" -ErrorAction SilentlyContinue) {
        $pyVer = & python --version 2>&1
        if ($pyVer -match "3\.") { $py3 = "python" }
    }
    if (-not $py3) {
        Write-Host "EROARE: python3 nu este instalat (necesar pentru HUD render)." -ForegroundColor Red
        exit 1
    }
    & $py3 -c "import matplotlib, numpy" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "EROARE: matplotlib / numpy lipsesc." -ForegroundColor Red
        Write-Host "Instaleaza cu: $py3 -m pip install matplotlib numpy pillow" -ForegroundColor Yellow
        exit 1
    }
    if (-not (Test-Path $RenderPy)) { Write-Host "EROARE: $RenderPy lipseste." -ForegroundColor Red; exit 1 }

    $pairs = Get-PairedFiles -PairedSuffix "_norm.csv" -MetaFn { param($csv) Get-BrandFromCsv $csv }
    if ($pairs.Count -eq 0) {
        Write-Host ""
        Write-Host "Nu am gasit nicio pereche video + norm CSV." -ForegroundColor Yellow
        Write-Host "  Asigura-te ca exista <name>_norm.csv in $OutputDir"
        exit 0
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  HUD TELEMETRY OVERLAY                        ║" -ForegroundColor Cyan
    Write-Host "║  Perechi gasite: $($pairs.Count)"
    Write-Host "║  Input  : $InputDir"
    Write-Host "║  Output : $OutputDir"
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    $selected = Select-Pairs -Pairs $pairs

    # Layout preset
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  LAYOUT PRESET                                ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  1) minimal     — timestamp + speed (corner)  ║"
    Write-Host "║  2) data-strip  — bottom bar gauges          ║"
    Write-Host "║  3) full        — data-strip + map + extras  ║"
    Write-Host "║     [implicit]                                ║"
    Write-Host "║  4) Anulare                                   ║"
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $presetChoice = Read-Host "Alege 1-4 [implicit: 3]"
    if (-not $presetChoice) { $presetChoice = "3" }
    switch ($presetChoice) {
        "1" { $preset = "minimal" }
        "2" { $preset = "data-strip" }
        "3" { $preset = "full" }
        "4" { Write-Host "Anulat."; exit 0 }
        default { $preset = "full" }
    }
    $presetFile = Join-Path $PresetsDir "${preset}.conf"
    if (-not (Test-Path $presetFile)) { Write-Host "EROARE: preset $preset nu exista." -ForegroundColor Red; exit 1 }

    Write-Host ""
    $hudFpsIn = Read-Host "HUD frame rate [implicit: 10 fps] (recomandat 10-30)"
    if (-not $hudFpsIn) { $hudFpsIn = "10" }
    $hudFps = 10
    if ([int]::TryParse($hudFpsIn, [ref]$hudFps)) {
        if ($hudFps -lt 1) { $hudFps = 10 }
        if ($hudFps -gt 60) { $hudFps = 60 }
    } else { $hudFps = 10 }

    $enc = Get-Encoder
    Get-PreviewMode -AllowStill

    $okCount = 0; $failCount = 0
    foreach ($idx in $selected) {
        $p = $pairs[$idx]
        Write-Host ""
        Write-Host "─────────────────────────────────────────────"
        Write-Host ("  -- {0}/{1}: {2}  [{3}]" -f ($idx+1), $pairs.Count, [System.IO.Path]::GetFileName($p.Video), $p.Meta) -ForegroundColor Yellow
        Write-Host "─────────────────────────────────────────────"

        # v58: HDR/LOG dialog + chain build
        $sourceInfo = Show-BurninHdrDialog -File $p.Video -EncInfo $enc
        if (-not (Build-BurninVideoChain -File $p.Video -EncInfo $enc -SourceInfo $sourceInfo)) {
            Write-Host "  [SKIP] mod=$(Get-BurninModeLabel $script:BurninMode) — sar la urmatorul fisier" -ForegroundColor DarkGray
            continue
        }
        if ($script:BurninSourceType -ne "sdr") {
            Write-Host "  Sursa: $($script:BurninSourceType) -> mod: $(Get-BurninModeLabel $script:BurninMode)" -ForegroundColor Cyan
            if ($script:BurninDowngradeReason) { Write-Host "  ⚠ $($script:BurninDowngradeReason)" -ForegroundColor Yellow }
        }

        $offset = 0
        if ($p.Meta -like "external_*") {
            Write-Host "  Brand sursa: $($p.Meta) — telemetria poate fi nesincronizata." -ForegroundColor Yellow
            $off = Read-Host "  Sync offset in secunde (+/-, implicit 0)"
            if ($off) { $tmp = 0.0; if ([double]::TryParse($off, [ref]$tmp)) { $offset = $tmp } }
        }

        # v57: default= in loc de csv=p=0 — single-field width/height/dur emit
        # trailing comma → Python script primea int invalid.
        $vidW = (& ffprobe -v error -select_streams v:0 -show_entries stream=width  -of default=noprint_wrappers=1:nokey=1 $p.Video 2>$null | Select-Object -First 1)
        $vidH = (& ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 $p.Video 2>$null | Select-Object -First 1)
        $vidDur = (& ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $p.Video 2>$null | Select-Object -First 1)
        if (-not $vidW) { $vidW = 1920 }
        if (-not $vidH) { $vidH = 1080 }
        if (-not $vidDur) { $vidDur = 0 }

        # ── Still layout preview (Tier 1): 1 cadru compus, FARA encode video ──
        if ($script:PreviewStill) {
            $vidDurNum = 0.0
            [double]::TryParse($vidDur, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$vidDurNum) | Out-Null
            $stT = "0"
            $pw = Get-PreviewWindow -Duration $vidDurNum
            if ($pw.Valid) { $stT = $pw.Start }
            $stDir = Join-Path $TempBase ("burnin_still_{0}_{1}" -f $p.Name, [System.Diagnostics.Process]::GetCurrentProcess().Id)
            New-Item -ItemType Directory -Force -Path $stDir | Out-Null
            $gridTxt = if ($script:PreviewGrid) { " + grila" } else { "" }
            Write-Host "  Still preview: 1 cadru la ${stT}s (preset=$preset$gridTxt)..." -ForegroundColor DarkGray
            $stArgs = @("--csv", $p.Aux, "--preset", $presetFile, "--output-dir", $stDir,
                        "--fps", $hudFps, "--duration", "1", "--single", $stT,
                        "--width", $vidW, "--height", $vidH,
                        "--offset", (Format-Inv ([double]$offset)), "--brand", $p.Meta)
            if ($script:PreviewGrid) { $stArgs += "--grid" }
            & $py3 $RenderPy @stArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  [EROARE] Render still esuat" -ForegroundColor Red
                Remove-Item $stDir -Recurse -Force -ErrorAction SilentlyContinue
                $failCount++; continue
            }
            $stOut = Join-Path $OutputDir ("{0}_preview.png" -f $p.Name)
            $stFc = if ($script:BurninPreFilter) {
                "[0:v]$($script:BurninPreFilter)[bb];[bb][1:v]overlay=0:0[v]"
            } else {
                "[0:v][1:v]overlay=0:0[v]"
            }
            Write-Host "  Compun still (cadru video la ${stT}s + HUD)..." -ForegroundColor DarkGray
            Invoke-BurninEncode -v error -ss $stT -i $p.Video -i (Join-Path $stDir "frame_000001.png") `
                -filter_complex $stFc -map "[v]" -frames:v 1 $stOut -y
            if ($LASTEXITCODE -eq 0 -and (Test-Path $stOut) -and (Get-Item $stOut).Length -gt 0) {
                Write-Host "  [OK] $stOut" -ForegroundColor Green; $okCount++
                try { Invoke-Item $stOut -ErrorAction SilentlyContinue } catch {}
            } else {
                Write-Host "  [EROARE] Compozitie still esuata" -ForegroundColor Red
                Remove-Item $stOut -Force -ErrorAction SilentlyContinue; $failCount++
            }
            Remove-Item $stDir -Recurse -Force -ErrorAction SilentlyContinue
            if ($script:BurninHdr10PlusJson -and (Test-Path $script:BurninHdr10PlusJson)) { Remove-Item $script:BurninHdr10PlusJson -Force -ErrorAction SilentlyContinue }
            continue
        }

        # Preview window (render doar 5s la mid)
        $renderDur = $vidDur
        $renderOffset = $offset
        $outSuffix = "hud"
        $seekArgs = @()
        if ($script:PreviewMode) {
            $vidDurNum = 0.0
            [double]::TryParse($vidDur, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$vidDurNum) | Out-Null
            $pw = Get-PreviewWindow -Duration $vidDurNum
            if ($pw.Valid) {
                $renderDur = $pw.Duration
                $renderOffset = Format-Inv ([double]$offset + $pw.StartNum)
                $outSuffix = "preview"
                $seekArgs = @("-ss", $pw.Start, "-t", $pw.Duration)
                Write-Host ("  Preview window: {0}s + {1}s (din {2}s)" -f $pw.Start, $pw.Duration, $vidDur) -ForegroundColor DarkGray
            } else {
                Write-Host "  [WARN] Durata invalida ($vidDur) - preview skipped, fall back la full encode." -ForegroundColor Yellow
            }
        }

        $framesDir = Join-Path $TempBase ("burnin_{0}_{1}" -f $p.Name, [System.Diagnostics.Process]::GetCurrentProcess().Id)
        New-Item -ItemType Directory -Force -Path $framesDir | Out-Null

        Write-Host "  Render PNG sequence (preset=$preset, hud_fps=$hudFps, dur=${renderDur}s)..." -ForegroundColor DarkGray
        & $py3 $RenderPy --csv $p.Aux --preset $presetFile --output-dir $framesDir `
            --fps $hudFps --duration $renderDur --width $vidW --height $vidH `
            --offset $renderOffset --brand $p.Meta
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [EROARE] Render PNG sequence esuat" -ForegroundColor Red
            Remove-Item $framesDir -Recurse -Force -ErrorAction SilentlyContinue
            $failCount++; continue
        }

        $out = Join-Path $OutputDir ("{0}_{1}.{2}" -f $p.Name, $outSuffix, $p.Ext)
        $codecTag = Get-CodecTagForContainer $enc.CodecKey $p.Ext
        # v58: pre-filter (LUT/tonemap) injectat in filter_complex inainte de overlay
        $fc = if ($script:BurninPreFilter) {
            "[0:v]$($script:BurninPreFilter)[burnin_base];[burnin_base][1:v]overlay=0:0:shortest=0[v]"
        } else {
            "[0:v][1:v]overlay=0:0:shortest=0[v]"
        }
        $extraArgs = @($script:BurninEncExtraArgs)
        Write-Host "  Overlay + re-encode ($($enc.Name) CRF $($enc.Crf) preset $($enc.Preset))..." -ForegroundColor DarkGray
        Invoke-BurninEncode -v error -stats `
            @seekArgs `
            -i $p.Video `
            -framerate $hudFps `
            -i (Join-Path $framesDir "frame_%06d.png") `
            -filter_complex $fc `
            -map "[v]" -map "0:a?" `
            -c:v $enc.Name -crf $enc.Crf -preset $enc.Preset `
            @extraArgs `
            -c:a copy @codecTag -movflags +faststart $out -y
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
            Write-Host "  [OK] $out" -ForegroundColor Green; $okCount++
        } else {
            Write-Host "  [EROARE] ffmpeg overlay esuat" -ForegroundColor Red
            Remove-Item $out -Force -ErrorAction SilentlyContinue; $failCount++
        }
        Remove-Item $framesDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($script:BurninHdr10PlusJson -and (Test-Path $script:BurninHdr10PlusJson)) {
            Remove-Item $script:BurninHdr10PlusJson -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════"
    Write-Host ("  Sumar HUD burn-in: {0} OK, {1} esuate (din {2} selectate)" -f $okCount, $failCount, $selected.Count) -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────
# FLOW 2: SRT
# ─────────────────────────────────────────────────────────────────────
function Invoke-SrtFlow {
    $pairs = Get-PairedFiles -PairedSuffix ".srt"
    if ($pairs.Count -eq 0) {
        Write-Host ""
        Write-Host "Nu am gasit nicio pereche video + .srt." -ForegroundColor Yellow
        Write-Host "  Asigura-te ca exista <name>.srt langa video sau in $OutputDir"
        exit 0
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  SRT BURN-IN (subtitrari hardcoded)           ║" -ForegroundColor Cyan
    Write-Host "║  Perechi gasite: $($pairs.Count)"
    Write-Host "║  Input  : $InputDir"
    Write-Host "║  Output : $OutputDir"
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    $selected = Select-Pairs -Pairs $pairs

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  STIL SRT                                     ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  1) Small  (font 18, white + black outline)   ║"
    Write-Host "║     [implicit]                                ║"
    Write-Host "║  2) Medium (font 24)                          ║"
    Write-Host "║  3) Large  (font 32)                          ║"
    Write-Host "║  4) Default ffmpeg (no override)              ║"
    Write-Host "║  5) Anulare                                   ║"
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $styleChoice = Read-Host "Alege 1-5 [implicit: 1]"
    if (-not $styleChoice) { $styleChoice = "1" }
    $forceStyle = ""
    switch ($styleChoice) {
        "1" { $forceStyle = "FontSize=18,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,Outline=2,Shadow=1" }
        "2" { $forceStyle = "FontSize=24,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,Outline=2,Shadow=1" }
        "3" { $forceStyle = "FontSize=32,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,Outline=3,Shadow=1" }
        "4" { $forceStyle = "" }
        "5" { Write-Host "Anulat."; exit 0 }
        default { $forceStyle = "FontSize=18,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,Outline=2,Shadow=1" }
    }

    $enc = Get-Encoder
    Get-PreviewMode

    $okCount = 0; $failCount = 0
    foreach ($idx in $selected) {
        $p = $pairs[$idx]
        Write-Host ""
        Write-Host "─────────────────────────────────────────────"
        Write-Host ("  -- {0}/{1}: {2}" -f ($idx+1), $pairs.Count, [System.IO.Path]::GetFileName($p.Video)) -ForegroundColor Yellow
        Write-Host "─────────────────────────────────────────────"

        # v58: HDR/LOG dialog + chain build
        $sourceInfo = Show-BurninHdrDialog -File $p.Video -EncInfo $enc
        if (-not (Build-BurninVideoChain -File $p.Video -EncInfo $enc -SourceInfo $sourceInfo)) {
            Write-Host "  [SKIP] mod=$(Get-BurninModeLabel $script:BurninMode) — sar la urmatorul fisier" -ForegroundColor DarkGray
            continue
        }
        if ($script:BurninSourceType -ne "sdr") {
            Write-Host "  Sursa: $($script:BurninSourceType) -> mod: $(Get-BurninModeLabel $script:BurninMode)" -ForegroundColor Cyan
            if ($script:BurninDowngradeReason) { Write-Host "  ⚠ $($script:BurninDowngradeReason)" -ForegroundColor Yellow }
        }

        $srtEsc = Get-EscapedFfmpegFilterPath $p.Aux
        $vf = "subtitles='$srtEsc'"
        if ($forceStyle) { $vf = "${vf}:force_style='$forceStyle'" }
        # v58: pre-filter (LUT/tonemap) prepended in -vf chain
        if ($script:BurninPreFilter) { $vf = "$($script:BurninPreFilter),$vf" }

        $outSuffix = "subs"
        $seekArgs = @()
        if ($script:PreviewMode) {
            $vidDurRaw = (& ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $p.Video 2>$null | Select-Object -First 1)
            $vidDurNum = 0.0
            if ($vidDurRaw) {
                [double]::TryParse($vidDurRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$vidDurNum) | Out-Null
            }
            $pw = Get-PreviewWindow -Duration $vidDurNum
            if ($pw.Valid) {
                $outSuffix = "preview"
                $seekArgs = @("-ss", $pw.Start, "-copyts", "-t", $pw.Duration)
                Write-Host ("  Preview window: {0}s + {1}s (din {2}s)" -f $pw.Start, $pw.Duration, $vidDurRaw) -ForegroundColor DarkGray
            } else {
                Write-Host "  [WARN] Durata invalida ($vidDurRaw) - preview skipped, fall back la full encode." -ForegroundColor Yellow
            }
        }

        $out = Join-Path $OutputDir ("{0}_{1}.{2}" -f $p.Name, $outSuffix, $p.Ext)
        $codecTag = Get-CodecTagForContainer $enc.CodecKey $p.Ext
        $extraArgs = @($script:BurninEncExtraArgs)
        Write-Host "  Burn-in SRT + re-encode ($($enc.Name) CRF $($enc.Crf) preset $($enc.Preset))..." -ForegroundColor DarkGray
        Invoke-BurninEncode -v error -stats `
            @seekArgs `
            -i $p.Video `
            -vf $vf `
            -c:v $enc.Name -crf $enc.Crf -preset $enc.Preset `
            @extraArgs `
            -c:a copy @codecTag -movflags +faststart $out -y
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
            Write-Host "  [OK] $out" -ForegroundColor Green; $okCount++
        } else {
            Write-Host "  [EROARE] ffmpeg SRT burn-in esuat" -ForegroundColor Red
            Remove-Item $out -Force -ErrorAction SilentlyContinue; $failCount++
        }
        if ($script:BurninHdr10PlusJson -and (Test-Path $script:BurninHdr10PlusJson)) {
            Remove-Item $script:BurninHdr10PlusJson -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════"
    Write-Host ("  Sumar SRT burn-in: {0} OK, {1} esuate (din {2} selectate)" -f $okCount, $failCount, $selected.Count) -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────
# FLOW 3: ASS
# ─────────────────────────────────────────────────────────────────────
function Invoke-AssFlow {
    $pairs = Get-PairedFiles -PairedSuffix ".ass"
    if ($pairs.Count -eq 0) {
        Write-Host ""
        Write-Host "Nu am gasit nicio pereche video + .ass." -ForegroundColor Yellow
        Write-Host "  Asigura-te ca exista <name>.ass langa video sau in $OutputDir"
        exit 0
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  ASS BURN-IN (styled subtitles, anime)        ║" -ForegroundColor Cyan
    Write-Host "║  Perechi gasite: $($pairs.Count)"
    Write-Host "║  Input  : $InputDir"
    Write-Host "║  Output : $OutputDir"
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    $selected = Select-Pairs -Pairs $pairs

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  ASS FONT SCALE                               ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  1) 1.0x (embedded styling, fara override)    ║"
    Write-Host "║     [implicit]                                ║"
    Write-Host "║  2) 1.25x (TV mediu)                          ║"
    Write-Host "║  3) 1.5x (TV mare)                            ║"
    Write-Host "║  4) Anulare                                   ║"
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $scaleChoice = Read-Host "Alege 1-4 [implicit: 1]"
    if (-not $scaleChoice) { $scaleChoice = "1" }
    $extraStyle = ""
    switch ($scaleChoice) {
        "1" { $extraStyle = "" }
        "2" { $extraStyle = ":force_style='ScaleX=125,ScaleY=125'" }
        "3" { $extraStyle = ":force_style='ScaleX=150,ScaleY=150'" }
        "4" { Write-Host "Anulat."; exit 0 }
        default { $extraStyle = "" }
    }

    $enc = Get-Encoder
    Get-PreviewMode

    $okCount = 0; $failCount = 0
    foreach ($idx in $selected) {
        $p = $pairs[$idx]
        Write-Host ""
        Write-Host "─────────────────────────────────────────────"
        Write-Host ("  -- {0}/{1}: {2}" -f ($idx+1), $pairs.Count, [System.IO.Path]::GetFileName($p.Video)) -ForegroundColor Yellow
        Write-Host "─────────────────────────────────────────────"

        # v58: HDR/LOG dialog + chain build
        $sourceInfo = Show-BurninHdrDialog -File $p.Video -EncInfo $enc
        if (-not (Build-BurninVideoChain -File $p.Video -EncInfo $enc -SourceInfo $sourceInfo)) {
            Write-Host "  [SKIP] mod=$(Get-BurninModeLabel $script:BurninMode) — sar la urmatorul fisier" -ForegroundColor DarkGray
            continue
        }
        if ($script:BurninSourceType -ne "sdr") {
            Write-Host "  Sursa: $($script:BurninSourceType) -> mod: $(Get-BurninModeLabel $script:BurninMode)" -ForegroundColor Cyan
            if ($script:BurninDowngradeReason) { Write-Host "  ⚠ $($script:BurninDowngradeReason)" -ForegroundColor Yellow }
        }

        $assEsc = Get-EscapedFfmpegFilterPath $p.Aux
        $vf = "ass='$assEsc'${extraStyle}"
        # v58: pre-filter (LUT/tonemap) prepended in -vf chain
        if ($script:BurninPreFilter) { $vf = "$($script:BurninPreFilter),$vf" }

        $outSuffix = "subs"
        $seekArgs = @()
        if ($script:PreviewMode) {
            $vidDurRaw = (& ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $p.Video 2>$null | Select-Object -First 1)
            $vidDurNum = 0.0
            if ($vidDurRaw) {
                [double]::TryParse($vidDurRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$vidDurNum) | Out-Null
            }
            $pw = Get-PreviewWindow -Duration $vidDurNum
            if ($pw.Valid) {
                $outSuffix = "preview"
                $seekArgs = @("-ss", $pw.Start, "-copyts", "-t", $pw.Duration)
                Write-Host ("  Preview window: {0}s + {1}s (din {2}s)" -f $pw.Start, $pw.Duration, $vidDurRaw) -ForegroundColor DarkGray
            } else {
                Write-Host "  [WARN] Durata invalida ($vidDurRaw) - preview skipped, fall back la full encode." -ForegroundColor Yellow
            }
        }

        $out = Join-Path $OutputDir ("{0}_{1}.{2}" -f $p.Name, $outSuffix, $p.Ext)
        $codecTag = Get-CodecTagForContainer $enc.CodecKey $p.Ext
        $extraArgs = @($script:BurninEncExtraArgs)
        Write-Host "  Burn-in ASS + re-encode ($($enc.Name) CRF $($enc.Crf) preset $($enc.Preset))..." -ForegroundColor DarkGray
        Invoke-BurninEncode -v error -stats `
            @seekArgs `
            -i $p.Video `
            -vf $vf `
            -c:v $enc.Name -crf $enc.Crf -preset $enc.Preset `
            @extraArgs `
            -c:a copy @codecTag -movflags +faststart $out -y
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
            Write-Host "  [OK] $out" -ForegroundColor Green; $okCount++
        } else {
            Write-Host "  [EROARE] ffmpeg ASS burn-in esuat" -ForegroundColor Red
            Remove-Item $out -Force -ErrorAction SilentlyContinue; $failCount++
        }
        if ($script:BurninHdr10PlusJson -and (Test-Path $script:BurninHdr10PlusJson)) {
            Remove-Item $script:BurninHdr10PlusJson -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════"
    Write-Host ("  Sumar ASS burn-in: {0} OK, {1} esuate (din {2} selectate)" -f $okCount, $failCount, $selected.Count) -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────
# FLOW 4: Image subs (Bluray PGS / DVD VobSub, ext + embedded)
# ─────────────────────────────────────────────────────────────────────
function Get-ImgPairs {
    $pairs = New-Object System.Collections.Generic.List[object]
    $haveFfprobe = [bool](Get-Command "ffprobe" -ErrorAction SilentlyContinue)
    foreach ($dir in @(@{Path=$OutputDir; Label="OUT"}, @{Path=$InputDir; Label="IN"})) {
        if (-not (Test-Path $dir.Path)) { continue }
        Get-ChildItem -Path $dir.Path -Recurse -Depth 1 -File -Include "*.mp4","*.mov","*.mkv","*.m4v" -ErrorAction SilentlyContinue | ForEach-Object {
            $name = $_.BaseName
            if ($name -like "*_hud" -or $name -like "*_telem" -or $name -like "*_subs" -or $name -like "*_preview") { return }
            $dirOf = $_.DirectoryName

            # External PGS .sup
            $sup = Join-Path $dirOf "${name}.sup"
            if (-not ((Test-Path $sup) -and (Get-Item $sup).Length -gt 0)) {
                $sup = Join-Path $OutputDir "${name}.sup"
            }
            if ((Test-Path $sup) -and (Get-Item $sup).Length -gt 0) {
                $pairs.Add([PSCustomObject]@{
                    Video = $_.FullName; Aux = $sup
                    Label = "[$($dir.Label)] $($_.Name) [PGS .sup]"
                    Kind  = "ext_pgs"; Track = ""
                    Name  = $name; Ext = $_.Extension.TrimStart(".")
                })
            }

            # External VobSub .idx + .sub
            $idxf = Join-Path $dirOf "${name}.idx"
            $subf = Join-Path $dirOf "${name}.sub"
            if (-not ((Test-Path $idxf) -and (Test-Path $subf))) {
                $idxf = Join-Path $OutputDir "${name}.idx"
                $subf = Join-Path $OutputDir "${name}.sub"
            }
            if ((Test-Path $idxf) -and (Test-Path $subf) -and (Get-Item $idxf).Length -gt 0 -and (Get-Item $subf).Length -gt 0) {
                $pairs.Add([PSCustomObject]@{
                    Video = $_.FullName; Aux = $idxf
                    Label = "[$($dir.Label)] $($_.Name) [VobSub .idx/.sub]"
                    Kind  = "ext_vob"; Track = ""
                    Name  = $name; Ext = $_.Extension.TrimStart(".")
                })
            }

            # Embedded subtitle tracks (PGS / VobSub)
            if ($haveFfprobe) {
                $streams = & ffprobe -v error -select_streams s `
                    -show_entries "stream=index,codec_name:stream_tags=language" `
                    -of csv=p=0 $_.FullName 2>$null
                $streamIdx = 0
                foreach ($line in $streams) {
                    if (-not $line) { continue }
                    $cols = $line.Split(",")
                    if ($cols.Length -lt 2) { continue }
                    $codec = $cols[1].Trim().TrimEnd(',')
                    # v58 audit: strip trailing comma de la csv=p=0 last field
                    $lang  = if ($cols.Length -ge 3) { $cols[2].Trim().TrimEnd(',') } else { "" }
                    if (-not $codec) { continue }
                    $kind = $null
                    if ($codec -eq "hdmv_pgs_subtitle") { $kind = "emb_pgs"; $tag = "PGS embedded" }
                    elseif ($codec -eq "dvd_subtitle")  { $kind = "emb_vob"; $tag = "VobSub embedded" }
                    if ($kind) {
                        $labelExtra = if ($lang) { " $lang" } else { "" }
                        $pairs.Add([PSCustomObject]@{
                            Video = $_.FullName; Aux = $_.FullName
                            Label = "[$($dir.Label)] $($_.Name) [$tag s:${streamIdx}${labelExtra}]"
                            Kind  = $kind; Track = "$streamIdx"
                            Name  = $name; Ext = $_.Extension.TrimStart(".")
                        })
                    }
                    $streamIdx++
                }
            }
        }
    }
    return $pairs
}

function Invoke-ImgFlow {
    $pairs = Get-ImgPairs
    if ($pairs.Count -eq 0) {
        Write-Host ""
        Write-Host "Nu am gasit nicio sursa de subtitrari imagine." -ForegroundColor Yellow
        Write-Host "  Cautat: <name>.sup (PGS) / <name>.idx+.sub (VobSub) langa video sau in $OutputDir"
        Write-Host "  Cautat: track-uri embedded PGS/VobSub in MKV/MP4 (via ffprobe)"
        exit 0
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  IMAGE SUBS BURN-IN (Bluray PGS / DVD VobSub) ║" -ForegroundColor Cyan
    Write-Host "║  Surse gasite: $($pairs.Count)"
    Write-Host "║  Input  : $InputDir"
    Write-Host "║  Output : $OutputDir"
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    $selected = Select-Pairs -Pairs $pairs

    Write-Host ""
    Write-Host "Nota: image subs (PGS/VobSub) sunt bitmap pre-rendered —" -ForegroundColor Yellow
    Write-Host "      fara optiuni de styling (font/size). Track selection only."

    $enc = Get-Encoder
    Get-PreviewMode

    $okCount = 0; $failCount = 0
    foreach ($idx in $selected) {
        $p = $pairs[$idx]
        Write-Host ""
        Write-Host "─────────────────────────────────────────────"
        Write-Host ("  -- {0}/{1}: {2}  [{3}{4}]" -f ($idx+1), $pairs.Count, [System.IO.Path]::GetFileName($p.Video), $p.Kind, $(if ($p.Track) { " s:$($p.Track)" } else { "" })) -ForegroundColor Yellow
        Write-Host "─────────────────────────────────────────────"

        # v58: HDR/LOG dialog + chain build
        $sourceInfo = Show-BurninHdrDialog -File $p.Video -EncInfo $enc
        if (-not (Build-BurninVideoChain -File $p.Video -EncInfo $enc -SourceInfo $sourceInfo)) {
            Write-Host "  [SKIP] mod=$(Get-BurninModeLabel $script:BurninMode) — sar la urmatorul fisier" -ForegroundColor DarkGray
            continue
        }
        if ($script:BurninSourceType -ne "sdr") {
            Write-Host "  Sursa: $($script:BurninSourceType) -> mod: $(Get-BurninModeLabel $script:BurninMode)" -ForegroundColor Cyan
            if ($script:BurninDowngradeReason) { Write-Host "  ⚠ $($script:BurninDowngradeReason)" -ForegroundColor Yellow }
        }

        $outSuffix = "subs"
        $seekArgs = @()
        if ($script:PreviewMode) {
            $vidDurRaw = (& ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $p.Video 2>$null | Select-Object -First 1)
            $vidDurNum = 0.0
            if ($vidDurRaw) {
                [double]::TryParse($vidDurRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$vidDurNum) | Out-Null
            }
            $pw = Get-PreviewWindow -Duration $vidDurNum
            if ($pw.Valid) {
                $outSuffix = "preview"
                $seekArgs = @("-ss", $pw.Start, "-copyts", "-t", $pw.Duration)
                Write-Host ("  Preview window: {0}s + {1}s (din {2}s)" -f $pw.Start, $pw.Duration, $vidDurRaw) -ForegroundColor DarkGray
            } else {
                Write-Host "  [WARN] Durata invalida ($vidDurRaw) - preview skipped, fall back la full encode." -ForegroundColor Yellow
            }
        }

        $out = Join-Path $OutputDir ("{0}_{1}.{2}" -f $p.Name, $outSuffix, $p.Ext)
        $codecTag = Get-CodecTagForContainer $enc.CodecKey $p.Ext
        $extraArgs = @($script:BurninEncExtraArgs)
        # v58: pre-filter (LUT/tonemap) injectat in filter_complex inainte de overlay
        $fcExt = if ($script:BurninPreFilter) {
            "[0:v]$($script:BurninPreFilter)[burnin_base];[burnin_base][1:s]overlay[v]"
        } else { "[0:v][1:s]overlay[v]" }
        $fcEmb = if ($script:BurninPreFilter) {
            "[0:v]$($script:BurninPreFilter)[burnin_base];[burnin_base][0:s:$($p.Track)]overlay[v]"
        } else { "[0:v][0:s:$($p.Track)]overlay[v]" }
        # v69 FIX: kind necunoscut prin FLAG — `continue` in switch NU sare perechea
        # (iese doar din switch) → cadea in verificarea $LASTEXITCODE de mai jos cu
        # un exit code STALE si dubla $failCount + afisa o a doua eroare falsa.
        $kindUnknown = $false
        switch ($p.Kind) {
            { $_ -in @("ext_pgs","ext_vob") } {
                Write-Host "  Burn-in $($p.Kind) (sursa: $($p.Aux)) + re-encode ($($enc.Name) CRF $($enc.Crf) preset $($enc.Preset))..." -ForegroundColor DarkGray
                Invoke-BurninEncode -v error -stats `
                    @seekArgs `
                    -i $p.Video `
                    -i $p.Aux `
                    -filter_complex $fcExt `
                    -map "[v]" -map "0:a?" `
                    -c:v $enc.Name -crf $enc.Crf -preset $enc.Preset `
                    @extraArgs `
                    -c:a copy @codecTag -movflags +faststart $out -y
            }
            { $_ -in @("emb_pgs","emb_vob") } {
                Write-Host "  Burn-in $($p.Kind) (track s:$($p.Track) embedded) + re-encode ($($enc.Name) CRF $($enc.Crf) preset $($enc.Preset))..." -ForegroundColor DarkGray
                Invoke-BurninEncode -v error -stats `
                    @seekArgs `
                    -i $p.Video `
                    -filter_complex $fcEmb `
                    -map "[v]" -map "0:a?" `
                    -c:v $enc.Name -crf $enc.Crf -preset $enc.Preset `
                    @extraArgs `
                    -c:a copy @codecTag -movflags +faststart $out -y
            }
            default {
                Write-Host "  [EROARE] kind necunoscut: $($p.Kind)" -ForegroundColor Red
                $kindUnknown = $true
            }
        }
        if ($kindUnknown) { $failCount++; continue }
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
            Write-Host "  [OK] $out" -ForegroundColor Green; $okCount++
        } else {
            Write-Host "  [EROARE] ffmpeg image subs burn-in esuat" -ForegroundColor Red
            Remove-Item $out -Force -ErrorAction SilentlyContinue; $failCount++
        }
        if ($script:BurninHdr10PlusJson -and (Test-Path $script:BurninHdr10PlusJson)) {
            Remove-Item $script:BurninHdr10PlusJson -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════"
    Write-Host ("  Sumar Image subs burn-in: {0} OK, {1} esuate (din {2} selectate)" -f $okCount, $failCount, $selected.Count) -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────
# Test mode: skip interactive menu (allow dot-sourcing for tests)
# ─────────────────────────────────────────────────────────────────────
if ($env:AV_BURNIN_TEST_MODE -eq "1") { return }

# ─────────────────────────────────────────────────────────────────────
# Main menu — alege tip burn-in
# ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  BURN-IN — selecteaza tipul                   ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  1) Telemetry HUD (gauges + map)              ║"
Write-Host "║     Sursa: norm CSV                           ║"
Write-Host "║  2) Subtitrari SRT (telemetry overlay/movies) ║"
Write-Host "║  3) Subtitrari ASS (anime, styled subs)       ║"
Write-Host "║  4) Image subs PGS/VobSub (Bluray/DVD)        ║"
Write-Host "║  5) Anulare                                   ║"
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
$burninType = Read-Host "Alege 1-5 [implicit: 1]"
if (-not $burninType) { $burninType = "1" }
switch ($burninType) {
    "1" { Invoke-HudFlow }
    "2" { Invoke-SrtFlow }
    "3" { Invoke-AssFlow }
    "4" { Invoke-ImgFlow }
    "5" { Write-Host "Anulat."; exit 0 }
    default { Write-Host "Optiune invalida." -ForegroundColor Red; exit 1 }
}
