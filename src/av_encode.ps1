# ══════════════════════════════════════════════════════════════════════
# av_encode.ps1 — AV Encoder Suite (Windows/PowerShell)
# Rulare: powershell -ExecutionPolicy Bypass -File av_encode.ps1
# ══════════════════════════════════════════════════════════════════════

# ── Verificare ffmpeg/ffprobe ────────────────────────────────────────
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "[EROARE] ffmpeg nu a fost gasit." -ForegroundColor Red
    Write-Host "Instaleaza ffmpeg si adauga-l in PATH."
    Write-Host "Download: https://ffmpeg.org/download.html"
    Read-Host; exit
}
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "[EROARE] ffprobe nu a fost gasit." -ForegroundColor Red
    Read-Host; exit
}

$InputDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutputDir = Join-Path $InputDir "output"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# ── Functii utilitare ─────────────────────────────────────────────────
function Format-Bytes {
    param([long]$b)
    if ($b -ge 1GB) { "{0:F2} GB" -f ($b/1GB) }
    elseif ($b -ge 1MB) { "{0:F1} MB" -f ($b/1MB) }
    else { "{0} KB" -f ($b/1KB) }
}

function Get-FFprobeValue {
    param([string]$file, [string]$stream, [string]$entry)
    ($( & ffprobe -v error -select_streams $stream `
        -show_entries "stream=$entry" -of csv=p=0 "$file" 2>$null) -join "").Trim()
}

function Test-BitrateFormat { param([string]$br); $br -match '^\d+[kKmM]$' }

function Convert-ToKbps {
    param([string]$br)
    $n = $br -replace '[kKmM]',''
    if ($br -match '[mM]$') { [int]$n * 1000 } else { [int]$n }
}

function Get-ContainerFlags {
    param([string]$c)
    if ($c -in @("mkv","mxf","webm")) { @() } else { @("-movflags","+faststart") }
}

# FIX: PGS/DVDSUB incompatibile cu mp4/mov — returneaza -sn (omite) nu -c:s mov_text
function Get-SubtitleCodec {
    param([string]$file, [string]$container)
    if ($container -eq "mkv") { return @("-c:s","copy") }
    if ($container -eq "webm") { return @("-sn") }
    $subCodecs = & ffprobe -v error -select_streams s `
        -show_entries stream=codec_name `
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>$null
    if ($subCodecs -match "hdmv_pgs|dvd_subtitle|dvb_subtitle") {
        Write-Host "  ATENTIE: Subtitrari PGS/DVDSUB incompatibile cu $container — omise" -ForegroundColor Yellow
        return @("-sn")
    }
    return @("-c:s","mov_text")
}

# FIX: Get-SourceInfo foloseste -show_entries frame_side_data=type
# pentru a limita output-ul enorm al show_frames la campul relevant
function Get-SourceInfo {
    param([string]$file)
    $codec    = Get-FFprobeValue $file "v:0" "codec_name"
    $pixFmt   = Get-FFprobeValue $file "v:0" "pix_fmt"
    $transfer = Get-FFprobeValue $file "v:0" "color_transfer"
    # FIX: -show_entries frame_side_data=type — evita sute KB output per fisier HDR
    $hdrPlus  = & ffprobe -v error -show_frames -select_streams v:0 `
        -read_intervals "%+#5" `
        -show_entries frame_side_data=type `
        "$file" 2>$null | Select-String "HDR10+"
    $is10bit  = $pixFmt -match "10"
    $isHDRPlus = [bool]$hdrPlus
    $isHDR    = $transfer -eq "smpte2084" -or $isHDRPlus
    $fmt = switch ($codec) {
        "h264" { if ($is10bit) { "H.264 10bit" } else { "H.264 8bit" } }
        "hevc" {
            if     ($isHDRPlus) { "H.265 HEVC HDR10+" }
            elseif ($isHDR)     { "H.265 HEVC HDR10"  }
            elseif ($is10bit)   { "H.265 HEVC 10bit SDR" }
            else                { "H.265 HEVC 8bit SDR"  }
        }
        "av1" {
            if     ($isHDRPlus) { "AV1 HDR10+"    }
            elseif ($isHDR)     { "AV1 HDR10"     }
            elseif ($is10bit)   { "AV1 10bit SDR" }
            else                { "AV1 8bit SDR"  }
        }
        default { if ($is10bit) { "$codec 10bit" } else { "$codec 8bit" } }
    }
    return @{
        fmt      = $fmt
        codec    = $codec
        pixFmt   = $pixFmt
        is10bit  = $is10bit
        isHDR    = $isHDR
        isHDRPlus= $isHDRPlus
        transfer = $transfer
    }
}

function Get-DVProfile {
    param([string]$file)
    $fd = & ffprobe -v error -show_frames -select_streams v:0 `
        -read_intervals "%+#5" `
        -show_entries frame_side_data=dv_profile,dv_bl_signal_compatibility_id `
        -of default "$file" 2>$null
    $n = ($fd | Where-Object { $_ -match "^dv_profile=(\d+)" } | Select-Object -First 1) `
        -replace "dv_profile=",""
    $c = ($fd | Where-Object { $_ -match "^dv_bl_signal_compatibility_id=(\d+)" } | Select-Object -First 1) `
        -replace "dv_bl_signal_compatibility_id=",""
    if ($n -match '^\d+$') {
        switch ($n) {
            "4" { "Profil 4 (DV+HDR10 fallback)" }
            "5" { "Profil 5 (DV only)" }
            "7" { "Profil 7 (DV+HDR10+)" }
            "8" {
                switch ($c) {
                    "1" { "Profil 8.1 (DV+HDR10, Blu-ray)" }
                    "2" { "Profil 8.2 (DV+SDR)" }
                    "4" { "Profil 8.4 (DV+HLG)" }
                    default { "Profil 8 (DV+HDR10)" }
                }
            }
            "9" { "Profil 9 (DV+SDR)" }
            default { "Profil $n" }
        }
    } else { "Dolby Vision (profil nedetectat)" }
}

# FIX: Get-DJITracks — HAS_TC detectat din codec_tag_string/codec_name (nu codec_type)
function Get-DJITracks {
    param([string]$file)
    # Un singur apel ffprobe cu toate campurile relevante
    $allTracks = & ffprobe -v error `
        -show_entries stream=index,codec_tag_string,codec_name,codec_type `
        -of default=noprint_wrappers=1 "$file" 2>$null
    $hasDjmd  = [bool]($allTracks | Where-Object { $_ -imatch "djmd" })
    $hasDbgi  = [bool]($allTracks | Where-Object { $_ -imatch "dbgi" })
    # tmcd apare in codec_name sau codec_tag_string, NU in codec_type (care e "data")
    $hasTC    = [bool]($allTracks | Where-Object { $_ -imatch "tmcd" })
    $hasCover = [bool]($allTracks | Where-Object { $_ -imatch "mjpeg|jpeg" })
    return @{
        hasDjmd = $hasDjmd
        hasDbgi = $hasDbgi
        hasTC   = $hasTC
        hasCover= $hasCover
        isDji   = ($hasDjmd -or $hasDbgi)
    }
}

function Get-DJIMapFlags {
    param([string]$file, [bool]$keepDbgi, $djiInfo, [string]$cont)
    if (-not $djiInfo.isDji) {
        return @("-map","0:v","-map","0:a","-map","0:s?","-map","0:t?",
                 "-map_metadata","0","-map_chapters","0")
    }
    # DJI: -map 0:v:0 (doar primul video) — cover JPEG NU se mapeaza
    # djmd/dbgi: doar in mkv (codec 'none' incompatibil cu mp4/mov)
    $maps = [System.Collections.Generic.List[string]]@(
        "-map","0:v:0","-map","0:a","-map","0:s?","-map","0:t?")
    $idx = 0
    # csv=p=0 cu un singur camp = exact o linie per stream = indexare corecta
    $tags = & ffprobe -v error -show_entries stream=codec_tag_string `
        -of csv=p=0 "$file" 2>$null
    foreach ($tag in $tags) {
        if     ($tag -imatch "djmd" -and $cont -eq "mkv")                     { $maps.AddRange([string[]]@("-map","0:$idx")) }
        elseif ($tag -imatch "djmd" -and $cont -ne "mkv")                     { Write-Host "  NOTA: djmd (GPS) omis — incompatibil cu $cont (doar mkv)" -ForegroundColor Yellow }
        elseif ($tag -imatch "dbgi" -and $keepDbgi -and $cont -eq "mkv")      { $maps.AddRange([string[]]@("-map","0:$idx")) }
        elseif ($tag -imatch "dbgi" -and $keepDbgi -and $cont -ne "mkv")      { Write-Host "  NOTA: dbgi (debug) omis — incompatibil cu $cont (doar mkv)" -ForegroundColor Yellow }
        elseif ($tag -imatch "tmcd")                                          { $maps.AddRange([string[]]@("-map","0:$idx")) }
        $idx++
    }
    $maps.AddRange([string[]]@("-map_metadata","0","-map_chapters","0"))
    return $maps.ToArray()
}

# ══════════════════════════════════════════════════════════════════════
# v32: Functii noi portate din bash — LOG detect, dialogs, helpers
# ══════════════════════════════════════════════════════════════════════

# ── Get-SourceInfoExtended — extinde Get-SourceInfo cu LOG detect, VFR ──
function Get-SourceInfoExtended {
    param([string]$file, [hashtable]$djiInfo)
    $logProfile  = ""
    $cameraMake  = ""
    $srcColorTrc = ""
    $srcIsVfr    = $false

    if ($script:forceLogDetection) {
        $logProfile = "forced_log"
        $cameraMake = "unknown"
    } else {
        # Detect camera make from format tags
        $allTags = & ffprobe -v error -show_entries format_tags `
            -of default=noprint_wrappers=1 "$file" 2>$null | Out-String
        if     ($allTags -imatch "make=.*apple")                        { $cameraMake = "apple" }
        elseif ($allTags -imatch "make=.*dji")                          { $cameraMake = "dji" }
        elseif ($allTags -imatch "manufacturer=.*samsung|make=.*samsung") { $cameraMake = "samsung" }
        # Fallback: DJI tracks
        if (-not $cameraMake -and $djiInfo -and $djiInfo.isDji) { $cameraMake = "dji" }

        # Detect color transfer
        $srcColorTrc = Get-FFprobeValue $file "v:0" "color_transfer"

        # Detect bit depth
        $srcBps = Get-FFprobeValue $file "v:0" "bits_per_raw_sample"
        if (-not $srcBps -or $srcBps -eq "0" -or $srcBps -notmatch '^\d+$') { $srcBps = "8" }
        $srcBps = [int]$srcBps

        # Detect color primaries
        $srcPrimaries = Get-FFprobeValue $file "v:0" "color_primaries"

        # Samsung Log mode tag
        $samsungLogTag = if ($allTags -imatch "log_mode|samsung.*log") { $true } else { $false }

        # HDR10+ and transfer from Get-SourceInfo (already called, reuse $si)
        $transfer = Get-FFprobeValue $file "v:0" "color_transfer"
        $hdrPlus = & ffprobe -v error -show_frames -select_streams v:0 `
            -read_intervals "%+#5" -show_entries frame_side_data=type `
            "$file" 2>$null | Select-String "HDR10+"
        $isHdrPlus = [bool]$hdrPlus
        $isHdr = ($transfer -eq "smpte2084") -or $isHdrPlus
        $dovi = & ffprobe -v error -show_entries stream=codec_tag_string `
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>$null |
            Select-String -Pattern "dovi|dvhe|dvh1" -CaseSensitive:$false

        # LOG profile identification
        if ($cameraMake -eq "apple") {
            if ($srcBps -ge 10 -and ($srcPrimaries -match "bt2020" -or $srcColorTrc -match "arib|log")) {
                $logProfile = "apple_log"
            }
        } elseif ($cameraMake -eq "samsung") {
            if ($samsungLogTag -or ($srcBps -ge 10 -and $srcPrimaries -match "bt2020")) {
                # Samsung HDR10+ is NOT Log
                if (-not $isHdrPlus -and $transfer -ne "smpte2084") {
                    $logProfile = "samsung_log"
                }
            }
        } elseif ($cameraMake -eq "dji") {
            if ($srcBps -ge 10 -and $srcPrimaries -match "bt2020") {
                $logProfile = "dlog_m"
            }
        } elseif ($srcBps -ge 10 -and $srcPrimaries -match "bt2020" `
                -and -not $isHdrPlus -and $transfer -ne "smpte2084" -and -not $dovi) {
            if ($srcColorTrc -eq "unknown" -or $srcColorTrc -match "log|arib") {
                $logProfile = "unknown_log"
                $cameraMake = "unknown"
            }
        }
    }

    # VFR detection (useful for Log sources from phones)
    if ($logProfile) {
        $avgFps = Get-FFprobeValue $file "v:0" "avg_frame_rate"
        $rFps   = Get-FFprobeValue $file "v:0" "r_frame_rate"
        if ($avgFps -match '(\d+)/(\d+)' ) { $avgDec = [double]$Matches[1] / [double]$Matches[2] } else { $avgDec = 0 }
        if ($rFps   -match '(\d+)/(\d+)' ) { $rDec   = [double]$Matches[1] / [double]$Matches[2] } else { $rDec   = 0 }
        if ($avgDec -gt 0 -and $rDec -gt 0 -and [math]::Abs($rDec - $avgDec) -gt 0.5) {
            $srcIsVfr = $true
        }
    }

    return @{
        logProfile  = $logProfile
        cameraMake  = $cameraMake
        srcColorTrc = $srcColorTrc
        srcIsVfr    = $srcIsVfr
    }
}

# ── Get-LogProfileLabel — human-readable LOG label ──────────────────
function Get-LogProfileLabel {
    param([string]$profile)
    switch ($profile) {
        "apple_log"   { "Apple Log (iPhone)" }
        "samsung_log" { "Samsung Log (S24 Ultra)" }
        "dlog_m"      { "D-Log M (DJI)" }
        "forced_log"  { "LOG (fortat manual)" }
        "unknown_log" { "LOG (brand necunoscut)" }
        default       { "LOG" }
    }
}

# ── Find-LutForBrand — cauta fisiere .cube cu prefix per brand ──────
function Find-LutForBrand {
    param([string]$brand, [string]$inputDir, [string]$scriptDir)
    $prefix = switch ($brand) {
        "apple"   { "apple_log_" }
        "samsung" { "samsung_log_" }
        "dji"     { "dji_dlog_m_" }
        default   { "" }
    }
    # Single location: $InputDir/Luts/ (case-insensitive on Windows)
    $lutsDir = Join-Path $inputDir "Luts"
    if (-not (Test-Path $lutsDir)) { return @{ files = @(); dir = "" } }

    $found = @()
    if ($prefix) {
        $found = @(Get-ChildItem -Path $lutsDir -Filter "${prefix}*.cube" -ErrorAction SilentlyContinue)
    }
    if ($found.Count -eq 0 -and ($brand -eq "unknown" -or -not $brand)) {
        $found = @(Get-ChildItem -Path $lutsDir -Filter "*.cube" -ErrorAction SilentlyContinue)
    }
    if ($found.Count -gt 0) {
        return @{ files = $found; dir = $lutsDir }
    }
    return @{ files = @(); dir = "" }
}

# ── Find-CreativeLuts — cauta LUT-uri creative in luts/creative/ ────
function Find-CreativeLuts {
    param([string]$inputDir, [string]$scriptDir)
    # Single location: $InputDir/Luts/Creative/
    $creativeDir = Join-Path $inputDir "Luts" "Creative"
    if (-not (Test-Path $creativeDir)) { return @{ files = @(); dir = "" } }
    $found = @(Get-ChildItem -Path $creativeDir -Filter "*.cube" -ErrorAction SilentlyContinue)
    if ($found.Count -gt 0) {
        return @{ files = $found; dir = $creativeDir }
    }
    return @{ files = @(); dir = "" }
}

# ── Invoke-StreamCopy — helper partajat stream copy cu progress+stats ──
function Invoke-StreamCopy {
    param(
        [System.IO.FileInfo]$fileInfo,
        [string]$outFile,
        [string[]]$mapFlags,
        [string]$container,
        [string]$logFile,
        [string[]]$audioParams = @("-c:a","copy")
    )
    $scProgFile = Join-Path $env:TEMP ("ffprog_"+[guid]::NewGuid().ToString("N")+".txt")
    $scStart = Get-Date
    $durRaw = & ffprobe -v error -show_entries format=duration `
        -of default=noprint_wrappers=1:nokey=1 $fileInfo.FullName 2>$null
    $durSec = if ($durRaw -match '^\d+') { [int]([double]$durRaw) } else { 0 }
    $scContFlags = if ($container -in @("mkv","mxf","webm")) { @() } else { @("-movflags","+faststart") }

    $scSubCodec = Get-SubtitleCodec $fileInfo.FullName $container

    $scArgs = @("-threads","0","-i",$fileInfo.FullName) + $mapFlags +
              @("-c:v","copy") + $audioParams + $scSubCodec + @("-c:t","copy") +
              $scContFlags + @("-progress",$scProgFile,"-nostats",$outFile)
    $scProc = Start-Process ffmpeg -ArgumentList $scArgs -NoNewWindow -PassThru `
        -RedirectStandardError "$env:TEMP\fferr.txt"
    Show-Progress $scProc $scProgFile $durSec $scStart; $scProc.WaitForExit()
    if ($scProc.ExitCode -ne 0) { return $false }

    # Stats
    $newSize = (Get-Item $outFile).Length
    $saved = [math]::Max(0, $fileInfo.Length - $newSize)
    $scTime = [int](Get-Date).Subtract($scStart).TotalSeconds
    $script:totalSaved += $saved
    $script:totalDone++
    $script:batchNames  += $fileInfo.Name
    $script:batchTimes  += $scTime
    $script:batchOrig   += $fileInfo.Length
    $script:batchNew    += $newSize
    $ratio = if ($fileInfo.Length -gt 0) { [math]::Round($newSize * 100.0 / $fileInfo.Length, 1) } else { "N/A" }
    $script:batchRatios += $ratio
    Write-Host "  Stream copy OK | Original: $(Format-Bytes $fileInfo.Length) | Rezultat: $(Format-Bytes $newSize) | Economisit: $(Format-Bytes $saved)" -ForegroundColor Green
    # Mark done for resume (atomic: write temp → rename)
    $bpTemp2 = "${script:batchProgressFile}.tmp"
    if (Test-Path $script:batchProgressFile) { Copy-Item $script:batchProgressFile $bpTemp2 -Force }
    $fileInfo.Name | Out-File $bpTemp2 -Append -Encoding UTF8
    Move-Item -Force $bpTemp2 $script:batchProgressFile
    "  Original: $(Format-Bytes $fileInfo.Length) | Rezultat: $(Format-Bytes $newSize) | Economisit: $(Format-Bytes $saved) | Timp: ${scTime}s" | Out-File $logFile -Append -Encoding UTF8
    return $true
}

# ── Test-EncoderAvailable — runtime check encoder ──────────────────
function Test-EncoderAvailable {
    param([string]$encoderName)
    $encoders = & ffmpeg -encoders 2>$null | Out-String
    return [bool]($encoders -match $encoderName)
}

# ── Show-Hdr10PlusDialog — HDR10+ dialog per fisier ────────────────
# Return: "static" | "preserve" | "copy" | "triple" | "skip"
function Show-Hdr10PlusDialog {
    param([string]$file)
    $hdr10plusToolAvail = [bool](Get-Command "hdr10plus_tool" -ErrorAction SilentlyContinue)
    $doviToolAvail      = [bool](Get-Command "dovi_tool" -ErrorAction SilentlyContinue)

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "  ║  HDR10+ DETECTAT                              ║" -ForegroundColor Magenta
    Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Magenta

    if ($hdr10plusToolAvail) {
        Write-Host "  ║  1) Re-encode HDR10 static (pierde +)        ║" -ForegroundColor White
        Write-Host "  ║  2) Re-encode HDR10+ (pastreaza metadata)    ║" -ForegroundColor White
        Write-Host "  ║     → extrage JSON via hdr10plus_tool        ║" -ForegroundColor DarkGray
        Write-Host "  ║  3) Stream copy video (pastreaza tot, rapid) ║" -ForegroundColor White
        $maxOpt = 3
        if ($doviToolAvail) {
            Write-Host "  ║  4) Triple-layer DV+HDR10+HDR10+             ║" -ForegroundColor White
            Write-Host "  ║     → DV Profile 8.1 + HDR10 + HDR10+       ║" -ForegroundColor DarkGray
            $maxOpt = 4
        }
        Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Magenta
        $ch = Read-Host "  Alege 1-$maxOpt [implicit: 2]"
        if (-not $ch) { $ch = "2" }
        switch ($ch) {
            "1" { return "static" }
            "3" { return "copy" }
            "4" { if ($doviToolAvail) { return "triple" } else { return "preserve" } }
            default { return "preserve" }
        }
    } else {
        Write-Host "  ║  hdr10plus_tool NU este instalat.            ║" -ForegroundColor Yellow
        Write-Host "  ║  Fara el, metadata dinamica se pierde.       ║" -ForegroundColor Yellow
        Write-Host "  ║  Instaleaza cu: .\hdr10plus_parser.ps1       ║" -ForegroundColor DarkGray
        Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Magenta
        Write-Host "  ║  1) Re-encode HDR10 static (pierde +)        ║" -ForegroundColor White
        Write-Host "  ║  2) Stream copy video (pastreaza tot, rapid) ║" -ForegroundColor White
        Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Magenta
        $ch = Read-Host "  Alege 1 sau 2 [implicit: 1]"
        switch ($ch) {
            "2" { return "copy" }
            default { return "static" }
        }
    }
}

# ── Extract-Hdr10PlusMetadata — extrage metadata HDR10+ in JSON ────
function Extract-Hdr10PlusMetadata {
    param([string]$file)
    $jsonFile = Join-Path $env:TEMP ("hdr10plus_"+[guid]::NewGuid().ToString("N")+".json")
    Write-Host "  HDR10+: Extrag metadata dinamica..." -ForegroundColor Cyan
    $srcCodec = Get-FFprobeValue $file "v:0" "codec_name"
    if ($srcCodec -eq "av1") {
        & ffmpeg -v error -i "$file" -c:v copy -f ivf - 2>$null |
            & hdr10plus_tool extract -i - -o "$jsonFile" 2>$null
    } else {
        & ffmpeg -v error -i "$file" -c:v copy -bsf:v hevc_mp4toannexb -f hevc - 2>$null |
            & hdr10plus_tool extract -i - -o "$jsonFile" 2>$null
    }
    if ($LASTEXITCODE -eq 0 -and (Test-Path $jsonFile) -and (Get-Item $jsonFile).Length -gt 0) {
        $count = (Select-String -Path $jsonFile -Pattern "BezierCurveData|TargetedSystemDisplay" -AllMatches).Matches.Count
        Write-Host "  HDR10+: Metadata extrasa ($count scene descriptors)" -ForegroundColor Green
        return $jsonFile
    } else {
        Write-Host "  HDR10+: Extractie esuata — fallback la HDR10 static" -ForegroundColor Yellow
        Remove-Item $jsonFile -Force -ErrorAction SilentlyContinue
        return ""
    }
}

# ── Generate-DvRpuFromHdr10Plus — genereaza DV RPU din HDR10+ JSON ──
function Generate-DvRpuFromHdr10Plus {
    param([string]$hdr10plusJson)
    $rpuFile = Join-Path $env:TEMP ("dv_rpu_"+[guid]::NewGuid().ToString("N")+".bin")
    $configFile = Join-Path $env:TEMP ("dv_config_"+[guid]::NewGuid().ToString("N")+".json")
    @'
{
    "cm_version": "V40",
    "length": 1,
    "level5": {
        "active_area_left_offset": 0,
        "active_area_right_offset": 0,
        "active_area_top_offset": 0,
        "active_area_bottom_offset": 0
    },
    "level6": {
        "max_display_mastering_luminance": 1000,
        "min_display_mastering_luminance": 1,
        "max_content_light_level": 1000,
        "max_frame_average_light_level": 400
    }
}
'@ | Out-File $configFile -Encoding ASCII
    Write-Host "  DV: Generez RPU din HDR10+ metadata..." -ForegroundColor Cyan
    & dovi_tool generate -j "$configFile" --hdr10plus-json "$hdr10plusJson" -o "$rpuFile" 2>$null
    Remove-Item $configFile -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -eq 0 -and (Test-Path $rpuFile) -and (Get-Item $rpuFile).Length -gt 0) {
        Write-Host "  DV: RPU generat cu succes (Profile 8.1)" -ForegroundColor Green
        return $rpuFile
    } else {
        Write-Host "  DV: Generare RPU esuata" -ForegroundColor Yellow
        Remove-Item $rpuFile -Force -ErrorAction SilentlyContinue
        return ""
    }
}

# ── Inject-DvRpu — injecteaza DV RPU in HEVC stream ────────────────
function Inject-DvRpu {
    param([string]$hevcFile, [string]$rpuFile, [string]$outputFile)
    Write-Host "  DV: Injectez RPU in HEVC bitstream..." -ForegroundColor Cyan
    & dovi_tool inject-rpu -i "$hevcFile" --rpu-in "$rpuFile" -o "$outputFile" 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $outputFile) -and (Get-Item $outputFile).Length -gt 0) {
        Write-Host "  DV: Injectare RPU reusita" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  DV: Injectare RPU esuata" -ForegroundColor Yellow
        return $false
    }
}

# ── Show-SourceDialog — ANALIZA SURSA HDR10/SDR per fisier ──────────
# Return: "hdr10" | "sdr_tonemap" | "sdr" | "copy" | "skip"
function Show-SourceDialog {
    param([string]$file, [string]$filename, [hashtable]$sourceInfo)
    $srcPixfmt = Get-FFprobeValue $file "v:0" "pix_fmt"
    $srcBitdepth = if ($srcPixfmt -match "10") { "10-bit" } else { "8-bit" }
    $w = Get-FFprobeValue $file "v:0" "width"
    $h = Get-FFprobeValue $file "v:0" "height"
    $isHdr10 = ($sourceInfo.transfer -eq "smpte2084")

    $srcLabel = if ($isHdr10) { "HDR10 $srcBitdepth" } else { "SDR $srcBitdepth" }

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  ANALIZA SURSA                               ║" -ForegroundColor Cyan
    Write-Host ("  ║  Fisier: {0,-37}║" -f $filename) -ForegroundColor White
    Write-Host ("  ║  Sursa : {0,-25} {1}║" -f "$srcLabel |" , "${w}x${h}   ") -ForegroundColor White
    Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Cyan

    if ($isHdr10) {
        Write-Host "  ║  1) Encodeaza HDR10 10-bit                   ║" -ForegroundColor White
        Write-Host "  ║  2) Encodeaza SDR 10-bit (tonemap Rec.709)   ║" -ForegroundColor White
        Write-Host "  ║  3) Stream copy video                        ║" -ForegroundColor White
        Write-Host "  ║  4) Sari acest fisier                        ║" -ForegroundColor White
        Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
        $ch = Read-Host "  Alege 1-4 [implicit: 1]"
        switch ($ch) {
            "2" { Write-Host "  Ales: SDR 10-bit (tonemap din HDR10)" -ForegroundColor Green; return "sdr_tonemap" }
            "3" { Write-Host "  Ales: Stream copy video" -ForegroundColor Green; return "copy" }
            "4" { Write-Host "  Sarit de utilizator" -ForegroundColor DarkYellow; return "skip" }
            default { Write-Host "  Ales: HDR10 10-bit" -ForegroundColor Green; return "hdr10" }
        }
    } else {
        Write-Host "  ║  1) Encodeaza 10-bit SDR                     ║" -ForegroundColor White
        Write-Host "  ║  2) Stream copy video                        ║" -ForegroundColor White
        Write-Host "  ║  3) Sari acest fisier                        ║" -ForegroundColor White
        Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
        $ch = Read-Host "  Alege 1-3 [implicit: 1]"
        switch ($ch) {
            "2" { Write-Host "  Ales: Stream copy video" -ForegroundColor Green; return "copy" }
            "3" { Write-Host "  Sarit de utilizator" -ForegroundColor DarkYellow; return "skip" }
            default { Write-Host "  Ales: 10-bit SDR" -ForegroundColor Green; return "sdr" }
        }
    }
}

# ── Show-LogDialog — LOG format video dialog per fisier ─────────────
# Return: "lut" | "sdr" | "hdr10" | "preserve" | "copy" | "skip"
# Seteaza script-scope: $script:logVideoFilter, $script:logColorFlags,
#                       $script:logPixFmt, $script:logExtraX265, $script:selectedLutPath
function Show-LogDialog {
    param([string]$file, [string]$filename, [string]$encoderType,
          [string]$logProfile, [string]$cameraMake, [bool]$srcIsVfr)

    $script:logVideoFilter = ""
    $script:logColorFlags  = @()
    $script:logPixFmt      = ""
    $script:logExtraX265   = ""
    $script:selectedLutPath = ""

    $profileLabel = Get-LogProfileLabel $logProfile
    $lutResult = Find-LutForBrand $cameraMake $InputDir $InputDir
    $hasLut = ($lutResult.files.Count -gt 0)
    $creativeLutResult = Find-CreativeLuts $InputDir $InputDir
    $hasCreativeLut = ($creativeLutResult.files.Count -gt 0)

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host ("  ║  LOG DETECTAT: {0,-31}║" -f $profileLabel) -ForegroundColor Yellow
    Write-Host ("  ║  Fisier: {0,-37}║" -f $filename) -ForegroundColor White
    Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Yellow

    # VFR warning
    if ($srcIsVfr) {
        Write-Host "  ║  ⚠ Sursa este VFR (Variable Frame Rate)     ║" -ForegroundColor Red
        Write-Host "  ║    Audio sync poate fi afectat.              ║" -ForegroundColor Yellow
        Write-Host "  ║    Recomandat: seteaza FPS fix din meniu.    ║" -ForegroundColor Yellow
        Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Yellow
    }

    $optNum = 1
    $optLut = 0; $optSdr = 0; $optHdr = 0; $optPreserve = 0; $optCopy = 0; $optSkip = 0

    if ($encoderType -eq "x264") {
        # x264: no HDR10 option
        if ($hasLut) {
            $optLut = $optNum
            if ($lutResult.files.Count -eq 1) {
                Write-Host ("  ║  {0}) Apply LUT → 8-bit SDR Rec.709           ║" -f $optNum) -ForegroundColor White
                Write-Host ("  ║     [✓ {0,-38}]║" -f $lutResult.files[0].Name) -ForegroundColor DarkGray
            } else {
                Write-Host ("  ║  {0}) Apply LUT → 8-bit SDR Rec.709           ║" -f $optNum) -ForegroundColor White
                Write-Host ("  ║     [{0} LUT-uri gasite — selectie]           ║" -f $lutResult.files.Count) -ForegroundColor DarkGray
            }
            $optNum++
        }
        $optSdr = $optNum
        Write-Host ("  ║  {0}) Convert SDR (fara LUT) → 8-bit Rec.709  ║" -f $optNum) -ForegroundColor White
        Write-Host "  ║     (best-effort — LUT recomandat)           ║" -ForegroundColor DarkGray
        $optNum++
        $optPreserve = $optNum
        Write-Host ("  ║  {0}) Preserve Log (compresie 8-bit)           ║" -f $optNum) -ForegroundColor White
        Write-Host "  ║     ⚠ 8-bit Log pierde gradatii — x265 rec.  ║" -ForegroundColor Yellow
        $optNum++
        $optCreative = 0
        if ($hasCreativeLut) {
            $optCreative = $optNum
            Write-Host ("  ║  {0}) Creative LUT (look artistic)             ║" -f $optNum) -ForegroundColor White
            Write-Host ("  ║     [{0} creative LUT-uri gasite]              ║" -f $creativeLutResult.files.Count) -ForegroundColor DarkGray
            $optNum++
        }
        $optCopy = $optNum
        Write-Host ("  ║  {0}) Stream copy video                        ║" -f $optNum) -ForegroundColor White
        $optNum++
        $optSkip = $optNum
        Write-Host ("  ║  {0}) Sari acest fisier                        ║" -f $optNum) -ForegroundColor White
    } else {
        # x265 / AV1: full menu with HDR10 option
        if ($hasLut) {
            $optLut = $optNum
            if ($lutResult.files.Count -eq 1) {
                Write-Host ("  ║  {0}) Apply LUT → 10-bit SDR Rec.709          ║" -f $optNum) -ForegroundColor White
                Write-Host ("  ║     [✓ {0,-38}]║" -f $lutResult.files[0].Name) -ForegroundColor DarkGray
            } else {
                Write-Host ("  ║  {0}) Apply LUT → 10-bit SDR Rec.709          ║" -f $optNum) -ForegroundColor White
                Write-Host ("  ║     [{0} LUT-uri gasite — selectie]            ║" -f $lutResult.files.Count) -ForegroundColor DarkGray
            }
            $optNum++
        }
        $optSdr = $optNum
        Write-Host ("  ║  {0}) Convert SDR (fara LUT) → 10-bit Rec.709 ║" -f $optNum) -ForegroundColor White
        Write-Host "  ║     (best-effort — LUT recomandat)           ║" -ForegroundColor DarkGray
        $optNum++
        $optHdr = $optNum
        Write-Host ("  ║  {0}) Convert HDR10 (fara LUT) → 10-bit       ║" -f $optNum) -ForegroundColor White
        Write-Host "  ║     BT.2020 / PQ (HDR10 static)              ║" -ForegroundColor DarkGray
        $optNum++
        $optPreserve = $optNum
        Write-Host ("  ║  {0}) Preserve Log (compresie, pastreaza prof) ║" -f $optNum) -ForegroundColor White
        $optNum++
        $optCreative = 0
        if ($hasCreativeLut) {
            $optCreative = $optNum
            Write-Host ("  ║  {0}) Creative LUT (look artistic)             ║" -f $optNum) -ForegroundColor White
            Write-Host ("  ║     [{0} creative LUT-uri gasite]              ║" -f $creativeLutResult.files.Count) -ForegroundColor DarkGray
            $optNum++
        }
        $optCopy = $optNum
        Write-Host ("  ║  {0}) Stream copy video                        ║" -f $optNum) -ForegroundColor White
        $optNum++
        $optSkip = $optNum
        Write-Host ("  ║  {0}) Sari acest fisier                        ║" -f $optNum) -ForegroundColor White
    }
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Yellow

    $maxOpt = $optSkip
    $defaultOpt = $optSdr
    if ($hasLut) { $defaultOpt = $optLut }
    $logChoice = Read-Host "  Alege 1-$maxOpt [implicit: $defaultOpt]"
    if (-not $logChoice) { $logChoice = $defaultOpt }
    $logChoice = [int]$logChoice

    # Process choice
    if ($logChoice -eq $optLut -and $optLut -gt 0) {
        # Apply LUT
        $selectedLut = $null
        if ($lutResult.files.Count -eq 1) {
            $selectedLut = $lutResult.files[0].FullName
        } else {
            Write-Host ""
            Write-Host "  LUT-uri disponibile:" -ForegroundColor Cyan
            for ($li = 0; $li -lt $lutResult.files.Count; $li++) {
                Write-Host "  $($li+1)) $($lutResult.files[$li].Name)" -ForegroundColor White
            }
            $lutSel = Read-Host "  Alege LUT [implicit: 1]"
            if (-not $lutSel) { $lutSel = "1" }
            if ($lutSel -match '^\d+$' -and [int]$lutSel -ge 1 -and [int]$lutSel -le $lutResult.files.Count) {
                $selectedLut = $lutResult.files[[int]$lutSel - 1].FullName
            } else {
                $selectedLut = $lutResult.files[0].FullName
            }
        }
        Write-Host "  LOG: Apply LUT — $(Split-Path -Leaf $selectedLut)" -ForegroundColor Green
        $script:selectedLutPath = $selectedLut
        # Windows: ffmpeg -vf lut3d needs forward slashes or escaped backslashes
        $lutPathEscaped = $selectedLut -replace '\\','/'
        if ($encoderType -eq "x264") {
            $script:logVideoFilter = "lut3d='$lutPathEscaped',format=yuv420p"
            $script:logPixFmt = "yuv420p"
        } else {
            $script:logVideoFilter = "lut3d='$lutPathEscaped',format=yuv420p10le"
            $script:logPixFmt = "yuv420p10le"
        }
        $script:logColorFlags = @("-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709")
        return "lut"
    }
    elseif ($logChoice -eq $optSdr) {
        Write-Host "  LOG: Convert SDR (best-effort, fara LUT)" -ForegroundColor Green
        if ($encoderType -eq "x264") {
            $script:logVideoFilter = "zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p"
            $script:logPixFmt = "yuv420p"
        } else {
            $script:logVideoFilter = "zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p10le"
            $script:logPixFmt = "yuv420p10le"
        }
        $script:logColorFlags = @("-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709")
        return "sdr"
    }
    elseif ($logChoice -eq $optHdr -and $optHdr -gt 0) {
        Write-Host "  LOG: Convert HDR10 static (fara LUT)" -ForegroundColor Green
        $script:logVideoFilter = "zscale=t=linear:npl=100,zscale=t=smpte2084:p=bt2020:m=bt2020nc,format=yuv420p10le"
        $script:logPixFmt = "yuv420p10le"
        $script:logColorFlags = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
        if ($encoderType -eq "x265") {
            $script:logExtraX265 = "hdr-opt=1:repeat-headers=1:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
        }
        return "hdr10"
    }
    elseif ($logChoice -eq $optPreserve) {
        Write-Host "  LOG: Preserve Log (compresie fara schimbare culori)" -ForegroundColor Green
        if ($encoderType -eq "x264") {
            $script:logPixFmt = "yuv420p"
            Write-Host "  ⚠ x264 8-bit — gradatii pierdute. x265 recomandat." -ForegroundColor Yellow
        } else {
            $script:logPixFmt = "yuv420p10le"
        }
        # Preserve original color flags
        $origPrimaries = Get-FFprobeValue $file "v:0" "color_primaries"
        $origTrc       = Get-FFprobeValue $file "v:0" "color_transfer"
        $origSpace     = Get-FFprobeValue $file "v:0" "color_space"
        $cf = @()
        if ($origPrimaries -and $origPrimaries -ne "unknown") { $cf += @("-color_primaries",$origPrimaries) }
        if ($origTrc       -and $origTrc -ne "unknown")       { $cf += @("-color_trc",$origTrc) }
        if ($origSpace     -and $origSpace -ne "unknown")     { $cf += @("-colorspace",$origSpace) }
        $script:logColorFlags = $cf
        return "preserve"
    }
    elseif ($logChoice -eq $optCreative -and $optCreative -gt 0) {
        # Creative LUT — artistic look
        $selectedCreative = $null
        if ($creativeLutResult.files.Count -eq 1) {
            $selectedCreative = $creativeLutResult.files[0].FullName
        } else {
            Write-Host ""
            Write-Host "  Creative LUT-uri disponibile:" -ForegroundColor Magenta
            for ($ci = 0; $ci -lt $creativeLutResult.files.Count; $ci++) {
                Write-Host "  $($ci+1)) $($creativeLutResult.files[$ci].Name)" -ForegroundColor White
            }
            $creativeSel = Read-Host "  Alege LUT [implicit: 1]"
            if (-not $creativeSel) { $creativeSel = "1" }
            if ($creativeSel -match '^\d+$' -and [int]$creativeSel -ge 1 -and [int]$creativeSel -le $creativeLutResult.files.Count) {
                $selectedCreative = $creativeLutResult.files[[int]$creativeSel - 1].FullName
            } else {
                $selectedCreative = $creativeLutResult.files[0].FullName
            }
        }
        Write-Host "  LOG: Creative LUT — $(Split-Path -Leaf $selectedCreative)" -ForegroundColor Magenta
        $script:selectedLutPath = $selectedCreative
        $creativePathEscaped = $selectedCreative -replace '\\','/'
        if ($encoderType -eq "x264") {
            $script:logVideoFilter = "lut3d='$creativePathEscaped',format=yuv420p"
            $script:logPixFmt = "yuv420p"
        } else {
            $script:logVideoFilter = "lut3d='$creativePathEscaped',format=yuv420p10le"
            $script:logPixFmt = "yuv420p10le"
        }
        $script:logColorFlags = @("-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709")
        return "creative_lut"
    }
    elseif ($logChoice -eq $optCopy) {
        Write-Host "  LOG: Stream copy video" -ForegroundColor Green
        return "copy"
    }
    else {
        Write-Host "  LOG: Sarit" -ForegroundColor DarkYellow
        return "skip"
    }
}

# ── Show-X264Dialog — x264 dialog per-file (8bit/10bit/copy/skip) ──
# Return: "8bit" | "10bit" | "copy" | "skip"
function Show-X264Dialog {
    param([string]$file, [string]$filename, [hashtable]$sourceInfo, [bool]$isHdr)
    $srcPixfmt = Get-FFprobeValue $file "v:0" "pix_fmt"
    $srcBitdepth = if ($srcPixfmt -match "10") { "10-bit" } else { "8-bit" }
    $w = Get-FFprobeValue $file "v:0" "width"
    $h = Get-FFprobeValue $file "v:0" "height"

    $srcLabel = "SDR $srcBitdepth"
    if ($sourceInfo.isHDRPlus) { $srcLabel = "HDR10+ $srcBitdepth" }
    elseif ($sourceInfo.isHDR) { $srcLabel = "HDR10 $srcBitdepth" }

    # Check DV
    $doVi = & ffprobe -v error -show_entries stream=codec_tag_string `
        -of default=noprint_wrappers=1:nokey=1 $file 2>$null |
        Select-String -Pattern "dovi|dvhe|dvh1" -CaseSensitive:$false
    if ($doVi) { $srcLabel = "Dolby Vision $srcBitdepth"; $isHdr = $true }

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  x264 — ANALIZA SURSA                        ║" -ForegroundColor Cyan
    Write-Host ("  ║  Fisier : {0,-37}║" -f $filename) -ForegroundColor White
    Write-Host ("  ║  Sursa  : {0,-37}║" -f $srcLabel) -ForegroundColor White
    Write-Host ("  ║  Rezol. : {0,-37}║" -f "${w}x${h}") -ForegroundColor White
    Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    if ($isHdr) {
        Write-Host "  ║  ⚠ x264 NU suporta metadata HDR/DV/HDR10+.  ║" -ForegroundColor Yellow
        Write-Host "  ║  Re-encode va produce video SDR (fara meta). ║" -ForegroundColor Yellow
        Write-Host "  ║  Doar Stream Copy pastreaza metadata intact. ║" -ForegroundColor Yellow
        Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    }
    Write-Host "  ║  Cum encodam?                                ║" -ForegroundColor White
    Write-Host "  ║  1) 8-bit  (high — compatibilitate maxima)   ║" -ForegroundColor White
    Write-Host "  ║  2) 10-bit (high10 — calitate, anti-banding) ║" -ForegroundColor White
    Write-Host "  ║  3) Stream copy video (pastreaza tot, rapid)  ║" -ForegroundColor White
    Write-Host "  ║  4) Sari acest fisier                        ║" -ForegroundColor White
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $ch = Read-Host "  Alege 1-4 [implicit: 1]"
    switch ($ch) {
        "2" { Write-Host "  Ales: 10-bit (high10)" -ForegroundColor Green; return "10bit" }
        "3" { Write-Host "  Ales: Stream copy video" -ForegroundColor Green; return "copy" }
        "4" { Write-Host "  Sarit de utilizator" -ForegroundColor DarkYellow; return "skip" }
        default { Write-Host "  Ales: 8-bit (high)" -ForegroundColor Green; return "8bit" }
    }
}

# ── Show-InteractiveSettingsDialog — modificare setari dupa fiecare fisier ──
function Show-InteractiveSettingsDialog {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "  ║  MOD INTERACTIV — Fisier urmator             ║" -ForegroundColor Green
    Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Green
    Write-Host "  ║  Setari curente:                             ║" -ForegroundColor White
    Write-Host ("  ║  Audio     : {0,-33}║" -f "$audioCodec $audioBitrate") -ForegroundColor White
    Write-Host ("  ║  Container : {0,-33}║" -f $container) -ForegroundColor White
    if ($customCrf) { Write-Host ("  ║  CRF       : {0,-33}║" -f $customCrf) -ForegroundColor White }
    Write-Host ("  ║  Filtru    : {0,-33}║" -f $(if ($vfPreset) { $vfPreset } elseif ($vfIsVidstab) { "vidstab" } else { "fara" })) -ForegroundColor White
    Write-Host ("  ║  Normalizare: {0,-32}║" -f $(if ($audioNormalize) { "EBU R128" } else { "dezactivata" })) -ForegroundColor White
    Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Green
    Write-Host "  ║  1) Pastreaza setarile (continua) [implicit] ║" -ForegroundColor White
    Write-Host "  ║  2) Modifica setarile pentru urmatorul fisier ║" -ForegroundColor White
    Write-Host "  ║  3) Opreste batch-ul aici                    ║" -ForegroundColor White
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Green
    $intChoice = Read-Host "  Alege 1-3 [implicit: 1]"
    switch ($intChoice) {
        "2" {
            Write-Host ""
            Write-Host "  Audio curent: $audioCodec $audioBitrate" -ForegroundColor White
            Write-Host "  Schimbi? (Enter = pastreaza, sau: aac 192k / opus 128k / eac3 224k / flac / pcm / copy)" -ForegroundColor DarkGray
            $newAudio = Read-Host "  Audio nou"
            if ($newAudio) {
                $parts = $newAudio -split '\s+'
                if ($parts[0] -eq "copy") {
                    $script:audioCopy = $true
                    $script:audioCodec = "copy"
                } else {
                    $script:audioCopy = $false
                    $script:audioCodec = $parts[0]
                    if ($parts.Count -gt 1) { $script:audioBitrate = $parts[1] }
                }
                Write-Host "  → Audio: $($script:audioCodec) $(if (-not $script:audioCopy) { $script:audioBitrate })" -ForegroundColor Green
            }
            if (-not $script:useDNxHR -and -not $script:useProRes) {
                Write-Host "  CRF curent: $(if ($script:customCrf) { $script:customCrf } else { 'auto' })" -ForegroundColor White
                $newCrf = Read-Host "  CRF nou (Enter = pastreaza)"
                if ($newCrf -match '^\d+$') { $script:customCrf = $newCrf; Write-Host "  → CRF: $newCrf" -ForegroundColor Green }
            }
            Write-Host "  Normalizare: $(if ($script:audioNormalize) { 'activa' } else { 'dezactivata' })" -ForegroundColor White
            $newNorm = Read-Host "  Schimbi? (1=activa, 0=dezactiva, Enter=pastreaza)"
            if ($newNorm -eq "1") { $script:audioNormalize = $true; Write-Host "  → Normalizare: activa" -ForegroundColor Green }
            if ($newNorm -eq "0") { $script:audioNormalize = $false; Write-Host "  → Normalizare: dezactivata" -ForegroundColor Green }
            Write-Host "  [INTERACTIV] Setari modificate" -ForegroundColor Green
            return "continue"
        }
        "3" {
            Write-Host "  [INTERACTIV] Batch oprit" -ForegroundColor Yellow
            return "stop"
        }
        default { return "continue" }
    }
}

# FIX: Show-Progress citeste fps= real din progress file
# Fallback la viteza relativa (outSec/elapsed) afisata ca "X.Xx"
function Show-Progress {
    param(
        [System.Diagnostics.Process]$proc,
        [string]$progFile,
        [int]$durSec,
        [datetime]$startTime
    )
    $initialized = $false
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 500
        if (-not (Test-Path $progFile)) {
            if (-not $initialized) {
                Write-Host -NoNewline "`r  Se initializeaza...                                      "
            }
            continue
        }
        $lines = Get-Content $progFile -ErrorAction SilentlyContinue
        if (-not $lines) { continue }

        $msLine = $lines | Where-Object { $_ -match "^out_time_ms=\d+" } | Select-Object -Last 1
        if (-not $msLine) { continue }
        $ms = [long]($msLine -replace "out_time_ms=","")
        if ($ms -le 0) { continue }

        $initialized = $true
        $outSec  = [int]($ms / 1000000)
        $elapsed = [math]::Max(1, [int](Get-Date).Subtract($startTime).TotalSeconds)
        $pct = if ($durSec -gt 0) { [math]::Min(100, [int]($outSec * 100 / $durSec)) } else { 0 }

        # Citim fps real din progress file (ffmpeg il scrie acolo)
        $fpsLine = $lines | Where-Object { $_ -match "^fps=" } | Select-Object -Last 1
        $fpsVal  = if ($fpsLine) { [double]($fpsLine -replace "fps=","").Trim() } else { 0 }
        $fpsStr = if ($fpsVal -gt 0) {
            [math]::Round($fpsVal, 1).ToString()
        } else {
            # Fallback: viteza relativa encodare
            if ($outSec -gt 0) { "$([math]::Round($outSec / $elapsed, 1))x" } else { "0.0x" }
        }

        $eta = if ($outSec -gt 0 -and $durSec -gt $outSec) {
            [int]($elapsed * ($durSec - $outSec) / $outSec)
        } else { 0 }
        $etaStr = "{0:D2}:{1:D2}:{2:D2}" -f ([int]($eta/3600)), ([int](($eta%3600)/60)), ($eta%60)
        Write-Host -NoNewline ("`r  Progres: {0,3}% | FPS: {1,5} | Timp ramas: {2}   " -f $pct, $fpsStr, $etaStr)
    }
    Write-Host ""
    if (Test-Path $progFile) { Remove-Item $progFile -Force -ErrorAction SilentlyContinue }
}

# Estimare dimensiune output — functie utilitara folosita in :checkvideo
# Definita la nivel global, nu in foreach (era redeclarata per fisier — ineficient)
function Get-SizeEst {
    param([int]$bps, [int]$dur)
    if ($dur -le 0) { return "N/A" }
    $mb = [int]($bps * $dur / 8 / 1MB)
    if ($mb -ge 1024) { "~{0:F1} GB" -f ($mb/1024) } else { "~$mb MB" }
}

# ── Header ────────────────────────────────────────────────────────────
Clear-Host
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     FFmpeg SMART ADAPTIVE ENCODER        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
$inputFiles = Get-ChildItem -Path $InputDir -Include "*.mp4","*.mov","*.mkv","*.m2ts","*.mts","*.vob","*.mxf","*.apv" -File
$fileCount  = $inputFiles.Count
$totalSz    = ($inputFiles | Measure-Object -Property Length -Sum).Sum
Write-Host "INPUT: $InputDir | Fisiere: $fileCount | $(Format-Bytes $totalSz)" -ForegroundColor Yellow
if ($fileCount -eq 0) { Write-Host "Nu am gasit fisiere." -ForegroundColor Red; Read-Host; exit }

# ══════════════════════════════════════════════════════════════════════
# Meniu principal INAINTE de configurarea encoderului
# Daca utilizatorul alege Verifica sau Iesire, nu mai parcurge intrebarile
# ══════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "1-Encode video+audio  2-Encode doar audio (video copy)  3-Verifica media  4-Export GPS/DJI  5-Import GPS extern  6-Iesire" -ForegroundColor Cyan
$mainChoice = Read-Host "Selecteaza"
if ($mainChoice -eq "6") { exit }

# ── Import GPS extern (GPX/FIT/KML → CSV/SRT) ─────────────────────
if ($mainChoice -eq "5") {
    # Verificare python3
    $py3 = $null
    if (Get-Command "python3" -ErrorAction SilentlyContinue) { $py3 = "python3" }
    elseif (Get-Command "python" -ErrorAction SilentlyContinue) {
        $pyVer = & python --version 2>&1
        if ($pyVer -match "3\.") { $py3 = "python" }
    }
    if (-not $py3) {
        Write-Host "[EROARE] Python3 nu este instalat sau nu este in PATH." -ForegroundColor Red
        Write-Host "Download: https://python.org/downloads/" -ForegroundColor Yellow
        Read-Host; exit
    }

    $gpsFiles = Get-ChildItem -Path $InputDir -Include "*.gpx","*.fit","*.kml" -File -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  GPS EXTRACTOR (GPX/FIT/KML)                 ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  Fisiere gasite : $($gpsFiles.Count)" -ForegroundColor White
    Write-Host "║  Input  : $InputDir" -ForegroundColor White
    Write-Host "║  Output : $OutputDir" -ForegroundColor White
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  1) CSV esential (Lat, Lon, Alt, Speed, Time)║" -ForegroundColor White
    Write-Host "║  2) CSV complet (toate metadatele)            ║" -ForegroundColor White
    Write-Host "║  3) Subtitrare SRT (overlay in VLC)           ║" -ForegroundColor White
    Write-Host "║  4) Totul (CSV basic + CSV full + SRT)        ║" -ForegroundColor White
    Write-Host "║  5) GPX & KML (conversie intre formate)       ║" -ForegroundColor White
    Write-Host "║  6) Anulare                                   ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $gpsChoice = Read-Host "Alege 1-6 [implicit: 1]"
    if (-not $gpsChoice) { $gpsChoice = "1" }
    if ($gpsChoice -eq "6") { exit }

    if (-not $gpsFiles -or $gpsFiles.Count -eq 0) {
        Write-Host "Nu am gasit fisiere .gpx, .fit sau .kml in $InputDir" -ForegroundColor Red
        Read-Host; exit
    }

    # Generate Python script as temp file
    $pyScript = Join-Path $env:TEMP "av_gps_extract_$(Get-Random).py"
    @"
import xml.etree.ElementTree as ET
import csv, sys, os, math, struct, re
from datetime import datetime, timedelta

def parse_gpx(file_path):
    tree = ET.parse(file_path)
    root = tree.getroot()
    ns = root.tag.split('}')[0] + '}' if root.tag.startswith('{') else ''
    points = []
    for trkpt in list(root.iter(f'{ns}trkpt')) or list(root.iter(f'{ns}wpt')):
        p = {'lat': trkpt.get('lat',''), 'lon': trkpt.get('lon','')}
        ele = trkpt.find(f'{ns}ele')
        p['alt'] = ele.text.strip() if ele is not None and ele.text else ''
        t = trkpt.find(f'{ns}time')
        p['time'] = t.text.strip() if t is not None and t.text else ''
        p['speed'] = ''
        for ext_tag in [f'{ns}extensions', 'extensions']:
            ext_el = trkpt.find(ext_tag)
            if ext_el is not None:
                for child in ext_el.iter():
                    tag = child.tag.split('}')[-1].lower() if '}' in child.tag else child.tag.lower()
                    if 'speed' in tag and child.text: p['speed'] = child.text.strip()
                    if ('hr' in tag or 'heartrate' in tag) and child.text: p['hr'] = child.text.strip()
                    if ('cad' in tag or 'cadence' in tag) and child.text: p['cad'] = child.text.strip()
                    if 'power' in tag and child.text: p['power'] = child.text.strip()
                    if ('temp' in tag or 'atemp' in tag) and child.text: p['temp'] = child.text.strip()
        points.append(p)
    # Calculate speed if missing
    for i in range(1, len(points)):
        if not points[i].get('speed') and points[i]['lat'] and points[i-1]['lat']:
            try:
                lat1,lon1 = float(points[i-1]['lat']),float(points[i-1]['lon'])
                lat2,lon2 = float(points[i]['lat']),float(points[i]['lon'])
                dlat,dlon = math.radians(lat2-lat1),math.radians(lon2-lon1)
                a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1))*math.cos(math.radians(lat2))*math.sin(dlon/2)**2
                dist = 6371000*2*math.atan2(math.sqrt(a),math.sqrt(1-a))
                if points[i].get('time') and points[i-1].get('time'):
                    for fmt in ['%Y-%m-%dT%H:%M:%SZ','%Y-%m-%dT%H:%M:%S.%fZ','%Y-%m-%dT%H:%M:%S%z']:
                        try:
                            t1=datetime.strptime(points[i-1]['time'],fmt); t2=datetime.strptime(points[i]['time'],fmt)
                            dt=(t2-t1).total_seconds()
                            if dt>0: points[i]['speed']=f"{dist/dt:.2f}"
                            break
                        except: continue
            except: pass
    return points

def parse_kml(file_path):
    tree = ET.parse(file_path)
    root = tree.getroot()
    ns = root.tag.split('}')[0]+'}' if root.tag.startswith('{') else ''
    points = []
    for coords_el in list(root.iter(f'{ns}coordinates'))+list(root.iter('coordinates')):
        if coords_el.text:
            for token in re.split(r'[\s]+', coords_el.text.strip()):
                token = token.strip()
                if not token: continue
                parts = token.split(',')
                if len(parts)>=2:
                    p = {'lon':parts[0].strip(),'lat':parts[1].strip(),'alt':parts[2].strip() if len(parts)>=3 else '','speed':'','time':''}
                    points.append(p)
    return points

def parse_fit(file_path):
    FIT_EPOCH = datetime(1989,12,31)
    with open(file_path,'rb') as f: data=f.read()
    if len(data)<14: return []
    hs = data[0]
    sig_off = hs-4 if hs>=14 else 8
    if data[sig_off:sig_off+4] != b'.FIT': return []
    points=[]; field_defs={}; mesg_nums={}; pos=hs
    while pos < len(data)-2:
        try:
            rh=data[pos]; pos+=1
            if rh & 0x40:
                lm=rh&0x0F; pos+=1; arch=data[pos]; pos+=1
                gm=struct.unpack('<H' if arch==0 else '>H',data[pos:pos+2])[0]; pos+=2
                nf=data[pos]; pos+=1; flds=[]
                for _ in range(nf): flds.append((data[pos],data[pos+1],data[pos+2])); pos+=3
                field_defs[lm]=(flds,arch); mesg_nums[lm]=gm
                if rh&0x20: nd=data[pos]; pos+=1; pos+=nd*3
            elif rh&0x80:
                lm=(rh>>5)&0x03
                if lm not in field_defs: break
                for _,fs,_ in field_defs[lm][0]: pos+=fs
            else:
                lm=rh&0x0F
                if lm not in field_defs: break
                flds,arch=field_defs[lm]; gm=mesg_nums.get(lm,0); fv={}
                for fdn,fs,fbt in flds:
                    raw=data[pos:pos+fs]; pos+=fs; val=None
                    if fs==1: val=raw[0]; val=None if val==0xFF else val
                    elif fs==2: val=struct.unpack('<H' if arch==0 else '>H',raw)[0]; val=None if val==0xFFFF else val
                    elif fs==4:
                        val=struct.unpack('<I' if arch==0 else '>I',raw)[0]; val=None if val==0xFFFFFFFF else val
                        if fbt&0x1F==0x85: val=struct.unpack('<i' if arch==0 else '>i',raw)[0]; val=None if val==0x7FFFFFFF else val
                    if val is not None: fv[fdn]=val
                if gm==20 and 0 in fv and 1 in fv:
                    lat_sc,lon_sc=fv[0],fv[1]
                    if lat_sc>0x7FFFFFFF: lat_sc-=0x100000000
                    if lon_sc>0x7FFFFFFF: lon_sc-=0x100000000
                    p={'lat':f"{lat_sc*(180.0/2**31):.8f}",'lon':f"{lon_sc*(180.0/2**31):.8f}"}
                    p['alt']=f"{(fv[2]/5.0)-500:.1f}" if 2 in fv and fv[2]!=0xFFFF else ''
                    p['speed']=f"{fv[6]/1000.0:.2f}" if 6 in fv else ''
                    p['time']=(FIT_EPOCH+timedelta(seconds=fv[253])).strftime('%Y-%m-%d %H:%M:%S') if 253 in fv else ''
                    if 3 in fv: p['hr']=str(fv[3])
                    if 4 in fv: p['cad']=str(fv[4])
                    if 7 in fv: p['power']=str(fv[7])
                    if 23 in fv: p['temp']=str(fv[23])
                    if -90<=float(p['lat'])<=90 and float(p['lat'])!=0: points.append(p)
        except: break
    return points

def write_csv_basic(points, path):
    with open(path,'w',newline='') as f:
        w=csv.writer(f); w.writerow(['Latitude','Longitude','Altitude(m)','Speed(m/s)','DateTime'])
        for p in points: w.writerow([p['lat'],p['lon'],p.get('alt',''),p.get('speed',''),p.get('time','')])

def write_csv_full(points, path):
    keys=sorted(set(k for p in points for k in p.keys()))
    with open(path,'w',newline='') as f:
        w=csv.writer(f); w.writerow(keys)
        for p in points: w.writerow([p.get(k,'') for k in keys])

def write_srt(points, path):
    with open(path,'w') as f:
        for i,p in enumerate(points):
            sv=p.get('speed','0')
            try: sk=f"{float(sv)*3.6:.1f}" if sv else "0.0"
            except: sk="0.0"
            s1,s2=i,i+1
            f.write(f"{i+1}\n{s1//3600:02d}:{(s1%3600)//60:02d}:{s1%60:02d},000 --> {s2//3600:02d}:{(s2%3600)//60:02d}:{s2%60:02d},000\n")
            f.write(f"Speed: {sk} km/h | Alt: {p.get('alt','N/A')}m\nGPS: {p['lat']}, {p['lon']}\n")
            hr=f" | HR: {p['hr']}bpm" if p.get('hr') else ""
            cad=f" | Cad: {p['cad']}rpm" if p.get('cad') else ""
            if hr or cad: f.write(f"{hr}{cad}\n")
            f.write("\n")

def write_kml(points, name, path):
    with open(path,'w') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<kml xmlns="http://www.opengis.net/kml/2.2">\n')
        f.write(f'<Document><name>{name}</name>\n<Style id="t"><LineStyle><color>ff0000ff</color><width>3</width></LineStyle></Style>\n')
        f.write('<Placemark><name>Track</name><styleUrl>#t</styleUrl><LineString><altitudeMode>absolute</altitudeMode><coordinates>\n')
        for p in points: f.write(f"{p['lon']},{p['lat']},{p.get('alt','0') or '0'}\n")
        f.write('</coordinates></LineString></Placemark></Document></kml>\n')

def write_gpx(points, name, path):
    with open(path,'w') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="AV Encoder Suite">\n')
        f.write(f'<trk><name>{name}</name><trkseg>\n')
        for p in points:
            f.write(f'<trkpt lat="{p["lat"]}" lon="{p["lon"]}"><ele>{p.get("alt","0") or "0"}</ele>')
            if p.get('time'): f.write(f'<time>{p["time"]}</time>')
            f.write('</trkpt>\n')
        f.write('</trkseg></trk></gpx>\n')

# Main
files = sys.argv[1:-1]
choice = sys.argv[-1]

for fp in files:
    name = os.path.splitext(os.path.basename(fp))[0]
    ext = os.path.splitext(fp)[1].lower()
    out = os.path.dirname(fp).replace('InputVideos','OutputVideos') if 'InputVideos' in os.path.dirname(fp) else os.path.join(os.path.dirname(fp),'output')
    # Use output dir from env or derive
    out = os.environ.get('AV_OUTPUT_DIR', out)
    os.makedirs(out, exist_ok=True)
    print(f"\n-- {os.path.basename(fp)}")
    try:
        if ext=='.gpx': pts=parse_gpx(fp)
        elif ext=='.fit': pts=parse_fit(fp)
        elif ext=='.kml': pts=parse_kml(fp)
        else: print(f"  [SKIP] Format necunoscut: {ext}"); continue
    except Exception as e: print(f"  [EROARE] {e}"); continue
    if not pts: print("  [SKIP] Nu am gasit puncte GPS"); continue
    print(f"  Puncte GPS: {len(pts)}")
    if choice in ('1','4'): write_csv_basic(pts,os.path.join(out,f"{name}_gps_basic.csv")); print(f"  [OK] CSV basic: {name}_gps_basic.csv")
    if choice in ('2','4'): write_csv_full(pts,os.path.join(out,f"{name}_gps_full.csv")); print(f"  [OK] CSV full: {name}_gps_full.csv")
    if choice in ('3','4'): write_srt(pts,os.path.join(out,f"{name}_gps.srt")); print(f"  [OK] SRT: {name}_gps.srt")
    if choice=='5':
        if ext!='.kml': write_kml(pts,name,os.path.join(out,f"{name}.kml")); print(f"  [OK] KML: {name}.kml")
        if ext!='.gpx': write_gpx(pts,name,os.path.join(out,f"{name}.gpx")); print(f"  [OK] GPX: {name}.gpx")
"@ | Out-File $pyScript -Encoding UTF8

    # Execute Python with file list + choice
    $env:AV_OUTPUT_DIR = $OutputDir
    $gpsArgs = @($pyScript) + ($gpsFiles | ForEach-Object { $_.FullName }) + @($gpsChoice)
    & $py3 @gpsArgs
    Remove-Item $pyScript -Force -ErrorAction SilentlyContinue
    Remove-Variable env:AV_OUTPUT_DIR -ErrorAction SilentlyContinue

    Write-Host "`nFINALIZAT — $($gpsFiles.Count) fisiere procesate" -ForegroundColor Green
    Write-Host "Output: $OutputDir" -ForegroundColor White
    Read-Host "Apasa Enter"; exit
}

