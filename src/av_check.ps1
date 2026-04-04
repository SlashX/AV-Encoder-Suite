# ══════════════════════════════════════════════════════════════════════
# av_check.ps1 — Analiza completa fisiere video + audio, export CSV
# Script standalone — echivalent av_check.sh (Termux)
# Rulare: powershell -ExecutionPolicy Bypass -File av_check.ps1
# ══════════════════════════════════════════════════════════════════════

if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "[EROARE] ffprobe nu a fost gasit." -ForegroundColor Red
    Write-Host "Instaleaza ffmpeg (include ffprobe) si adauga in PATH."
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

function Get-SizeEst {
    param([long]$bps, [int]$dur)
    if ($dur -le 0) { return "N/A" }
    $mb = [long]($bps * $dur / 8 / 1MB)
    if ($mb -ge 1024) { "~{0:F1} GB" -f ($mb/1024) } else { "~$mb MB" }
}

function Get-SourceInfo {
    param([string]$file)
    $codec    = Get-FFprobeValue $file "v:0" "codec_name"
    $pixFmt   = Get-FFprobeValue $file "v:0" "pix_fmt"
    $transfer = Get-FFprobeValue $file "v:0" "color_transfer"
    $hdrPlus  = & ffprobe -v error -show_frames -select_streams v:0 `
        -read_intervals "%+#5" -show_entries frame_side_data=type `
        "$file" 2>$null | Select-String "HDR10+"
    $is10bit   = $pixFmt -match "10"
    $isHDRPlus = [bool]$hdrPlus
    $isHDR     = $transfer -eq "smpte2084" -or $isHDRPlus
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
        "prores"     { "Apple ProRes" }
        "apv"        { "Samsung APV" }
        "mpeg2video" { "MPEG-2" }
        default { if ($is10bit) { "$codec 10bit" } else { "$codec 8bit" } }
    }
    return @{ fmt=$fmt; codec=$codec; pixFmt=$pixFmt; is10bit=$is10bit;
              isHDR=$isHDR; isHDRPlus=$isHDRPlus; transfer=$transfer }
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
            "4" { "Profil 4 (DV+HDR10)" } "5" { "Profil 5 (DV only)" } "7" { "Profil 7 (DV+HDR10+)" }
            "8" { switch ($c) { "1"{"Profil 8.1 (DV+HDR10, Blu-ray)"} "2"{"Profil 8.2 (DV+SDR)"} "4"{"Profil 8.4 (DV+HLG)"} default{"Profil 8 (DV+HDR10)"} } }
            "9" { "Profil 9 (DV+SDR)" } default { "Profil $n" }
        }
    } else { "Dolby Vision (profil nedetectat)" }
}

function Get-DJITracks {
    param([string]$file)
    $allTracks = & ffprobe -v error `
        -show_entries stream=index,codec_tag_string,codec_name,codec_type `
        -of default=noprint_wrappers=1 "$file" 2>$null
    $hasDjmd  = [bool]($allTracks | Where-Object { $_ -imatch "djmd" })
    $hasDbgi  = [bool]($allTracks | Where-Object { $_ -imatch "dbgi" })
    $hasTC    = [bool]($allTracks | Where-Object { $_ -imatch "tmcd" })
    return @{ hasDjmd=$hasDjmd; hasDbgi=$hasDbgi; hasTC=$hasTC; isDji=($hasDjmd -or $hasDbgi) }
}

