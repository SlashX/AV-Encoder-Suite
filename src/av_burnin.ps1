# av_burnin.ps1 — Burn-in overlay (HUD + SRT + ASS) — PS1 mirror al av_burnin.sh
# 3 flow-uri: 1) HUD telemetrie (Python+matplotlib) 2) SRT 3) ASS
# Output: OutputVideos/<name>_hud.<ext> sau <name>_subs.<ext>

$ErrorActionPreference = "Stop"

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

function Get-PreviewMode {
    Write-Host ""
    $ans = Read-Host "Preview mode (5s clip la mid-point pentru verificare rapida) [y/N]"
    if ($ans -match '^[yY]') {
        $script:PreviewMode = $true
        Write-Host "  -> Preview activ: 5s la 50% din durata. Output: <name>_preview.<ext>" -ForegroundColor Yellow
    } else {
        $script:PreviewMode = $false
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
        "1" { return @{ Name = "libx265";    Crf = 23; Preset = "medium" } }
        "2" { return @{ Name = "libx264";    Crf = 20; Preset = "medium" } }
        "3" { return @{ Name = "libsvtav1";  Crf = 30; Preset = "6" } }
        "4" { Write-Host "Anulat."; exit 0 }
        default { return @{ Name = "libx265"; Crf = 23; Preset = "medium" } }
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
        $row2 = (Get-Content -LiteralPath $CsvPath -TotalCount 2 -ErrorAction SilentlyContinue)[1]
        if ($row2) {
            $cols = $row2.Split(",")
            if ($cols.Length -ge 18) { return $cols[17].Trim('"').Trim() }
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
    Get-PreviewMode

    $okCount = 0; $failCount = 0
    foreach ($idx in $selected) {
        $p = $pairs[$idx]
        Write-Host ""
        Write-Host "─────────────────────────────────────────────"
        Write-Host ("  -- {0}/{1}: {2}  [{3}]" -f ($idx+1), $pairs.Count, [System.IO.Path]::GetFileName($p.Video), $p.Meta) -ForegroundColor Yellow
        Write-Host "─────────────────────────────────────────────"

        $offset = 0
        if ($p.Meta -like "external_*") {
            Write-Host "  Brand sursa: $($p.Meta) — telemetria poate fi nesincronizata." -ForegroundColor Yellow
            $off = Read-Host "  Sync offset in secunde (+/-, implicit 0)"
            if ($off) { $tmp = 0.0; if ([double]::TryParse($off, [ref]$tmp)) { $offset = $tmp } }
        }

        $vidW = (& ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 $p.Video 2>$null | Select-Object -First 1)
        $vidH = (& ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 $p.Video 2>$null | Select-Object -First 1)
        $vidDur = (& ffprobe -v error -show_entries format=duration -of csv=p=0 $p.Video 2>$null | Select-Object -First 1)
        if (-not $vidW) { $vidW = 1920 }
        if (-not $vidH) { $vidH = 1080 }
        if (-not $vidDur) { $vidDur = 0 }

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
        Write-Host "  Overlay + re-encode ($($enc.Name) CRF $($enc.Crf) preset $($enc.Preset))..." -ForegroundColor DarkGray
        & ffmpeg -v error -stats `
            @seekArgs `
            -i $p.Video `
            -framerate $hudFps `
            -i (Join-Path $framesDir "frame_%06d.png") `
            -filter_complex "[0:v][1:v]overlay=0:0:shortest=0[v]" `
            -map "[v]" -map "0:a?" `
            -c:v $enc.Name -crf $enc.Crf -preset $enc.Preset `
            -c:a copy -movflags +faststart $out -y
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
            Write-Host "  [OK] $out" -ForegroundColor Green; $okCount++
        } else {
            Write-Host "  [EROARE] ffmpeg overlay esuat" -ForegroundColor Red
            Remove-Item $out -Force -ErrorAction SilentlyContinue; $failCount++
        }
        Remove-Item $framesDir -Recurse -Force -ErrorAction SilentlyContinue
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

        $srtEsc = Get-EscapedFfmpegFilterPath $p.Aux
        $vf = "subtitles='$srtEsc'"
        if ($forceStyle) { $vf = "${vf}:force_style='$forceStyle'" }

        $outSuffix = "subs"
        $seekArgs = @()
        if ($script:PreviewMode) {
            $vidDurRaw = (& ffprobe -v error -show_entries format=duration -of csv=p=0 $p.Video 2>$null | Select-Object -First 1)
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
        Write-Host "  Burn-in SRT + re-encode ($($enc.Name) CRF $($enc.Crf) preset $($enc.Preset))..." -ForegroundColor DarkGray
        & ffmpeg -v error -stats `
            @seekArgs `
            -i $p.Video `
            -vf $vf `
            -c:v $enc.Name -crf $enc.Crf -preset $enc.Preset `
            -c:a copy -movflags +faststart $out -y
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
            Write-Host "  [OK] $out" -ForegroundColor Green; $okCount++
        } else {
            Write-Host "  [EROARE] ffmpeg SRT burn-in esuat" -ForegroundColor Red
            Remove-Item $out -Force -ErrorAction SilentlyContinue; $failCount++
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

        $assEsc = Get-EscapedFfmpegFilterPath $p.Aux
        $vf = "ass='$assEsc'${extraStyle}"

        $outSuffix = "subs"
        $seekArgs = @()
        if ($script:PreviewMode) {
            $vidDurRaw = (& ffprobe -v error -show_entries format=duration -of csv=p=0 $p.Video 2>$null | Select-Object -First 1)
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
        Write-Host "  Burn-in ASS + re-encode ($($enc.Name) CRF $($enc.Crf) preset $($enc.Preset))..." -ForegroundColor DarkGray
        & ffmpeg -v error -stats `
            @seekArgs `
            -i $p.Video `
            -vf $vf `
            -c:v $enc.Name -crf $enc.Crf -preset $enc.Preset `
            -c:a copy -movflags +faststart $out -y
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
            Write-Host "  [OK] $out" -ForegroundColor Green; $okCount++
        } else {
            Write-Host "  [EROARE] ffmpeg ASS burn-in esuat" -ForegroundColor Red
            Remove-Item $out -Force -ErrorAction SilentlyContinue; $failCount++
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
                    $codec = $cols[1].Trim()
                    $lang  = if ($cols.Length -ge 3) { $cols[2].Trim() } else { "" }
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

        $outSuffix = "subs"
        $seekArgs = @()
        if ($script:PreviewMode) {
            $vidDurRaw = (& ffprobe -v error -show_entries format=duration -of csv=p=0 $p.Video 2>$null | Select-Object -First 1)
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
        switch ($p.Kind) {
            { $_ -in @("ext_pgs","ext_vob") } {
                Write-Host "  Burn-in $($p.Kind) (sursa: $($p.Aux)) + re-encode ($($enc.Name) CRF $($enc.Crf) preset $($enc.Preset))..." -ForegroundColor DarkGray
                & ffmpeg -v error -stats `
                    @seekArgs `
                    -i $p.Video `
                    -i $p.Aux `
                    -filter_complex "[0:v][1:s]overlay[v]" `
                    -map "[v]" -map "0:a?" `
                    -c:v $enc.Name -crf $enc.Crf -preset $enc.Preset `
                    -c:a copy -movflags +faststart $out -y
            }
            { $_ -in @("emb_pgs","emb_vob") } {
                Write-Host "  Burn-in $($p.Kind) (track s:$($p.Track) embedded) + re-encode ($($enc.Name) CRF $($enc.Crf) preset $($enc.Preset))..." -ForegroundColor DarkGray
                & ffmpeg -v error -stats `
                    @seekArgs `
                    -i $p.Video `
                    -filter_complex "[0:v][0:s:$($p.Track)]overlay[v]" `
                    -map "[v]" -map "0:a?" `
                    -c:v $enc.Name -crf $enc.Crf -preset $enc.Preset `
                    -c:a copy -movflags +faststart $out -y
            }
            default {
                Write-Host "  [EROARE] kind necunoscut: $($p.Kind)" -ForegroundColor Red
                $failCount++; continue
            }
        }
        if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
            Write-Host "  [OK] $out" -ForegroundColor Green; $okCount++
        } else {
            Write-Host "  [EROARE] ffmpeg image subs burn-in esuat" -ForegroundColor Red
            Remove-Item $out -Force -ErrorAction SilentlyContinue; $failCount++
        }
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════"
    Write-Host ("  Sumar Image subs burn-in: {0} OK, {1} esuate (din {2} selectate)" -f $okCount, $failCount, $selected.Count) -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════"
}

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