# ── Export GPS/DJI via ExifTool ──────────────────────────────────────
if ($mainChoice -eq "4") {
    # Verificare ExifTool
    $exifCmd = $null
    if (Get-Command "exiftool" -ErrorAction SilentlyContinue) {
        $exifCmd = "exiftool"
    } elseif (Test-Path (Join-Path $PSScriptRoot "exiftool.exe")) {
        $exifCmd = Join-Path $PSScriptRoot "exiftool.exe"
    } else {
        Write-Host "[EROARE] ExifTool nu a fost gasit." -ForegroundColor Red
        Write-Host "Descarca exiftool.exe de pe https://exiftool.org/" -ForegroundColor Yellow
        Write-Host "si pune-l in acelasi folder cu acest script sau in PATH." -ForegroundColor Yellow
        Read-Host; exit
    }
    Write-Host "[OK] ExifTool gasit." -ForegroundColor Green

    # Generare template GPX
    $gpxFmt = Join-Path $OutputDir "gpx.fmt"
    @'
#[HEAD]<?xml version="1.0" encoding="utf-8"?>
#[HEAD]<gpx version="1.0" creator="ExifTool $[ExifToolVersion]" xmlns="http://www.topografix.com/GPX/1/0">
#[HEAD]<trk><name>$filename</name><trkseg>
#[BODY]<trkpt lat="$gpslatitude#" lon="$gpslongitude#"><ele>$gpsaltitude#</ele><time>$gpsdatetime</time></trkpt>
#[TAIL]</trkseg></trk></gpx>
'@ | Out-File $gpxFmt -Encoding ASCII

    # Generare template SRT
    $srtFmt = Join-Path $OutputDir "srt.fmt"
    @'
#[BODY]${self:SampleIndex}
#[BODY]${gpsdatetime} --> ${gpsdatetime}
#[BODY]Viteza: ${gpsspeed#} m/s | Alt: ${gpsaltitude#}m
#[BODY]Coord: ${gpslatitude#}, ${gpslongitude#}
#[BODY]
'@ | Out-File $srtFmt -Encoding ASCII

    Write-Host "`n╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  DJI GPS/TELEMETRIE EXTRACTOR                ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  1) Standard (GPX + CSV esential)            ║" -ForegroundColor White
    Write-Host "║  2) Full Data (GPX + CSV TOATE metadatele)   ║" -ForegroundColor White
    Write-Host "║  3) Subtitrare (fisier .SRT pentru VLC)      ║" -ForegroundColor White
    Write-Host "║  4) Totul (GPX + CSV + SRT)                  ║" -ForegroundColor White
    Write-Host "║  5) Raw streams (djmd, dbgi, tmcd, cover)    ║" -ForegroundColor White
    Write-Host "║  6) Anulare                                  ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $djiChoice = Read-Host "Alege 1-6 [implicit: 1]"
    if (-not $djiChoice) { $djiChoice = "1" }
    if ($djiChoice -eq "6") {
        Remove-Item $gpxFmt,$srtFmt -Force -ErrorAction SilentlyContinue
        exit
    }

    Write-Host "`n--- Incep extractia ---" -ForegroundColor Green
    $djiDone = 0
    foreach ($f in $inputFiles) {
        $djiDone++
        $name = $f.BaseName
        Write-Host "`nProcesez: $($f.Name)" -ForegroundColor Yellow

        # GPX — optiunile 1, 2, 4
        if ($djiChoice -in @("1","2","4")) {
            & $exifCmd -p $gpxFmt -ee3 -api LargeFileSupport=1 $f.FullName 2>$null |
                Out-File (Join-Path $OutputDir "$name.gpx") -Encoding UTF8
            $gpxOut = Join-Path $OutputDir "$name.gpx"
            if ((Test-Path $gpxOut) -and (Get-Item $gpxOut).Length -gt 0) {
                Write-Host "  [OK] GPX: $name.gpx" -ForegroundColor Green
            } else {
                Write-Host "  [SKIP] GPX: nu s-au gasit date GPS" -ForegroundColor DarkGray
                Remove-Item $gpxOut -Force -ErrorAction SilentlyContinue
            }
        }

        # CSV Basic — optiunile 1, 4
        if ($djiChoice -in @("1","4")) {
            & $exifCmd -ee3 -api LargeFileSupport=1 -csv -n `
                -GPSLatitude -GPSLongitude -GPSAltitude `
                -GPSSpeed -GPSTrack -GPSDateTime `
                $f.FullName 2>$null |
                Out-File (Join-Path $OutputDir "${name}_basic.csv") -Encoding UTF8
            Write-Host "  [OK] CSV Basic: ${name}_basic.csv" -ForegroundColor Green
        }

        # CSV Full — optiunile 2, 4
        if ($djiChoice -in @("2","4")) {
            & $exifCmd -ee3 -api LargeFileSupport=1 -csv -G -n `
                $f.FullName 2>$null |
                Out-File (Join-Path $OutputDir "${name}_FULL.csv") -Encoding UTF8
            Write-Host "  [OK] CSV Full: ${name}_FULL.csv" -ForegroundColor Green
        }

        # SRT — optiunile 3, 4
        if ($djiChoice -in @("3","4")) {
            & $exifCmd -p $srtFmt -ee3 -api LargeFileSupport=1 $f.FullName 2>$null |
                Out-File (Join-Path $OutputDir "$name.srt") -Encoding UTF8
            $srtOut = Join-Path $OutputDir "$name.srt"
            if ((Test-Path $srtOut) -and (Get-Item $srtOut).Length -gt 0) {
                Write-Host "  [OK] SRT: $name.srt" -ForegroundColor Green
            } else {
                Write-Host "  [SKIP] SRT: nu s-au gasit date GPS" -ForegroundColor DarkGray
                Remove-Item $srtOut -Force -ErrorAction SilentlyContinue
            }
        }

        # RAW STREAMS — optiunea 5: extrage djmd, dbgi, tmcd, cover cu ffmpeg
        if ($djiChoice -eq "5") {
            $rawIdx = 0
            $tags = & ffprobe -v error -show_entries stream=codec_tag_string,codec_name `
                -of csv=p=0 $f.FullName 2>$null
            foreach ($tag in $tags) {
                if ($tag -imatch "djmd") {
                    & ffmpeg -v error -i $f.FullName -map "0:$rawIdx" -c copy -f data `
                        (Join-Path $OutputDir "${name}_djmd.bin") -y 2>$null
                    $djmdOut = Join-Path $OutputDir "${name}_djmd.bin"
                    if ((Test-Path $djmdOut) -and (Get-Item $djmdOut).Length -gt 0) {
                        Write-Host "  [OK] djmd: ${name}_djmd.bin ($(Format-Bytes (Get-Item $djmdOut).Length))" -ForegroundColor Green
                    } else { Remove-Item $djmdOut -Force -ErrorAction SilentlyContinue }
                }
                elseif ($tag -imatch "dbgi") {
                    & ffmpeg -v error -i $f.FullName -map "0:$rawIdx" -c copy -f data `
                        (Join-Path $OutputDir "${name}_dbgi.bin") -y 2>$null
                    $dbgiOut = Join-Path $OutputDir "${name}_dbgi.bin"
                    if ((Test-Path $dbgiOut) -and (Get-Item $dbgiOut).Length -gt 0) {
                        Write-Host "  [OK] dbgi: ${name}_dbgi.bin ($(Format-Bytes (Get-Item $dbgiOut).Length))" -ForegroundColor Green
                    } else { Remove-Item $dbgiOut -Force -ErrorAction SilentlyContinue }
                }
                elseif ($tag -imatch "tmcd") {
                    & ffmpeg -v error -i $f.FullName -map "0:$rawIdx" -c copy -f data `
                        (Join-Path $OutputDir "${name}_tmcd.bin") -y 2>$null
                    $tmcdOut = Join-Path $OutputDir "${name}_tmcd.bin"
                    if ((Test-Path $tmcdOut) -and (Get-Item $tmcdOut).Length -gt 0) {
                        Write-Host "  [OK] tmcd: ${name}_tmcd.bin ($(Format-Bytes (Get-Item $tmcdOut).Length))" -ForegroundColor Green
                    } else { Remove-Item $tmcdOut -Force -ErrorAction SilentlyContinue }
                }
                elseif ($tag -imatch "mjpeg|jpeg") {
                    & ffmpeg -v error -i $f.FullName -map "0:$rawIdx" -c copy -f mjpeg `
                        (Join-Path $OutputDir "${name}_cover.jpg") -y 2>$null
                    $coverOut = Join-Path $OutputDir "${name}_cover.jpg"
                    if ((Test-Path $coverOut) -and (Get-Item $coverOut).Length -gt 0) {
                        Write-Host "  [OK] cover: ${name}_cover.jpg ($(Format-Bytes (Get-Item $coverOut).Length))" -ForegroundColor Green
                    } else { Remove-Item $coverOut -Force -ErrorAction SilentlyContinue }
                }
                $rawIdx++
            }
        }
    }

    # Curatenie
    Remove-Item $gpxFmt,$srtFmt -Force -ErrorAction SilentlyContinue

    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "FINALIZAT — $djiDone fisiere procesate" -ForegroundColor Green
    Write-Host "Output: $OutputDir" -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan
    Read-Host
    exit
}

# ── Audio-only encode (video copy) ───────────────────────────────────
if ($mainChoice -eq "2") {
    Write-Host "`n╔══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  AUDIO-ONLY ENCODER (video copy)     ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "Container: 1-mp4  2-mkv [impl]  3-mov  4-webm" -ForegroundColor Cyan
    $eaCont = Read-Host "Alege [implicit: 2]"
    $eaContainer = switch ($eaCont) { "1"{"mp4"} "3"{"mov"} "4"{"webm"} default{"mkv"} }
    $eaFlags = if ($eaContainer -in @("mkv","webm")) { @() } else { @("-movflags","+faststart") }

    Write-Host "Audio: 1-AAC 192k/384k/768k [impl] 2-AAC custom 3-Opus 128k/256k/512k 4-Opus custom 5-FLAC 6-FLAC custom 7-E-AC3 8-LPCM" -ForegroundColor Cyan
    $eaAC = Read-Host "Alege 1-8 [implicit: 1]"
    $eaCodec = "aac"; $eaBr = "192k"; $eaFlvl = 8; $eaPcmDepth = "16le"
    switch ($eaAC) {
        "2" { $eaBr = Read-Host "  Bitrate AAC"; if ($eaBr -notmatch '^\d+[kK]$') { $eaBr = "192k" } }
        "3" { $eaCodec = "opus"; $eaBr = "128k" }
        "4" { $eaCodec = "opus"; $eaBr = Read-Host "  Bitrate Opus"; if ($eaBr -notmatch '^\d+[kK]$') { $eaBr = "128k" } }
        "5" { $eaCodec = "flac" }
        "6" { $eaCodec = "flac"; $fl = Read-Host "  Compression 0-12"; if ($fl -match '^\d+$' -and [int]$fl -le 12) { $eaFlvl = [int]$fl } }
        "7" { $eaCodec = "eac3"; $eaBr = "224k" }
        "8" {
            $eaCodec = "pcm"
            Write-Host "  LPCM: 1-16bit [impl] 2-24bit 3-32bit" -ForegroundColor Cyan
            $epd = Read-Host "  Alege [impl: 1]"
            switch ($epd) { "2" { $eaPcmDepth = "24le" } "3" { $eaPcmDepth = "32le" } default { $eaPcmDepth = "16le" } }
        }
    }
    # FLAC + mp4/mov
    if ($eaCodec -eq "flac" -and $eaContainer -ne "mkv") {
        Write-Host "  FLAC incompatibil cu $eaContainer. 1-MKV 2-AAC 192k" -ForegroundColor Red
        $ff = Read-Host "  Alege [impl: 1]"
        if ($ff -eq "2") { $eaCodec = "aac"; $eaBr = "192k" } else { $eaContainer = "mkv"; $eaFlags = @() }
    }
    # E-AC3 + mov
    if ($eaCodec -eq "eac3" -and $eaContainer -eq "mov") {
        Write-Host "  E-AC3 incompatibil cu mov. 1-MKV 2-MP4 3-AAC 192k" -ForegroundColor Red
        $ef = Read-Host "  Alege [impl: 1]"
        switch ($ef) {
            "2" { $eaContainer = "mp4"; $eaFlags = @("-movflags","+faststart") }
            "3" { $eaCodec = "aac"; $eaBr = "192k" }
            default { $eaContainer = "mkv"; $eaFlags = @() }
        }
    }
    # LPCM + mp4
    if ($eaCodec -eq "pcm" -and $eaContainer -eq "mp4") {
        Write-Host "  LPCM incompatibil cu mp4. 1-MKV 2-MOV 3-AAC 192k" -ForegroundColor Red
        $pf = Read-Host "  Alege [impl: 1]"
        switch ($pf) {
            "2" { $eaContainer = "mov"; $eaFlags = @("-movflags","+faststart") }
            "3" { $eaCodec = "aac"; $eaBr = "192k" }
            default { $eaContainer = "mkv"; $eaFlags = @() }
        }
    }
    # WebM: doar Opus/Vorbis audio suportat
    if ($eaContainer -eq "webm" -and $eaCodec -ne "opus") {
        Write-Host "  WebM suporta doar Opus audio. 1-Opus 128k [impl] 2-MKV" -ForegroundColor Red
        $wf = Read-Host "  Alege [impl: 1]"
        if ($wf -eq "2") { $eaContainer = "mkv"; $eaFlags = @() }
        else { $eaCodec = "opus"; $eaBr = "128k" }
    }

    Write-Host "`n--- Incep audio encode ---" -ForegroundColor Green
    $eaDone = 0; $eaErr = 0; $eaSkip = 0
    $eaLog = Join-Path $OutputDir "av_encode_log_audio.txt"
    foreach ($f in $inputFiles) {
        $eaDone++
        $name = $f.BaseName
        $outFile = Join-Path $OutputDir "${name}_audio.$eaContainer"
        Write-Host "`n── $($f.Name)" -ForegroundColor Yellow

        if ((Test-Path $outFile) -and (Get-Item $outFile).Length -gt 1MB) {
            Write-Host "  SKIP: output exista" -ForegroundColor DarkGray; $eaSkip++; $eaDone--; continue
        }
        if (Test-Path $outFile) { Remove-Item $outFile -Force }

        # Surround detect
        $eaCh = Get-FFprobeValue $f.FullName "a:0" "channels"
        $eaChN = if ($eaCh -match '^\d+$') { [int]$eaCh } else { 2 }
        $abr = $eaBr
        if ($eaCodec -eq "aac" -and $abr -eq "192k") {
            if ($eaChN -gt 6) { $abr = "768k" }
            elseif ($eaChN -gt 2) { $abr = "384k" }
        }
        if ($eaCodec -eq "opus" -and $abr -eq "128k") {
            if ($eaChN -gt 6) { $abr = "512k" }
            elseif ($eaChN -gt 2) { $abr = "256k" }
        }
        if ($eaCodec -eq "eac3" -and $abr -eq "224k") {
            if ($eaChN -gt 6) { $abr = "1024k" }
            elseif ($eaChN -gt 2) { $abr = "640k" }
        }

        $eaAP = switch ($eaCodec) {
            "aac"  { @("-c:a:0","aac","-b:a:0",$abr,"-c:a","copy") }
            "opus" { @("-c:a:0","libopus","-b:a:0",$abr,"-c:a","copy") }
            "flac" { @("-c:a:0","flac","-compression_level",$eaFlvl,"-c:a","copy") }
            "eac3" { @("-c:a:0","eac3","-b:a:0",$abr,"-c:a","copy") }
            "pcm"  { @("-c:a:0","pcm_s${eaPcmDepth}","-c:a","copy") }
        }
        Write-Host "  Audio: $eaCodec $abr | Canale: $eaChN" -ForegroundColor White

        # Avertizari metadata TrueHD/DTS
        $eaAudioCodecs = & ffprobe -v error -select_streams a `
            -show_entries stream=codec_name `
            -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null
        $eaAudioProfile = & ffprobe -v error -select_streams a `
            -show_entries stream=profile `
            -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null
        if ($eaAudioCodecs -match "truehd") {
            Write-Host "  ⚠ TrueHD detectat — metadata Atmos se va pierde la re-encode." -ForegroundColor Yellow
        }
        if ($eaAudioCodecs -match "dts") {
            if ($eaAudioProfile -match "DTS-HD MA|DTS:X") {
                Write-Host "  ⚠ DTS-HD MA / DTS:X detectat — metadata lossless/spatiala se va pierde." -ForegroundColor Yellow
            } else {
                Write-Host "  ⚠ DTS detectat — metadata se va pierde la re-encode." -ForegroundColor Yellow
            }
        }

        $eaArgs = @("-i",$f.FullName,"-map","0","-map_metadata","0","-map_chapters","0",
                     "-c:v","copy") + $eaAP + @("-c:s","copy","-c:t","copy") +
                  $eaFlags + @("-nostats",$outFile)
        & ffmpeg @eaArgs 2>>$eaLog

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outFile)) {
            Write-Host "  EROARE" -ForegroundColor Red; Remove-Item $outFile -Force -ErrorAction SilentlyContinue
            $eaErr++; $eaDone--
        } else {
            $ns = (Get-Item $outFile).Length
            Write-Host "  OK — $(Format-Bytes $ns)" -ForegroundColor Green
        }
    }
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "FINALIZAT — $eaDone procesate, $eaErr erori, $eaSkip sarite" -ForegroundColor Green
    Read-Host; exit
}