function Get-LogProfile {
    param([string]$file, [bool]$isDji)
    $allTags = & ffprobe -v error -show_entries format_tags `
        -of default=noprint_wrappers=1 "$file" 2>$null | Out-String
    $cameraMake = ""
    if     ($allTags -imatch "make=.*apple")                          { $cameraMake = "apple" }
    elseif ($allTags -imatch "make=.*dji")                            { $cameraMake = "dji" }
    elseif ($allTags -imatch "manufacturer=.*samsung|make=.*samsung") { $cameraMake = "samsung" }
    if (-not $cameraMake -and $isDji) { $cameraMake = "dji" }

    $srcTrc = Get-FFprobeValue $file "v:0" "color_transfer"
    $srcBps = Get-FFprobeValue $file "v:0" "bits_per_raw_sample"
    if (-not $srcBps -or $srcBps -notmatch '^\d+$') { $srcBps = "8" }
    $srcBps = [int]$srcBps
    $srcPrimaries = Get-FFprobeValue $file "v:0" "color_primaries"
    $transfer = Get-FFprobeValue $file "v:0" "color_transfer"
    $hdrPlus = & ffprobe -v error -show_frames -select_streams v:0 `
        -read_intervals "%+#5" -show_entries frame_side_data=type `
        "$file" 2>$null | Select-String "HDR10+"
    $isHdrPlus = [bool]$hdrPlus
    $dovi = & ffprobe -v error -show_entries stream=codec_tag_string `
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>$null |
        Select-String -Pattern "dovi|dvhe|dvh1" -CaseSensitive:$false

    if ($cameraMake -eq "apple" -and $srcBps -ge 10 -and ($srcPrimaries -match "bt2020" -or $srcTrc -match "arib|log")) {
        return "Apple Log (iPhone)"
    } elseif ($cameraMake -eq "samsung" -and $srcBps -ge 10 -and $srcPrimaries -match "bt2020" -and -not $isHdrPlus -and $transfer -ne "smpte2084") {
        return "Samsung Log (S24 Ultra)"
    } elseif ($cameraMake -eq "dji" -and $srcBps -ge 10 -and $srcPrimaries -match "bt2020") {
        return "D-Log M (DJI)"
    } elseif ($srcBps -ge 10 -and $srcPrimaries -match "bt2020" -and -not $isHdrPlus -and $transfer -ne "smpte2084" -and -not $dovi) {
        if ($srcTrc -eq "unknown" -or $srcTrc -match "log|arib") { return "LOG (brand necunoscut)" }
    }
    return "N/A"
}

# ══════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════
Clear-Host
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     AV CHECK — ANALIZA FISIERE MEDIA     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan

$inputFiles = Get-ChildItem -Path $InputDir -Include "*.mp4","*.mov","*.mkv","*.m2ts","*.mts","*.vob","*.mxf","*.apv" -File
$fileCount  = $inputFiles.Count
$totalSz    = ($inputFiles | Measure-Object -Property Length -Sum).Sum
Write-Host "INPUT: $InputDir | Fisiere: $fileCount | $(Format-Bytes $totalSz)" -ForegroundColor Yellow
if ($fileCount -eq 0) { Write-Host "Nu am gasit fisiere." -ForegroundColor Red; Read-Host; exit }

$csvPath = Join-Path $OutputDir "av_check_report.csv"
"Fisier,FormatSursa,Dimensiune(MB),Durata(sec),Rezolutie,PixelFmt,FPS,Bitrate_video(Mbps),TipHDR,Profil_DV,LogProfile,AudioCodec,AudioBitrate(kbps),SampleRate(kHz),BitDepth,Layout,Limba,Canale_audio,AudioTrackuri,Subtitrari,Capitole,Attachments,DJI_djmd,DJI_dbgi,DJI_TC,Recomandat_encoder,Est_x265,Est_x264,Est_AV1,Est_ProRes" |
    Out-File $csvPath -Encoding UTF8

