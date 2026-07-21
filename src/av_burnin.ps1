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
$DesignerPy  = Join-Path $ScriptDir "burnin_designer.py"

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

# v88: detecteaza audio Eclipsa/IAMF — copie standalone (av_burnin.ps1 nu importa
# av_encode.ps1; mirror Get-IamfLayout / _iamf_probe). Layout sau "" (fara grup).
# Folosit de nota din Show-BurninHdrDialog + de graftul post-encode (v90).
function Get-IamfLayout {
    param([string]$File)
    $gtype = @(& ffprobe -v error -show_stream_groups -show_entries stream_group=type `
        -of default=noprint_wrappers=1:nokey=1 $File 2>$null) -join ' '
    if ($gtype -notmatch "IAMF Audio Element") { return "" }
    $layMatch = @(& ffprobe -hide_banner $File 2>&1) | Select-String -Pattern 'Layer \d+:' | Select-Object -Last 1
    $lay = if ($layMatch) { $layMatch.ToString() } else { "" }
    if ($lay -match 'stereo')      { return "stereo" }
    if ($lay -match '6 channels')  { return "5.1" }
    if ($lay -match '8 channels')  { return "7.1" }
    if ($lay -match '12 channels') { return "7.1.4" }
    return "iamf"
}

# v90: passthrough Eclipsa/IAMF — copie standalone (mirror Invoke-IamfPreserve /
# _iamf_preserve; av_burnin.ps1 nu importa av_encode.ps1). Burn-in re-encodeaza
# video-ul dar copiaza audio-ul prin ffmpeg → grupul IAMF se aplatizeaza la Opus
# simplu; timeline-ul audio ramane insa 1:1 pe output-ul COMPLET → re-grefam grupul
# INTREG din sursa (extract raw MP4Box → rebuild -rem/-add → mv atomic). DOAR
# MP4/MOV. NU se apeleaza pe preview-uri (clip taiat → substream-urile nu se
# regrupeaza). Temp-uri CO-LOCATE. Idempotent. Soft-fail: output NEATINS la esec.
function Invoke-IamfPreserve {
    param([string]$Source, [string]$Output, [switch]$AllowNoAudio)
    $ext = [System.IO.Path]::GetExtension($Output).TrimStart('.').ToLowerInvariant()
    if (-not (Get-IamfLayout -File $Source)) { return $true }
    if ($ext -notin @('mp4','mov','m4v')) {
        Write-Host "  ⚠ Sursa are audio Eclipsa/IAMF — grupul NU exista in .$ext →" -ForegroundColor Yellow
        Write-Host "    audio ramane Opus multi-pista simplu. Foloseste MP4/MOV ca sa pastrezi Eclipsa." -ForegroundColor Yellow
        return $false
    }
    $mux = if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } elseif ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "GPAC\mp4box.exe"))) { Join-Path $PSScriptRoot "GPAC\mp4box.exe" } else { "mp4box" }
    if (-not (Get-Command $mux -ErrorAction SilentlyContinue)) {
        Write-Host "  ⚠ MP4Box lipseste — grupul Eclipsa/IAMF nu poate fi re-scris (audio ramane Opus simplu)." -ForegroundColor Yellow
        return $false
    }
    if (Get-IamfLayout -File $Output) { return $true }
    $remArgs = @()
    foreach ($ln in @(& ffprobe -v error -select_streams a -show_entries stream=id -of csv=p=0 $Output 2>$null)) {
        $idhex = ($ln -split ',')[0].Trim()
        if ($idhex -match '^0x[0-9a-fA-F]+$') { $remArgs += @("-rem", [Convert]::ToInt32($idhex, 16)) }
    }
    if ($remArgs.Count -eq 0 -and -not $AllowNoAudio) { return $true }
    $tid = $null
    foreach ($ln in @(& $mux -info $Source 2>&1)) {
        if ("$ln" -match '^# Track \d+ Info - ID (\d+)') { $curId = $Matches[1] }
        if ("$ln" -match 'Media Type: soun:iamf') { $tid = $curId; break }
    }
    if (-not ($tid -match '^\d+$')) { return $false }
    $dir = Split-Path $Output -Parent
    $g = [guid]::NewGuid().ToString("N")
    $raw = Join-Path $dir ("iamfpre_" + $g + ".iamf")
    $tmp = Join-Path $dir ("iamfpre_" + $g + "." + $ext)
    # capitolele se cara DETERMINIST prin dump-chap + -chap (rebuild-ul MP4Box
    # trunchiaza etichetele track-ului QT — regula v88)
    $chapf = Join-Path $dir ("iamfpre_" + $g + ".txt")
    $nch = (@(& ffprobe -v error -show_chapters $Output 2>$null) | Where-Object { $_ -match '^\[CHAPTER\]' }).Count
    if ($nch -gt 0) { & $mux -dump-chap $Output -out $chapf 2>$null | Out-Null }
    & $mux -raw $tid -out $raw $Source 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $raw) -or (Get-Item $raw).Length -eq 0) {
        Remove-Item $raw, $chapf -Force -ErrorAction SilentlyContinue; return $false
    }
    $addArgs = @("-add", $Output) + $remArgs + @("-add", $raw, "-new", $tmp)
    & $mux @addArgs 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0 -and (Get-IamfLayout -File $tmp)) {
        Move-Item -Force $tmp $Output
        if ((Test-Path $chapf) -and (Get-Item $chapf).Length -gt 0) { & $mux -chap $chapf $Output 2>$null | Out-Null }
        Remove-Item $raw, $chapf -Force -ErrorAction SilentlyContinue
        Write-Host "  Grup Eclipsa/IAMF re-scris in container (audio spatial pastrat 1:1)" -ForegroundColor Green
        return $true
    }
    Remove-Item $raw, $tmp, $chapf -Force -ErrorAction SilentlyContinue
    return $false
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
# ── A (v82): filtru de display pentru still preview ───────────────────
# Pre-filter existent (tonemap/LUT) are prioritate; pe HDR-preserve (pre-filter
# gol) tonemapeaza DOAR pentru PNG ca sa nu iasa stins. BURNIN_STILL_NO_TONEMAP=1
# -> sare tonemap-ul (raw). SDR -> gol.
function Get-BurninStillDisplayFilter {
    if ($script:BurninPreFilter) { return $script:BurninPreFilter }
    if ($env:BURNIN_STILL_NO_TONEMAP -ne "1" -and
        @("hdr10","hdr10plus","hlg") -contains $script:BurninSourceType) {
        return "zscale=t=linear:npl=100,tonemap=tonemap=hable,zscale=t=bt709:m=bt709:p=bt709:r=tv,format=yuv420p"
    }
    return ""
}

# ── B (v82): text shaping pt subtitrari (libass HarfBuzz; subtitles/ass) ──
# Optiunea `shaping` e NEW in ffmpeg -> gate de capabilitate. Pt scripturi
# complexe (araba/ebraica/indic). Gol = auto (default-ul filtrului).
$script:BurninShapingCap = $null
function Test-BurninSubtitleShaping {
    if ($null -eq $script:BurninShapingCap) {
        $h = (& ffmpeg -hide_banner -h filter=subtitles 2>&1) -join "`n"
        $script:BurninShapingCap = [bool]($h -match 'shaping')
    }
    return $script:BurninShapingCap
}
function Get-BurninShaping {
    if (-not (Test-BurninSubtitleShaping)) { return "" }
    Write-Host ""
    Write-Host "  Text shaping (scripturi complexe: araba / ebraica / indic):"
    Write-Host "    1) auto [implicit]   2) simple   3) complex"
    $s = Read-Host "  Alege 1-3 [implicit 1]"
    switch ($s) {
        "2" { Write-Host "  -> shaping=simple" -ForegroundColor DarkGray; return "simple" }
        "3" { Write-Host "  -> shaping=complex" -ForegroundColor DarkGray; return "complex" }
        default { return "" }
    }
}