if ($mainChoice -eq "3") {
    Write-Host "`n===== ANALIZA FISIERE MEDIA =====" -ForegroundColor Cyan
    $csvPath = Join-Path $OutputDir "av_check_report.csv"
    "Fisier,FormatSursa,Dimensiune(MB),Durata(sec),Rezolutie,PixelFmt,FPS,Bitrate_video(Mbps),TipHDR,Profil_DV,LogProfile,AudioCodec,AudioBitrate(kbps),SampleRate(kHz),BitDepth,Layout,Limba,Canale_audio,AudioTrackuri,Subtitrari,Capitole,Attachments,DJI_djmd,DJI_dbgi,DJI_TC,Recomandat_encoder,Est_x265,Est_x264,Est_AV1,Est_ProRes" |
        Out-File $csvPath -Encoding UTF8

    foreach ($f in $inputFiles) {
        Write-Host ""
        Write-Host "─────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "Fisier: $($f.Name)" -ForegroundColor Yellow
        Write-Host "─────────────────────────────────────────" -ForegroundColor DarkGray

        $si       = Get-SourceInfo $f.FullName
        $w        = Get-FFprobeValue $f.FullName "v:0" "width"
        $h        = Get-FFprobeValue $f.FullName "v:0" "height"
        $ac       = Get-FFprobeValue $f.FullName "a:0" "codec_name"
        $ab       = Get-FFprobeValue $f.FullName "a:0" "bit_rate"
        $abk      = if ($ab -match '^\d+$') { [math]::Round([long]$ab / 1000) } else { "N/A" }
        $audioChannelsRaw = Get-FFprobeValue $f.FullName "a:0" "channels"
        $audioChannels = if ($audioChannelsRaw -match '^\d+$') { $audioChannelsRaw } else { "N/A" }
        $audioSR  = Get-FFprobeValue $f.FullName "a:0" "sample_rate"
        $audioSRk = if ($audioSR -match '^\d+$') { [math]::Round([long]$audioSR / 1000, 1) } else { "N/A" }
        $audioBD  = Get-FFprobeValue $f.FullName "a:0" "bits_per_raw_sample"
        if (-not $audioBD -or $audioBD -eq "0") { $audioBD = Get-FFprobeValue $f.FullName "a:0" "bits_per_sample" }
        if (-not $audioBD -or $audioBD -eq "0") { $audioBD = "N/A" }
        $audioLayout = Get-FFprobeValue $f.FullName "a:0" "channel_layout"
        if (-not $audioLayout) {
            $audioLayout = switch ($audioChannels) { "1"{"mono"} "2"{"stereo"} "6"{"5.1"} "8"{"7.1"} default{"${audioChannels}ch"} }
        }
        $audioLangRaw = & ffprobe -v error -select_streams a:0 -show_entries stream_tags=language -of csv=p=0 $f.FullName 2>$null | Select-Object -First 1
        $audioLang = if ($audioLangRaw) { $audioLangRaw.Trim() } else { "und" }
        $fsMB     = [math]::Round($f.Length / 1MB, 1)
        $fpsRaw   = Get-FFprobeValue $f.FullName "v:0" "avg_frame_rate"
        $bitrateRaw = Get-FFprobeValue $f.FullName "v:0" "bit_rate"
        $bitrateMbps = if ($bitrateRaw -match '^\d+$') {
            [math]::Round([long]$bitrateRaw / 1000000, 2)
        } else { "N/A" }
        $durRaw   = & ffprobe -v error -show_entries format=duration `
            -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null
        $durSec   = if ($durRaw -match '^\d+') { [int]([double]$durRaw) } else { 0 }

        # FIX: validare stream video — skip daca lipseste
        if (-not $si.fmt -or $si.fmt -eq " 8bit") {
            Write-Host "  ATENTIE: Nu s-a gasit stream video valid — sarit." -ForegroundColor Red
            continue
        }

        $srcCodec = $si.codec   # reutilizeaza Get-SourceInfo — fara ffprobe duplicat
        $srcFmt   = $si.fmt
        $pixFmt   = $si.pixFmt  # FIX: reutilizeaza pixFmt din Get-SourceInfo — elimina al doilea ffprobe

        # FIX: audio track count cu Where-Object { $_ } ignora linii goale
        $audioTracks = (& ffprobe -v error -select_streams a `
            -show_entries stream=index -of csv=p=0 $f.FullName 2>$null |
            Where-Object { $_ -match '^\d' }).Count

        # Subtitrari cu limbi
        $subStreams = & ffprobe -v error -select_streams s `
            -show_entries stream=index:stream_tags=language `
            -of default=noprint_wrappers=1 $f.FullName 2>$null
        $subCount = ($subStreams | Where-Object { $_ -match "^index=" }).Count
        $subLangs = ($subStreams | Where-Object { $_ -match "^TAG:language=" } |
            ForEach-Object { $_ -replace "TAG:language=","" } |
            Where-Object { $_ -ne "und" }) -join "/"
        $subStr = if ($subCount -gt 0) {
            if ($subLangs) { "$subCount ($subLangs)" } else { "$subCount" }
        } else { "Nu" }

        # Capitole
        $chapCount = (& ffprobe -v error -show_chapters $f.FullName 2>$null |
            Where-Object { $_ -match "^\[CHAPTER\]" }).Count
        $chapStr = if ($chapCount -gt 0) { "$chapCount capitole" } else { "Nu" }

        # Attachments
        $attStreams = & ffprobe -v error -select_streams t `
            -show_entries stream=index:stream_tags=mimetype `
            -of default=noprint_wrappers=1 $f.FullName 2>$null
        $attCount = ($attStreams | Where-Object { $_ -match "^index=" }).Count
        $attMimes = ($attStreams | Where-Object { $_ -match "^TAG:mimetype=" } |
            ForEach-Object { $_ -replace "TAG:mimetype=","" } |
            Select-Object -Unique) -join ", "
        $attStr = if ($attCount -gt 0) {
            if ($attMimes) { "$attCount ($attMimes)" } else { "$attCount" }
        } else { "Nu" }

        $dji = Get-DJITracks $f.FullName

        # DV detectat din codec_tag_string (stream-level, nu din frames)
        $doVi = & ffprobe -v error -show_entries stream=codec_tag_string `
            -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null |
            Select-String -Pattern "dovi|dvhe|dvh1" -CaseSensitive:$false
        $tipHdr = "SDR"; $dvProf = "N/A"
        if     ($si.isHDRPlus) { $tipHdr = "HDR10+" }
        elseif ($si.isHDR)     { $tipHdr = "HDR10"  }
        if ($doVi) { $tipHdr = "Dolby Vision"; $dvProf = Get-DVProfile $f.FullName }

        # LOG Profile detect (reuse Get-SourceInfoExtended)
        $chkLogInfo = Get-SourceInfoExtended $f.FullName $dji
        $chkLogProfile = if ($chkLogInfo.logProfile) { Get-LogProfileLabel $chkLogInfo.logProfile } else { "N/A" }

        # Recomandare encoder
        $encRec = "libx265 (optiune sigura universala)"
        if     ($tipHdr -eq "Dolby Vision")                          { $encRec = "libx265 (singurul care suporta DV)" }
        elseif ($tipHdr -eq "HDR10+")                                { $encRec = "libx265 sau AV1/SVT (ambele suporta HDR10+)" }
        elseif ($tipHdr -eq "HDR10")                                 { $encRec = "libx265 sau AV1/SVT (ambele suporta HDR10)" }
        elseif ($dji.isDji)                                          { $encRec = "libx265 (fisier DJI — metadata pastrate)" }
        elseif ($srcCodec -eq "av1")                                 { $encRec = "Deja AV1 — re-encode nu e recomandat" }
        elseif ($srcCodec -eq "prores")                              { $encRec = "libx265 sau AV1 (ProRes→compresie ~70-80% mai mic)" }
        elseif ($srcCodec -eq "hevc" -and $tipHdr -eq "SDR")         { $encRec = "AV1/SVT (HEVC→AV1 ~20-30% mai mic)" }
        elseif ($srcCodec -eq "h264")                                { $encRec = "libx265 (H.264→H.265 ~40% mai mic) sau AV1 (~50%)" }

        # Estimare dimensiune output
        $bpsX265 = if ([int]$w -ge 3840) { 10000000 } elseif ([int]$w -ge 1920) { 4000000 } else { 2000000 }
        $bpsX264 = if ([int]$w -ge 3840) { 12000000 } elseif ([int]$w -ge 1920) { 5000000 } else { 2500000 }
        $bpsAV1  = if ([int]$w -ge 3840) { 8000000  } elseif ([int]$w -ge 1920) { 3000000 } else { 1500000 }
        # ProRes bitrate fix per profil (HQ default ~220 Mbps)
        $bpsProRes = if ([int]$w -ge 3840) { 880000000 } elseif ([int]$w -ge 1920) { 220000000 } else { 110000000 }
        if ($tipHdr -match "HDR|Dolby") { $bpsX265 = [int]($bpsX265 * 1.3); $bpsAV1 = [int]($bpsAV1 * 1.3) }
        $estX265 = Get-SizeEst $bpsX265 $durSec
        $estX264 = Get-SizeEst $bpsX264 $durSec
        $estAV1  = Get-SizeEst $bpsAV1  $durSec
        $estProRes = Get-SizeEst $bpsProRes $durSec

        # Output terminal
        Write-Host "  Format sursa : $srcFmt"           -ForegroundColor White
        Write-Host "  Dimensiune   : $fsMB MB"          -ForegroundColor White
        Write-Host "  Durata       : $durSec sec"        -ForegroundColor White
        Write-Host "  Rezolutie    : ${w}x${h}"         -ForegroundColor White
        Write-Host "  FPS          : $fpsRaw"            -ForegroundColor White
        Write-Host "  Bitrate video: $bitrateMbps Mb/s" -ForegroundColor White
        Write-Host "  Tip HDR      : $tipHdr" -ForegroundColor $(if ($tipHdr -ne "SDR") { "Magenta" } else { "White" })
        if ($doVi) { Write-Host "  Profil DV    : $dvProf" -ForegroundColor Magenta }
        if ($chkLogProfile -ne "N/A") { Write-Host "  LOG Profile  : $chkLogProfile" -ForegroundColor Yellow }
        Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray
        if ($audioTracks -gt 1) {
            Write-Host "  Audio (main) : $ac | $abk kbps | ${audioSRk} kHz | ${audioBD}bit | $audioLayout | $audioLang | $audioTracks track-uri" -ForegroundColor White
        } else {
            Write-Host "  Audio        : $ac | $abk kbps | ${audioSRk} kHz | ${audioBD}bit | $audioLayout | $audioLang" -ForegroundColor White
        }
        Write-Host "  Subtitrari   : $subStr"  -ForegroundColor $(if ($subCount -gt 0) { "Green" } else { "Gray" })
        Write-Host "  Capitole     : $chapStr" -ForegroundColor $(if ($chapCount -gt 0) { "Green" } else { "Gray" })
        Write-Host "  Attachments  : $attStr"  -ForegroundColor $(if ($attCount -gt 0) { "Green" } else { "Gray" })
        if ($dji.isDji) {
            Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray
            Write-Host "  DJI tracks   :" -ForegroundColor Yellow
            if ($dji.hasDjmd)  { Write-Host "    ✅ djmd  — GPS, telemetrie, setari camera" -ForegroundColor Green }
            if ($dji.hasDbgi)  { Write-Host "    ⚠️  dbgi  — date debug (~295 MB)"          -ForegroundColor Yellow }
            if ($dji.hasTC)    { Write-Host "    ✅ Timecode — sincronizare profesionala"   -ForegroundColor Green }
        }
        Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Recomandat   : $encRec" -ForegroundColor Cyan
        Write-Host "  Estimare output (aproximativ, preset medium):" -ForegroundColor White
        Write-Host "    x265   : $estX265" -ForegroundColor White
        Write-Host "    x264   : $estX264" -ForegroundColor White
        Write-Host "    AV1    : $estAV1"  -ForegroundColor Green
        Write-Host "    ProRes : $estProRes (HQ ~220 Mbps)" -ForegroundColor White

        # CSV — 30 campuri (extins cu LogProfile, Est_ProRes)
        "$($f.Name),$srcFmt,$fsMB,$durSec,${w}x${h},$pixFmt,$fpsRaw,$bitrateMbps,$tipHdr,$dvProf,$chkLogProfile,$ac,$abk,$audioSRk,$audioBD,$audioLayout,$audioLang,$audioChannels,$audioTracks,$subStr,$chapStr,$attStr,$($dji.hasDjmd),$($dji.hasDbgi),$($dji.hasTC),`"$encRec`",$estX265,$estX264,$estAV1,$estProRes" |
            Out-File $csvPath -Append -Encoding UTF8
    }
    Write-Host ""
    Write-Host "CSV: $csvPath" -ForegroundColor Green

    # ── Comparatie Input vs Output ────────────────────────────────────
    $outFiles = Get-ChildItem -Path $OutputDir -Include "*.mp4","*.mov","*.mkv","*.mxf","*.webm" -File -ErrorAction SilentlyContinue
    if ($outFiles -and $outFiles.Count -gt 0) {
        Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        Write-Host "COMPARATIE INPUT vs OUTPUT" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        $compCount = 0; $compTotalOrig = 0L; $compTotalNew = 0L
        foreach ($of in $outFiles) {
            $baseName = $of.BaseName
            foreach ($sfx in @("_x265","_x264","_av1","_dnxhr","_prores","_audio","_hwenc")) {
                $baseName = $baseName -replace [regex]::Escape($sfx),""
            }
            $origFound = $null
            foreach ($ext in @("mp4","mov","mkv","m2ts","mts","vob","mxf","apv")) {
                $candidate = Join-Path $InputDir "$baseName.$ext"
                if (Test-Path $candidate) { $origFound = Get-Item $candidate; break }
            }
            if ($origFound) {
                $compCount++
                $origSize = $origFound.Length; $newSize = $of.Length
                $compTotalOrig += $origSize; $compTotalNew += $newSize
                $ratio = if ($origSize -gt 0) { [math]::Round($newSize * 100.0 / $origSize, 1) } else { "N/A" }
                $savedMB = [math]::Max(0, [int](($origSize - $newSize) / 1MB))
                Write-Host "  $baseName" -ForegroundColor White
                Write-Host "    $(Format-Bytes $origSize) → $(Format-Bytes $newSize) | ${ratio}% | Salvat: ${savedMB} MB" -ForegroundColor Green
            }
        }
        if ($compCount -gt 0) {
            Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray
            $totalRatio = if ($compTotalOrig -gt 0) { [math]::Round($compTotalNew * 100.0 / $compTotalOrig, 1) } else { "N/A" }
            Write-Host "  TOTAL: $(Format-Bytes $compTotalOrig) → $(Format-Bytes $compTotalNew) | ${totalRatio}% | Perechi: $compCount" -ForegroundColor Cyan
        }
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    }

    Read-Host "Apasa Enter"; exit
}