$count = 0
foreach ($f in $inputFiles) {
    $count++
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    Write-Host "Analizam ($count/$fileCount): $($f.Name)" -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray

    $si = Get-SourceInfo $f.FullName
    if (-not $si.fmt -or $si.fmt -eq " 8bit") {
        Write-Host "  ATENTIE: Nu s-a gasit stream video valid — sarit." -ForegroundColor Red; continue
    }

    $w = Get-FFprobeValue $f.FullName "v:0" "width"
    $h = Get-FFprobeValue $f.FullName "v:0" "height"
    $ac = Get-FFprobeValue $f.FullName "a:0" "codec_name"
    $ab = Get-FFprobeValue $f.FullName "a:0" "bit_rate"
    $abk = if ($ab -match '^\d+$') { [math]::Round([long]$ab / 1000) } else { "N/A" }
    $audioChannelsRaw = Get-FFprobeValue $f.FullName "a:0" "channels"
    $audioChannels = if ($audioChannelsRaw -match '^\d+$') { $audioChannelsRaw } else { "N/A" }
    $audioSR = Get-FFprobeValue $f.FullName "a:0" "sample_rate"
    $audioSRk = if ($audioSR -match '^\d+$') { [math]::Round([long]$audioSR / 1000, 1) } else { "N/A" }
    $audioBD = Get-FFprobeValue $f.FullName "a:0" "bits_per_raw_sample"
    if (-not $audioBD -or $audioBD -eq "0") { $audioBD = Get-FFprobeValue $f.FullName "a:0" "bits_per_sample" }
    if (-not $audioBD -or $audioBD -eq "0") { $audioBD = "N/A" }
    $audioLayout = Get-FFprobeValue $f.FullName "a:0" "channel_layout"
    if (-not $audioLayout) {
        $audioLayout = switch ($audioChannels) { "1"{"mono"} "2"{"stereo"} "6"{"5.1"} "8"{"7.1"} default{"${audioChannels}ch"} }
    }
    $audioLangRaw = & ffprobe -v error -select_streams a:0 -show_entries stream_tags=language -of csv=p=0 $f.FullName 2>$null | Select-Object -First 1
    $audioLang = if ($audioLangRaw) { $audioLangRaw.Trim() } else { "und" }
    $fsMB = [math]::Round($f.Length / 1MB, 1)
    $fpsRaw = Get-FFprobeValue $f.FullName "v:0" "avg_frame_rate"
    $bitrateRaw = Get-FFprobeValue $f.FullName "v:0" "bit_rate"
    $bitrateMbps = if ($bitrateRaw -match '^\d+$') { [math]::Round([long]$bitrateRaw / 1000000, 2) } else { "N/A" }
    $durRaw = & ffprobe -v error -show_entries format=duration `
        -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null
    $durSec = if ($durRaw -match '^\d+') { [int]([double]$durRaw) } else { 0 }
    $audioTracks = (& ffprobe -v error -select_streams a `
        -show_entries stream=index -of csv=p=0 $f.FullName 2>$null |
        Where-Object { $_ -match '^\d' }).Count
    $subStreams = & ffprobe -v error -select_streams s `
        -show_entries stream=index:stream_tags=language `
        -of default=noprint_wrappers=1 $f.FullName 2>$null
    $subCount = ($subStreams | Where-Object { $_ -match "^index=" }).Count
    $subLangs = ($subStreams | Where-Object { $_ -match "^TAG:language=" } |
        ForEach-Object { $_ -replace "TAG:language=","" } | Where-Object { $_ -ne "und" }) -join "/"
    $subStr = if ($subCount -gt 0) { if ($subLangs) { "$subCount ($subLangs)" } else { "$subCount" } } else { "Nu" }
    $chapCount = (& ffprobe -v error -show_chapters $f.FullName 2>$null |
        Where-Object { $_ -match "^\[CHAPTER\]" }).Count
    $chapStr = if ($chapCount -gt 0) { "$chapCount capitole" } else { "Nu" }
    $attStreams = & ffprobe -v error -select_streams t `
        -show_entries stream=index:stream_tags=mimetype `
        -of default=noprint_wrappers=1 $f.FullName 2>$null
    $attCount = ($attStreams | Where-Object { $_ -match "^index=" }).Count
    $attStr = if ($attCount -gt 0) { "$attCount" } else { "Nu" }

    $dji = Get-DJITracks $f.FullName
    $doVi = & ffprobe -v error -show_entries stream=codec_tag_string `
        -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null |
        Select-String -Pattern "dovi|dvhe|dvh1" -CaseSensitive:$false
    $tipHdr = "SDR"; $dvProf = "N/A"
    if     ($si.isHDRPlus) { $tipHdr = "HDR10+" }
    elseif ($si.isHDR)     { $tipHdr = "HDR10"  }
    if ($doVi) { $tipHdr = "Dolby Vision"; $dvProf = Get-DVProfile $f.FullName }

    $logProf = Get-LogProfile $f.FullName $dji.isDji

    # Encoder recommendation
    $srcCodec = $si.codec
    $encRec = "libx265 (optiune sigura universala)"
    if     ($tipHdr -eq "Dolby Vision")                          { $encRec = "libx265 (singurul care suporta DV)" }
    elseif ($tipHdr -eq "HDR10+")                                { $encRec = "libx265 sau AV1/SVT (ambele suporta HDR10+)" }
    elseif ($tipHdr -eq "HDR10")                                 { $encRec = "libx265 sau AV1/SVT (ambele suporta HDR10)" }
    elseif ($dji.isDji)                                          { $encRec = "libx265 (fisier DJI — metadata pastrate)" }
    elseif ($srcCodec -eq "av1")                                 { $encRec = "Deja AV1 — re-encode nu e recomandat" }
    elseif ($srcCodec -eq "prores")                              { $encRec = "libx265 sau AV1 (ProRes→compresie ~70-80% mai mic)" }
    elseif ($srcCodec -eq "hevc" -and $tipHdr -eq "SDR")         { $encRec = "AV1/SVT (HEVC→AV1 ~20-30% mai mic)" }
    elseif ($srcCodec -eq "h264")                                { $encRec = "libx265 (H.264→H.265 ~40% mai mic) sau AV1 (~50%)" }

    # Estimates
    $bpsX265 = if ([int]$w -ge 3840) { 10000000 } elseif ([int]$w -ge 1920) { 4000000 } else { 2000000 }
    $bpsX264 = if ([int]$w -ge 3840) { 12000000 } elseif ([int]$w -ge 1920) { 5000000 } else { 2500000 }
    $bpsAV1  = if ([int]$w -ge 3840) { 8000000  } elseif ([int]$w -ge 1920) { 3000000 } else { 1500000 }
    $bpsProRes = if ([int]$w -ge 3840) { 880000000 } elseif ([int]$w -ge 1920) { 220000000 } else { 110000000 }
    if ($tipHdr -match "HDR|Dolby") { $bpsX265 = [int]($bpsX265 * 1.3); $bpsAV1 = [int]($bpsAV1 * 1.3) }
    $estX265 = Get-SizeEst $bpsX265 $durSec
    $estX264 = Get-SizeEst $bpsX264 $durSec
    $estAV1  = Get-SizeEst $bpsAV1  $durSec
    $estProRes = Get-SizeEst $bpsProRes $durSec

    # Terminal output
    Write-Host "  Format sursa : $($si.fmt)"       -ForegroundColor White
    Write-Host "  Dimensiune   : $fsMB MB"          -ForegroundColor White
    Write-Host "  Durata       : $durSec sec"       -ForegroundColor White
    Write-Host "  Rezolutie    : ${w}x${h}"         -ForegroundColor White
    Write-Host "  FPS          : $fpsRaw"           -ForegroundColor White
    Write-Host "  Bitrate video: $bitrateMbps Mb/s" -ForegroundColor White
    Write-Host "  Tip HDR      : $tipHdr" -ForegroundColor $(if ($tipHdr -ne "SDR") { "Magenta" } else { "White" })
    if ($doVi) { Write-Host "  Profil DV    : $dvProf" -ForegroundColor Magenta }
    if ($logProf -ne "N/A") { Write-Host "  LOG Profile  : $logProf" -ForegroundColor Yellow }
    Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Audio        : $ac | $abk kbps | ${audioSRk} kHz | ${audioBD}bit | $audioLayout | $audioLang" -ForegroundColor White
    if ($audioTracks -gt 1) { Write-Host "  Audio tracks : $audioTracks" -ForegroundColor White }
    Write-Host "  Subtitrari   : $subStr"  -ForegroundColor $(if ($subCount -gt 0) { "Green" } else { "Gray" })
    Write-Host "  Capitole     : $chapStr" -ForegroundColor $(if ($chapCount -gt 0) { "Green" } else { "Gray" })
    if ($dji.isDji) {
        Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray
        if ($dji.hasDjmd) { Write-Host "    ✅ djmd  — GPS, telemetrie" -ForegroundColor Green }
        if ($dji.hasDbgi) { Write-Host "    ⚠️  dbgi  — debug (~295 MB)" -ForegroundColor Yellow }
        if ($dji.hasTC)   { Write-Host "    ✅ Timecode" -ForegroundColor Green }
    }
    Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Recomandat   : $encRec" -ForegroundColor Cyan
    Write-Host "    x265   : $estX265"    -ForegroundColor White
    Write-Host "    x264   : $estX264"    -ForegroundColor White
    Write-Host "    AV1    : $estAV1"     -ForegroundColor Green
    Write-Host "    ProRes : $estProRes (HQ)" -ForegroundColor White

    # CSV
    "$($f.Name),$($si.fmt),$fsMB,$durSec,${w}x${h},$($si.pixFmt),$fpsRaw,$bitrateMbps,$tipHdr,$dvProf,$logProf,$ac,$abk,$audioSRk,$audioBD,$audioLayout,$audioLang,$audioChannels,$audioTracks,$subStr,$chapStr,$attStr,$($dji.hasDjmd),$($dji.hasDbgi),$($dji.hasTC),`"$encRec`",$estX265,$estX264,$estAV1,$estProRes" |
        Out-File $csvPath -Append -Encoding UTF8
}

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "Analiza completa! $count fisiere procesate." -ForegroundColor Green
Write-Host "CSV: $csvPath" -ForegroundColor White
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

