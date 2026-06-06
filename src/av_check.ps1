# ══════════════════════════════════════════════════════════════════════
# av_check.ps1 — Analiza completa fisiere video + audio, export CSV
# Script standalone — echivalent av_check.sh (Termux)
# Rulare: powershell -ExecutionPolicy Bypass -File av_check.ps1
# ══════════════════════════════════════════════════════════════════════

# ── Binare locale: folderul scriptului (src/) are prioritate in PATH ──
$env:PATH = "$PSScriptRoot;$env:PATH"

if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "[EROARE] ffprobe nu a fost gasit." -ForegroundColor Red
    Write-Host "Instaleaza ffmpeg (include ffprobe) si adauga in PATH."
    Read-Host; exit
}

# v57: respect env overrides AV_INPUT_DIR / AV_OUTPUT_DIR (utile pentru CI/testing,
# paritate cu bash care accepta INPUT_DIR/OUTPUT_DIR env)
if ($env:AV_INPUT_DIR)  { $InputDir  = $env:AV_INPUT_DIR }
else                    { $InputDir  = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ($env:AV_OUTPUT_DIR) { $OutputDir = $env:AV_OUTPUT_DIR }
else                    { $OutputDir = Join-Path $InputDir "output" }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$TempBase = Join-Path $InputDir "Temp"   # v63: temp-ul nostru (djmd dump), nu $env:TEMP
New-Item -ItemType Directory -Force -Path $TempBase | Out-Null

# ── Functii utilitare ─────────────────────────────────────────────────
function Format-Bytes {
    param([long]$b)
    if ($b -ge 1GB) { "{0:F2} GB" -f ($b/1GB) }
    elseif ($b -ge 1MB) { "{0:F1} MB" -f ($b/1MB) }
    else { "{0} KB" -f ($b/1KB) }
}

function Get-FFprobeValue {
    param([string]$file, [string]$stream, [string]$entry)
    # v57 FIX: csv=p=0 emite trailing comma chiar la single-field queries (ffprobe 8.x)
    # → polua display + CSV (`1920,x1080,`, `bt2020,`). default=noprint_wrappers=1:nokey=1
    # returneaza valoarea curata (paritate cu bash).
    # v61 audit: -First 1 (paritate cu awk '...{exit}' din av_check.sh). Pe surse unde
    # -select_streams v:0 raporteaza streamul de 2 ori (DJI: cover mjpeg + multi-track),
    # `-join ""` concatena valorile → "hevchevc" / "26882688x15121512" in CSV.
    $v = @(& ffprobe -v error -select_streams $stream `
        -show_entries "stream=$entry" -of default=noprint_wrappers=1:nokey=1 "$file" 2>$null)
    if ($v.Count -ge 1 -and $null -ne $v[0]) { return ([string]$v[0]).Trim() }
    return ""
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
    $bitsRaw  = Get-FFprobeValue $file "v:0" "bits_per_raw_sample"
    # v57 FIX: field-ul corect e `side_data_type` (nu `type`); cu `type` ffprobe
    # ignora selectorul si returneaza tot frame-ul → Select-String esueaza silentios.
    $hdrPlus  = & ffprobe -v error -show_frames -select_streams v:0 `
        -read_intervals "%+#5" -show_entries frame_side_data=side_data_type `
        "$file" 2>$null | Select-String "HDR10+"
    # v57: AV1 DV nu apare in codec_tag ([0][0][0][0]) — detectie via side_data per-frame
    $dvFrames = & ffprobe -v error -show_frames -select_streams v:0 `
        -read_intervals "%+#5" -show_entries frame_side_data=side_data_type `
        "$file" 2>$null | Select-String "Dolby Vision Metadata"
    # v57 FIX: detectie bit depth corecta — vechiul `-match "10"` NU prinde yuv420p12le
    # (substring "12", nu "10") → 12-bit etichetat ca 8-bit. Folosim bits_per_raw_sample
    # (autoritar) cu fallback la pattern pix_fmt p10/p12/p16.
    $depth = 8
    if ($bitsRaw -match '^\d+$' -and [int]$bitsRaw -ge 10 -and [int]$bitsRaw -le 16) {
        $depth = [int]$bitsRaw
    } elseif ($pixFmt -match 'p10|p010') {
        $depth = 10
    } elseif ($pixFmt -match 'p12|p012') {
        $depth = 12
    } elseif ($pixFmt -match 'p16|p016') {
        $depth = 16
    }
    $depthLabel = "${depth}bit"
    $isHDRPlus = [bool]$hdrPlus
    $isDVFrames = [bool]$dvFrames
    $isHDR     = $transfer -eq "smpte2084" -or $isHDRPlus
    $isHLG     = ($transfer -eq "arib-std-b67") -and (-not $isHDRPlus)
    $fmt = switch ($codec) {
        "h264" { "H.264 $depthLabel" }
        "hevc" {
            if     ($isHDRPlus) { "H.265 HEVC HDR10+" }
            elseif ($isHDR)     { "H.265 HEVC HDR10"  }
            elseif ($isHLG)     { "H.265 HEVC HLG"    }
            else                { "H.265 HEVC $depthLabel SDR" }
        }
        "av1" {
            if     ($isHDRPlus) { "AV1 HDR10+"    }
            elseif ($isHDR)     { "AV1 HDR10"     }
            elseif ($isHLG)     { "AV1 HLG"       }
            else                { "AV1 $depthLabel SDR" }
        }
        "prores"     { "Apple ProRes" }
        "dnxhd"      { "Avid DNxHR $depthLabel" }
        "apv"        { "Samsung APV $depthLabel" }
        "mpeg2video" { "MPEG-2" }
        default      { "$codec $depthLabel" }
    }
    return @{ fmt=$fmt; codec=$codec; pixFmt=$pixFmt; depth=$depth;
              isHDR=$isHDR; isHDRPlus=$isHDRPlus; isHLG=$isHLG;
              isDVFrames=$isDVFrames; transfer=$transfer }
}

function Get-DVProfile {
    param([string]$file)
    # v62: sursa autoritara = STREAM side_data "DOVI configuration record" (HEVC + AV1);
    # frame_side_data=dv_profile e GOL pe AV1 (doar vdr_rpu_profile) → P10 ramanea N/A.
    $sd = & ffprobe -v error -select_streams v:0 `
        -show_entries stream_side_data=dv_profile,dv_bl_signal_compatibility_id `
        -of default=noprint_wrappers=1 "$file" 2>$null
    $n = ($sd | Where-Object { $_ -match "^dv_profile=(\d+)" } | Select-Object -First 1) -replace "dv_profile=",""
    $c = ($sd | Where-Object { $_ -match "^dv_bl_signal_compatibility_id=(\d+)" } | Select-Object -First 1) -replace "dv_bl_signal_compatibility_id=",""
    if (-not ($n -match '^\d+$')) {
        # fallback: frame side_data (unele surse HEVC expun DV doar per-frame, fara config record)
        $fd = & ffprobe -v error -show_frames -select_streams v:0 `
            -read_intervals "%+#5" `
            -show_entries frame_side_data=dv_profile,dv_bl_signal_compatibility_id `
            -of default "$file" 2>$null
        $n = ($fd | Where-Object { $_ -match "^dv_profile=(\d+)" } | Select-Object -First 1) -replace "dv_profile=",""
        $c = ($fd | Where-Object { $_ -match "^dv_bl_signal_compatibility_id=(\d+)" } | Select-Object -First 1) -replace "dv_bl_signal_compatibility_id=",""
    }
    if ($n -match '^\d+$') {
        switch ($n) {
            "4" { "Profil 4 (DV+HDR10)" } "5" { "Profil 5 (DV only)" } "7" { "Profil 7 (DV+HDR10+)" }
            "8" { switch ($c) { "1"{"Profil 8.1 (DV+HDR10, Blu-ray)"} "2"{"Profil 8.2 (DV+SDR)"} "4"{"Profil 8.4 (DV+HLG)"} default{"Profil 8 (DV+HDR10)"} } }
            "9" { "Profil 9 (DV+SDR)" }
            "10" { switch ($c) { "1"{"Profil 10.1 (DV AV1 + HDR10)"} "2"{"Profil 10.2 (DV AV1 + SDR)"} "4"{"Profil 10.4 (DV AV1 + HLG)"} default{"Profil 10 (DV AV1)"} } }
            default { "Profil $n" }
        }
    } else {
        # v57: fallback codec_tag (paritate cu bash get_dv_profile) — apare cand
        # frame_side_data nu carry dv_profile (ex: AV1 DV via side_data only).
        $codecTag = & ffprobe -v error -show_entries stream=codec_tag_string `
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>$null | Select-Object -First 5
        $tagJoined = ($codecTag -join "`n").ToLower()
        if     ($tagJoined -match 'dvhe') { "Profil 8 (dvhe)" }
        elseif ($tagJoined -match 'dvh1') { "Profil 8 (dvh1)" }
        else                              { "Dolby Vision (profil nedetectat)" }
    }
}

# v57: HDR rich fields helper — color metadata + mastering + HDR10+ scene count
function Get-HdrRichInfo {
    param([string]$file, [string]$type, [bool]$hasHdr10Plus)
    $info = @{
        colorPrimaries  = "N/A"
        colorSpace      = "N/A"
        colorRange      = "N/A"
        maxCll          = "N/A"
        maxFall         = "N/A"
        masterDisplay   = "N/A"
        hdr10PlusScenes = "N/A"
    }
    # Color metadata din stream (cheap, mereu disponibil pe HDR)
    $cp = Get-FFprobeValue $file "v:0" "color_primaries"
    $cs = Get-FFprobeValue $file "v:0" "color_space"
    $cr = Get-FFprobeValue $file "v:0" "color_range"
    if ($cp -and $cp -ne "unknown") { $info.colorPrimaries = $cp }
    if ($cs -and $cs -ne "unknown") { $info.colorSpace     = $cs }
    if ($cr -and $cr -ne "unknown") { $info.colorRange     = $cr }

    # Mastering display + CLL/FALL — doar pe HDR static
    if ($type -in @("HDR10","HDR10+","Dolby Vision")) {
        $sd = & ffprobe -v error -read_intervals "%+#5" -show_frames -select_streams v:0 `
            -show_entries frame_side_data "$file" 2>$null
        $mc = ($sd | Where-Object { $_ -match "^max_content=(\d+)" } | Select-Object -First 1) -replace "max_content=",""
        $mf = ($sd | Where-Object { $_ -match "^max_average=(\d+)" } | Select-Object -First 1) -replace "max_average=",""
        if ($mc -match '^\d+$') { $info.maxCll  = $mc }
        if ($mf -match '^\d+$') { $info.maxFall = $mf }

        # Parse rational fractions (num/denom)
        $parseFrac = {
            param($line, $denom)
            if ($line -match "=(\d+)/(\d+)") {
                $num = [double]$matches[1]; $den = [double]$matches[2]
                if ($den -gt 0) { return ($num / $den) }
            }
            return $null
        }
        $lMaxLine = ($sd | Where-Object { $_ -match "^max_luminance=" } | Select-Object -First 1)
        $lMinLine = ($sd | Where-Object { $_ -match "^min_luminance=" } | Select-Object -First 1)
        $gXLine   = ($sd | Where-Object { $_ -match "^green_x=" } | Select-Object -First 1)
        $lMax = & $parseFrac $lMaxLine 10000
        $lMin = & $parseFrac $lMinLine 10000
        $gX   = & $parseFrac $gXLine   50000
        if ($lMax -ne $null -and $lMax -gt 0) {
            $primaries = "custom"
            if     ($gX -ne $null -and $gX -lt 0.20) { $primaries = "BT.2020" }
            elseif ($gX -ne $null -and $gX -lt 0.28) { $primaries = "DCI-P3"  }
            elseif ($gX -ne $null -and $gX -lt 0.32) { $primaries = "BT.709"  }
            # Format InvariantCulture (locale EU → dot decimals)
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $lMaxStr = ([Math]::Round($lMax, 0)).ToString("0", $inv)
            $lMinStr = ([Math]::Round($lMin, 4)).ToString("0.0###", $inv)
            $info.masterDisplay = "$primaries max ${lMaxStr}n min ${lMinStr}n"
        }
    }

    # HDR10+ scene count (bounded keyframe scan)
    if ($hasHdr10Plus) {
        $scenes = & ffprobe -v error -select_streams v:0 -skip_frame nokey -show_frames `
            -read_intervals "%+#9999" `
            -show_entries frame_side_data=side_data_type `
            "$file" 2>$null | Select-String "HDR Dynamic Metadata SMPTE2094-40"
        if ($scenes) { $info.hdr10PlusScenes = "$($scenes.Count)" }
    }
    return $info
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

# _Get-AvPython — interpretor Python 3 (python3 preferat, fallback python 3.x).
function _Get-AvPython {
    if (Get-Command python3 -ErrorAction SilentlyContinue) { return "python3" }
    $p = Get-Command python -ErrorAction SilentlyContinue
    if ($p -and ((& python --version 2>&1) -match "3\.")) { return "python" }
    return $null
}

# Test-DjiDLogM — detecteaza D-Log M pe DJI Osmo Action 6 (AC006) din track-ul djmd.
# Container raporteaza bt709 identic pt Normal SI D-Log M → singura cale e protobuf-ul
# djmd (.2.4.1==19). Engine partajat src/dji_djmd_dlogm.py (model-gate intern pe
# dvtm_ac206.proto). Return: "dlog_m" | "normal" | "unknown". Soft-fail → "unknown".
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

function Get-LogProfile {
    param([string]$file, [bool]$isDji)
    $allTags = & ffprobe -v error -show_entries format_tags `
        -of default=noprint_wrappers=1 "$file" 2>$null | Out-String
    # Samsung S24 Ultra: tag autoritar `com.samsung.android.logvideo` —
    # cand e prezent, fisierul ESTE Samsung Log (short-circuit).
    if ($allTags -imatch "com\.samsung\.android\.logvideo") {
        return "Samsung Log (S24 Ultra)"
    }
    $cameraMake = ""
    if     ($allTags -imatch "make=.*apple")                                                { $cameraMake = "apple" }
    elseif ($allTags -imatch "make=.*dji|encoder=.*dji")                                    { $cameraMake = "dji" }
    elseif ($allTags -imatch "manufacturer=.*samsung|make=.*samsung|com\.samsung\.android") { $cameraMake = "samsung" }
    if (-not $cameraMake -and $isDji) { $cameraMake = "dji" }

    $srcTrc = Get-FFprobeValue $file "v:0" "color_transfer"
    $srcBps = Get-FFprobeValue $file "v:0" "bits_per_raw_sample"
    if (-not $srcBps -or $srcBps -notmatch '^\d+$') {
        # Fallback: deriva depth-ul din pix_fmt (paritate cu Get-SourceInfo)
        $pf = Get-FFprobeValue $file "v:0" "pix_fmt"
        if     ($pf -match 'p16|p016') { $srcBps = "16" }
        elseif ($pf -match 'p12|p012') { $srcBps = "12" }
        elseif ($pf -match 'p10|p010') { $srcBps = "10" }
        else                           { $srcBps = "8"  }
    }
    $srcBps = [int]$srcBps
    $srcPrimaries = Get-FFprobeValue $file "v:0" "color_primaries"
    $transfer = Get-FFprobeValue $file "v:0" "color_transfer"
    $hdrPlus = & ffprobe -v error -show_frames -select_streams v:0 `
        -read_intervals "%+#5" -show_entries frame_side_data=side_data_type `
        "$file" 2>$null | Select-String "HDR10+"
    $isHdrPlus = [bool]$hdrPlus
    $dovi = & ffprobe -v error -show_entries stream=codec_tag_string `
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>$null |
        Select-String -Pattern "dovi|dvhe|dvh1" -CaseSensitive:$false

    if ($cameraMake -eq "apple" -and $srcBps -ge 10 -and ($srcPrimaries -match "bt2020" -or $srcTrc -match "arib|log")) {
        return "Apple Log (iPhone)"
    } elseif ($cameraMake -eq "samsung" -and $srcBps -ge 10 -and $srcPrimaries -match "bt2020" -and -not $isHdrPlus -and $transfer -ne "smpte2084" -and $transfer -ne "arib-std-b67") {
        # v62: exclude HLG (arib) — Samsung gradat-HLG nu mai e marcat Log
        return "Samsung Log (S24 Ultra)"
    } elseif ($cameraMake -eq "dji" -and $srcBps -ge 10 -and $transfer -ne "arib-std-b67") {
        if ($srcPrimaries -match "bt2020") {
            return "D-Log M (DJI)"   # DJI vechi (Mavic/Air) D-Log Wide → container bt2020
        } elseif ($transfer -ne "smpte2084" -and -not $dovi -and -not $isHdrPlus) {
            # v62 Faza B: Osmo Action 6 D-Log M e bt709 in container → djmd protobuf
            # (.2.4.1==19). Normal / non-AC006 / fara djmd → cade pe N/A (SDR onest).
            if ((Test-DjiDLogM $file) -eq "dlog_m") { return "D-Log M (DJI)" }
        }
    } elseif ($srcBps -ge 10 -and $srcPrimaries -match "bt2020" -and -not $isHdrPlus -and $transfer -ne "smpte2084" -and -not $dovi) {
        # v62: arib NU mai e semnal Log (e HLG)
        if ($srcTrc -eq "unknown" -or $srcTrc -match "log") { return "LOG (brand necunoscut)" }
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

$inputFiles = Get-ChildItem -Path (Join-Path $InputDir '*') -Include "*.mp4","*.mov","*.mkv","*.m2ts","*.mts","*.vob","*.mxf","*.apv","*.webm" -File
$fileCount  = $inputFiles.Count
$totalSz    = ($inputFiles | Measure-Object -Property Length -Sum).Sum
Write-Host "INPUT: $InputDir | Fisiere: $fileCount | $(Format-Bytes $totalSz)" -ForegroundColor Yellow
if ($fileCount -eq 0) { Write-Host "Nu am gasit fisiere." -ForegroundColor Red; Read-Host; exit }

$csvPath = Join-Path $OutputDir "av_check_report.csv"
# v57: header CSV aliniat cu bash — 38 coloane (7 HDR rich dupa Profil_DV +
# 1 Container dupa Format_sursa)
"Fisier,Format_sursa,Container,Dimensiune(MB),Durata(sec),Rezolutie,PixelFormat,FPS,Bitrate_video(Mbps),Tip_HDR,Profil_DV,ColorPrimaries,ColorSpace,ColorRange,MaxCLL,MaxFALL,MasterDisplay,HDR10Plus_Scenes,Log_Profile,Codec_audio,Bitrate_audio(kbps),SampleRate(kHz),BitDepth,Layout_canale,Limba_audio,Canale_audio,AudioTrackuri,Subtitrari,Capitole,Attachments,DJI_djmd,DJI_dbgi,DJI_Timecode,Recomandat_encoder,Est_x265,Est_x264,Est_AV1,Est_ProRes" |
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
    # v57: container extras din extensie (lowercase, fara dot)
    $container = $f.Extension.TrimStart('.').ToLowerInvariant()

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
    $durRaw = & ffprobe -v error -show_entries format=duration `
        -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null
    $durSec = if ($durRaw -match '^\d+') { [int]([double]$durRaw) } else { 0 }
    # v57: fallback in cascada — stream=bit_rate (lipseste de obicei pe MKV),
    # apoi format=bit_rate, apoi estimat din size/duration.
    if ($bitrateRaw -match '^\d+$') {
        $bitrateMbps = [math]::Round([long]$bitrateRaw / 1000000, 2)
    } else {
        $fmtBr = & ffprobe -v error -show_entries format=bit_rate `
            -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null
        if ($fmtBr -match '^\d+$') {
            $bitrateMbps = [math]::Round([long]$fmtBr / 1000000, 2)
        } elseif ($durSec -gt 0 -and $f.Length -gt 0) {
            $estBr = [math]::Round(($f.Length * 8.0) / 1000000.0 / $durSec, 2)
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $bitrateMbps = "$($estBr.ToString('0.##', $inv)) (est)"
        } else {
            $bitrateMbps = "N/A"
        }
    }
    $audioTracks = (& ffprobe -v error -select_streams a `
        -show_entries stream=index -of csv=p=0 $f.FullName 2>$null |
        Where-Object { $_ -match '^\d' }).Count

    # v57: per-track audio detail (paritate cu bash AUDIO_TRACKS_DETAIL)
    # Folosim compact=nk=0 (key=value pairs, | separated) — robust la reordonarea ffprobe
    $audioTracksDetail = @()
    if ($audioTracks -gt 0) {
        $aLines = & ffprobe -v error -select_streams a `
            -show_entries stream=codec_name,bit_rate,channels,sample_rate,channel_layout:stream_tags=language `
            -of compact=nk=0:p=0 $f.FullName 2>$null
        $tIdx = 0
        foreach ($line in $aLines) {
            if (-not $line) { continue }
            $kv = @{}
            foreach ($pair in ($line -split '\|')) {
                if ($pair -match '^([^=]+)=(.*)$') { $kv[$matches[1]] = $matches[2] }
            }
            $tc = if ($kv['codec_name']) { $kv['codec_name'] } else { "N/A" }
            $tbr = if ($kv['bit_rate'] -match '^\d+$') { [math]::Round([long]$kv['bit_rate'] / 1000) } else { "N/A" }
            $tsr = if ($kv['sample_rate'] -match '^\d+$') { [math]::Round([long]$kv['sample_rate'] / 1000, 1) } else { "N/A" }
            $tlayout = if ($kv['channel_layout']) { $kv['channel_layout'] } else { "$($kv['channels'])ch" }
            $tlang = if ($kv['tag:language']) { $kv['tag:language'] } else { "und" }
            $audioTracksDetail += "    Track ${tIdx}: ${tc} | ${tbr}kbps | ${tsr}kHz | ${tlayout} | ${tlang}"
            $tIdx++
        }
    }
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
    # v57: afiseaza si mimetypes (paritate cu bash get_attachments_info)
    $attMimes = ($attStreams | Where-Object { $_ -match "^TAG:mimetype=" } |
        ForEach-Object { $_ -replace "TAG:mimetype=","" }) -join " "
    $attStr = if ($attCount -gt 0) {
        if ($attMimes) { "$attCount ($attMimes)" } else { "$attCount" }
    } else { "Nu" }

    $dji = Get-DJITracks $f.FullName
    $doVi = & ffprobe -v error -show_entries stream=codec_tag_string `
        -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null |
        Select-String -Pattern "dovi|dvhe|dvh1" -CaseSensitive:$false

    # v57: LOG profile computat ÎNAINTE de TYPE (mutual exclusion)
    $logProf = Get-LogProfile $f.FullName $dji.isDji

    # v57: TYPE detection cu LOG/DV awareness
    # Prioritati: DV (codec_tag OR side_data per-frame) > LOG > HDR10+ > HDR10 > HLG > SDR
    $tipHdr = "SDR"; $dvProf = "N/A"
    if ($doVi -or $si.isDVFrames) {
        $tipHdr = "Dolby Vision"
        $dvProf = Get-DVProfile $f.FullName
    } elseif ($logProf -ne "N/A") {
        $tipHdr = "SDR (LOG)"
    } elseif ($si.isHDRPlus) {
        $tipHdr = "HDR10+"
    } elseif ($si.isHDR) {
        $tipHdr = "HDR10"
    } elseif ($si.isHLG) {
        $tipHdr = "HLG"
    }

    # v57: HDR rich fields (color metadata + mastering + scene count)
    $hdr = Get-HdrRichInfo $f.FullName $tipHdr ([bool]$si.isHDRPlus)

    # Encoder recommendation
    $srcCodec = $si.codec
    $encRec = "libx265 (optiune sigura universala)"
    if     ($tipHdr -eq "Dolby Vision")                          { $encRec = "libx265 (singurul care suporta DV)" }
    elseif ($tipHdr -eq "HDR10+")                                { $encRec = "libx265 sau AV1/SVT (ambele suporta HDR10+)" }
    elseif ($tipHdr -eq "HDR10")                                 { $encRec = "libx265 sau AV1/SVT (ambele suporta HDR10)" }
    elseif ($tipHdr -eq "HLG")                                   { $encRec = "libx265 sau AV1/SVT (HLG nativ — transfer=arib-std-b67)" }
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
    if ($tipHdr -match "HDR|Dolby|HLG") { $bpsX265 = [int]($bpsX265 * 1.3); $bpsAV1 = [int]($bpsAV1 * 1.3) }
    $estX265 = Get-SizeEst $bpsX265 $durSec
    $estX264 = Get-SizeEst $bpsX264 $durSec
    $estAV1  = Get-SizeEst $bpsAV1  $durSec
    $estProRes = Get-SizeEst $bpsProRes $durSec

    # Terminal output
    Write-Host "  Format sursa : $($si.fmt)"       -ForegroundColor White
    Write-Host "  Container    : $container"        -ForegroundColor White
    Write-Host "  Dimensiune   : $fsMB MB"          -ForegroundColor White
    Write-Host "  Durata       : $durSec sec"       -ForegroundColor White
    Write-Host "  Rezolutie    : ${w}x${h}"         -ForegroundColor White
    Write-Host "  FPS          : $fpsRaw"           -ForegroundColor White
    Write-Host "  Bitrate video: $bitrateMbps Mb/s" -ForegroundColor White
    # v57: Tip HDR adnotat cu numar markeri HDR10+ daca disponibil
    $tipHdrDisplay = $tipHdr
    if ($si.isHDRPlus -and $hdr.hdr10PlusScenes -match '^\d+$' -and [int]$hdr.hdr10PlusScenes -gt 0) {
        $tipHdrDisplay = "$tipHdr (~$($hdr.hdr10PlusScenes) scene markers)"
    }
    Write-Host "  Tip HDR      : $tipHdrDisplay" -ForegroundColor $(if ($tipHdr -ne "SDR") { "Magenta" } else { "White" })
    if ($doVi -or $si.isDVFrames) { Write-Host "  Profil DV    : $dvProf" -ForegroundColor Magenta }
    if ($logProf -ne "N/A") { Write-Host "  LOG Profile  : $logProf" -ForegroundColor Yellow }
    # v57: HDR rich fields display
    if ($hdr.colorPrimaries -ne "N/A" -or $hdr.colorSpace -ne "N/A" -or $hdr.colorRange -ne "N/A") {
        Write-Host "  Color        : primaries=$($hdr.colorPrimaries) matrix=$($hdr.colorSpace) range=$($hdr.colorRange)" -ForegroundColor White
    }
    if ($hdr.maxCll -ne "N/A" -or $hdr.maxFall -ne "N/A") {
        Write-Host "  MaxCLL/FALL  : $($hdr.maxCll) / $($hdr.maxFall) nits" -ForegroundColor White
    }
    if ($hdr.masterDisplay -ne "N/A") {
        Write-Host "  Mastering    : $($hdr.masterDisplay)" -ForegroundColor White
    }
    Write-Host "  ─────────────────────────────────────" -ForegroundColor DarkGray
    # v57: audio main + per-track detail (paritate cu bash)
    if ($audioTracks -gt 1) {
        Write-Host "  Audio (main) : $ac | $abk kbps | ${audioSRk} kHz | ${audioBD}bit | $audioLayout | $audioLang | $audioTracks track-uri" -ForegroundColor White
        foreach ($t in $audioTracksDetail) { Write-Host $t -ForegroundColor White }
    } else {
        Write-Host "  Audio        : $ac | $abk kbps | ${audioSRk} kHz | ${audioBD}bit | $audioLayout | $audioLang" -ForegroundColor White
    }
    Write-Host "  Subtitrari   : $subStr"  -ForegroundColor $(if ($subCount -gt 0) { "Green" } else { "Gray" })
    Write-Host "  Capitole     : $chapStr" -ForegroundColor $(if ($chapCount -gt 0) { "Green" } else { "Gray" })
    Write-Host "  Attachments  : $attStr" -ForegroundColor $(if ($attCount -gt 0) { "Green" } else { "Gray" })
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

    # CSV — v57: 37 campuri (30 + 7 HDR rich field-uri dupa Profil_DV)
    # Defaulting la N/A pe campurile audio cand stream-ul lipseste (paritate bash)
    # DJI tracks: emit 0/1 nu True/False (paritate bash)
    # Canale_audio default 0 cand stream lipseste (paritate bash ${AUDIO_CHANNELS:-0})
    # v57 follow-up: quote-ing complet pe text fields (paritate cu bash printf "%s")
    $csv_ac      = if ($ac)         { $ac }         else { "N/A" }
    $csv_abk     = if ($abk)        { $abk }        else { "N/A" }
    $csv_aSRk    = if ($audioSRk)   { $audioSRk }   else { "N/A" }
    $csv_aBD     = if ($audioBD)    { $audioBD }    else { "N/A" }
    $csv_aLay    = if ($audioLayout){ $audioLayout }else { "N/A" }
    $csv_aLang   = if ($audioLang)  { $audioLang }  else { "und" }
    $csv_aCh     = if ($audioChannels -match '^\d+$') { $audioChannels } else { 0 }
    $csv_djmd    = if ($dji.hasDjmd) { 1 } else { 0 }
    $csv_dbgi    = if ($dji.hasDbgi) { 1 } else { 0 }
    $csv_djtc    = if ($dji.hasTC)   { 1 } else { 0 }
    # bash: %s pe toate text fields, %d pe numerice
    # Numerice (fara quote): fsMB, durSec, csv_aCh, audioTracks, csv_djmd, csv_dbgi, csv_djtc
    # Text fields (cu quote): toate celelalte 30
    "`"$($f.Name)`",`"$($si.fmt)`",`"$container`",$fsMB,$durSec,`"${w}x${h}`",`"$($si.pixFmt)`",`"$fpsRaw`",`"$bitrateMbps`",`"$tipHdr`",`"$dvProf`",`"$($hdr.colorPrimaries)`",`"$($hdr.colorSpace)`",`"$($hdr.colorRange)`",`"$($hdr.maxCll)`",`"$($hdr.maxFall)`",`"$($hdr.masterDisplay)`",`"$($hdr.hdr10PlusScenes)`",`"$logProf`",`"$csv_ac`",`"$csv_abk`",`"$csv_aSRk`",`"$csv_aBD`",`"$csv_aLay`",`"$csv_aLang`",$csv_aCh,$audioTracks,`"$subStr`",`"$chapStr`",`"$attStr`",$csv_djmd,$csv_dbgi,$csv_djtc,`"$encRec`",`"$estX265`",`"$estX264`",`"$estAV1`",`"$estProRes`"" |
        Out-File $csvPath -Append -Encoding UTF8
}

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "Analiza completa! $count fisiere procesate." -ForegroundColor Green
Write-Host "CSV: $csvPath" -ForegroundColor White
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

# ── Comparatie Input vs Output ────────────────────────────────────────
$outFiles = Get-ChildItem -Path (Join-Path $OutputDir '*') -Include "*.mp4","*.mov","*.mkv","*.mxf","*.webm" -File -ErrorAction SilentlyContinue
if ($outFiles -and $outFiles.Count -gt 0) {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "COMPARATIE INPUT vs OUTPUT" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    $compCount = 0; $compTotalOrig = 0L; $compTotalNew = 0L
    foreach ($of in $outFiles) {
        $baseName = $of.BaseName
        # v57: lista sufixe extinsa cu toate output naming patterns post-v44
        # (encoder outputs + Mux v49/v50 + Telemetry v47 + Burn-in v48 + HDR/DV v56)
        foreach ($sfx in @("_x265","_x264","_av1","_dnxhr","_prores","_apv","_audio","_hwenc",
                            "_remux","_mux","_telem","_hud","_subs","_preview",
                            "_nodv","_nohdr10plus","_dvhybrid")) {
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