# ── Profil salvat (load) ─────────────────────────────────────────────
$profileDir = Join-Path $InputDir "Profiles"
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
$profiles = Get-ChildItem -Path $profileDir -Filter "*.conf" -ErrorAction SilentlyContinue
$profLoaded = $false

if ($profiles.Count -gt 0) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Profile salvate disponibile          ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════╣" -ForegroundColor Cyan
    $pIdx = 1
    foreach ($pf in $profiles) {
        Write-Host "║  $pIdx) $($pf.BaseName)" -ForegroundColor White
        $pIdx++
    }
    Write-Host "║  N) Configurare noua (meniu normal)  ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
    $profChoice = Read-Host "Alege profil sau N [implicit: N]"
    if ($profChoice -match '^\d+$' -and [int]$profChoice -ge 1 -and [int]$profChoice -le $profiles.Count) {
        $loadFile = $profiles[[int]$profChoice - 1].FullName
        Write-Host "  Incarc profil: $($profiles[[int]$profChoice - 1].BaseName)" -ForegroundColor Green
        # Parse .conf (key=value)
        Get-Content $loadFile | ForEach-Object {
            if ($_ -match '^([A-Za-z_]\w*)=(.*)$') {
                Set-Variable -Name $Matches[1] -Value $Matches[2] -Scope Script
            }
        }
        # Map loaded vars to ps1 variables
        $useX264  = ($ENCODER -eq "libx264")
        $useAV1   = ($ENCODER -eq "av1")
        $useDNxHR = ($ENCODER -eq "dnxhr")
        $useProRes = ($ENCODER -eq "prores")
        $useHWEnc  = ($ENCODER -eq "hwenc")
        $av1Impl  = if ($AV1_IMPL) { $AV1_IMPL } else { "libsvtav1" }
        $container = $CONTAINER
        $scaleWidth = if ($SCALE_WIDTH) { [int]$SCALE_WIDTH } else { $null }
        $targetFps = $TARGET_FPS
        $fpsMethod = $FPS_METHOD
        $vfPreset = $VF_PRESET
        $vfIsVidstab = ($VF_PRESET -eq "vidstab")
        $vfIsUpscale4K = ($VF_PRESET -match "scale=3840")
        if ($vfIsVidstab) { $vfPreset = $null }
        $audioCodec = $AUDIO_CODEC
        $audioBitrate = $AUDIO_BITRATE
        $audioCopy = ($AUDIO_COPY -eq "1")
        $audioFlacLevel = if ($AUDIO_FLAC_LEVEL) { $AUDIO_FLAC_LEVEL } else { "8" }
        $pcmDepth = if ($PCM_DEPTH) { $PCM_DEPTH } else { "16le" }
        $audioNormalize = ($AUDIO_NORMALIZE -eq "1")
        $encMode = if ($ENCODE_MODE) { $ENCODE_MODE } else { "1" }
        $customCrf = $CUSTOM_CRF
        $selectedPreset = if ($PRESET) { $PRESET } else { "slow" }
        $selectedTune = $TUNE
        $extraParams = $EXTRA_PARAMS
        $vbrTarget = $VBR_TARGET
        $vbrMaxrate = $VBR_MAXRATE
        $vbrBufsize = $VBR_BUFSIZE
        $dnxhrProfile = if ($DNXHR_PROFILE) { $DNXHR_PROFILE } else { "sq" }
        $proresProfile = if ($PRORES_PROFILE) { $PRORES_PROFILE } else { "hq" }
        $x264ProfileGlobal = if ($X264_PROFILE) { $X264_PROFILE } else { "auto" }
        $forceLogDetection = ($FORCE_LOG_DETECTION -eq "1")
        $interactiveMode = ($INTERACTIVE_MODE -eq "1")
        $hwEncCodec  = if ($HW_ENC_CODEC)  { $HW_ENC_CODEC }  else { "" }
        $hwEncPreset = if ($HW_ENC_PRESET) { $HW_ENC_PRESET } else { "" }
        $hwEncQP     = if ($HW_ENC_QP)     { $HW_ENC_QP }     else { "23" }
        $hwEncName   = $hwEncCodec

        $encoderName = if ($useX264) { "libx264" } elseif ($useAV1) { "av1 ($av1Impl)" } elseif ($useDNxHR) { "dnxhr" } elseif ($useProRes) { "prores ($proresProfile)" } elseif ($useHWEnc) { $hwEncName } else { "libx265" }
        $outSuffix   = if ($useX264) { "_x264" } elseif ($useAV1) { "_av1" } elseif ($useDNxHR) { "_dnxhr" } elseif ($useProRes) { "_prores" } elseif ($useHWEnc) { "_hwenc" } else { "_x265" }
        $containerFlags = Get-ContainerFlags $container
        $LogFile = Join-Path $OutputDir "av_encode_log_$encoderName.txt"

        Write-Host "  Encoder      : $encoderName" -ForegroundColor White
        Write-Host "  Container    : $container" -ForegroundColor White
        Write-Host "  Audio        : $audioCodec $audioBitrate" -ForegroundColor White
        Write-Host "  Filtru video : $(if ($vfPreset) { $vfPreset } elseif ($vfIsVidstab) { 'vidstab' } else { 'fara' })" -ForegroundColor White
        Write-Host "  Normalizare  : $audioNormalize" -ForegroundColor White
        if ($forceLogDetection) { Write-Host "  Force LOG    : ACTIV" -ForegroundColor Yellow }
        if ($interactiveMode) { Write-Host "  Interactiv   : ACTIV" -ForegroundColor Green }
        $profConfirm = Read-Host "Lanseaza cu aceste setari? (D/n)"
        if ($profConfirm -ine "n") {
            $profLoaded = $true
        } else {
            Write-Host "  Profil anulat — continuam cu meniu normal." -ForegroundColor Yellow
        }
    }
}