function Invoke-BurninEncode {
    # v85 (F7): apelantii TREBUIE sa paseze argumentele ca UN array splatat
    #   (construieste $ffArgs=@(...), apoi splateaza-l), NU tokenuri literale. La un apel de FUNCTIE
    #   PowerShell, un flag cu doua puncte (`-c:v`, `-c:a`, `-frames:v`) e parsat ca
    #   sintaxa `-param:value` → `-c:v libx265` devine `-c:` + `v` + `libx265` →
    #   `v` ajunge fisier de iesire ("Unable to choose an output format for 'v'").
    #   Splatarea unui array pre-construit transmite elementele ca DATE (fara
    #   re-parsare de `:`), deci flag-urile raman intacte.
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
    # v85: Apple fallback pe encoderul de STREAM ("Apple ProRes") — supravietuieste la
    # -c copy/trim cand make=Apple de container se pierde. Paritate cu detect_source_info.
    if (-not $info.CameraMake) {
        $vEnc = @(& ffprobe -v error -select_streams v:0 -show_entries stream_tags=encoder `
            -of default=noprint_wrappers=1:nokey=1 $File 2>$null)[0]
        if ("$vEnc" -match "Apple ProRes") { $info.CameraMake = "apple" }
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
    $all = @(Get-ChildItem -Path $lutsDir -Filter "*.cube" -File -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return @() }
    # v83: brand-aware — recunoaste NUME REALE (AppleLog*, *Samsung*Log*, *D-LogM*) pe langa
    # prefixul conventional; brand-matched primele, restul dupa (burn-in foloseste [0] = brand).
    # FIX paritate: inainte, pe apple/samsung/dji cu nume real (fara prefix apple_log_) intorcea
    # GOL (lipsea fallback-ul v62 pe care il au find_lut_for_brand/Find-LutForBrand).
    $brandLuts = @(); $rest = @()
    foreach ($f in $all) {
        $lb = $f.Name.ToLower()
        $isBrand = $false
        switch ($Brand) {
            "apple"   { if ($lb.StartsWith($prefix) -or $lb -match 'apple.*log')      { $isBrand = $true } }
            "samsung" { if ($lb.StartsWith($prefix) -or $lb -match 'samsung.*log')    { $isBrand = $true } }
            "dji"     { if ($lb.StartsWith($prefix) -or $lb -match 'dlog|d-log|d_log') { $isBrand = $true } }
        }
        if ($isBrand) { $brandLuts += $f.FullName } else { $rest += $f.FullName }
    }
    return @(@($brandLuts) + @($rest))
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

    # v88: sursa cu grup Eclipsa/IAMF — burn-in copiaza audio-ul prin ffmpeg, care
    # APLATIZEAZA grupul la Opus simplu → nota onesta, o data per fisier, INAINTE de
    # early-return-ul SDR (sursele Eclipsa au tipic video SDR). v90: graftul e cablat
    # pe output-ul COMPLET → pe MP4/MOV grupul se re-scrie automat; pe alte containere
    # / pe PREVIEW (clip taiat) ramane aplatizat.
    if (Get-IamfLayout -File $File) {
        Write-Host "  ℹ Sursa are grup Eclipsa/IAMF — la burn-in audio-ul se copiaza prin ffmpeg →" -ForegroundColor Cyan
        Write-Host "    pe MP4/MOV grupul se RE-SCRIE automat dupa encode (v90); pe alte containere" -ForegroundColor Cyan
        Write-Host "    si pe preview-uri ramane Opus simplu (pistele raman, spatialul se pierde)." -ForegroundColor Cyan
    }

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
    # v85 (F9): DV Profile 5/7 au baza IPT cu color_transfer=unknown → zscale nu poate
    # liniariza ("no path between colorspaces") → tonemap-ul (optiunea RECOMANDATA in
    # dialogul DV) CRAPA. Prepend setparams=PQ/BT.2020 DOAR cand transferul e necunoscut
    # (baza P5/P7 e HDR10-like). P8.1 (smpte2084)/P8.4 (arib) au transfer cunoscut →
    # prefix gol → tonemap corect neschimbat. Sigur si pe fallback-urile libx264
    # preserve_hdr10/hlg (sursa lor are transfer cunoscut → prefix gol).
    $tmTrc = (& ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 $File 2>$null | Select-Object -First 1)
    if ($tmTrc) { $tmTrc = $tmTrc.Trim() }
    $tmPrefix = ""
    if ((-not $tmTrc) -or $tmTrc -eq "unknown") {
        $tmPrefix = "setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc,"
    }
    $tonemapFilter = "${tmPrefix}zscale=transfer=linear:matrix=bt709:primaries=bt709,tonemap=hable:desat=0,zscale=transfer=bt709:matrix=bt709:primaries=bt709,format=yuv420p"

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
    Write-Host "║  4) custom      — preset salvat (Designer)    ║"
    Write-Host "║  5) Anulare                                   ║"
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $presetChoice = Read-Host "Alege 1-5 [implicit: 3]"
    if (-not $presetChoice) { $presetChoice = "3" }
    $presetFile = ""
    switch ($presetChoice) {
        "1" { $preset = "minimal" }
        "2" { $preset = "data-strip" }
        "3" { $preset = "full" }
        "4" {
            # v84: preseturi salvate de Designer (UserProfiles/burnin/)
            $custDir = Join-Path (Join-Path $ScriptDir "UserProfiles") "burnin"
            $custConfs = @()
            if (Test-Path $custDir) {
                $custConfs = @(Get-ChildItem -Path $custDir -Filter "*.conf" -File -ErrorAction SilentlyContinue | Sort-Object Name)
            }
            if ($custConfs.Count -eq 0) {
                Write-Host ""
                Write-Host "Niciun preset custom in $custDir." -ForegroundColor Yellow
                Write-Host "  Creeaza unul cu Designerul vizual (meniul Burn-in, optiunea 5)."
                exit 0
            }
            for ($i = 0; $i -lt $custConfs.Count; $i++) {
                "  {0,2}) {1}" -f ($i+1), $custConfs[$i].BaseName | Write-Host
            }
            Write-Host ""
            $custIdx = Read-Host "Alege preset [implicit 1]"
            if (-not $custIdx) { $custIdx = "1" }
            if ($custIdx -notmatch '^\d+$') { Write-Host "Index invalid." -ForegroundColor Red; exit 1 }
            $ci = [int]$custIdx - 1
            if ($ci -lt 0 -or $ci -ge $custConfs.Count) { Write-Host "Index in afara range." -ForegroundColor Red; exit 1 }
            $presetFile = $custConfs[$ci].FullName
            $preset = $custConfs[$ci].BaseName
        }
        "5" { Write-Host "Anulat."; exit 0 }
        default { $preset = "full" }
    }
    if (-not $presetFile) { $presetFile = Join-Path $PresetsDir "${preset}.conf" }
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
            $stDisp = Get-BurninStillDisplayFilter
            $stFc = if ($stDisp) {
                "[0:v]$($stDisp)[bb];[bb][1:v]overlay=0:0[v]"
            } else {
                "[0:v][1:v]overlay=0:0[v]"
            }
            if ((-not $script:BurninPreFilter) -and $stDisp) {
                Write-Host "  (still tonemapped pentru preview; output-ul real pastreaza HDR)" -ForegroundColor DarkGray
            }
            Write-Host "  Compun still (cadru video la ${stT}s + HUD)..." -ForegroundColor DarkGray
            $stArgs = @('-v','error','-ss',$stT,'-i',$p.Video,'-i',(Join-Path $stDir "frame_000001.png"),
                '-filter_complex',$stFc,'-map','[v]','-frames:v','1',$stOut,'-y')
            Invoke-BurninEncode @stArgs
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
        # v85 (F6): ffmpeg nou negociaza formate CU alpha la iesirea overlay-ului
        # (PNG-ul HUD e RGBA → [v]=yuva420p) iar libx265 refuza deschiderea
        # ("does not support alpha layer encoding") → format EXPLICIT dupa overlay.
        # 10-bit pe modurile preserve (lantul HDR ramane 10-bit), altfel 8-bit.
        $ovFmt = if ($script:BurninMode -in @("preserve_hdr10","preserve_hdr10plus","preserve_hlg")) { "yuv420p10le" } else { "yuv420p" }
        $fc = if ($script:BurninPreFilter) {
            "[0:v]$($script:BurninPreFilter)[burnin_base];[burnin_base][1:v]overlay=0:0:shortest=0,format=$ovFmt[v]"
        } else {
            "[0:v][1:v]overlay=0:0:shortest=0,format=$ovFmt[v]"
        }
        $extraArgs = @($script:BurninEncExtraArgs)
        Write-Host "  Overlay + re-encode ($($enc.Name) CRF $($enc.Crf) preset $($enc.Preset))..." -ForegroundColor DarkGray
        $ffArgs = @('-v','error','-stats') + $seekArgs + @(
            '-i',$p.Video,'-framerate',$hudFps,
            '-i',(Join-Path $framesDir "frame_%06d.png"),
            '-filter_complex',$fc,'-map','[v]','-map','0:a?',
            '-c:v',$enc.Name,'-crf',$enc.Crf,'-preset',$enc.Preset) + $extraArgs + @('-c:a','copy')
        if ($codecTag) { $ffArgs += $codecTag }
        $ffArgs += @('-movflags','+faststart',$out,'-y')
        Invoke-BurninEncode @ffArgs
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
            Write-Host "  [OK] $out" -ForegroundColor Green; $okCount++
            # v90: re-graft grupul Eclipsa/IAMF pe output-ul complet (NU pe preview —
            # clip taiat → substream-urile nu se regrupeaza; regula trim/concat)
            if ($outSuffix -ne "preview") { Invoke-IamfPreserve -Source $p.Video -Output $out | Out-Null }
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

    $subShaping = Get-BurninShaping

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
        if ($subShaping) { $vf = "${vf}:shaping=$subShaping" }
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
        $ffArgs = @('-v','error','-stats') + $seekArgs + @(
            '-i',$p.Video,'-vf',$vf,
            '-c:v',$enc.Name,'-crf',$enc.Crf,'-preset',$enc.Preset) + $extraArgs + @('-c:a','copy')
        if ($codecTag) { $ffArgs += $codecTag }
        $ffArgs += @('-movflags','+faststart',$out,'-y')
        Invoke-BurninEncode @ffArgs
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
            Write-Host "  [OK] $out" -ForegroundColor Green; $okCount++
            # v90: re-graft grupul Eclipsa/IAMF pe output-ul complet (NU pe preview —
            # clip taiat → substream-urile nu se regrupeaza; regula trim/concat)
            if ($outSuffix -ne "preview") { Invoke-IamfPreserve -Source $p.Video -Output $out | Out-Null }
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

    # v82: ASS-urile isi poarta propriul styling (font, marime, culoare, pozitie)
    # in fisier -> nu oferim override de scale. Optiunile vechi 1.25x/1.5x foloseau
    # `force_style='ScaleX/Y'` pe filtrul `ass`, care NU are force_style -> erau
    # rupte din v48 (nu redau nimic). Folosim filtrul nativ `ass` (respecta styling-ul)
    # + shaping optional (filtrul `ass` suporta shaping nativ).
    Write-Host ""
    Write-Host "  ASS: styling embedded pastrat (font / marime / culoare din fisierul .ass)." -ForegroundColor DarkGray

    $subShaping = Get-BurninShaping

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
        $vf = "ass='$assEsc'"
        if ($subShaping) { $vf = "${vf}:shaping=$subShaping" }
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
        $ffArgs = @('-v','error','-stats') + $seekArgs + @(
            '-i',$p.Video,'-vf',$vf,
            '-c:v',$enc.Name,'-crf',$enc.Crf,'-preset',$enc.Preset) + $extraArgs + @('-c:a','copy')
        if ($codecTag) { $ffArgs += $codecTag }
        $ffArgs += @('-movflags','+faststart',$out,'-y')
        Invoke-BurninEncode @ffArgs
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
            Write-Host "  [OK] $out" -ForegroundColor Green; $okCount++
            # v90: re-graft grupul Eclipsa/IAMF pe output-ul complet (NU pe preview —
            # clip taiat → substream-urile nu se regrupeaza; regula trim/concat)
            if ($outSuffix -ne "preview") { Invoke-IamfPreserve -Source $p.Video -Output $out | Out-Null }
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
        # v85 (F6): subpicture-urile (PGS/VobSub) au alpha → ffmpeg nou negociaza
        # yuva* la iesirea overlay → x265 refuza → format EXPLICIT dupa overlay
        # (10-bit pe modurile preserve, altfel 8-bit — ca la HUD).
        $ovFmt = if ($script:BurninMode -in @("preserve_hdr10","preserve_hdr10plus","preserve_hlg")) { "yuv420p10le" } else { "yuv420p" }
        $fcExt = if ($script:BurninPreFilter) {
            "[0:v]$($script:BurninPreFilter)[burnin_base];[burnin_base][1:s]overlay,format=$ovFmt[v]"
        } else { "[0:v][1:s]overlay,format=$ovFmt[v]" }
        $fcEmb = if ($script:BurninPreFilter) {
            "[0:v]$($script:BurninPreFilter)[burnin_base];[burnin_base][0:s:$($p.Track)]overlay,format=$ovFmt[v]"
        } else { "[0:v][0:s:$($p.Track)]overlay,format=$ovFmt[v]" }
        # v69 FIX: kind necunoscut prin FLAG — `continue` in switch NU sare perechea
        # (iese doar din switch) → cadea in verificarea $LASTEXITCODE de mai jos cu
        # un exit code STALE si dubla $failCount + afisa o a doua eroare falsa.
        $kindUnknown = $false
        switch ($p.Kind) {
            { $_ -in @("ext_pgs","ext_vob") } {
                Write-Host "  Burn-in $($p.Kind) (sursa: $($p.Aux)) + re-encode ($($enc.Name) CRF $($enc.Crf) preset $($enc.Preset))..." -ForegroundColor DarkGray
                $ffArgs = @('-v','error','-stats') + $seekArgs + @(
                    '-i',$p.Video,'-i',$p.Aux,
                    '-filter_complex',$fcExt,'-map','[v]','-map','0:a?',
                    '-c:v',$enc.Name,'-crf',$enc.Crf,'-preset',$enc.Preset) + $extraArgs + @('-c:a','copy')
                if ($codecTag) { $ffArgs += $codecTag }
                $ffArgs += @('-movflags','+faststart',$out,'-y')
                Invoke-BurninEncode @ffArgs
            }
            { $_ -in @("emb_pgs","emb_vob") } {
                Write-Host "  Burn-in $($p.Kind) (track s:$($p.Track) embedded) + re-encode ($($enc.Name) CRF $($enc.Crf) preset $($enc.Preset))..." -ForegroundColor DarkGray
                $ffArgs = @('-v','error','-stats') + $seekArgs + @(
                    '-i',$p.Video,
                    '-filter_complex',$fcEmb,'-map','[v]','-map','0:a?',
                    '-c:v',$enc.Name,'-crf',$enc.Crf,'-preset',$enc.Preset) + $extraArgs + @('-c:a','copy')
                if ($codecTag) { $ffArgs += $codecTag }
                $ffArgs += @('-movflags','+faststart',$out,'-y')
                Invoke-BurninEncode @ffArgs
            }
            default {
                Write-Host "  [EROARE] kind necunoscut: $($p.Kind)" -ForegroundColor Red
                $kindUnknown = $true
            }
        }
        if ($kindUnknown) { $failCount++; continue }
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
            Write-Host "  [OK] $out" -ForegroundColor Green; $okCount++
            # v90: re-graft grupul Eclipsa/IAMF pe output-ul complet (NU pe preview —
            # clip taiat → substream-urile nu se regrupeaza; regula trim/concat)
            if ($outSuffix -ne "preview") { Invoke-IamfPreserve -Source $p.Video -Output $out | Out-Null }
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
# FLOW 5 (v84): Designer vizual layout HUD — browser local
# Server Python stdlib (burnin_designer.py) + UI (burnin_designer.html);
# randare cu engine-ul REAL (burnin_render) → preview fidel cu encode-ul.
# Preseturile se salveaza in UserProfiles/burnin/ → apar la HUD opt "custom".
# ─────────────────────────────────────────────────────────────────────
function Invoke-DesignerFlow {
    $py3 = $null
    if (Get-Command "python3" -ErrorAction SilentlyContinue) { $py3 = "python3" }
    elseif (Get-Command "python" -ErrorAction SilentlyContinue) {
        $pyVer = & python --version 2>&1
        if ($pyVer -match "3\.") { $py3 = "python" }
    }
    if (-not $py3) {
        Write-Host "EROARE: python3 nu este instalat (necesar pentru designer)." -ForegroundColor Red
        exit 1
    }
    & $py3 -c "import matplotlib, numpy" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "EROARE: matplotlib / numpy lipsesc." -ForegroundColor Red
        Write-Host "Instaleaza cu: $py3 -m pip install matplotlib numpy pillow" -ForegroundColor Yellow
        exit 1
    }
    if (-not (Test-Path $DesignerPy)) { Write-Host "EROARE: $DesignerPy lipseste." -ForegroundColor Red; exit 1 }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  DESIGNER VIZUAL LAYOUT HUD (browser)         ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  1) Video + telemetrie reala (norm CSV)       ║"
    Write-Host "║     [implicit]                                ║"
    Write-Host "║  2) Doar video — date DEMO (doar layout)      ║"
    Write-Host "║  3) Anulare                                   ║"
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $dsMode = Read-Host "Alege 1-3 [implicit: 1]"
    if (-not $dsMode) { $dsMode = "1" }
    $vid = ""; $csv = ""
    switch ($dsMode) {
        "1" {
            $pairs = Get-PairedFiles -PairedSuffix "_norm.csv" -MetaFn { param($c) Get-BrandFromCsv $c }
            if ($pairs.Count -eq 0) {
                Write-Host ""
                Write-Host "Nu am gasit nicio pereche video + norm CSV." -ForegroundColor Yellow
                Write-Host "  (Genereaza CSV cu av_telemetry / av_extractor_gps, sau foloseste"
                Write-Host "   optiunea 2 — date DEMO, doar pentru aranjarea layoutului.)"
                exit 0
            }
            for ($i = 0; $i -lt $pairs.Count; $i++) {
                "  {0,2}) {1}" -f ($i+1), $pairs[$i].Label | Write-Host
            }
            Write-Host ""
            $dsIdx = Read-Host "Alege UN index [implicit 1]"
            if (-not $dsIdx) { $dsIdx = "1" }
            if ($dsIdx -notmatch '^\d+$') { Write-Host "Index invalid." -ForegroundColor Red; exit 1 }
            $di = [int]$dsIdx - 1
            if ($di -lt 0 -or $di -ge $pairs.Count) { Write-Host "Index in afara range." -ForegroundColor Red; exit 1 }
            $vid = $pairs[$di].Video; $csv = $pairs[$di].Aux
        }
        "2" {
            $vids = New-Object System.Collections.Generic.List[string]
            foreach ($dir in @($OutputDir, $InputDir)) {
                if (-not (Test-Path $dir)) { continue }
                Get-ChildItem -Path $dir -Recurse -Depth 1 -File -Include "*.mp4","*.mov","*.mkv","*.m4v" -ErrorAction SilentlyContinue | ForEach-Object {
                    $name = $_.BaseName
                    if ($name -like "*_hud" -or $name -like "*_telem" -or $name -like "*_subs" -or $name -like "*_preview") { return }
                    $vids.Add($_.FullName)
                }
            }
            if ($vids.Count -eq 0) { Write-Host "Niciun video gasit in $InputDir / $OutputDir."; exit 0 }
            for ($i = 0; $i -lt $vids.Count; $i++) {
                "  {0,2}) {1}" -f ($i+1), [System.IO.Path]::GetFileName($vids[$i]) | Write-Host
            }
            Write-Host ""
            $dsIdx = Read-Host "Alege UN index [implicit 1]"
            if (-not $dsIdx) { $dsIdx = "1" }
            if ($dsIdx -notmatch '^\d+$') { Write-Host "Index invalid." -ForegroundColor Red; exit 1 }
            $di = [int]$dsIdx - 1
            if ($di -lt 0 -or $di -ge $vids.Count) { Write-Host "Index in afara range." -ForegroundColor Red; exit 1 }
            $vid = $vids[$di]
            Write-Host "  (fara CSV — designerul foloseste date DEMO sintetice)"
        }
        "3" { Write-Host "Anulat."; exit 0 }
        default { Write-Host "Optiune invalida." -ForegroundColor Red; exit 1 }
    }

    $userDir = Join-Path (Join-Path $ScriptDir "UserProfiles") "burnin"
    New-Item -ItemType Directory -Force -Path $userDir | Out-Null

    Write-Host ""
    Write-Host "Pornesc designerul... (inchide-l din browser — Salveaza & Inchide — sau cu Ctrl+C aici)"
    $dsArgs = @($DesignerPy, "--video", $vid,
                "--presets-dir", $PresetsDir, "--user-presets-dir", $userDir,
                "--temp-dir", $TempBase)
    if ($csv) { $dsArgs += @("--csv", $csv) }
    & $py3 @dsArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [EROARE] designerul a iesit cu cod $LASTEXITCODE" -ForegroundColor Red
        exit 1
    }
    Write-Host ""
    Write-Host "Preseturile salvate apar in fluxul HUD la optiunea 'custom' (LAYOUT PRESET → 4)."
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
Write-Host "║  5) Designer vizual layout HUD (browser)      ║"
Write-Host "║  6) Anulare                                   ║"
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
$burninType = Read-Host "Alege 1-6 [implicit: 1]"
if (-not $burninType) { $burninType = "1" }
switch ($burninType) {
    "1" { Invoke-HudFlow }
    "2" { Invoke-SrtFlow }
    "3" { Invoke-AssFlow }
    "4" { Invoke-ImgFlow }
    "5" { Invoke-DesignerFlow }
    "6" { Write-Host "Anulat."; exit 0 }
    default { Write-Host "Optiune invalida." -ForegroundColor Red; exit 1 }
}