# ── Comparatie Input vs Output ────────────────────────────────────────
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
            $origV = (& ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 $origFound.FullName 2>$null | Where-Object { $_ -match '^\d' }).Count
            $newV  = (& ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 $of.FullName 2>$null | Where-Object { $_ -match '^\d' }).Count
            $origA = (& ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 $origFound.FullName 2>$null | Where-Object { $_ -match '^\d' }).Count
            $newA  = (& ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 $of.FullName 2>$null | Where-Object { $_ -match '^\d' }).Count
            $streamOk = if ($newV -lt $origV) { "V:$origV>$newV" } elseif ($newA -lt $origA) { "A:$origA>$newA" } else { "OK" }
            Write-Host "  $baseName" -ForegroundColor White
            Write-Host "    $(Format-Bytes $origSize) → $(Format-Bytes $newSize) | ${ratio}% | Salvat: ${savedMB} MB | Streams: $streamOk" -ForegroundColor $(if ($streamOk -eq "OK") { "Green" } else { "Yellow" })
        }
    }
    if ($compCount -gt 0) {
        Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray
        $totalRatio = if ($compTotalOrig -gt 0) { [math]::Round($compTotalNew * 100.0 / $compTotalOrig, 1) } else { "N/A" }
        $totalSavedMB = [int](($compTotalOrig - $compTotalNew) / 1MB)
        Write-Host "  TOTAL: $(Format-Bytes $compTotalOrig) → $(Format-Bytes $compTotalNew) | ${totalRatio}% | Salvat: ${totalSavedMB} MB | Perechi: $compCount" -ForegroundColor Cyan
    } else {
        Write-Host "  Nu s-au gasit perechi Input/Output." -ForegroundColor DarkGray
    }
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
}

Read-Host "Apasa Enter"