if (-not $profLoaded) {
# ── Configurare encoder ───────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  1-libx265  H.265/HEVC [implicit]        ║" -ForegroundColor Cyan
Write-Host "║  2-libx264  H.264/AVC                    ║" -ForegroundColor Cyan
Write-Host "║  3-AV1      codec viitor, compresie max  ║" -ForegroundColor Cyan
Write-Host "║  4-DNxHR    Avid mezzanine, lossless     ║" -ForegroundColor Cyan
Write-Host "║  5-ProRes   Apple profesional (mov)       ║" -ForegroundColor Cyan
Write-Host "║  6-HW Encode  GPU accelerat (NVENC/QSV)  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
$encChoice = Read-Host "Alege 1-6 [implicit: 1]"
$useX264  = ($encChoice -eq "2")
$useAV1   = ($encChoice -eq "3")
$useDNxHR = ($encChoice -eq "4")
$useProRes = ($encChoice -eq "5")
$useHWEnc  = ($encChoice -eq "6")
$av1Impl  = "libsvtav1"
if ($useAV1) {
    Write-Host "  1-libsvtav1 rapid [implicit]  2-libaom-av1 calitate maxima" -ForegroundColor Cyan
    $av1Choice = Read-Host "  Alege [implicit: 1]"
    $av1Impl = if ($av1Choice -eq "2") { "libaom-av1" } else { "libsvtav1" }
    Write-Host "  AV1: $av1Impl" -ForegroundColor Green
}
$dnxhrProfile = "sq"
if ($useDNxHR) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Profil DNxHR                        ║" -ForegroundColor Cyan
    Write-Host "║  1-LB  ~45 Mbps  offline edit        ║" -ForegroundColor White
    Write-Host "║  2-SQ  ~145 Mbps standard [implicit] ║" -ForegroundColor White
    Write-Host "║  3-HQ  ~220 Mbps high quality        ║" -ForegroundColor White
    Write-Host "║  4-HQX ~220 Mbps 12-bit HDR          ║" -ForegroundColor White
    Write-Host "║  5-444 ~440 Mbps 4:4:4 grading       ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
    $dnxhrChoice = Read-Host "Alege 1-5 [implicit: 2]"
    $dnxhrProfile = switch ($dnxhrChoice) {
        "1" { "lb" } "3" { "hq" } "4" { "hqx" } "5" { "444" } default { "sq" }
    }
    $dnxhrLabel = switch ($dnxhrProfile) {
        "lb"  { "DNxHR LB (~45 Mbps)"  }
        "hq"  { "DNxHR HQ (~220 Mbps)" }
        "hqx" { "DNxHR HQX (~220 Mbps, 12-bit HDR)" }
        "444" { "DNxHR 444 (~440 Mbps, 4:4:4)" }
        default { "DNxHR SQ (~145 Mbps)" }
    }
    Write-Host "  Profil: $dnxhrLabel" -ForegroundColor Green
}
$proresProfile = "hq"
if ($useProRes) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Profil ProRes                       ║" -ForegroundColor Cyan
    Write-Host "║  1-Proxy    ~45 Mbps  offline        ║" -ForegroundColor White
    Write-Host "║  2-LT       ~100 Mbps  light         ║" -ForegroundColor White
    Write-Host "║  3-Standard ~145 Mbps                ║" -ForegroundColor White
    Write-Host "║  4-HQ       ~220 Mbps [implicit]     ║" -ForegroundColor White
    Write-Host "║  5-4444     ~330 Mbps  alpha          ║" -ForegroundColor White
    Write-Host "║  6-4444 XQ  ~500 Mbps  maxim          ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
    $proresChoice = Read-Host "Alege 1-6 [implicit: 4]"
    $proresProfile = switch ($proresChoice) {
        "1" { "proxy" } "2" { "lt" } "3" { "standard" } "5" { "4444" } "6" { "xq" } default { "hq" }
    }
    $proresLabel = switch ($proresProfile) {
        "proxy"    { "ProRes Proxy (~45 Mbps)" }
        "lt"       { "ProRes LT (~100 Mbps)" }
        "standard" { "ProRes Standard (~145 Mbps)" }
        "4444"     { "ProRes 4444 (~330 Mbps, alpha)" }
        "xq"       { "ProRes 4444 XQ (~500 Mbps)" }
        default    { "ProRes HQ (~220 Mbps)" }
    }
    Write-Host "  Profil: $proresLabel" -ForegroundColor Green
}
$hwEncCodec = ""; $hwEncName = ""; $hwEncPreset = ""; $hwEncQP = ""
if ($useHWEnc) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  HW ENCODE — Detectie GPU                ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════╣" -ForegroundColor Cyan
    # Detect available HW encoders
    $hwEncoders = & ffmpeg -encoders 2>$null | Out-String
    $hwAvail = @()
    if ($hwEncoders -match "hevc_nvenc")  { $hwAvail += @{id="hevc_nvenc";  label="NVIDIA NVENC H.265"; codec="hevc"} }
    if ($hwEncoders -match "h264_nvenc")  { $hwAvail += @{id="h264_nvenc";  label="NVIDIA NVENC H.264"; codec="h264"} }
    if ($hwEncoders -match "av1_nvenc")   { $hwAvail += @{id="av1_nvenc";   label="NVIDIA NVENC AV1";   codec="av1"} }
    if ($hwEncoders -match "hevc_qsv")    { $hwAvail += @{id="hevc_qsv";   label="Intel QSV H.265";    codec="hevc"} }
    if ($hwEncoders -match "h264_qsv")    { $hwAvail += @{id="h264_qsv";   label="Intel QSV H.264";    codec="h264"} }
    if ($hwEncoders -match "av1_qsv")     { $hwAvail += @{id="av1_qsv";    label="Intel QSV AV1";      codec="av1"} }
    if ($hwEncoders -match "hevc_amf")    { $hwAvail += @{id="hevc_amf";   label="AMD AMF H.265";      codec="hevc"} }
    if ($hwEncoders -match "h264_amf")    { $hwAvail += @{id="h264_amf";   label="AMD AMF H.264";      codec="h264"} }
    if ($hwAvail.Count -eq 0) {
        Write-Host "║  NU s-au gasit encodere GPU!             ║" -ForegroundColor Red
        Write-Host "║  Necesita: NVIDIA GPU + drivers CUDA     ║" -ForegroundColor Yellow
        Write-Host "║           sau Intel iGPU + drivers QSV   ║" -ForegroundColor Yellow
        Write-Host "║           sau AMD GPU + drivers AMF      ║" -ForegroundColor Yellow
        Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
        Read-Host; exit
    }
    for ($hi = 0; $hi -lt $hwAvail.Count; $hi++) {
        Write-Host ("║  {0}) {1,-37}║" -f ($hi+1), $hwAvail[$hi].label) -ForegroundColor White
    }
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    $hwChoice = Read-Host "Alege [implicit: 1]"
    if (-not $hwChoice) { $hwChoice = "1" }
    $hwIdx = [int]$hwChoice - 1
    if ($hwIdx -lt 0 -or $hwIdx -ge $hwAvail.Count) { $hwIdx = 0 }
    $hwEncCodec = $hwAvail[$hwIdx].id
    $hwEncName  = $hwAvail[$hwIdx].label
    Write-Host "  HW Encoder: $hwEncName" -ForegroundColor Green

    # Preset
    Write-Host ""
    if ($hwEncCodec -match "nvenc") {
        Write-Host "Preset NVENC: 1-p1(fastest) 2-p2 3-p3 4-p4(medium) 5-p5 6-p6 7-p7(slowest/best)" -ForegroundColor Cyan
        $hwpc = Read-Host "Alege [implicit: 4]"
        $hwEncPreset = switch ($hwpc) { "1"{"p1"} "2"{"p2"} "3"{"p3"} "5"{"p5"} "6"{"p6"} "7"{"p7"} default{"p4"} }
    } elseif ($hwEncCodec -match "qsv") {
        Write-Host "Preset QSV: 1-veryfast 2-fast 3-medium 4-slow 5-veryslow" -ForegroundColor Cyan
        $hwpc = Read-Host "Alege [implicit: 3]"
        $hwEncPreset = switch ($hwpc) { "1"{"veryfast"} "2"{"fast"} "4"{"slow"} "5"{"veryslow"} default{"medium"} }
    } else {
        Write-Host "Preset AMF: 1-speed 2-balanced 3-quality" -ForegroundColor Cyan
        $hwpc = Read-Host "Alege [implicit: 2]"
        $hwEncPreset = switch ($hwpc) { "1"{"speed"} "3"{"quality"} default{"balanced"} }
    }
    Write-Host "  Preset: $hwEncPreset" -ForegroundColor Green

    # Quality (QP/CQ)
    Write-Host ""
    Write-Host "Calitate: A-Auto (CQ 23)  B-Custom QP" -ForegroundColor Cyan
    $hwqc = Read-Host "Alege [implicit: A]"
    if ($hwqc -ieq "B") {
        $hwEncQP = Read-Host "QP (0-51, recomandat 18-28)"
        if ($hwEncQP -notmatch '^\d+$' -or [int]$hwEncQP -gt 51) { $hwEncQP = "23" }
    } else { $hwEncQP = "23" }
    Write-Host "  QP: $hwEncQP" -ForegroundColor Green
}

# ── Runtime checks ──────────────────────────────────────────────────
$rtEncoder = if ($useX264) { "libx264" } elseif ($useAV1) { $av1Impl } elseif ($useDNxHR) { "dnxhd" } elseif ($useProRes) { "prores_ks" } elseif ($useHWEnc) { $hwEncCodec } else { "libx265" }
if (-not $useHWEnc) {
    if (-not (Test-EncoderAvailable $rtEncoder)) {
        Write-Host "[EROARE] $rtEncoder nu este disponibil in ffmpeg!" -ForegroundColor Red
        Write-Host "Verifica ffmpeg build (ffmpeg -encoders)." -ForegroundColor Yellow
        Read-Host; exit
    }
    Write-Host "  [OK] $rtEncoder disponibil" -ForegroundColor Green
} else {
    Write-Host "  [OK] $hwEncCodec detectat" -ForegroundColor Green
}

$encoderName = if ($useX264) { "libx264" } elseif ($useAV1) { "av1 ($av1Impl)" } elseif ($useDNxHR) { "dnxhr" } elseif ($useProRes) { "prores ($proresProfile)" } elseif ($useHWEnc) { $hwEncName } else { "libx265" }
$outSuffix   = if ($useX264) { "_x264" } elseif ($useAV1) { "_av1" } elseif ($useDNxHR) { "_dnxhr" } elseif ($useProRes) { "_prores" } elseif ($useHWEnc) { "_hwenc" } else { "_x265" }
Write-Host "  Encoder: $encoderName" -ForegroundColor Green

$x264ProfileGlobal = "auto"
if ($useX264) {
    Write-Host "Profil x264: 1-high  2-high10  3-high422  A-Auto [recomandat]" -ForegroundColor Cyan
    $pc = Read-Host "Alege [implicit: A]"
    $x264ProfileGlobal = switch ($pc) { "1"{"high"} "2"{"high10"} "3"{"high422"} default{"auto"} }
    Write-Host "  Profil: $x264ProfileGlobal" -ForegroundColor Green
}

Write-Host ""
if ($useProRes) {
    # ProRes: container obligatoriu mov
    $container = "mov"
    Write-Host "  Container: mov (obligatoriu pentru ProRes)" -ForegroundColor Green
} elseif ($useDNxHR) {
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Container DNxHR                         ║" -ForegroundColor Cyan
    Write-Host "║  1-mov  QuickTime [implicit]              ║" -ForegroundColor White
    Write-Host "║  2-mxf  Avid native                      ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    $contChoice = Read-Host "Alege 1 sau 2 [implicit: 1]"
    $container  = if ($contChoice -eq "2") { "mxf" } else { "mov" }
} elseif ($useAV1) {
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  1-mp4  compatibil maxim                 ║" -ForegroundColor Cyan
    Write-Host "║  2-mkv  flexibil [implicit]              ║" -ForegroundColor Cyan
    Write-Host "║  3-webm WebM (AV1 nativ, web)           ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    $contChoice = Read-Host "Alege [implicit: 2]"
    $container  = switch ($contChoice) { "1"{"mp4"} "3"{"webm"} default{"mkv"} }
} else {
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  1-mp4  compatibil maxim                 ║" -ForegroundColor Cyan
    Write-Host "║  2-mkv  flexibil, suporta DV [implicit]  ║" -ForegroundColor Cyan
    Write-Host "║  3-mov  Apple / Final Cut                ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    $contChoice = Read-Host "Alege [implicit: 2]"
    $container  = switch ($contChoice) { "1"{"mp4"} "3"{"mov"} default{"mkv"} }
}
Write-Host "  Container: $container" -ForegroundColor Green
$containerFlags = Get-ContainerFlags $container
$LogFile = Join-Path $OutputDir "av_encode_log_$encoderName.txt"

# ── Rezolutie output ──────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Rezolutie output                    ║" -ForegroundColor Cyan
Write-Host "║  1) Pastreaza originala [implicit]   ║" -ForegroundColor White
Write-Host "║  2) 3840 — 4K UHD                   ║" -ForegroundColor White
Write-Host "║  3) 2560 — 2K / 1440p               ║" -ForegroundColor White
Write-Host "║  4) 1920 — Full HD 1080p            ║" -ForegroundColor White
Write-Host "║  5) 1280 — HD 720p                  ║" -ForegroundColor White
Write-Host "║  6) Custom (introdu width)           ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
$resChoice = Read-Host "Alege 1-6 [implicit: 1]"
$scaleWidth = switch ($resChoice) {
    "2" { 3840 } "3" { 2560 } "4" { 1920 } "5" { 1280 }
    "6" {
        $cw = Read-Host "  Introdu width (minim 320, numar par)"
        if ($cw -match '^\d+$' -and [int]$cw -ge 320) {
            $v = [int]$cw
            if ($v % 2 -ne 0) { $v++; Write-Host "  Ajustat la $v (trebuie sa fie par)" -ForegroundColor Yellow }
            $v
        } else {
            Write-Host "  Valoare invalida — se pastreaza rezolutia originala." -ForegroundColor Yellow
            $null
        }
    }
    default { $null }
}
if ($scaleWidth) {
    Write-Host "  Rezolutie: scale la ${scaleWidth}px width (aspect ratio pastrat)" -ForegroundColor Green
} else {
    Write-Host "  Rezolutie: originala (fara resize)" -ForegroundColor White
}

# ── FPS output ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Frame rate output                   ║" -ForegroundColor Cyan
Write-Host "║  1) Pastreaza original [implicit]    ║" -ForegroundColor White
Write-Host "║  2) 60 fps                           ║" -ForegroundColor White
Write-Host "║  3) 50 fps                           ║" -ForegroundColor White
Write-Host "║  4) 30 fps                           ║" -ForegroundColor White
Write-Host "║  5) 25 fps (PAL)                     ║" -ForegroundColor White
Write-Host "║  6) 24 fps (cinematic)               ║" -ForegroundColor White
Write-Host "║  7) 23.976 fps (Blu-ray/Netflix)     ║" -ForegroundColor White
Write-Host "║  8) Custom                            ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
$fpsChoice = Read-Host "Alege 1-8 [implicit: 1]"
$targetFps = switch ($fpsChoice) {
    "2" { "60" } "3" { "50" } "4" { "30" } "5" { "25" } "6" { "24" } "7" { "24000/1001" }
    "8" {
        $cf = Read-Host "  Introdu FPS (ex: 29.97, 48, 120)"
        if ($cf -match '^[\d./]+$') { $cf } else { Write-Host "  Valoare invalida — FPS original." -ForegroundColor Yellow; $null }
    }
    default { $null }
}
$fpsMethod = $null
if ($targetFps) {
    Write-Host "  Metoda: 1-Drop/duplicate [impl]  2-Motion interpolation (lent)" -ForegroundColor Cyan
    $fmChoice = Read-Host "  Alege [implicit: 1]"
    $fpsMethod = if ($fmChoice -eq "2") { "minterpolate" } else { "drop" }
    Write-Host "  FPS: $targetFps ($fpsMethod)" -ForegroundColor Green
} else {
    Write-Host "  FPS: original (fara conversie)" -ForegroundColor White
}

# ── Filtre video (optional) ──────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Filtre video (optional)             ║" -ForegroundColor Cyan
Write-Host "║  1) Fara filtre [implicit]           ║" -ForegroundColor White
Write-Host "║  2) Denoise light  (nlmeans h=1.0)   ║" -ForegroundColor White
Write-Host "║  3) Denoise medium (hqdn3d rapid)    ║" -ForegroundColor White
Write-Host "║  4) Denoise strong (nlmeans h=3.0)   ║" -ForegroundColor White
Write-Host "║  5) Sharpen light  (unsharp)         ║" -ForegroundColor White
Write-Host "║  6) Sharpen medium (CAS)             ║" -ForegroundColor White
Write-Host "║  7) Deinterlace    (bwdif)           ║" -ForegroundColor White
Write-Host "║  8) Custom (scrii filtrul manual)    ║" -ForegroundColor White
Write-Host "║  9) Upscale 4K    (lanczos)          ║" -ForegroundColor White
Write-Host "║ 10) Stabilizare   (vidstab 2-pass)   ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
$vfChoice = Read-Host "Alege 1-10 [implicit: 1]"
$vfIsVidstab = $false
$vfIsUpscale4K = $false
$vfPreset = switch ($vfChoice) {
    "2" { "nlmeans=h=1.0:s=7:p=3:r=5" }
    "3" { "hqdn3d=luma_spatial=4:chroma_spatial=3:luma_tmp=6:chroma_tmp=4.5" }
    "4" { "nlmeans=h=3.0:s=7:p=5:r=9" }
    "5" { "unsharp=luma_msize_x=5:luma_msize_y=5:luma_amount=0.8:chroma_msize_x=5:chroma_msize_y=5:chroma_amount=0.4" }
    "6" { "cas=strength=0.6" }
    "7" { "bwdif=mode=send_field:parity=auto:deint=all" }
    "8" {
        $cf = Read-Host "  Filtru ffmpeg custom (ex: eq=brightness=0.1)"
        if ($cf) { $cf } else { $null }
    }
    "9" { $script:vfIsUpscale4K = $true; "scale=3840:-2:flags=lanczos" }
    "10" { $script:vfIsVidstab = $true; $null }
    default { $null }
}
if ($vfPreset) {
    Write-Host "  Filtru: $vfPreset" -ForegroundColor Green
} elseif ($vfIsVidstab) {
    Write-Host "  Filtru: Stabilizare video (vidstab 2-pass)" -ForegroundColor Green
} else {
    Write-Host "  Fara filtre video." -ForegroundColor White
}

# DNxHR/ProRes/HW: bitrate fix sau QP — skip CRF/Preset/Tune/Extra
$encMode = "1"; $customCrf = ""; $vbrTarget = ""; $vbrMaxrate = ""; $vbrBufsize = ""
$selectedPreset = "slow"; $selectedTune = ""; $extraParams = ""
if (-not $useDNxHR -and -not $useProRes -and -not $useHWEnc) {

Write-Host ""; Write-Host "Mod: 1-CRF [implicit]  2-VBR" -ForegroundColor Cyan
$encMode = Read-Host "Alege [implicit: 1]"
if ($encMode -ne "2") { $encMode = "1" }
$customCrf = ""; $vbrTarget = ""; $vbrMaxrate = ""; $vbrBufsize = ""
if ($encMode -eq "1") {
    Write-Host "CRF: A-Auto  B-Custom" -ForegroundColor Cyan
    $cc = Read-Host "Alege A sau B [implicit: A]"
    if ($cc -ieq "B") {
        $crfMax = if ($useAV1) { 63 } else { 51 }
        $customCrf = Read-Host "Introdu CRF (0-$crfMax)"
        if ($customCrf -match "^\d+$" -and [int]$customCrf -ge 0 -and [int]$customCrf -le $crfMax) {
            Write-Host "  CRF setat la: $customCrf" -ForegroundColor Green
        } else {
            Write-Host "  Valoare invalida (0-$crfMax) — se foloseste CRF auto." -ForegroundColor Yellow
            $customCrf = ""
        }
    }
} else {
    $vi = Read-Host "Bitrate tinta (ex: 4000k, 4M)"
    if (-not (Test-BitrateFormat $vi)) { Write-Host "Format invalid!" -ForegroundColor Red; Read-Host; exit }
    $vbrTarget = $vi; $kbps = Convert-ToKbps $vi
    $vbrMaxrate = "$([int]($kbps*1.5))k"; $vbrBufsize = "$($kbps*2)k"
    Write-Host "  VBR: $vbrTarget / max $vbrMaxrate" -ForegroundColor Green
    $ov = Read-Host "Modifica maxrate/bufsize? (d/N)"
    if ($ov -ieq "d") {
        $mr = Read-Host "Maxrate"; $bs = Read-Host "Bufsize"
        # FIX: avertisment explicit la valori invalide (nu cade silently)
        if (Test-BitrateFormat $mr) { $vbrMaxrate = $mr }
        else { Write-Host "  AVERTISMENT: Maxrate invalid — se pastreaza $vbrMaxrate" -ForegroundColor Yellow }
        if (Test-BitrateFormat $bs) { $vbrBufsize = $bs }
        else { Write-Host "  AVERTISMENT: Bufsize invalid — se pastreaza $vbrBufsize" -ForegroundColor Yellow }
    }
    Write-Host "  VBR final: $vbrTarget / max $vbrMaxrate / buf $vbrBufsize" -ForegroundColor Green
}

# Preset
Write-Host ""
$pm = @{"1"="ultrafast";"2"="superfast";"3"="veryfast";"4"="faster";"5"="fast";
        "6"="medium";"7"="slow";"8"="slower";"9"="veryslow"}

if ($useAV1) {
    # AV1 are meniu preset propriu (valori diferite de x265/x264)
    if ($av1Impl -eq "libsvtav1") {
        Write-Host "Preset SVT-AV1: 1-veryslow(0) 2-slower(2) 3-slow(4) 4-med-slow(5)" -ForegroundColor Cyan
        Write-Host "                5-medium(6)[rec] 6-med-fast(7) 7-fast(8) 8-faster(10) 9-ultrafast(12)" -ForegroundColor Cyan
    } else {
        Write-Host "Preset libaom cpu-used: 1-0 2-1 3-2 4-3 5-4[rec] 6-5 7-6 8-7 9-8" -ForegroundColor Cyan
    }
    # FIX: $pc2 citit SEPARAT pt AV1 — nu se reutilizeaza variabila preset x265/x264
    $pc2 = Read-Host "Alege 1-9 [implicit: 5]"
    if ([string]::IsNullOrWhiteSpace($pc2)) { $pc2 = "5" }
    # $selectedPreset nu se foloseste pt AV1 — AV1 foloseste $av1Preset din av1PresetMap
} else {
    Write-Host "Preset: 1-ultrafast 2-superfast 3-veryfast 4-faster 5-fast 6-medium 7-slow[impl] 8-slower 9-veryslow" -ForegroundColor Cyan
    $pc2 = Read-Host "Alege [implicit: 7]"
    $selectedPreset = if ($pm.ContainsKey($pc2)) { $pm[$pc2] } else { "slow" }
    Write-Host "  Preset: $selectedPreset" -ForegroundColor Green
}

# Tune / Film-grain — NOTA: AV1 nu foloseste -tune
Write-Host ""
$selectedTune = ""; $tuneFlag = @()
if ($useAV1) {
    Write-Host "Film-grain synthesis (AV1 specific, NU -tune): 0=off 1-10=usor 11-20=mediu 21-50=intens" -ForegroundColor Cyan
    $fgIn = Read-Host "Nivel 0-50 [implicit: 0]"
    $fgLevel = if ($fgIn -match '^\d+$' -and [int]$fgIn -ge 0 -and [int]$fgIn -le 50) { [int]$fgIn } else { 0 }
    if ($fgIn -and -not ($fgIn -match '^\d+$')) {
        Write-Host "  Valoare invalida — se foloseste 0." -ForegroundColor Yellow
    }
    $selectedTune = $fgLevel.ToString()
    if ($fgLevel -gt 0) { Write-Host "  Film-grain: $fgLevel" -ForegroundColor Green } else { Write-Host "  Film-grain dezactivat." -ForegroundColor White }
} else {
    Write-Host "Tune: 1-Fara[impl] 2-animation 3-grain 4-film 5-stillimage 6-fastdecode" -ForegroundColor Cyan
    $tm = @{"2"="animation";"3"="grain";"4"="film";"5"="stillimage";"6"="fastdecode"}
    $tc2 = Read-Host "Alege 1-6"
    $selectedTune = if ($tm.ContainsKey($tc2)) { $tm[$tc2] } else { "" }
    $tuneFlag = if ($selectedTune) { @("-tune",$selectedTune) } else { @() }
    if ($selectedTune) { Write-Host "  Tune: $selectedTune" -ForegroundColor Green } else { Write-Host "  Fara tune." -ForegroundColor White }
}

# ── Parametri extra encoder (optional) ────────────────────────────────
Write-Host ""
if ($useAV1) {
    if ($av1Impl -eq "libsvtav1") {
        Write-Host "Parametri extra SVT-AV1 (optional, ex: enable-overlays=1:scd=1):" -ForegroundColor Cyan
    } else {
        Write-Host "Parametri extra libaom (optional, ex: -enable-chroma-deltaqp 1):" -ForegroundColor Cyan
    }
} elseif ($useX264) {
    Write-Host "Parametri extra libx264 (optional, ex: rc-lookahead=40:psy-rd=1.5):" -ForegroundColor Cyan
} else {
    Write-Host "Parametri extra libx265 (optional, ex: rc-lookahead=40:psy-rd=1.5):" -ForegroundColor Cyan
}
Write-Host "  Enter = sari" -ForegroundColor DarkGray
$extraParams = Read-Host "Parametri"
if ($extraParams) {
    # Validare parametri extra (identic cu bash launcher.sh)
    $extraValid = $true; $extraErr = ""
    if ($useAV1 -and $av1Impl -eq "libaom-av1") {
        # libaom: doar validare caractere (permite spatii si dash la inceput)
        if ($extraParams -notmatch '^[-a-zA-Z0-9=:_., ]+$') {
            $extraValid = $false; $extraErr = "Caractere invalide pentru libaom."
        }
    } else {
        # x265/x264/svt: validare caractere + segment cu segment
        if ($extraParams -notmatch '^[a-zA-Z0-9=:_.,\-]+$') {
            $extraValid = $false; $extraErr = "Caractere invalide."
        }
        if ($extraValid) {
            $segments = $extraParams -split ':'
            foreach ($seg in $segments) {
                if ([string]::IsNullOrEmpty($seg)) {
                    $extraValid = $false; $extraErr = "Segment gol detectat (:: dublu)."; break
                } elseif ($seg -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*=.') {
                    $extraValid = $false; $extraErr = "Segment invalid: '$seg' (format: key=value)"; break
                }
            }
        }
    }
    if (-not $extraValid) {
        Write-Host "  EROARE: $extraErr — Scriptul se opreste." -ForegroundColor Red
        Read-Host; exit
    }
    Write-Host "  Parametri validati: $extraParams" -ForegroundColor Green
} else {
    Write-Host "  Fara parametri extra." -ForegroundColor White
}

} # end if (-not $useDNxHR -and -not $useProRes -and -not $useHWEnc)

# ── Audio output ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Audio output                                    ║" -ForegroundColor Cyan
Write-Host "║  1) AAC 192k / 5.1 384k / 7.1 768k [implicit]   ║" -ForegroundColor White
Write-Host "║  2) AAC custom                                   ║" -ForegroundColor White
Write-Host "║  3) Opus 128k / 5.1 256k / 7.1 512k             ║" -ForegroundColor White
Write-Host "║  4) Opus custom                                  ║" -ForegroundColor White
Write-Host "║  5) FLAC lossless                                ║" -ForegroundColor White
Write-Host "║  6) FLAC custom (compression level)              ║" -ForegroundColor White
Write-Host "║  7) E-AC3 (Dolby Digital Plus)                   ║" -ForegroundColor White
Write-Host "║     Stereo 224k / 5.1 640k / 7.1 1024k          ║" -ForegroundColor White
Write-Host "║  8) LPCM (PCM necomprimat) 16/24/32bit          ║" -ForegroundColor White
Write-Host "║  9) Pastreaza audio original (copy)              ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
$audioChoice = Read-Host "Alege 1-9 [implicit: 1]"
$audioCodec = "aac"; $audioBitrate = "192k"; $audioFlacLevel = 8; $audioCopy = $false; $pcmDepth = "16le"
switch ($audioChoice) {
    "1" { Write-Host "  Audio: AAC 192k / 5.1 384k / 7.1 768k" -ForegroundColor Green }
    "2" {
        $abr = Read-Host "  Bitrate AAC (ex: 128k, 256k, 320k)"
        if ($abr -match '^\d+[kK]$') { $audioBitrate = $abr.ToLower() } else { $audioBitrate = "192k"; Write-Host "  Invalid — AAC 192k" -ForegroundColor Yellow }
        Write-Host "  Audio: AAC $audioBitrate" -ForegroundColor Green
    }
    "3" { $audioCodec = "opus"; $audioBitrate = "128k"; Write-Host "  Audio: Opus 128k / 5.1 256k / 7.1 512k" -ForegroundColor Green }
    "4" {
        $audioCodec = "opus"
        $obr = Read-Host "  Bitrate Opus (ex: 64k, 96k, 128k)"
        if ($obr -match '^\d+[kK]$') { $audioBitrate = $obr.ToLower() } else { $audioBitrate = "128k"; Write-Host "  Invalid — Opus 128k" -ForegroundColor Yellow }
        Write-Host "  Audio: Opus $audioBitrate" -ForegroundColor Green
    }
    "5" { $audioCodec = "flac"; Write-Host "  Audio: FLAC lossless (compression 8)" -ForegroundColor Green }
    "6" {
        $audioCodec = "flac"
        $flvl = Read-Host "  Compression level FLAC (0-12)"
        if ($flvl -match '^\d+$' -and [int]$flvl -ge 0 -and [int]$flvl -le 12) { $audioFlacLevel = [int]$flvl } else { $audioFlacLevel = 8; Write-Host "  Invalid — FLAC compression 8" -ForegroundColor Yellow }
        Write-Host "  Audio: FLAC compression $audioFlacLevel" -ForegroundColor Green
    }
    "7" { $audioCodec = "eac3"; $audioBitrate = "224k"; Write-Host "  Audio: E-AC3 (Dolby Digital Plus) — stereo 224k / 5.1 640k / 7.1 1024k" -ForegroundColor Green }
    "8" {
        $audioCodec = "pcm"
        Write-Host "  LPCM bit depth: 1-16bit [impl] 2-24bit 3-32bit" -ForegroundColor Cyan
        $pd = Read-Host "  Alege [impl: 1]"
        switch ($pd) { "2" { $pcmDepth = "24le" } "3" { $pcmDepth = "32le" } default { $pcmDepth = "16le" } }
        Write-Host "  Audio: LPCM pcm_s${pcmDepth}" -ForegroundColor Green
    }
    "9" { $audioCopy = $true; Write-Host "  Audio: copy (original)" -ForegroundColor Green }
    default { Write-Host "  Audio: AAC 192k / 5.1 384k / 7.1 768k" -ForegroundColor Green }
}

# FLAC + mp4/mov avertisment (nu se aplica DNxHR — FLAC compatibil cu mov/mxf)
if ($audioCodec -eq "flac" -and $container -ne "mkv" -and -not $useDNxHR) {
    Write-Host "`n  ATENTIE: FLAC nu e compatibil cu $container." -ForegroundColor Red
    Write-Host "  1-Schimba la MKV [recomandat]  2-Schimba audio la AAC 192k" -ForegroundColor Yellow
    $flacFix = Read-Host "  Alege [implicit: 1]"
    if ($flacFix -eq "2") {
        $audioCodec = "aac"; $audioBitrate = "192k"
        Write-Host "  Audio schimbat la AAC 192k" -ForegroundColor Yellow
    } else {
        $container = "mkv"; $containerFlags = @()
        Write-Host "  Container schimbat la MKV" -ForegroundColor Yellow
    }
}

# E-AC3 + mov avertisment
if ($audioCodec -eq "eac3" -and $container -eq "mov") {
    Write-Host "`n  ATENTIE: E-AC3 nu e compatibil cu mov." -ForegroundColor Red
    Write-Host "  1-MKV [recomandat]  2-MP4  3-AAC 192k" -ForegroundColor Yellow
    $eac3Fix = Read-Host "  Alege [implicit: 1]"
    switch ($eac3Fix) {
        "2" { $container = "mp4"; $containerFlags = @("-movflags","+faststart"); Write-Host "  Container schimbat la MP4" -ForegroundColor Yellow }
        "3" { $audioCodec = "aac"; $audioBitrate = "192k"; Write-Host "  Audio schimbat la AAC 192k" -ForegroundColor Yellow }
        default { $container = "mkv"; $containerFlags = @(); Write-Host "  Container schimbat la MKV" -ForegroundColor Yellow }
    }
}

# LPCM + mp4 avertisment
if ($audioCodec -eq "pcm" -and $container -eq "mp4") {
    Write-Host "`n  ATENTIE: LPCM nu e compatibil cu mp4." -ForegroundColor Red
    Write-Host "  1-MKV [recomandat]  2-MOV  3-AAC 192k" -ForegroundColor Yellow
    $pcmFix = Read-Host "  Alege [implicit: 1]"
    switch ($pcmFix) {
        "2" { $container = "mov"; $containerFlags = @("-movflags","+faststart"); Write-Host "  Container schimbat la MOV" -ForegroundColor Yellow }
        "3" { $audioCodec = "aac"; $audioBitrate = "192k"; Write-Host "  Audio schimbat la AAC 192k" -ForegroundColor Yellow }
        default { $container = "mkv"; $containerFlags = @(); Write-Host "  Container schimbat la MKV" -ForegroundColor Yellow }
    }
}

# ── Normalizare audio (loudnorm EBU R128) ────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Normalizare volum (EBU R128)        ║" -ForegroundColor Cyan
Write-Host "║  1) Fara normalizare [implicit]      ║" -ForegroundColor White
Write-Host "║  2) Normalizeaza la -24 LUFS         ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
$normChoice = Read-Host "Alege 1 sau 2 [implicit: 1]"
$audioNormalize = $false
if ($normChoice -eq "2") {
    $audioNormalize = $true
    Write-Host "  Normalizare: EBU R128 (-24 LUFS, 2-pass)" -ForegroundColor Green
} else {
    Write-Host "  Fara normalizare audio." -ForegroundColor White
}

# Opus + webm: Opus e singurul audio suportat in webm
if ($container -eq "webm" -and $audioCodec -ne "opus" -and -not $audioCopy) {
    Write-Host "`n  ATENTIE: WebM suporta doar Opus audio." -ForegroundColor Red
    Write-Host "  1-Schimba audio la Opus 128k [recomandat]  2-Schimba container la MKV" -ForegroundColor Yellow
    $webmFix = Read-Host "  Alege [implicit: 1]"
    if ($webmFix -eq "2") {
        $container = "mkv"; $containerFlags = @()
        Write-Host "  Container schimbat la MKV" -ForegroundColor Yellow
    } else {
        $audioCodec = "opus"; $audioBitrate = "128k"
        Write-Host "  Audio schimbat la Opus 128k" -ForegroundColor Yellow
    }
}
# WebM + audio copy: verificare codec sursa la runtime (per fisier, in loop)
if ($container -eq "webm" -and $audioCopy) {
    Write-Host "`n  ATENTIE: WebM + audio copy — daca sursa nu este Opus/Vorbis, ffmpeg va esua." -ForegroundColor Yellow
    Write-Host "  Recomandat: schimba la Opus 128k sau container MKV." -ForegroundColor Yellow
    Write-Host "  1-Schimba audio la Opus 128k  2-Schimba container la MKV  3-Continua [risc]" -ForegroundColor Yellow
    $webmCopyFix = Read-Host "  Alege [implicit: 1]"
    switch ($webmCopyFix) {
        "2" { $container = "mkv"; $containerFlags = @(); Write-Host "  Container schimbat la MKV" -ForegroundColor Yellow }
        "3" { Write-Host "  Continuam cu risc — ffmpeg va esua daca sursa nu e Opus/Vorbis." -ForegroundColor Red }
        default { $audioCopy = $false; $audioCodec = "opus"; $audioBitrate = "128k"; Write-Host "  Audio schimbat la Opus 128k" -ForegroundColor Yellow }
    }
}

# ── Force LOG detection (optional) ──────────────────────────────────
$forceLogDetection = $false
if (-not $useDNxHR -and -not $useProRes -and -not $useHWEnc) {
    Write-Host ""
    Write-Host "Force LOG detection: 1-Nu [implicit]  2-Da (toate fisierele primesc dialog LOG)" -ForegroundColor Cyan
    $fldChoice = Read-Host "Alege [implicit: 1]"
    if ($fldChoice -eq "2") {
        $forceLogDetection = $true
        Write-Host "  Force LOG: ACTIV — toate fisierele vor avea dialog LOG" -ForegroundColor Yellow
    }
}

# ── Interactive Mode (optional) ─────────────────────────────────────
$interactiveMode = $false
Write-Host ""
Write-Host "Mod interactiv: 1-Nu [implicit]  2-Da (modifica setari dupa fiecare fisier)" -ForegroundColor Cyan
$imChoice = Read-Host "Alege [implicit: 1]"
if ($imChoice -eq "2") {
    $interactiveMode = $true
    Write-Host "  Mod interactiv: ACTIV" -ForegroundColor Green
}

# ── Salvare profil (optional) ────────────────────────────────────────
Write-Host ""
$saveProf = Read-Host "Salvezi configuratia ca profil? (d/N)"
if ($saveProf -ieq "d") {
    $profName = Read-Host "  Nume profil (ex: drone_4k, film_hdr)"
    if ($profName) {
        $profFile = Join-Path $profileDir "$profName.conf"
        $encShort = if ($useX264) { "libx264" } elseif ($useAV1) { "av1" } elseif ($useDNxHR) { "dnxhr" } elseif ($useProRes) { "prores" } elseif ($useHWEnc) { "hwenc" } else { "libx265" }
        $vfSave = if ($vfIsVidstab) { "vidstab" } elseif ($vfPreset) { $vfPreset } else { "" }
        @(
            ":: AV Encoder Suite — Profil salvat: $profName"
            "ENCODER=$encShort"
            "AV1_IMPL=$av1Impl"
            "DNXHR_PROFILE=$dnxhrProfile"
            "PRORES_PROFILE=$proresProfile"
            "X264_PROFILE=$x264ProfileGlobal"
            "HW_ENC_CODEC=$hwEncCodec"
            "HW_ENC_PRESET=$hwEncPreset"
            "HW_ENC_QP=$hwEncQP"
            "CONTAINER=$container"
            "SCALE_WIDTH=$scaleWidth"
            "TARGET_FPS=$targetFps"
            "FPS_METHOD=$fpsMethod"
            "VF_PRESET=$vfSave"
            "AUDIO_CODEC=$audioCodec"
            "AUDIO_BITRATE=$audioBitrate"
            "AUDIO_COPY=$(if ($audioCopy) { '1' } else { '0' })"
            "AUDIO_FLAC_LEVEL=$audioFlacLevel"
            "PCM_DEPTH=$pcmDepth"
            "AUDIO_NORMALIZE=$(if ($audioNormalize) { '1' } else { '0' })"
            "ENCODE_MODE=$encMode"
            "CUSTOM_CRF=$customCrf"
            "PRESET=$selectedPreset"
            "TUNE=$selectedTune"
            "EXTRA_PARAMS=$extraParams"
            "VBR_TARGET=$vbrTarget"
            "VBR_MAXRATE=$vbrMaxrate"
            "VBR_BUFSIZE=$vbrBufsize"
            "FORCE_LOG_DETECTION=$(if ($forceLogDetection) { '1' } else { '0' })"
            "INTERACTIVE_MODE=$(if ($interactiveMode) { '1' } else { '0' })"
        ) | Out-File $profFile -Encoding UTF8
        Write-Host "  Profil salvat: $profFile" -ForegroundColor Green
    }
}

} # end if (-not $profLoaded)

"===========================================" | Out-File $LogFile -Encoding UTF8
"Encode: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $encoderName | $container" | Out-File $LogFile -Append -Encoding UTF8
if ($useDNxHR) { "Profil DNxHR: $dnxhrProfile" | Out-File $LogFile -Append -Encoding UTF8 }
if ($useProRes) { "Profil ProRes: $proresProfile" | Out-File $LogFile -Append -Encoding UTF8 }
if ($useHWEnc) { "HW Encoder: $hwEncCodec | Preset: $hwEncPreset | QP: $hwEncQP" | Out-File $LogFile -Append -Encoding UTF8 }
"Resize: $(if ($scaleWidth) { "${scaleWidth}px width" } else { 'original' })" | Out-File $LogFile -Append -Encoding UTF8
"FPS: $(if ($targetFps) { "$targetFps ($fpsMethod)" } else { 'original' })" | Out-File $LogFile -Append -Encoding UTF8
"Filtru video: $(if ($vfPreset) { $vfPreset } elseif ($vfIsVidstab) { 'vidstab' } else { 'fara' })" | Out-File $LogFile -Append -Encoding UTF8
"Normalizare: $audioNormalize" | Out-File $LogFile -Append -Encoding UTF8
if ($extraParams) { "Extra: $extraParams" | Out-File $LogFile -Append -Encoding UTF8 }
"===========================================" | Out-File $LogFile -Append -Encoding UTF8

# ── Dry-run / Mod lansare ─────────────────────────────────────────────
Write-Host ""
Write-Host "Mod lansare: 1-Encodeaza normal [implicit]  2-Dry-run (doar analiza)" -ForegroundColor Cyan
$launchMode = Read-Host "Alege [implicit: 1]"
$dryRun = ($launchMode -eq "2")
if ($dryRun) { Write-Host "  MOD DRY-RUN: se afiseaza ce ar face fara sa encodeze." -ForegroundColor Yellow }

# ── Batch Queue — editare ordine si excludere fisiere ────────────────
Write-Host ""
Write-Host "Editezi batch queue (ordine/excludere)? 1-Nu [impl]  2-Da" -ForegroundColor Cyan
$bqChoice = Read-Host "Alege [implicit: 1]"
if ($bqChoice -eq "2") {
    $bqList = @()
    for ($bi = 0; $bi -lt $inputFiles.Count; $bi++) {
        $bqList += @{ idx=$bi; file=$inputFiles[$bi]; included=$true }
    }
    $bqDone = $false
    while (-not $bqDone) {
        Clear-Host
        Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host ("║  BATCH QUEUE — {0} fisiere                        ║" -f $bqList.Count) -ForegroundColor Cyan
        Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor Cyan
        for ($bi = 0; $bi -lt $bqList.Count; $bi++) {
            $mark = if ($bqList[$bi].included) { "✓" } else { "✗" }
            $col  = if ($bqList[$bi].included) { "White" } else { "DarkGray" }
            $sz   = Format-Bytes $bqList[$bi].file.Length
            Write-Host ("  {0,2}) [{1}] {2,-30} ({3})" -f ($bi+1), $mark, $bqList[$bi].file.Name, $sz) -ForegroundColor $col
        }
        $inclCount = ($bqList | Where-Object { $_.included }).Count
        Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor Cyan
        Write-Host "  X<nr>  — exclude/include (ex: X3)" -ForegroundColor Yellow
        Write-Host "  F<nr>  — muta pe prima pozitie (ex: F5)" -ForegroundColor Yellow
        Write-Host "  M<de>,<la> — muta (ex: M3,1)" -ForegroundColor Yellow
        Write-Host "  D<nr>  — doar acest fisier" -ForegroundColor Yellow
        Write-Host "  Enter  — lanseaza ($inclCount fisiere)" -ForegroundColor Green
        Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
        $bqCmd = Read-Host "Comanda"
        if (-not $bqCmd) { $bqDone = $true; continue }
        $bqCmd = $bqCmd.Trim().ToUpper()
        if ($bqCmd -match '^X(\d+)$') {
            $xi = [int]$Matches[1] - 1
            if ($xi -ge 0 -and $xi -lt $bqList.Count) {
                $bqList[$xi].included = -not $bqList[$xi].included
            }
        } elseif ($bqCmd -match '^F(\d+)$') {
            $fi = [int]$Matches[1] - 1
            if ($fi -gt 0 -and $fi -lt $bqList.Count) {
                $item = $bqList[$fi]
                $bqList = @($item) + ($bqList[0..($fi-1)]) + ($bqList[($fi+1)..($bqList.Count-1)])
            }
        } elseif ($bqCmd -match '^M(\d+),(\d+)$') {
            $from = [int]$Matches[1] - 1; $to = [int]$Matches[2] - 1
            if ($from -ge 0 -and $from -lt $bqList.Count -and $to -ge 0 -and $to -lt $bqList.Count -and $from -ne $to) {
                $item = $bqList[$from]
                $temp = [System.Collections.ArrayList]@($bqList)
                $temp.RemoveAt($from)
                $temp.Insert($to, $item)
                $bqList = @($temp)
            }
        } elseif ($bqCmd -match '^D(\d+)$') {
            $di = [int]$Matches[1] - 1
            if ($di -ge 0 -and $di -lt $bqList.Count) {
                for ($bi = 0; $bi -lt $bqList.Count; $bi++) {
                    $bqList[$bi].included = ($bi -eq $di)
                }
            }
        }
    }
    # Apply queue: filter included, preserve order
    $inputFiles = @($bqList | Where-Object { $_.included } | ForEach-Object { $_.file })
    $fileCount = $inputFiles.Count
    if ($fileCount -eq 0) {
        Write-Host "Toate fisierele au fost excluse." -ForegroundColor Red; Read-Host; exit
    }
    Write-Host "  Batch queue: $fileCount fisiere selectate." -ForegroundColor Green
}

$batchProgressFile = Join-Path $OutputDir "batch_progress.log"

$totalSaved=0L; $totalErrors=0; $totalSkipped=0; $totalDone=0; $grandStart=Get-Date
$batchNames=@(); $batchTimes=@(); $batchOrig=@(); $batchNew=@(); $batchRatios=@()
$origContainer = $container; $origContainerFlags = $containerFlags

foreach ($f in $inputFiles) {
    # Reset container per fisier (switch mkv din iteratia anterioara nu contamineaza)
    $container = $origContainer; $containerFlags = $origContainerFlags
    $outFile = Join-Path $OutputDir ($f.BaseName + $outSuffix + "." + $container)
    Write-Host "`n══════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "Procesam: $($f.Name) → $($f.BaseName)$outSuffix.$container" -ForegroundColor Yellow
    # Hint format sursa DVD/Blu-ray
    $extLower = $f.Extension.ToLower().TrimStart('.')
    if ($extLower -eq "vob") {
        Write-Host "  SURSA DVD (.vob): MPEG-2, posibil interlasata." -ForegroundColor Yellow
        Write-Host "  Recomandat: activeaza filtrul Deinterlace (bwdif) din meniu." -ForegroundColor Yellow
    } elseif ($extLower -eq "m2ts" -or $extLower -eq "mts") {
        Write-Host "  SURSA Blu-ray (.m2ts): H.264/H.265, progresiv de obicei." -ForegroundColor Cyan
    }
    # ProRes source hint (detect from codec, not extension — ProRes comes in .mov)
    $srcCodecHint = Get-FFprobeValue $f.FullName "v:0" "codec_name"
    if ($srcCodecHint -eq "prores") {
        Write-Host "  SURSA ProRes: codec Apple profesional (intra-frame, editare)." -ForegroundColor Cyan
    }

    if (Test-Path $outFile) {
        $es = (Get-Item $outFile).Length
        if ($es -gt 1MB) {
            Write-Host "  Sarit ($(Format-Bytes $es))" -ForegroundColor DarkYellow
            $totalSkipped++; continue
        } else { Remove-Item $outFile -Force }
    }

    # Resume: skip daca in batch_progress.log
    if (Test-Path $batchProgressFile) {
        $doneList = Get-Content $batchProgressFile -ErrorAction SilentlyContinue
        if ($doneList -contains $f.Name) {
            Write-Host "  Sarit (resume — deja procesat anterior)" -ForegroundColor DarkYellow
            $totalSkipped++; continue
        }
    }

    $dji = Get-DJITracks $f.FullName
    $keepDbgi = $false
    if ($dji.isDji) {
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "  ║  FISIER DJI DETECTAT                         ║" -ForegroundColor Yellow
        Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Yellow
        if ($dji.hasDjmd)  { Write-Host "  ║  ✅ djmd — GPS, telemetrie, setari camera    ║" -ForegroundColor Green }
        if ($dji.hasTC)    { Write-Host "  ║  ✅ tmcd — Timecode sincronizare              ║" -ForegroundColor Green }
        if ($dji.hasDbgi)  { Write-Host "  ║  ⚠️  dbgi — date debug DJI (~295 MB)          ║" -ForegroundColor Yellow }
        if ($dji.hasCover) { Write-Host "  ║  ℹ️  Cover JPEG — nu se copiaza (re-encode)   ║" -ForegroundColor DarkGray }

        if ($container -ne "mkv") {
            Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Yellow
            Write-Host "  ║  Track-urile DJI nu pot fi copiate in $container       ║" -ForegroundColor White
            Write-Host "  ║  (codec 'none' incompatibil cu mp4/mov).    ║" -ForegroundColor White
            Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Yellow
            Write-Host "  ║  1) Schimba la MKV (pastreaza tot)          ║" -ForegroundColor White
            Write-Host "  ║  2) Continua $container fara track-uri DJI [impl]  ║" -ForegroundColor White
            Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Yellow
            $djiContChoice = Read-Host "  Alege [implicit: 2]"
            if ($djiContChoice -eq "1") {
                $container = "mkv"
                $containerFlags = @()
                $outFile = Join-Path $OutputDir ($f.BaseName + $outSuffix + ".mkv")
                Write-Host "  Container schimbat la mkv (track-uri DJI pastrate)" -ForegroundColor Green
                if ($dji.hasDbgi) {
                    Write-Host "  Pastrezi dbgi (debug, ~295 MB)? 1-Da  2-Nu [impl]" -ForegroundColor White
                    $dbgiChoice = Read-Host "  Alege [implicit: 2]"
                    $keepDbgi = ($dbgiChoice -eq "1")
                }
            }
        } else {
            if ($dji.hasDbgi) {
                Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Yellow
                Write-Host "  ║  Pastrezi track-ul dbgi (debug, ~295 MB)?   ║" -ForegroundColor White
                Write-Host "  ║  1-Da   2-Nu [recomandat]                   ║" -ForegroundColor White
                Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Yellow
                $dbgiChoice = Read-Host "  Alege [implicit: 2]"
                $keepDbgi = ($dbgiChoice -eq "1")
            } else {
                Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Yellow
            }
        }
        "DJI: djmd=$($dji.hasDjmd) dbgi=$keepDbgi container=$container" | Out-File $LogFile -Append -Encoding UTF8
    }

    $mapFlags  = Get-DJIMapFlags $f.FullName $keepDbgi $dji $container
    $si        = Get-SourceInfo $f.FullName
    $width     = Get-FFprobeValue $f.FullName "v:0" "width"
    $durRaw    = & ffprobe -v error -show_entries format=duration `
        -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null
    $durSec    = if ($durRaw -match '^\d+') { [int]([double]$durRaw) } else { 0 }
    Write-Host "  Format sursa: $($si.fmt)" -ForegroundColor White

    # Video filter (scale + preset + fps) — no upscale
    $vfParts = @()
    # Skip scale daca upscale_4k e activ (include scale= propriu)
    if (-not $vfIsUpscale4K) {
        if ($scaleWidth -and $width -match '^\d+$' -and [int]$width -gt $scaleWidth) {
            $vfParts += "scale=${scaleWidth}:-2"
            Write-Host "  Resize: ${width}px → ${scaleWidth}px (aspect ratio pastrat)" -ForegroundColor Cyan
        }
    }
    # ── Dry-run: afiseaza ce ar face, fara sa encodeze ────────────────
    # NOTA: plasat INAINTE de vidstab si loudnorm pt a evita ffmpeg calls inutile
    if ($dryRun) {
        Write-Host ""
        Write-Host "  ══════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  DRY-RUN: $($f.Name)" -ForegroundColor Yellow
        Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Encoder  : $encoderName | Container: $container" -ForegroundColor White
        Write-Host "  Sursa    : $($si.fmt) | ${width}px | $(Format-Bytes $f.Length)" -ForegroundColor White
        Write-Host "  Output   : $($f.BaseName)$outSuffix.$container" -ForegroundColor White
        $resMsg = if ($scaleWidth) { "${width}px → ${scaleWidth}px" } else { "original" }
        Write-Host "  Resize   : $resMsg" -ForegroundColor White
        $fpsMsg = if ($targetFps) { "→ $targetFps ($fpsMethod)" } else { "original" }
        Write-Host "  FPS      : $fpsMsg" -ForegroundColor White
        $vfMsg = if ($vfPreset) { $vfPreset } elseif ($vfIsVidstab) { "vidstab 2-pass" } else { "fara" }
        Write-Host "  Filtru   : $vfMsg" -ForegroundColor White
        Write-Host "  Audio    : $audioCodec $audioBitrate" -ForegroundColor White
        if ($audioNormalize) { Write-Host "  Loudnorm : EBU R128 (-24 LUFS)" -ForegroundColor White }
        if ($logInfo.logProfile) { Write-Host "  LOG      : $(Get-LogProfileLabel $logInfo.logProfile)" -ForegroundColor Yellow }
        if ($durSec -gt 0) {
            $estBps = if ([int]$width -ge 3840) { 10000000 } elseif ([int]$width -ge 1920) { 4000000 } else { 2000000 }
            $estMB = [int]($estBps * $durSec / 8 / 1MB)
            Write-Host "  Estimare : ~${estMB} MB | Durata: $([int]($durSec/60))m" -ForegroundColor DarkCyan
        }
        Write-Host "  ══════════════════════════════════════════════════" -ForegroundColor Cyan
        $totalDone++; continue
    }
    # Vidstab 2-pass: trecerea 1 (analiza)
    $trfFile = $null
    if ($vfIsVidstab) {
        Write-Host "  Vidstab: Trecerea 1/2 — analiza miscare..." -ForegroundColor Cyan
        $trfFile = Join-Path $env:TEMP ("vidstab_"+[guid]::NewGuid().ToString("N")+".trf")
        & ffmpeg -threads 0 -i $f.FullName -vf "vidstabdetect=shakiness=5:accuracy=15:result=$trfFile" -f null NUL 2>>$LogFile
        if (Test-Path $trfFile) {
            $vfParts += "vidstabtransform=input=${trfFile}:smoothing=10:interpol=bicubic:optzoom=1:zoomspeed=0.25"
            Write-Host "  Vidstab: Trecerea 2/2 — encodare cu stabilizare" -ForegroundColor Green
        } else {
            Write-Host "  Vidstab: analiza esuata — continuam fara stabilizare" -ForegroundColor Yellow
        }
    }
    # Preset filter (denoise / sharpen / deinterlace / custom)
    if ($vfPreset) {
        $vfParts += $vfPreset
        Write-Host "  Filtru aplicat: $vfPreset" -ForegroundColor Cyan
        "  Filtru video: $vfPreset" | Out-File $LogFile -Append -Encoding UTF8
    }
    # FPS — no upscale (sursa trebuie sa fie > target)
    $fpsFlag = @()
    $srcFpsRaw = & ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate `
        -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null | Select-Object -First 1
    $srcFpsDec = if ($srcFpsRaw -match '(\d+)/(\d+)') {
        [math]::Round([double]$Matches[1] / [double]$Matches[2], 3)
    } elseif ($srcFpsRaw -match '^\d+\.?\d*$') { [double]$srcFpsRaw } else { 0 }
    $targetFpsDec = if ($targetFps -match '(\d+)/(\d+)') {
        [math]::Round([double]$Matches[1] / [double]$Matches[2], 3)
    } elseif ($targetFps -match '^\d+\.?\d*$') { [double]$targetFps } else { 0 }
    $fpsActive = ($targetFps -and $srcFpsDec -gt $targetFpsDec)
    if ($fpsActive) {
        if ($fpsMethod -eq "minterpolate") {
            $vfParts += "minterpolate=fps=${targetFps}:mi_mode=mci:mc_mode=aobmc:vsbmc=1"
            Write-Host "  FPS: ${srcFpsDec} → ${targetFps} (minterpolate)" -ForegroundColor Cyan
        } else {
            $fpsFlag = @("-r",$targetFps)
            Write-Host "  FPS: ${srcFpsDec} → ${targetFps} (drop/duplicate)" -ForegroundColor Cyan
        }
    }
    $videoFilter = if ($vfParts.Count -gt 0) { @("-vf",($vfParts -join ",")) } else { @() }

    # Audio params per fisier (surround detection)
    if ($audioCopy) {
        $audioParams = @("-c:a","copy")
        # Avertisment TrueHD/DTS-HD + mp4/mov — incompatibile la copy
        if ($container -ne "mkv" -and $container -ne "mxf") {
            $audioCodecs = & ffprobe -v error -select_streams a `
                -show_entries stream=codec_name `
                -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null
            if ($audioCodecs -match "truehd|dts") {
                Write-Host "  ATENTIE: Audio TrueHD/DTS-HD detectat — incompatibil cu $container la copy." -ForegroundColor Yellow
                Write-Host "  Recomandat: schimba containerul la mkv sau re-encodeaza audio." -ForegroundColor Yellow
            }
        }
    } else {
        $srcChannels = Get-FFprobeValue $f.FullName "a:0" "channels"
        $srcCh = if ($srcChannels -match '^\d+$') { [int]$srcChannels } else { 2 }
        switch ($audioCodec) {
            "aac" {
                $abr = $audioBitrate
                if ($abr -eq "192k") {
                    if ($srcCh -gt 6) { $abr = "768k" }
                    elseif ($srcCh -gt 2) { $abr = "384k" }
                }
                $audioParams = @("-c:a:0","aac","-b:a:0",$abr,"-c:a","copy")
            }
            "opus" {
                $abr = $audioBitrate
                if ($abr -eq "128k") {
                    if ($srcCh -gt 6) { $abr = "512k" }
                    elseif ($srcCh -gt 2) { $abr = "256k" }
                }
                $audioParams = @("-c:a:0","libopus","-b:a:0",$abr,"-c:a","copy")
            }
            "flac" {
                $audioParams = @("-c:a:0","flac","-compression_level",$audioFlacLevel,"-c:a","copy")
            }
            "eac3" {
                $abr = $audioBitrate
                if ($abr -eq "224k") {
                    if ($srcCh -gt 6) { $abr = "1024k" }
                    elseif ($srcCh -gt 2) { $abr = "640k" }
                }
                $audioParams = @("-c:a:0","eac3","-b:a:0",$abr,"-c:a","copy")
            }
            "pcm" {
                $audioParams = @("-c:a:0","pcm_s${pcmDepth}","-c:a","copy")
            }
            default {
                $audioParams = @("-c:a:0","aac","-b:a:0","192k","-c:a","copy")
            }
        }

        # Avertizari metadata TrueHD/DTS la re-encode (per fisier, in log)
        $srcAudioCodecs = & ffprobe -v error -select_streams a `
            -show_entries stream=codec_name `
            -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null
        $srcAudioProfile = & ffprobe -v error -select_streams a `
            -show_entries stream=profile `
            -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null
        if ($srcAudioCodecs -match "truehd") {
            Write-Host "  ⚠ ATENTIE: Sursa contine TrueHD. Metadata Atmos (obiecte spatiale) se va pierde." -ForegroundColor Yellow
            "  ⚠ TrueHD detectat — metadata Atmos pierduta la re-encode" | Out-File $LogFile -Append -Encoding UTF8
        }
        if ($srcAudioCodecs -match "dts") {
            if ($srcAudioProfile -match "DTS-HD MA|DTS:X") {
                Write-Host "  ⚠ ATENTIE: Sursa contine DTS-HD MA / DTS:X — metadata lossless/spatiala se va pierde." -ForegroundColor Yellow
                "  ⚠ DTS-HD MA / DTS:X detectat — metadata pierduta la re-encode" | Out-File $LogFile -Append -Encoding UTF8
            } else {
                Write-Host "  ⚠ ATENTIE: Sursa contine DTS — metadata DTS se va pierde la re-encode." -ForegroundColor Yellow
                "  ⚠ DTS detectat — metadata pierduta la re-encode" | Out-File $LogFile -Append -Encoding UTF8
            }
        }
    }

    # ── Multi-audio track dialog (daca >1 track si nu e audio copy) ──
    $audioTrackCount = (& ffprobe -v error -select_streams a `
        -show_entries stream=index -of csv=p=0 $f.FullName 2>$null |
        Where-Object { $_ -match '^\d' }).Count
    if ($audioTrackCount -gt 1 -and -not $audioCopy) {
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host ("  ║  {0} TRACK-URI AUDIO DETECTATE                ║" -f $audioTrackCount) -ForegroundColor Cyan
        Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
        # List all audio tracks
        $atList = & ffprobe -v error -select_streams a `
            -show_entries stream=index,codec_name,channels,bit_rate:stream_tags=language `
            -of csv=p=0 $f.FullName 2>$null
        $atIdx = 0
        foreach ($atLine in ($atList -split "`n" | Where-Object { $_ })) {
            $atParts = $atLine -split ','
            $atCodec = if ($atParts.Count -gt 1) { $atParts[1] } else { "?" }
            $atCh    = if ($atParts.Count -gt 2) { $atParts[2] } else { "?" }
            $atBr    = if ($atParts.Count -gt 3 -and $atParts[3] -match '^\d+$') { "$([int]([long]$atParts[3]/1000))k" } else { "N/A" }
            $atLang  = if ($atParts.Count -gt 4 -and $atParts[4]) { $atParts[4] } else { "und" }
            Write-Host ("  ║  Track {0}: {1} | {2}ch | {3} | {4,-14}║" -f $atIdx, $atCodec, $atCh, $atBr, $atLang) -ForegroundColor White
            $atIdx++
        }
        Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
        Write-Host "  ║  1) Track 0 re-encode, restul copy [impl]   ║" -ForegroundColor White
        Write-Host "  ║  2) Selecteaza track-uri (encode/copy/skip)  ║" -ForegroundColor White
        Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
        $multiAudioChoice = Read-Host "  Alege [implicit: 1]"
        if ($multiAudioChoice -eq "2") {
            $customAudioParams = @()
            $skipMaps = @()
            for ($ai = 0; $ai -lt $audioTrackCount; $ai++) {
                $aiChoice = Read-Host "  Track $ai (E=encode, C=copy, S=skip) [implicit: $(if ($ai -eq 0) {'E'} else {'C'})]"
                if (-not $aiChoice) { $aiChoice = if ($ai -eq 0) { "E" } else { "C" } }
                switch ($aiChoice.ToUpper()) {
                    "E" {
                        switch ($audioCodec) {
                            "aac"  { $customAudioParams += @("-c:a:$ai","aac","-b:a:$ai",$audioBitrate) }
                            "opus" { $customAudioParams += @("-c:a:$ai","libopus","-b:a:$ai",$audioBitrate) }
                            "flac" { $customAudioParams += @("-c:a:$ai","flac") }
                            "eac3" { $customAudioParams += @("-c:a:$ai","eac3","-b:a:$ai",$audioBitrate) }
                            "pcm"  { $customAudioParams += @("-c:a:$ai","pcm_s${pcmDepth}") }
                            default { $customAudioParams += @("-c:a:$ai","aac","-b:a:$ai","192k") }
                        }
                        Write-Host "    Track $ai → re-encode ($audioCodec)" -ForegroundColor Green
                    }
                    "S" {
                        # Exclude track from output with negative map
                        $skipMaps += @("-map","-0:a:$ai")
                        Write-Host "    Track $ai → SKIP (exclus din output)" -ForegroundColor DarkYellow
                    }
                    default {
                        $customAudioParams += @("-c:a:$ai","copy")
                        Write-Host "    Track $ai → copy" -ForegroundColor White
                    }
                }
            }
            if ($customAudioParams.Count -gt 0 -or $skipMaps.Count -gt 0) {
                $audioParams = $customAudioParams
                # Negative maps must be added to mapFlags, not audioParams
                if ($skipMaps.Count -gt 0) { $mapFlags = $mapFlags + $skipMaps }
            }
        }
    }

    # Loudnorm (normalizare audio EBU R128) — 2-pass
    $loudnormFlag = @()
    if ($audioNormalize -and -not $audioCopy) {
        Write-Host "  Loudnorm: analiza volum EBU R128..." -ForegroundColor Cyan
        Write-Host -NoNewline "  Loudnorm: pass 1/2 — analiza in curs...  "
        $lnOutput = & ffmpeg -i $f.FullName -af "loudnorm=I=-24:TP=-2.0:LRA=7:print_format=json" -f null NUL 2>&1 | Out-String
        Write-Host "`r  Loudnorm: pass 1/2 — complet.              " -ForegroundColor Green
        if ($lnOutput -match '"input_i"\s*:\s*"([^"]+)"') { $m_i = $Matches[1] } else { $m_i = $null }
        if ($lnOutput -match '"input_tp"\s*:\s*"([^"]+)"') { $m_tp = $Matches[1] }
        if ($lnOutput -match '"input_lra"\s*:\s*"([^"]+)"') { $m_lra = $Matches[1] }
        if ($lnOutput -match '"input_thresh"\s*:\s*"([^"]+)"') { $m_thresh = $Matches[1] }
        if ($m_i) {
            $loudnormFlag = @("-af","loudnorm=I=-24:TP=-2.0:LRA=7:measured_I=${m_i}:measured_TP=${m_tp}:measured_LRA=${m_lra}:measured_thresh=${m_thresh}:linear=true")
            Write-Host "  Loudnorm: I=${m_i} LUFS | TP=${m_tp} dB" -ForegroundColor Green
        } else {
            Write-Host "  Loudnorm: analiza esuata — skip normalizare" -ForegroundColor Yellow
        }
    }

    $rateParams = @(); $crfFlag = @()
    if ($encMode -eq "2") {
        $rateParams = @("-b:v",$vbrTarget,"-maxrate",$vbrMaxrate,"-bufsize",$vbrBufsize)
        Write-Host "  VBR: $vbrTarget" -ForegroundColor White
    } else {
        $crf = if ($customCrf) { [int]$customCrf }
               elseif ($useX264) { if ([int]$width -ge 3840){20}elseif([int]$width -ge 1920){19}else{18} }
               elseif ($useAV1)  { if ([int]$width -ge 3840){30}elseif([int]$width -ge 1920){28}else{26} }
               else              { if ([int]$width -ge 3840){22}elseif([int]$width -ge 1920){21}else{20} }
        $crfFlag = @("-crf",$crf)
        Write-Host "  CRF: $crf | ${width}px" -ForegroundColor White
    }

    $progFile  = Join-Path $env:TEMP ("ffprog_"+[guid]::NewGuid().ToString("N")+".txt")
    $startTime = Get-Date

    # ══════════════════════════════════════════════════════════════════
    # v32: LOG detect + per-file dialogs (portat din bash)
    # Ordinea: DV → HDR10+ → LOG → HDR10/SDR (identic cu SH)
    # ══════════════════════════════════════════════════════════════════
    $logInfo = Get-SourceInfoExtended $f.FullName $dji
    $skipFile = $false
    $doStreamCopy = $false
    $tripleLayerMode = $false
    $hdr10PlusJson = ""
    $doviRpuFile = ""
    # Reset LOG vars per fisier — previne contaminare din fisierul anterior
    $script:logVideoFilter = ""
    $script:logColorFlags  = @()
    $script:logPixFmt      = ""
    $script:logExtraX265   = ""
    $script:selectedLutPath = ""

    if ($useX264) {
        # ── x264 per-file dialog ─────────────────────────────────────
        if ($logInfo.logProfile) {
            # LOG dialog
            $logResult = Show-LogDialog $f.FullName $f.Name "x264" $logInfo.logProfile $logInfo.cameraMake $logInfo.srcIsVfr
            switch ($logResult) {
                "copy" { $doStreamCopy = $true }
                "skip" { $skipFile = $true }
                default {
                    # Apply LOG filters to videoFilter
                    if ($script:logVideoFilter) {
                        if ($videoFilter.Count -gt 0) {
                            $existingVf = $videoFilter[1]
                            $videoFilter = @("-vf","$($script:logVideoFilter),$existingVf")
                        } else {
                            $videoFilter = @("-vf",$script:logVideoFilter)
                        }
                    }
                }
            }
        }
        if (-not $skipFile -and -not $doStreamCopy -and -not $logInfo.logProfile) {
            # Standard x264 dialog
            $x264Result = Show-X264Dialog $f.FullName $f.Name $si $si.isHDR
            switch ($x264Result) {
                "copy" { $doStreamCopy = $true }
                "skip" { $skipFile = $true }
            }
        }
        if ($skipFile) { $totalSkipped++; continue }
        if ($doStreamCopy) {
            $scOk = Invoke-StreamCopy $f $outFile $mapFlags $container $LogFile $audioParams
            if (-not $scOk) { $totalErrors++ }
            continue
        }
        # Determine x264 profile from dialog or LOG result
        $x264Profile = $x264ProfileGlobal
        if ($logInfo.logProfile) {
            $x264Profile = "high"
            $x264PixFmt = if ($script:logPixFmt) { $script:logPixFmt } else { "yuv420p" }
            if ($x264PixFmt -eq "yuv420p10le") { $x264Profile = "high10" }
        } elseif ($x264Result -eq "10bit") {
            $x264Profile = "high10"; $x264PixFmt = "yuv420p10le"
        } else {
            $x264Profile = "high"; $x264PixFmt = "yuv420p"
        }
        if (-not $x264PixFmt) { $x264PixFmt = switch ($x264Profile) { "high422"{"yuv422p10le"} "high10"{"yuv420p10le"} default{"yuv420p"} } }
        $x264Level = if ([int]$width -ge 3840 -or $x264Profile -eq "high422") { "5.1" }
                     elseif ([int]$width -ge 2560) { "5.0" } else { "4.1" }
        $x264BF = @("-bf","3")
        $x264Refs = if ($x264Profile -in @("high10","high422")) { @("-refs","4") } else { @("-refs","3") }
        $x264ExtraFlag = if ($extraParams) { @("-x264-params",$extraParams) } else { @() }
        $x264ColorFlags = if ($script:logColorFlags) { $script:logColorFlags } else { @() }
        Write-Host "  Profil: $x264Profile | Level: $x264Level | Container: $container" -ForegroundColor White

        $ffArgs = @("-threads","0","-i",$f.FullName) + $mapFlags +
                  @("-c:v","libx264","-preset",$selectedPreset) + $tuneFlag + $crfFlag +
                  @("-profile:v",$x264Profile,"-level:v",$x264Level,"-pix_fmt",$x264PixFmt) +
                  $x264BF + $x264Refs + $x264ExtraFlag + $x264ColorFlags +
                  $videoFilter + $fpsFlag + $rateParams + $audioParams + $loudnormFlag +
                  (Get-SubtitleCodec $f.FullName $container) + @("-c:t","copy") +
                  $containerFlags + @("-progress",$progFile,"-nostats",$outFile)

    } elseif ($useAV1) {
        # ── AV1 per-file dialog ──────────────────────────────────────
        $av1PresetMap = if ($av1Impl -eq "libsvtav1") {
            @{"1"=0;"2"=2;"3"=4;"4"=5;"5"=6;"6"=7;"7"=8;"8"=10;"9"=12}
        } else { @{"1"=0;"2"=1;"3"=2;"4"=3;"5"=4;"6"=5;"7"=6;"8"=7;"9"=8} }
        $av1Preset = if ($av1PresetMap.ContainsKey($pc2)) { $av1PresetMap[$pc2] }
                     else { if ($av1Impl -eq "libsvtav1") { 6 } else { 4 } }
        $fgLevel = if ($selectedTune -match '^\d+$') { [int]$selectedTune } else { 0 }
        $fgSuffix = if ($fgLevel -gt 0 -and $av1Impl -eq "libsvtav1") {
            ":film-grain=${fgLevel}:film-grain-denoise=0"
        } else { "" }
        $av1Color = @()
        $av1PixFmt = "yuv420p10le"
        $hdr10PlusAv1Param = ""

        # DV check
        $doViAv1 = & ffprobe -v error -show_entries stream=codec_tag_string `
            -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null |
            Select-String -Pattern "dovi|dvhe|dvh1" -CaseSensitive:$false
        if ($doViAv1) {
            Write-Host "  DOLBY VISION detectat — AV1 nu suporta DV nativ." -ForegroundColor Yellow
            Write-Host "  1-Converteste la HDR10 (pierde layer DV)  2-Sari" -ForegroundColor White
            $dvAv1 = Read-Host "  Alege [implicit: 2]"
            if ($dvAv1 -ne "1") { $totalSkipped++; continue }
            $av1Color = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
        }
        # HDR10+ dialog
        elseif ($si.isHDRPlus) {
            $hdr10pResult = Show-Hdr10PlusDialog $f.FullName
            switch ($hdr10pResult) {
                "copy"    { $doStreamCopy = $true }
                "static"  { $av1Color = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc") }
                default   {
                    # preserve or triple (triple not supported on AV1)
                    $av1Color = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                    if ($hdr10pResult -eq "preserve") {
                        $jsonPath = Extract-Hdr10PlusMetadata $f.FullName
                        if ($jsonPath -and $av1Impl -eq "libsvtav1") {
                            $hdr10PlusAv1Param = ":hdr10plus-json=$jsonPath"
                            $hdr10PlusJson = $jsonPath
                        }
                    }
                }
            }
        }
        # LOG dialog
        elseif ($logInfo.logProfile) {
            $logResult = Show-LogDialog $f.FullName $f.Name "av1" $logInfo.logProfile $logInfo.cameraMake $logInfo.srcIsVfr
            switch ($logResult) {
                "copy" { $doStreamCopy = $true }
                "skip" { $skipFile = $true }
                default {
                    if ($script:logVideoFilter) {
                        if ($videoFilter.Count -gt 0) { $videoFilter = @("-vf","$($script:logVideoFilter),$($videoFilter[1])") }
                        else { $videoFilter = @("-vf",$script:logVideoFilter) }
                    }
                    $av1Color = if ($script:logColorFlags) { $script:logColorFlags } else { @() }
                    $av1PixFmt = if ($script:logPixFmt) { $script:logPixFmt } else { "yuv420p10le" }
                }
            }
        }
        # Source dialog (HDR10/SDR)
        elseif (-not $doViAv1) {
            $srcResult = Show-SourceDialog $f.FullName $f.Name $si
            switch ($srcResult) {
                "copy"        { $doStreamCopy = $true }
                "skip"        { $skipFile = $true }
                "hdr10"       { $av1Color = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc") }
                "sdr_tonemap" {
                    $av1Color = @("-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709")
                    $tmVf = "zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p10le"
                    if ($videoFilter.Count -gt 0) { $videoFilter = @("-vf","$tmVf,$($videoFilter[1])") }
                    else { $videoFilter = @("-vf",$tmVf) }
                }
            }
        }
        if ($skipFile) { $totalSkipped++; continue }
        if ($doStreamCopy) {
            $scOk = Invoke-StreamCopy $f $outFile $mapFlags $container $LogFile $audioParams
            if (-not $scOk) { $totalErrors++ }
            continue
        }

        Write-Host "  $av1Impl | Preset: $av1Preset | Film-grain: $fgLevel" -ForegroundColor White
        $isVbr = ($encMode -eq "2")
        $svtParams = if ($isVbr) {
            "preset=${av1Preset}:rc=1:lp=$([Environment]::ProcessorCount)${fgSuffix}${hdr10PlusAv1Param}"
        } else {
            "preset=${av1Preset}:lp=$([Environment]::ProcessorCount)${fgSuffix}${hdr10PlusAv1Param}"
        }
        if ($extraParams -and $av1Impl -eq "libsvtav1") { $svtParams += ":$extraParams" }
        $libaomExtra = if ($extraParams -and $av1Impl -eq "libaom-av1") { $extraParams -split '\s+' | Where-Object { $_ } } else { @() }

        if ($av1Impl -eq "libsvtav1") {
            $ffArgs = @("-threads","0","-i",$f.FullName) + $mapFlags +
                      @("-c:v","libsvtav1") + $crfFlag +
                      @("-pix_fmt",$av1PixFmt,"-svtav1-params",$svtParams) +
                      $videoFilter + $fpsFlag + $av1Color + $rateParams + $audioParams + $loudnormFlag +
                      (Get-SubtitleCodec $f.FullName $container) + @("-c:t","copy") +
                      $containerFlags + @("-progress",$progFile,"-nostats",$outFile)
        } else {
            $libaomBv = if (-not $isVbr) { @("-b:v","0") } else { @() }
            $libaomFg = if ($fgLevel -gt 0) { @("-denoise-noise-level",$fgLevel) } else { @() }
            $ffArgs = @("-threads","0","-i",$f.FullName) + $mapFlags +
                      @("-c:v","libaom-av1") + $crfFlag + $libaomBv +
                      @("-pix_fmt",$av1PixFmt,"-cpu-used",$av1Preset,"-row-mt","1") +
                      $libaomFg + $libaomExtra + $videoFilter + $fpsFlag + $av1Color + $rateParams + $audioParams + $loudnormFlag +
                      (Get-SubtitleCodec $f.FullName $container) + @("-c:t","copy") +
                      $containerFlags + @("-progress",$progFile,"-nostats",$outFile)
        }

    } elseif ($useHWEnc) {
        # ── HW Encode (NVENC/QSV/AMF) per-file ──────────────────────
        Write-Host "  HW Encode: $hwEncName | Preset: $hwEncPreset | QP: $hwEncQP" -ForegroundColor Green
        $hwQpFlag = if ($hwEncCodec -match "nvenc") {
            @("-rc","constqp","-qp",$hwEncQP)
        } elseif ($hwEncCodec -match "qsv") {
            @("-global_quality",$hwEncQP)
        } else {
            # AMF
            @("-rc","cqp","-qp_i",$hwEncQP,"-qp_p",$hwEncQP)
        }
        $hwPresetFlag = if ($hwEncCodec -match "nvenc") {
            @("-preset",$hwEncPreset)
        } elseif ($hwEncCodec -match "qsv") {
            @("-preset",$hwEncPreset)
        } else {
            @("-quality",$hwEncPreset)
        }
        $hwPixFmt = "yuv420p"
        # 10-bit for NVENC/QSV if source is 10-bit
        if ($si.is10bit -and $hwEncCodec -match "nvenc|qsv") {
            $hwPixFmt = "p010le"
        }
        $ffArgs = @("-threads","0","-i",$f.FullName) + $mapFlags +
                  @("-c:v",$hwEncCodec) + $hwQpFlag + $hwPresetFlag +
                  @("-pix_fmt",$hwPixFmt) +
                  $videoFilter + $fpsFlag + $audioParams + $loudnormFlag +
                  (Get-SubtitleCodec $f.FullName $container) + @("-c:t","copy") +
                  $containerFlags + @("-progress",$progFile,"-nostats",$outFile)

    } elseif ($useProRes) {
        # ── ProRes per-file ──────────────────────────────────────────
        # LOG format — ProRes pastreaza Log-ul intact automat
        if ($logInfo.logProfile) {
            $profileLabel = Get-LogProfileLabel $logInfo.logProfile
            Write-Host "  LOG detectat: $profileLabel — ProRes pastreaza profilul Log intact." -ForegroundColor Green
        }
        $profileNum = switch ($proresProfile) {
            "proxy" { 0 } "lt" { 1 } "standard" { 2 } "hq" { 3 } "4444" { 4 } "xq" { 4 } default { 3 }
        }
        $proresPixFmt = switch ($proresProfile) {
            "4444" { "yuva444p10le" } "xq" { "yuva444p10le" } default { "yuv422p10le" }
        }
        $proresQuality = switch ($proresProfile) {
            "proxy" { "ProRes Proxy (~45 Mbps)" } "lt" { "ProRes LT (~100 Mbps)" }
            "standard" { "ProRes Standard (~145 Mbps)" } "hq" { "ProRes HQ (~220 Mbps)" }
            "4444" { "ProRes 4444 (~330 Mbps, alpha)" } "xq" { "ProRes 4444 XQ (~500 Mbps)" }
            default { "ProRes HQ (~220 Mbps)" }
        }
        $xqFlag = if ($proresProfile -eq "xq") { @("-qscale:v","1") } else { @() }
        Write-Host "  Profil: $proresQuality | PixFmt: $proresPixFmt | Container: $container" -ForegroundColor White
        "  Profil: $proresQuality | Container: $container" | Out-File $LogFile -Append -Encoding UTF8

        # ProRes uses simple map flags (no DJI tracks in mov)
        $proresMapFlags = @("-map","0:v:0","-map","0:a","-map","0:s?","-map_metadata","0","-map_chapters","0")

        $ffArgs = @("-threads","0","-i",$f.FullName) + $proresMapFlags +
                  @("-c:v","prores_ks","-profile:v",$profileNum,"-pix_fmt",$proresPixFmt,
                    "-vendor","apl0","-bits_per_mb","8000") + $xqFlag +
                  $videoFilter + $fpsFlag + $audioParams + $loudnormFlag +
                  (Get-SubtitleCodec $f.FullName $container) + @("-c:t","copy") +
                  $containerFlags + @("-progress",$progFile,"-nostats",$outFile)

    } elseif ($useDNxHR) {
        # ── DNxHR per-file ───────────────────────────────────────────
        # LOG format — DNxHR pastreaza Log-ul intact automat
        if ($logInfo.logProfile) {
            $profileLabel = Get-LogProfileLabel $logInfo.logProfile
            Write-Host "  LOG detectat: $profileLabel — DNxHR pastreaza profilul Log intact." -ForegroundColor Green
        }
        $dnxhrPixFmt = switch ($dnxhrProfile) {
            "hqx" { "yuv422p12le" } "444" { "yuv444p10le" } default { "yuv422p10le" }
        }
        $dnxhrProfFlag = switch ($dnxhrProfile) {
            "lb" { "dnxhr_lb" } "hq" { "dnxhr_hq" } "hqx" { "dnxhr_hqx" } "444" { "dnxhr_444" } default { "dnxhr_sq" }
        }
        if ($si.isHDR -and $dnxhrProfile -ne "hqx") {
            Write-Host "  ATENTIE: Sursa HDR — pentru HDR workflow recomandat profil HQX (12-bit)." -ForegroundColor Yellow
        }
        Write-Host "  Profil: $dnxhrProfile | PixFmt: $dnxhrPixFmt | Container: $container" -ForegroundColor White
        "  Profil: $dnxhrProfile | Container: $container" | Out-File $LogFile -Append -Encoding UTF8
        $dnxMapFlags = @("-map","0:v:0","-map","0:a","-map","0:s?","-map_metadata","0","-map_chapters","0")

        $ffArgs = @("-threads","0","-i",$f.FullName) + $dnxMapFlags +
                  @("-c:v","dnxhd","-profile:v",$dnxhrProfFlag,"-pix_fmt",$dnxhrPixFmt) +
                  $videoFilter + $fpsFlag + $audioParams + $loudnormFlag +
                  (Get-SubtitleCodec $f.FullName $container) + @("-c:t","copy") +
                  $containerFlags + @("-progress",$progFile,"-nostats",$outFile)

    } else {
        # ── x265 per-file dialog ─────────────────────────────────────
        $doVi = & ffprobe -v error -show_entries stream=codec_tag_string `
            -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null |
            Select-String -Pattern "dovi|dvhe|dvh1" -CaseSensitive:$false

        $colorParams = @(); $x265Hdr = ""
        $x265PixFmt = "yuv420p10le"

        if ($doVi) {
            # Dolby Vision dialog
            $dvP = Get-DVProfile $f.FullName
            Write-Host ""; Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Magenta
            Write-Host "  ║  DOLBY VISION: $($f.Name)" -ForegroundColor Magenta
            Write-Host "  ║  Profil: $dvP" -ForegroundColor Magenta
            Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Magenta
            Write-Host "  ║  1-Stream copy  2-HDR10 (best-effort)  3-Sari║" -ForegroundColor White
            Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Magenta
            $dvc = Read-Host "  Alege"
            if ($dvc -eq "3") { $totalSkipped++; continue }
            if ($dvc -eq "1") {
                $scOk = Invoke-StreamCopy $f $outFile $mapFlags $container $LogFile $audioParams
                if (-not $scOk) { $totalErrors++ }
                continue
            }
            # DV re-encode → HDR10 best-effort
            $colorParams = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
            $x265Hdr = "hdr-opt=1:repeat-headers=1:hdr10=1:"

        } elseif ($si.isHDRPlus) {
            # HDR10+ dialog
            $hdr10pResult = Show-Hdr10PlusDialog $f.FullName
            switch ($hdr10pResult) {
                "copy" {
                    $scOk = Invoke-StreamCopy $f $outFile $mapFlags $container $LogFile $audioParams
                    if (-not $scOk) { $totalErrors++ }
                    continue
                }
                "static" {
                    $colorParams = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                    $x265Hdr = "hdr-opt=1:repeat-headers=1:hdr10=1:"
                }
                "triple" {
                    # Triple-layer pipeline
                    $hdr10PlusJson = Extract-Hdr10PlusMetadata $f.FullName
                    if ($hdr10PlusJson) {
                        $doviRpuFile = Generate-DvRpuFromHdr10Plus $hdr10PlusJson
                        if ($doviRpuFile) {
                            $tripleLayerMode = $true
                            Write-Host "  Triple-layer: HDR10+ JSON + DV RPU pregatite" -ForegroundColor Green
                        }
                    }
                    $colorParams = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                    $x265Hdr = "hdr-opt=1:repeat-headers=1:hdr10=1:"
                    if ($hdr10PlusJson) { $x265Hdr += "dhdr10-info=${hdr10PlusJson}:" }
                }
                default {
                    # preserve HDR10+ metadata
                    $hdr10PlusJson = Extract-Hdr10PlusMetadata $f.FullName
                    $colorParams = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                    $x265Hdr = "hdr-opt=1:repeat-headers=1:hdr10=1:"
                    if ($hdr10PlusJson) { $x265Hdr += "dhdr10-info=${hdr10PlusJson}:" }
                }
            }

        } elseif ($logInfo.logProfile) {
            # LOG dialog
            $logResult = Show-LogDialog $f.FullName $f.Name "x265" $logInfo.logProfile $logInfo.cameraMake $logInfo.srcIsVfr
            switch ($logResult) {
                "copy" {
                    $scOk = Invoke-StreamCopy $f $outFile $mapFlags $container $LogFile $audioParams
                    if (-not $scOk) { $totalErrors++ }
                    continue
                }
                "skip" { $totalSkipped++; continue }
                default {
                    if ($script:logVideoFilter) {
                        if ($videoFilter.Count -gt 0) { $videoFilter = @("-vf","$($script:logVideoFilter),$($videoFilter[1])") }
                        else { $videoFilter = @("-vf",$script:logVideoFilter) }
                    }
                    $colorParams = if ($script:logColorFlags) { $script:logColorFlags } else { @() }
                    $x265PixFmt = if ($script:logPixFmt) { $script:logPixFmt } else { "yuv420p10le" }
                    if ($script:logExtraX265) {
                        $x265Hdr = "$($script:logExtraX265):"
                    }
                }
            }

        } else {
            # Source dialog (HDR10/SDR)
            $srcResult = Show-SourceDialog $f.FullName $f.Name $si
            switch ($srcResult) {
                "copy" {
                    $scOk = Invoke-StreamCopy $f $outFile $mapFlags $container $LogFile $audioParams
                    if (-not $scOk) { $totalErrors++ }
                    continue
                }
                "skip" { $totalSkipped++; continue }
                "hdr10" {
                    $colorParams = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                    $x265Hdr = "hdr-opt=1:repeat-headers=1:hdr10=1:"
                }
                "sdr_tonemap" {
                    $colorParams = @("-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709")
                    $tmVf = "zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p10le"
                    if ($videoFilter.Count -gt 0) { $videoFilter = @("-vf","$tmVf,$($videoFilter[1])") }
                    else { $videoFilter = @("-vf",$tmVf) }
                }
                default {
                    # SDR 10-bit — no color params needed
                }
            }
        }

        $nProc = [Environment]::ProcessorCount
        $x265Params = "${x265Hdr}pools=${nProc}:aq-mode=3:aq-strength=1.0"
        if ($extraParams) { $x265Params += ":$extraParams" }
        # Remove trailing colon if present
        $x265Params = $x265Params -replace '::+',':'
        $x265Params = $x265Params.TrimEnd(':')
        Write-Host "  Container: $container | Preset: $selectedPreset" -ForegroundColor White

        $ffArgs = @("-threads","0","-i",$f.FullName) + $mapFlags +
                  @("-c:v","libx265","-preset",$selectedPreset) + $tuneFlag + $crfFlag +
                  @("-pix_fmt",$x265PixFmt,"-x265-params",$x265Params) +
                  $videoFilter + $fpsFlag + $colorParams + $rateParams + $audioParams + $loudnormFlag +
                  (Get-SubtitleCodec $f.FullName $container) + @("-c:t","copy") +
                  $containerFlags + @("-progress",$progFile,"-nostats",$outFile)
    }

    $proc = Start-Process ffmpeg -ArgumentList $ffArgs -NoNewWindow -PassThru `
        -RedirectStandardError "$env:TEMP\fferr.txt"
    Show-Progress $proc $progFile $durSec $startTime; $proc.WaitForExit()

    # Cleanup vidstab .trf
    if ($trfFile -and (Test-Path $trfFile)) { Remove-Item $trfFile -Force -ErrorAction SilentlyContinue }

    if ($proc.ExitCode -ne 0) {
        Write-Host "  EROARE encode!" -ForegroundColor Red
        if (Test-Path $outFile) { Remove-Item $outFile -Force }
        if ($hdr10PlusJson -and (Test-Path $hdr10PlusJson)) { Remove-Item $hdr10PlusJson -Force -ErrorAction SilentlyContinue }
        if ($doviRpuFile -and (Test-Path $doviRpuFile)) { Remove-Item $doviRpuFile -Force -ErrorAction SilentlyContinue }
        $totalErrors++; continue
    }

    # ── Triple-layer: injecteaza DV RPU in HEVC output ───────────────
    if ($tripleLayerMode -and $doviRpuFile) {
        Write-Host "  Triple-layer: Injectez DV RPU in output..." -ForegroundColor Cyan
        $hevcTemp = Join-Path $env:TEMP ("hevc_"+[guid]::NewGuid().ToString("N")+".hevc")
        & ffmpeg -v error -i $outFile -c:v copy -bsf:v hevc_mp4toannexb -f hevc $hevcTemp 2>>"$LogFile"
        if ($LASTEXITCODE -eq 0 -and (Test-Path $hevcTemp)) {
            $injectedTemp = Join-Path $env:TEMP ("injected_"+[guid]::NewGuid().ToString("N")+".hevc")
            if (Inject-DvRpu $hevcTemp $doviRpuFile $injectedTemp) {
                $finalTemp = Join-Path $env:TEMP ("final_"+[guid]::NewGuid().ToString("N")+".$container")
                $tlContFlags = Get-ContainerFlags $container
                $tlArgs = @("-v","error","-i",$injectedTemp,"-i",$outFile,
                           "-map","0:v:0","-map","1:a","-map","1:s?","-map","1:t?",
                           "-c","copy") + $tlContFlags + @($finalTemp)
                & ffmpeg @tlArgs 2>>"$LogFile"
                if ($LASTEXITCODE -eq 0 -and (Test-Path $finalTemp) -and (Get-Item $finalTemp).Length -gt 0) {
                    Move-Item -Force $finalTemp $outFile
                    Write-Host "  Triple-layer: DV Profile 8.1 + HDR10 + HDR10+ — OK" -ForegroundColor Green
                    "  Triple-layer: DV Profile 8.1 + HDR10 + HDR10+" | Out-File $LogFile -Append -Encoding UTF8
                } else {
                    Write-Host "  Triple-layer: Re-mux esuat — output fara DV (HDR10+ pastrat)" -ForegroundColor Yellow
                    Remove-Item $finalTemp -Force -ErrorAction SilentlyContinue
                }
            } else {
                Write-Host "  Triple-layer: Injectare RPU esuata — output fara DV" -ForegroundColor Yellow
            }
            Remove-Item $injectedTemp -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "  Triple-layer: Extractie HEVC esuata" -ForegroundColor Yellow
        }
        Remove-Item $hevcTemp -Force -ErrorAction SilentlyContinue
    }
    # Cleanup HDR10+ / DV temp files
    if ($hdr10PlusJson -and (Test-Path $hdr10PlusJson)) { Remove-Item $hdr10PlusJson -Force -ErrorAction SilentlyContinue }
    if ($doviRpuFile -and (Test-Path $doviRpuFile)) { Remove-Item $doviRpuFile -Force -ErrorAction SilentlyContinue }

    $newSize   = (Get-Item $outFile).Length
    $saved     = [math]::Max(0, $f.Length - $newSize)
    $totalSaved += $saved
    $encTime   = [int](Get-Date).Subtract($startTime).TotalSeconds
    $totalDone++

    # Batch summary per fisier
    $batchNames  += $f.Name
    $batchTimes  += $encTime
    $batchOrig   += $f.Length
    $batchNew    += $newSize
    $ratio = if ($f.Length -gt 0) { [math]::Round($newSize * 100.0 / $f.Length, 1) } else { "N/A" }
    $batchRatios += $ratio

    Write-Host "  Original: $(Format-Bytes $f.Length) | Encodat: $(Format-Bytes $newSize) | Economisit: $(Format-Bytes $saved)" -ForegroundColor Green
    Write-Host "  Timp: $([int]($encTime/60))m $($encTime%60)s" -ForegroundColor White
    "  Salvat: $(Format-Bytes $saved)" | Out-File $LogFile -Append -Encoding UTF8
    # Mark done for resume (atomic: write temp → rename)
    $bpTemp = "${batchProgressFile}.tmp"
    if (Test-Path $batchProgressFile) {
        Copy-Item $batchProgressFile $bpTemp -Force
    }
    $f.Name | Out-File $bpTemp -Append -Encoding UTF8
    Move-Item -Force $bpTemp $batchProgressFile

    # ── MOD INTERACTIV: dialog dupa fiecare fisier ────────────────
    if ($interactiveMode -and $totalDone -lt $inputFiles.Count) {
        $intResult = Show-InteractiveSettingsDialog
        if ($intResult -eq "stop") {
            # Skip remaining files
            break
        }
    }
}

# Dry-run summary
if ($dryRun) {
    Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  DRY-RUN COMPLET — $encoderName [$origContainer]" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "  Fisiere analizate: $totalDone | Sarite: $totalSkipped" -ForegroundColor White
    Write-Host "  Nu s-a encodat nimic — aceasta a fost doar o simulare." -ForegroundColor Yellow
    Read-Host "`nApasa Enter"; exit
}
# Clear batch progress la finalizarea cu succes
if (Test-Path $batchProgressFile) { Remove-Item $batchProgressFile -Force -ErrorAction SilentlyContinue }

$totalTime = [int](Get-Date).Subtract($grandStart).TotalSeconds
Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  STATISTICI — $encoderName [$origContainer]" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Procesate: $totalDone | Sarite: $totalSkipped | Erori: $totalErrors" -ForegroundColor White
Write-Host "  Spatiu salvat: $(Format-Bytes $totalSaved)" -ForegroundColor Green
Write-Host "  Timp: $([int]($totalTime/3600))h $([int](($totalTime%3600)/60))m $($totalTime%60)s"

# ── Rezumat batch detaliat ────────────────────────────────────────────
if ($batchNames.Count -gt 1) {
    Write-Host "`n── REZUMAT BATCH DETALIAT ──────────────────────────" -ForegroundColor Cyan
    $fastIdx = 0; $slowIdx = 0
    for ($i = 0; $i -lt $batchNames.Count; $i++) {
        $origMb = [math]::Round($batchOrig[$i]/1MB, 0)
        $newMb  = [math]::Round($batchNew[$i]/1MB, 0)
        $tm     = $batchTimes[$i]
        Write-Host "  $($batchNames[$i]): ${origMb}MB → ${newMb}MB ($($batchRatios[$i])%) | $([int]($tm/60))m" -ForegroundColor White
        if ($tm -lt $batchTimes[$fastIdx]) { $fastIdx = $i }
        if ($tm -gt $batchTimes[$slowIdx]) { $slowIdx = $i }
        # Log to file
        "  $($batchNames[$i]): ${origMb}MB→${newMb}MB ($($batchRatios[$i])%) $([int]($tm/60))m" | Out-File $LogFile -Append -Encoding UTF8
    }
    Write-Host "  Cel mai rapid: $($batchNames[$fastIdx]) | Cel mai lent: $($batchNames[$slowIdx])" -ForegroundColor Yellow
}

Write-Host "  Log: $LogFile" -ForegroundColor White
"FINAL: $totalDone procesate $(Format-Bytes $totalSaved) [$encoderName/$container]" |
    Out-File $LogFile -Append -Encoding UTF8
Read-Host "`nApasa Enter"
