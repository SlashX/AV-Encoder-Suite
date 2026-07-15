# av_mux.ps1 — Mux tools (v50) — PS1 mirror al av_mux.sh
# Submeniu: 1) Remux 2) Demux 3) Mux 4) Anulare
# Input remux/demux: mkv, webm, mp4, m4v, mov, ts, m2ts, mts, vob, mxf
# Output remux: <name>_remux.<ext>
# Output demux: <name>_v<idx>_<codec>.mkv / <name>_a<idx>_<codec>_<lang>.mka /
#               <name>_s<idx>_<codec>_<lang>.<ext> / <name>_cover_<idx>.<ext> /
#               <name>_chapters.xml / <name>_attach/* / <name>_data/* (opt-in)
# Output mux:   <video_basename>_mux.<ext>

$ErrorActionPreference = "Stop"

# Binare locale (src/) au prioritate in PATH — ffmpeg/ffprobe langa script
$env:PATH = "$PSScriptRoot;$env:PATH"

$ScriptDir = $PSScriptRoot
# v85 (O3): env override AV_INPUT_DIR / AV_OUTPUT_DIR (paritate cu av_check.ps1 +
# bash INPUT_DIR/OUTPUT_DIR) — util pt CI/testare fara a muta scriptul.
if ($env:AV_INPUT_DIR)  { $InputDir  = $env:AV_INPUT_DIR }  else { $InputDir  = Join-Path $ScriptDir "InputVideos" }
if ($env:AV_OUTPUT_DIR) { $OutputDir = $env:AV_OUTPUT_DIR } else { $OutputDir = Join-Path $ScriptDir "OutputVideos" }
$TempBase  = Join-Path $ScriptDir "Temp"   # v63: temp-ul nostru (chapters ffmetadata), nu OS temp
New-Item -ItemType Directory -Force -Path $InputDir, $OutputDir, $TempBase | Out-Null

if (-not (Get-Command "ffmpeg" -ErrorAction SilentlyContinue)) {
    Write-Host "EROARE: ffmpeg nu este in PATH." -ForegroundColor Red
    exit 1
}
if (-not (Get-Command "ffprobe" -ErrorAction SilentlyContinue)) {
    Write-Host "EROARE: ffprobe nu este in PATH." -ForegroundColor Red
    exit 1
}

$SupportedInputExt  = @("mkv","webm","mp4","m4v","mov","ts","m2ts","mts","vob","mxf")
$SupportedOutputExt = @("mkv","mp4","mov","webm")

# ══════════════════════════════════════════════════════════════════════
# SHARED HELPERS
# ══════════════════════════════════════════════════════════════════════

function Get-SourceCodec {
    param([string]$File)
    # v57: default= in loc de csv=p=0 — single-field emite trailing comma "av1,"
    # v61 audit: [0] (prima linie) — DJI v:0 dublu-listat → Out-String concatena "hevc\nhevc"
    # → codec_tag (hvc1/av01) pierdut la mux (paritate cu head -1 bash).
    $c = "$(@(& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 -- $File 2>$null)[0])"
    return $c.Trim().ToLowerInvariant()
}

function Get-RemuxStreamCompat {
    param([string]$Codec, [string]$CodecType, [string]$Target)
    $codec = $Codec.ToLowerInvariant()
    $ctype = $CodecType.ToLowerInvariant()
    $t = $Target.ToLowerInvariant()
    if ($t -eq "mkv") { return "copy" }
    switch ($ctype) {
        "video" {
            switch ($t) {
                "mp4"  { if ($codec -in @("hevc","h264","av1","mpeg4","mpeg2video","vp9","prores")) { return "copy" } else { return "drop" } }
                "mov"  { if ($codec -in @("hevc","h264","prores","dnxhd","dnxhr","mpeg4","mjpeg")) { return "copy" } else { return "drop" } }
                "webm" { if ($codec -in @("vp8","vp9","av1")) { return "copy" } else { return "drop" } }
            }
            return "drop"
        }
        "audio" {
            switch ($t) {
                "mp4"  { if ($codec -in @("aac","ac3","eac3","mp3","opus","alac","flac")) { return "copy" } else { return "drop" } }
                "mov"  { if ($codec -in @("aac","ac3","mp3","alac","pcm_s16be","pcm_s24be","pcm_s16le","pcm_s24le")) { return "copy" } else { return "drop" } }
                "webm" { if ($codec -in @("opus","vorbis")) { return "copy" } else { return "drop" } }
            }
            return "drop"
        }
        "subtitle" {
            switch ($t) {
                { $_ -in @("mp4","mov") } {
                    if ($codec -in @("mov_text","tx3g")) { return "copy" }
                    if ($codec -in @("subrip","srt","ass","ssa")) { return "convert:mov_text" }
                    return "drop"
                }
                "webm" { if ($codec -eq "webvtt") { return "copy" } else { return "drop" } }
            }
            return "drop"
        }
        "attachment" { return "drop" }
    }
    return "drop"
}

function Get-RemuxStreams {
    param([string]$File)
    $result = @{
        Video = New-Object System.Collections.Generic.List[object]
        Audio = New-Object System.Collections.Generic.List[object]
        Subtitle = New-Object System.Collections.Generic.List[object]
        Attachment = New-Object System.Collections.Generic.List[object]
        ChapterCount = 0
    }
    # v59 audit: csv=p=0 emite trailing comma pe surse cu [SIDE_DATA] sections
    # (HDR10/HDR10+/HEVC HDR) → ultimul field include "value,". Defensiv TrimEnd(',')
    # pe titles + other last-fields ca sa nu poluam display + metadata.
    # v88: pe surse IAMF-in-MP4 ffprobe listeaza streamurile de DOUA ori (o data prin
    # grupul IAMF, o data normal) → gate numeric pe idx + dedupe (mirror bash).
    $seenIdx = @{}
    $raw = (& ffprobe -v error -select_streams v -show_entries stream=index,codec_name,width,height:stream_tags=language,title -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 6
        $idx = "$($parts[0])".Trim()
        if ($idx -notmatch '^\d+$' -or $seenIdx.ContainsKey($idx)) { continue }   # v88
        $seenIdx[$idx] = $true
        $codec = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $w = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $h = if ($parts.Count -gt 3) { $parts[3] } else { "" }
        $lang = if ($parts.Count -gt 4) { $parts[4] } else { "" }
        $title = if ($parts.Count -gt 5) { $parts[5].TrimEnd(',') } else { "" }
        $result.Video.Add([PSCustomObject]@{ AbsIndex=$idx; Codec=$codec; Lang=$lang; Title=$title; Extra="${w}x${h}" }) | Out-Null
    }
    $raw = (& ffprobe -v error -select_streams a -show_entries stream=index,codec_name,channels:stream_tags=language,title -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 5
        $idx = "$($parts[0])".Trim()
        if ($idx -notmatch '^\d+$' -or $seenIdx.ContainsKey($idx)) { continue }   # v88
        $seenIdx[$idx] = $true
        $codec = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $ch = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $lang = if ($parts.Count -gt 3) { $parts[3] } else { "" }
        $title = if ($parts.Count -gt 4) { $parts[4].TrimEnd(',') } else { "" }
        $result.Audio.Add([PSCustomObject]@{ AbsIndex=$idx; Codec=$codec; Lang=$lang; Title=$title; Extra="${ch}ch" }) | Out-Null
    }
    $raw = (& ffprobe -v error -select_streams s -show_entries stream=index,codec_name:stream_tags=language,title -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 4
        $idx = "$($parts[0])".Trim()
        if ($idx -notmatch '^\d+$' -or $seenIdx.ContainsKey($idx)) { continue }   # v88
        $seenIdx[$idx] = $true
        $codec = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $lang = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $title = if ($parts.Count -gt 3) { $parts[3].TrimEnd(',') } else { "" }
        $result.Subtitle.Add([PSCustomObject]@{ AbsIndex=$idx; Codec=$codec; Lang=$lang; Title=$title; Extra="" }) | Out-Null
    }
    $raw = (& ffprobe -v error -select_streams t -show_entries stream=index,codec_name:stream_tags=filename -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 3
        $idx = "$($parts[0])".Trim()
        if ($idx -notmatch '^\d+$' -or $seenIdx.ContainsKey($idx)) { continue }   # v88
        $seenIdx[$idx] = $true
        $codec = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $title = if ($parts.Count -gt 2) { $parts[2].TrimEnd(',') } else { "" }
        $result.Attachment.Add([PSCustomObject]@{ AbsIndex=$idx; Codec=$codec; Lang=""; Title=$title; Extra="" }) | Out-Null
    }
    $rawCh = (& ffprobe -v error -show_chapters -of csv=p=0 -- $File 2>$null) | Out-String
    $result.ChapterCount = ($rawCh -split "`r?`n" | Where-Object { $_ }).Count
    return $result
}

# v87: detecteaza audio spatial cu obiecte (Atmos / DTS:X) pe O pista — copie standalone
# (av_mux.ps1 nu importa av_encode.ps1; mirror Get-AudioSpatialKind + _audio_spatial_kind).
# Profil via stream=profile; retry probe 25M pe profil necunoscut (edge TrueHD 9.1.6).
function Get-AudioSpatialKind {
    param([string]$File, [int]$AIdx = 0)
    $codec = @(& ffprobe -v error -select_streams "a:$AIdx" -show_entries stream=codec_name `
        -of default=noprint_wrappers=1:nokey=1 $File 2>$null)
    $codec = if ($codec.Count -gt 0) { "$($codec[0])".Trim() } else { "" }
    if ($codec -notin @("eac3","truehd","dts")) { return "" }
    $prof = @(& ffprobe -v error -select_streams "a:$AIdx" -show_entries stream=profile `
        -of default=noprint_wrappers=1:nokey=1 $File 2>$null)
    $p = if ($prof.Count -gt 0) { "$($prof[0])".Trim() } else { "" }
    if (-not $p -or $p -eq "unknown") {
        $prof = @(& ffprobe -v error -analyzeduration 25M -probesize 25M -select_streams "a:$AIdx" `
            -show_entries stream=profile -of default=noprint_wrappers=1:nokey=1 $File 2>$null)
        $p = if ($prof.Count -gt 0) { "$($prof[0])".Trim() } else { "" }
    }
    if ($p -match "Dolby Atmos") { return "atmos" }
    if ($p -match "DTS:X")       { return "dtsx" }
    return ""
}

# v87: eticheta primei piste spatiale ("Dolby Atmos"/"DTS:X"/"") — mirror _file_spatial_label.
function Get-FileSpatialLabel {
    param([Parameter(Mandatory)][string]$File)
    $nb = (@(& ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 $File 2>$null) | Where-Object { $_ -match '^\d' }).Count
    if (-not $nb) { return "" }
    for ($n = 0; $n -lt $nb; $n++) {
        $k = Get-AudioSpatialKind -File $File -AIdx $n
        if ($k -eq "atmos") { return "Dolby Atmos" }
        if ($k -eq "dtsx")  { return "DTS:X" }
    }
    return ""
}

# v87: semnalizare Atmos de CONTAINER pe MP4/MOV — copie standalone a Invoke-AtmosMp4Signal
# (av_encode.ps1; mirror _atmos_mp4_signal bash). ffmpeg nu scrie extensia JOC in dec3 →
# MP4Box o scrie din raw .ec3. Soft-fail: output NEATINS; no-op pe MKV/non-Atmos/etc.
function Invoke-AtmosMp4Signal {
    param([Parameter(Mandatory)][string]$File)
    $ext = [System.IO.Path]::GetExtension($File).TrimStart('.').ToLowerInvariant()
    if ($ext -notin @('mp4','mov','m4v')) { return }
    $mux = if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } else { "mp4box" }
    if (-not (Get-Command $mux -ErrorAction SilentlyContinue)) { return }
    $nb = (@(& ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 $File 2>$null) | Where-Object { $_ -match '^\d' }).Count
    if (-not $nb) { return }
    # deja semnalizat? Check O DATA, INAINTE de bucla (in bucla ar opri gresit dupa
    # PRIMA pista pe fisiere multi-Atmos). GPAC scrie -info pe STDERR → 2>&1.
    $info = (& $mux -info $File 2>&1) -join "`n"
    if ($info -match 'ATMOS complexity') { return }
    # FAZA 1: colecteaza + extrage TOATE raw-urile cu indexurile ORIGINALE (dupa un
    # rebuild indexurile a:N se schimba). UN SINGUR rebuild la final.
    $dir = Split-Path $File -Parent
    $rebuild = New-Object System.Collections.Generic.List[string]
    $raws = @(); $sigged = @()
    for ($n = 0; $n -lt $nb; $n++) {
        if ((Get-AudioSpatialKind -File $File -AIdx $n) -ne 'atmos') { continue }
        # offset de start (tipic pe trim-uri) → PASTRAT prin optiunea MP4Box `:delay=<ms>`
        $st = @(& ffprobe -v error -select_streams "a:$n" -show_entries stream=start_time -of default=noprint_wrappers=1:nokey=1 $File 2>$null)
        $stv = if ($st.Count -gt 0) { "$($st[0])".Trim() } else { "" }
        $dlyOpt = ""
        if ($stv -match '^[0-9.]+$') {
            $stD = [double]::Parse($stv, [System.Globalization.CultureInfo]::InvariantCulture)
            if ($stD -gt 0.001) { $dlyOpt = ":delay=" + [math]::Round($stD * 1000) }
        }
        $idhex = @(& ffprobe -v error -select_streams "a:$n" -show_entries stream=id -of default=noprint_wrappers=1:nokey=1 $File 2>$null)
        $idv = if ($idhex.Count -gt 0) { "$($idhex[0])".Trim() } else { "" }
        if ($idv -notmatch '^0x[0-9a-fA-F]+$') { continue }
        $tid = [Convert]::ToInt32($idv.Substring(2), 16)
        $lang = @(& ffprobe -v error -select_streams "a:$n" -show_entries stream_tags=language -of default=noprint_wrappers=1:nokey=1 $File 2>$null)
        $langv = if ($lang.Count -gt 0) { "$($lang[0])".Trim() } else { "" }
        $raw = Join-Path $dir ("atmossig_" + [guid]::NewGuid().ToString("N") + ".ec3")
        & ffmpeg -y -v error -i $File -map "0:a:$n" -c copy -f eac3 $raw 2>$null
        if (-not ((Test-Path $raw) -and (Get-Item $raw).Length -gt 0)) {
            if (Test-Path $raw) { Remove-Item $raw -Force -ErrorAction SilentlyContinue }
            continue
        }
        $rebuild.Add("-rem"); $rebuild.Add("$tid")
        $rebuild.Add("-add")
        $addSpec = $raw + $dlyOpt
        if ($langv -match '^[a-zA-Z]{3}$') { $addSpec += ":lang=$langv" }
        $rebuild.Add($addSpec)
        $raws += $raw
        $sigged += "a:$n"
    }
    if ($raws.Count -eq 0) { return }
    $tmp = Join-Path $dir ("atmossig_" + [guid]::NewGuid().ToString("N") + "." + $ext)
    & $mux -add $File @rebuild -new $tmp 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0) {
        Move-Item -Force $tmp $File
        Write-Host ("  Semnalizare Atmos scrisa in container (dec3 JOC) — pista(e) {0}" -f ($sigged -join " ")) -ForegroundColor Green
    } elseif (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    foreach ($r in $raws) { Remove-Item $r -Force -ErrorAction SilentlyContinue }
}

# v88: detecteaza audio Eclipsa/IAMF — copie standalone (av_mux.ps1 nu importa
# av_encode.ps1; mirror Get-IamfLayout / _iamf_probe). Layout sau "" (fara grup).
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

# v88: passthrough Eclipsa/IAMF — copie standalone (mirror Invoke-IamfPreserve /
# _iamf_preserve). ffmpeg aplatizeaza grupul la Opus simplu la orice mux/copy →
# re-grefam grupul INTREG din sursa (extract raw MP4Box → rebuild -rem/-add → mv
# atomic). DOAR MP4/MOV. -AllowNoAudio: userul a CERUT audio dar compat-ul l-a
# dropat la ffmpeg (opus→MOV). Temp-uri CO-LOCATE. Idempotent. Soft-fail.
function Invoke-IamfPreserve {
    param([string]$Source, [string]$Output, [switch]$AllowNoAudio)
    $ext = [System.IO.Path]::GetExtension($Output).TrimStart('.').ToLowerInvariant()
    if (-not (Get-IamfLayout -File $Source)) { return $true }
    if ($ext -notin @('mp4','mov','m4v')) {
        Write-Host "  ⚠ Sursa are audio Eclipsa/IAMF — grupul NU exista in .$ext →" -ForegroundColor Yellow
        Write-Host "    audio ramane Opus multi-pista simplu. Foloseste MP4/MOV ca sa pastrezi Eclipsa." -ForegroundColor Yellow
        return $false
    }
    $mux = if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } else { "mp4box" }
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
    # v88 audit: capitolele se cara DETERMINIST prin dump-chap (inainte de rebuild) +
    # -chap (dupa mv) — rebuild-ul MP4Box importa track-ul de capitole QT scris de
    # ffmpeg dar ii TRUNCHIAZA etichetele (validat empiric: 2 capitole -> 1).
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

function Get-RemuxPreflight {
    param([string]$File, [string]$TargetContainer)
    $notes = New-Object System.Collections.Generic.List[string]
    $level = 0
    $target = $TargetContainer.ToLowerInvariant()
    # v57: default= in loc de csv=p=0 — single-field emite trailing comma "av1,"
    # care esua gate-urile regex anchored (`^av1$`).
    # v61 audit: [0] (prima linie) — DJI v:0 dublu-listat → "hevc\nhevc".
    $videoCodec = "$(@(& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 -- $File 2>$null)[0])".Trim()
    $audioCodecs = ((& ffprobe -v error -select_streams a -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 -- $File 2>$null) | Out-String) -split "`r?`n" | Where-Object { $_ }
    $subCodecs   = ((& ffprobe -v error -select_streams s -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 -- $File 2>$null) | Out-String) -split "`r?`n" | Where-Object { $_ }
    $codecTags   = (& ffprobe -v error -show_entries stream=codec_tag_string -of default=noprint_wrappers=1:nokey=1 -- $File 2>$null) | Out-String
    $attachCount = (((& ffprobe -v error -select_streams t -show_entries stream=index -of default=noprint_wrappers=1:nokey=1 -- $File 2>$null) | Out-String) -split "`r?`n" | Where-Object { $_ }).Count
    $djiPresent = $codecTags -match "(?i)\b(djmd|dbgi)\b"
    function _Matches([string[]]$list, [string]$pat) { foreach ($c in $list) { if ($c -match $pat) { return $true } }; return $false }
    switch ($target) {
        "mp4" {
            if (_Matches $audioCodecs '^(truehd|dts|pcm_s24le|pcm_s16be)$') {
                $notes.Add("Audio lossless (TrueHD/DTS-HD/PCM) incompatibil cu MP4 — strip") | Out-Null
                # v87: spune EXPLICIT cand pista strip-uita poarta obiecte spatiale
                $spl = Get-FileSpatialLabel -File $File
                if ($spl) { $notes.Add("Pista contine $spl (obiecte spatiale) — foloseste MKV ca s-o pastrezi") | Out-Null }
                if ($level -lt 1) { $level = 1 }
            }
            if (_Matches $subCodecs '^(subrip|srt|ass|ssa)$') { $notes.Add("Subtitrari text vor fi convertite la mov_text pentru MP4") | Out-Null; if ($level -lt 1) { $level = 1 } }
            if (_Matches $subCodecs '^(dvd_subtitle|hdmv_pgs_subtitle)$') { $notes.Add("Subtitrari bitmap (PGS/VobSub) incompatibile cu MP4 — strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
            if ($djiPresent) { $notes.Add("Track-uri DJI (djmd/dbgi) incompatibile cu MP4 — strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
            if ($attachCount -gt 0) { $notes.Add("$attachCount atasament(e) — doar MKV suporta, strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
        }
        "mov" {
            # v57: AV1 NU e suportat de MOV (ffmpeg: "av1 only supported in MP4 and AVIF")
            if ($videoCodec -eq "av1") { $notes.Add("Video AV1 incompatibil cu .mov (ffmpeg limit) — alege .mp4 sau .mkv") | Out-Null; $level = 2 }
            if (_Matches $audioCodecs '^eac3$') { $notes.Add("E-AC3 audio incompatibil cu .mov — abort"); $level = 2 }
            if (_Matches $audioCodecs '^(truehd|dts|opus)$') {
                $notes.Add("Audio (TrueHD/DTS/Opus) incompatibil cu MOV — strip") | Out-Null
                # v87: spune EXPLICIT cand pista strip-uita poarta obiecte spatiale
                $spl = Get-FileSpatialLabel -File $File
                if ($spl) { $notes.Add("Pista contine $spl (obiecte spatiale) — foloseste MKV ca s-o pastrezi") | Out-Null }
                if ($level -lt 1) { $level = 1 }
            }
            if (_Matches $subCodecs '^(subrip|srt|ass|ssa)$') { $notes.Add("Subtitrari text vor fi convertite la mov_text pentru MOV") | Out-Null; if ($level -lt 1) { $level = 1 } }
            if (_Matches $subCodecs '^(dvd_subtitle|hdmv_pgs_subtitle)$') { $notes.Add("Subtitrari bitmap (PGS/VobSub) incompatibile cu MOV — strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
            if ($djiPresent) { $notes.Add("Track-uri DJI (djmd/dbgi) incompatibile cu MOV — strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
            if ($attachCount -gt 0) { $notes.Add("$attachCount atasament(e) — doar MKV suporta, strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
        }
        "webm" {
            if ($videoCodec -and $videoCodec -notmatch '^(vp8|vp9|av1)$') { $notes.Add("Video '$videoCodec' incompatibil cu WEBM (doar VP8/VP9/AV1) — abort"); $level = 2 }
            if (_Matches $audioCodecs '^(aac|ac3|eac3|mp3|dts|truehd|alac|pcm_s16le|pcm_s24le)$') { $notes.Add("Audio incompatibil cu WEBM (doar Opus/Vorbis) — strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
            if (_Matches $subCodecs '^(subrip|srt|ass|ssa|dvd_subtitle|hdmv_pgs_subtitle|mov_text)$') { $notes.Add("Subtitrari incompatibile cu WEBM (doar WebVTT) — strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
            if ($attachCount -gt 0) { $notes.Add("$attachCount atasament(e) — WEBM nu suporta, strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
        }
        "mkv" { }
        default { $notes.Add("Container '$target' nesuportat (foloseste mkv/mp4/mov/webm)") | Out-Null; $level = 2 }
    }
    return @{ level = $level; notes = @($notes) }
}

function ConvertFrom-Selection {
    param([string]$Text, [int]$Max)
    $clean = ($Text -replace '\s', '')
    if ([string]::IsNullOrEmpty($clean) -or $clean -match '^(?i)all$') {
        if ($Max -le 0) { return @() }
        return @(0..($Max-1))
    }
    if ($clean -match '^(?i)none$') { return @() }
    $out = New-Object System.Collections.Generic.List[int]
    foreach ($p in ($clean -split ',')) {
        if ($p -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            for ($i = $a-1; $i -le $b-1; $i++) {
                if ($i -ge 0 -and $i -lt $Max) { $out.Add($i) | Out-Null }
            }
        } elseif ($p -match '^\d+$') {
            $i = [int]$p - 1
            if ($i -ge 0 -and $i -lt $Max) { $out.Add($i) | Out-Null }
        } else {
            return $null
        }
    }
    return ,@($out)
}

function Get-SanitizedFilename {
    param([string]$Text)
    $s = ($Text -replace '[^a-zA-Z0-9._-]', '_')
    if ($s.Length -gt 64) { $s = $s.Substring(0, 64) }
    return $s
}

# Scan input dirs, return candidate file list
function Get-MuxCandidates {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($d in @(@{Path=$OutputDir; Label="OUT"}, @{Path=$InputDir; Label="IN"})) {
        if (-not (Test-Path $d.Path)) { continue }
        Get-ChildItem -LiteralPath $d.Path -File | ForEach-Object {
            $ext = $_.Extension.TrimStart('.').ToLowerInvariant()
            if ($SupportedInputExt -contains $ext) {
                $name = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                # Exclude propriile output-uri mux/remux/demux
                if ($name -notlike "*_mux" -and $name -notlike "*_remux" -and $name -notmatch '_v\d+_' -and $name -notmatch '_a\d+_' -and $name -notmatch '_s\d+_' -and $name -notlike "*_cover_*") {
                    $list.Add([PSCustomObject]@{
                        Path = $_.FullName; Name = $_.Name; Label = "[$($d.Label)] $($_.Name)"
                    }) | Out-Null
                }
            }
        }
    }
    return ,$list
}

function Show-FilePicker {
    param($Candidates)
    if ($Candidates.Count -eq 0) {
        Write-Host ""
        Write-Host "Niciun fisier suportat in $InputDir sau $OutputDir." -ForegroundColor Yellow
        Write-Host "Extensii suportate: $($SupportedInputExt -join ', ')" -ForegroundColor DarkGray
        return @()
    }
    Write-Host ""
    Write-Host "Fisiere disponibile:"
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        Write-Host ("  {0,2}) {1}" -f ($i+1), $Candidates[$i].Label)
    }
    Write-Host ""
    $sel = Read-Host "Selecteaza (ex: 1 sau 1,3,5 sau ALL) [implicit ALL]"
    $picks = ConvertFrom-Selection -Text $sel -Max $Candidates.Count
    if ($null -eq $picks) { Write-Host "Selectie invalida." -ForegroundColor Red; return @() }
    if ($picks.Count -eq 0) { Write-Host "Nimic selectat."; return @() }
    return @($picks | ForEach-Object { $Candidates[$_].Path })
}

# ══════════════════════════════════════════════════════════════════════
# REMUX FLOW
# ══════════════════════════════════════════════════════════════════════

function Show-RemuxStreamSelection {
    param([string]$File, [string]$Target)
    $base = [System.IO.Path]::GetFileName($File)
    $szMB = [int]((Get-Item -LiteralPath $File).Length / 1MB)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    Write-Host ("  {0} ({1} MB) -> .{2}" -f $base, $szMB, $Target) -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor DarkGray

    $streams = Get-RemuxStreams -File $File

    $videoCount = $streams.Video.Count
    if ($videoCount -eq 0) {
        Write-Host "VIDEO: nicio stream — skip fisier." -ForegroundColor Yellow
        return $null
    }

    Write-Host ""
    Write-Host "VIDEO ($videoCount):"
    for ($i = 0; $i -lt $videoCount; $i++) {
        $s = $streams.Video[$i]
        $compat = Get-RemuxStreamCompat -Codec $s.Codec -CodecType "video" -Target $Target
        $warn = if ($compat -eq "drop") { " WARN incompat -> drop" } else { "" }
        $langPart = if ($s.Lang) { "[$($s.Lang)] " } else { "" }
        Write-Host ("  {0,2}) {1,-10} {2,-10} {3}{4}{5}" -f ($i+1), $s.Codec, $s.Extra, $langPart, $s.Title, $warn)
    }
    if ($videoCount -eq 1) {
        $videoRel = @(0)
        Write-Host "  -> 1 stream video, selectat automat." -ForegroundColor DarkGray
    } else {
        $inp = Read-Host "Pastreaza video (ex: 1,3 sau ALL/NONE) [ALL]"
        $videoRel = ConvertFrom-Selection -Text $inp -Max $videoCount
        if ($null -eq $videoRel) { Write-Host "Selectie invalida." -ForegroundColor Red; return $null }
    }
    if ($videoRel.Count -eq 0) {
        Write-Host "ATENTIE: niciun stream video selectat — skip fisier." -ForegroundColor Yellow
        return $null
    }

    $audioCount = $streams.Audio.Count
    $audioRel = @()
    $iamfWantAudio = $false
    # v88: substream-urile Opus ale unui grup Eclipsa/IAMF sunt ATOMICE — pe MP4/MOV
    # grupul INTREG se re-scrie la final (indiferent de selectia partiala); pe alte
    # containere nu exista mapare IAMF → spune-o AICI, la selectie (ca la Atmos v87).
    $iamfSrcRemux = [bool](Get-IamfLayout -File $File)
    if ($audioCount -gt 0) {
        Write-Host ""
        Write-Host "AUDIO ($audioCount):"
        if ($iamfSrcRemux) {
            if ($Target -in @("mp4","mov")) {
                Write-Host "  ℹ Pistele opus de mai jos = UN grup Eclipsa/IAMF (atomic) → se pastreaza INTREG pe .$Target" -ForegroundColor Cyan
            } else {
                Write-Host "  ⚠ Pistele opus de mai jos = grup Eclipsa/IAMF — .$Target nu are mapare IAMF → raman Opus simplu (alege MP4/MOV ca sa pastrezi grupul)" -ForegroundColor Yellow
            }
        }
        $audioCompatList = @()
        for ($i = 0; $i -lt $audioCount; $i++) {
            $s = $streams.Audio[$i]
            $compat = Get-RemuxStreamCompat -Codec $s.Codec -CodecType "audio" -Target $Target
            $audioCompatList += $compat
            $warn = if ($compat -eq "drop") { " WARN incompat -> drop" } else { "" }
            if ($compat -eq "drop") {
                # v87: pierderea e mai grava cand pista poarta obiecte spatiale — spune-o AICI,
                # la momentul selectiei (notele preflight level-1 nu se afiseaza pe acest flux)
                switch (Get-AudioSpatialKind -File $File -AIdx $i) {
                    "atmos" { $warn = " WARN incompat -> drop (Dolby Atmos! foloseste MKV ca s-o pastrezi)" }
                    "dtsx"  { $warn = " WARN incompat -> drop (DTS:X! foloseste MKV ca s-o pastrezi)" }
                }
            }
            $langPart = if ($s.Lang) { "[$($s.Lang)] " } else { "" }
            Write-Host ("  {0,2}) {1,-10} {2,-6} {3}{4}{5}" -f ($i+1), $s.Codec, $s.Extra, $langPart, $s.Title, $warn)
        }
        $inp = Read-Host "Pastreaza audio (ex: 1,3 sau ALL/NONE) [ALL]"
        $audioRel = ConvertFrom-Selection -Text $inp -Max $audioCount
        if ($null -eq $audioRel) { Write-Host "Selectie invalida." -ForegroundColor Red; return $null }
        # v88: userul a CERUT audio (selectie ne-goala INAINTE de filtrarea compat) —
        # daca compat-ul dropeaza substream-urile opus (ex. →MOV), graft-ul IAMF de la
        # final tot ruleaza (grupul vine din SURSA, nu din output).
        $iamfWantAudio = (@($audioRel).Count -gt 0)
        # v87 FIX pre-existent (v49): drop-ul promis in afisaj NU se aplica efectiv la
        # AUDIO — pistele incompatibile selectate (ALL/explicit) intrau in comanda ffmpeg
        # -> "Could not write header" -> remux esuat COMPLET. Mirror-ul mecanismului subs.
        $audioRel = @($audioRel | Where-Object {
            if ($audioCompatList[$_] -eq "drop") {
                Write-Host ("  -> pista audio {0} incompatibila cu .{1} — dropata" -f ($_ + 1), $Target) -ForegroundColor Yellow
                $false
            } else { $true }
        })
    } else {
        Write-Host ""
        Write-Host "AUDIO: niciun stream." -ForegroundColor DarkGray
    }

    $subCount = $streams.Subtitle.Count
    $subRel = @(); $subAction = New-Object System.Collections.Generic.List[string]
    if ($subCount -gt 0) {
        Write-Host ""
        Write-Host "SUBTITRARI ($subCount):"
        $subCompatList = @()
        for ($i = 0; $i -lt $subCount; $i++) {
            $s = $streams.Subtitle[$i]
            $compat = Get-RemuxStreamCompat -Codec $s.Codec -CodecType "subtitle" -Target $Target
            $subCompatList += $compat
            $warn = ""
            if ($compat -eq "drop") { $warn = " WARN incompat -> drop" }
            elseif ($compat -like "convert:*") { $warn = " -> $($compat.Substring(8))" }
            $langPart = if ($s.Lang) { "[$($s.Lang)] " } else { "" }
            Write-Host ("  {0,2}) {1,-15} {2}{3}{4}" -f ($i+1), $s.Codec, $langPart, $s.Title, $warn)
        }
        $inp = Read-Host "Pastreaza subtitrari (ex: 1,3 sau ALL/NONE) [ALL]"
        $subRel = ConvertFrom-Selection -Text $inp -Max $subCount
        if ($null -eq $subRel) { Write-Host "Selectie invalida." -ForegroundColor Red; return $null }
        foreach ($r in $subRel) { $subAction.Add($subCompatList[$r]) | Out-Null }
    }

    $attachCount = $streams.Attachment.Count
    $keepAttach = $false
    if ($attachCount -gt 0) {
        Write-Host ""
        if ($Target -eq "mkv") {
            Write-Host "ATTACHMENTS: $attachCount fisier(e) (fonts/imagini)"
            $inp = Read-Host "Pastreaza atasamente? (D/n) [D]"
            $keepAttach = -not ($inp -match '^[nN]')
        } else {
            Write-Host "ATTACHMENTS: $attachCount — doar MKV suporta atasamente. Vor fi strip-uite." -ForegroundColor DarkGray
        }
    }

    $keepChapters = $false
    if ($streams.ChapterCount -gt 0) {
        Write-Host ""
        Write-Host "CHAPTERS: $($streams.ChapterCount) marker(e)"
        $inp = Read-Host "Pastreaza chapters? (D/n) [D]"
        $keepChapters = -not ($inp -match '^[nN]')
    }

    return @{
        Streams       = $streams
        VideoRel      = @($videoRel)
        AudioRel      = @($audioRel)
        SubRel        = @($subRel)
        SubAction     = @($subAction)
        KeepAttach    = $keepAttach
        KeepChapters  = $keepChapters
        IamfWantAudio = $iamfWantAudio   # v88: audio cerut pre-filtrare compat (graft IAMF)
    }
}

# v71: scrie dvcC de container pe un fisier DEJA construit ($Built), inlocuind
# video-ul cu $Raw (DV, cu RPU). Dispatch dupa container: mkv -> mkvmerge, mp4/mov
# -> MP4Box. Inline (av_mux.ps1 e standalone). Folosit de Mux + Remux (DRY).
# Unealta absenta / esec -> pastreaza $Built (comportament neschimbat).
function Invoke-AvMuxDvSignal {
    param([string]$Raw, [string]$Built, [string]$Target, [string]$DvRef = "")
    $afr = (& ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 $Built 2>$null | Select-Object -First 1)
    if ($afr) { $afr = $afr.Trim() }
    if ($afr -notmatch '^[1-9][0-9]*(/[1-9][0-9]*)?$') { return }
    $dvFinal = Join-Path $TempBase ("muxdv_" + [guid]::NewGuid().ToString("N") + "." + $Target)
    $ok = $false
    if ($Target -eq 'mkv') {
        $mux = if ($env:AV_TOOL_MKVMERGE) { $env:AV_TOOL_MKVMERGE } else { "mkvmerge" }
        if (Get-Command $mux -ErrorAction SilentlyContinue) {
            & $mux -o $dvFinal --default-duration "0:${afr}fps" $Raw --no-video $Built 2>$null | Out-Null
            $ok = ($LASTEXITCODE -eq 0 -and (Test-Path $dvFinal) -and (Get-Item $dvFinal).Length -gt 0)
        }
    } else {
        $mux = if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } else { "mp4box" }
        # HEVC: MP4Box auto-detecteaza DV din NAL-uri. AV1 (.ivf/.av1/.obu): auto-detect-ul
        # refuza plasarea OBU DV de la av1dovi_tool -> dvp= EXPLICIT (v72), care scrie dvcC
        # oricum. Compat din $DvRef (sursa la Remux/passthrough) sau $Built, fallback 10.1.
        $rawExt = [System.IO.Path]::GetExtension($Raw).TrimStart('.').ToLowerInvariant()
        $isAv1 = $rawExt -in @('ivf','av1','obu')
        if (($rawExt -in @('hevc','h265','265','ivf','av1','obu')) -and (Get-Command $mux -ErrorAction SilentlyContinue)) {
            $firstAdd = "${Raw}:fps=${afr}"
            if ($isAv1) {
                # AV1 DV e MEREU profil 10 (dav1.10.xx) — NU citi dv_profile din referinta
                # (cross-codec ar da 8/5/7). Citeste DOAR compat; fallback 10.1.
                $dvRef = if ($DvRef) { $DvRef } else { $Built }
                $dvp = "10.1"
                $c = (& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_bl_signal_compatibility_id -of default=noprint_wrappers=1:nokey=1 $dvRef 2>$null | Select-Object -First 1)
                if ($c) { $c = $c.Trim() }
                if ($c -match '^[0-9]+$') { $dvp = "10.$c" }
                $firstAdd = "${Raw}:dvp=${dvp}:fps=${afr}"
            }
            $addArgs = New-Object System.Collections.Generic.List[string]
            $addArgs.Add("-add"); $addArgs.Add($firstAdd)
            # ffprobe -select_streams ia un singur specificator → audio apoi subtitle
            foreach ($st in @('a','s')) {
                $ids = @(& ffprobe -v error -select_streams $st -show_entries stream=id -of default=noprint_wrappers=1:nokey=1 $Built 2>$null)
                foreach ($id in $ids) {
                    $id = "$id".Trim()
                    if (-not $id -or $id -eq 'N/A') { continue }
                    $dec = if ($id -like '0x*') { [Convert]::ToInt32($id.Substring(2),16) } else { [int]$id }
                    $addArgs.Add("-add"); $addArgs.Add("${Built}#${dec}")
                }
            }
            & $mux @addArgs -new $dvFinal 2>$null | Out-Null
            $ok = ($LASTEXITCODE -eq 0 -and (Test-Path $dvFinal) -and (Get-Item $dvFinal).Length -gt 0)
            if ($ok) {
                # MP4Box -add NU copiaza capitolele (mkvmerge --no-video le include)
                # → le caram separat (dump-chap + chap), doar daca exista.
                $nch = @(& ffprobe -v error -show_chapters -of csv=p=0 $Built 2>$null).Count
                if ($nch -gt 0) {
                    $chap = Join-Path $TempBase ("chap_" + [guid]::NewGuid().ToString("N") + ".txt")
                    & $mux -dump-chap $Built -out $chap 2>$null | Out-Null
                    if ((Test-Path $chap) -and (Get-Item $chap).Length -gt 0) {
                        & $mux -chap $chap $dvFinal 2>$null | Out-Null
                    }
                    if (Test-Path $chap) { Remove-Item $chap -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    }
    if ($ok) {
        Move-Item -LiteralPath $dvFinal -Destination $Built -Force
        Write-Host "  dvcC de container scris (DV pe TV)" -ForegroundColor DarkGray
    } elseif (Test-Path $dvFinal) {
        Remove-Item -LiteralPath $dvFinal -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RemuxFile {
    param([string]$File, [string]$Target, [hashtable]$Sel)
    $base = [System.IO.Path]::GetFileName($File)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($base)
    $finalOut = Join-Path $OutputDir ("{0}_remux.{1}" -f $name, $Target)

    if (Test-Path -LiteralPath $finalOut) {
        $ow = Read-Host "$([System.IO.Path]::GetFileName($finalOut)) exista. Suprascriu? (d/N) [N]"
        if ($ow -notmatch '^[dD]') { Write-Host "  Sarit." -ForegroundColor Yellow; return $false }
        Remove-Item -LiteralPath $finalOut -Force
    }

    $mapArgs = New-Object System.Collections.Generic.List[string]
    foreach ($r in $Sel.VideoRel) { $mapArgs.Add("-map") | Out-Null; $mapArgs.Add("0:v:$r") | Out-Null }
    foreach ($r in $Sel.AudioRel) { $mapArgs.Add("-map") | Out-Null; $mapArgs.Add("0:a:$r") | Out-Null }

    $needConvertMovText = $false
    $subMappedCount = 0
    for ($i = 0; $i -lt $Sel.SubRel.Count; $i++) {
        $action = $Sel.SubAction[$i]
        if ($action -ne "drop") {
            $mapArgs.Add("-map") | Out-Null
            $mapArgs.Add("0:s:$($Sel.SubRel[$i])") | Out-Null
            if ($action -eq "convert:mov_text") { $needConvertMovText = $true }
            $subMappedCount++
        }
    }

    if ($Sel.KeepAttach) { $mapArgs.Add("-map") | Out-Null; $mapArgs.Add("0:t?") | Out-Null }
    $chaptersArg = if ($Sel.KeepChapters) { @("-map_chapters","0") } else { @("-map_chapters","-1") }

    $codecArgs = @("-c:v","copy","-c:a","copy")
    if ($Target -in @("mp4","mov")) {
        if ($needConvertMovText) { $codecArgs += @("-c:s","mov_text") } else { $codecArgs += @("-c:s","copy") }
    } else {
        $codecArgs += @("-c:s","copy")
    }

    $extraArgs = @()
    $srcCodec = Get-SourceCodec -File $File
    if ($Target -in @("mp4","mov")) {
        switch ($srcCodec) {
            "hevc" { $extraArgs += @("-tag:v","hvc1") }
            "av1"  { $extraArgs += @("-tag:v","av01") }
            "h264" { $extraArgs += @("-tag:v","avc1") }
        }
        $extraArgs += @("-movflags","+faststart")
    }

    Write-Host ""
    Write-Host "  -> $finalOut" -ForegroundColor Cyan
    Write-Host ("  Streams: {0}v + {1}a + {2}s + attach={3} chapters={4}" -f $Sel.VideoRel.Count, $Sel.AudioRel.Count, $subMappedCount, [int]$Sel.KeepAttach, [int]$Sel.KeepChapters)

    $startTs = Get-Date
    $allArgs = @("-y","-v","warning","-nostats","-i",$File) + @($mapArgs) + $chaptersArg + $codecArgs + $extraArgs + @($finalOut)
    & ffmpeg @allArgs
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -or -not (Test-Path -LiteralPath $finalOut) -or (Get-Item -LiteralPath $finalOut).Length -eq 0) {
        Write-Host "  EROARE: remux esuat pentru $base" -ForegroundColor Red
        Remove-Item -LiteralPath $finalOut -Force -ErrorAction SilentlyContinue
        return $false
    }
    # v71 (HEVC) / v72 (AV1): remux al unui DV -> scrie dvcC de container. ffmpeg -c copy
    # PASTREAZA semnalizarea DV la orice ->MKV (block addition in track header), dar o PIERDE
    # la orice ->MP4/MOV. Doar DV (side_data) + video pastrat + tinta mkv/mp4/mov.
    if ($srcCodec -in @("hevc","av1") -and $Sel.VideoRel.Count -gt 0 -and $Target -in @("mkv","mp4","mov")) {
        $sdProbe = ((& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type -of default=noprint_wrappers=1:nokey=1 $File 2>$null) -join "`n")
        # output-DOVI check (paritate cu _dv_resignal_copy): daca ffmpeg a pastrat deja
        # semnalizarea (->MKV), nimic de re-muxat → evitam un re-mux redundant.
        $sdOut = ((& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type -of default=noprint_wrappers=1:nokey=1 $finalOut 2>$null) -join "`n")
        if (($sdProbe -match "DOVI") -and ($sdOut -notmatch "DOVI")) {
            # extragere raw codec-aware: HEVC annexb / AV1 IVF (v72). $File = referinta compat.
            if ($srcCodec -eq "av1") {
                $rxRaw = Join-Path $TempBase ("rxraw_" + [guid]::NewGuid().ToString("N") + ".ivf")
                & ffmpeg -v error -y -i $finalOut -map 0:v:0 -c:v copy -f ivf $rxRaw 2>$null
            } else {
                $rxRaw = Join-Path $TempBase ("rxraw_" + [guid]::NewGuid().ToString("N") + ".hevc")
                & ffmpeg -v error -y -i $finalOut -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb $rxRaw 2>$null
            }
            if ((Test-Path $rxRaw) -and (Get-Item $rxRaw).Length -gt 0) {
                Invoke-AvMuxDvSignal -Raw $rxRaw -Built $finalOut -Target $Target -DvRef $File
            }
            if (Test-Path $rxRaw) { Remove-Item -LiteralPath $rxRaw -Force -ErrorAction SilentlyContinue }
        }
    }
    # v87: pista E-AC-3 Atmos copiata pe MP4/MOV -> ffmpeg scrie dec3 FARA extensia JOC ->
    # re-scrie semnalizarea de container (analog dvcC). No-op pe MKV/non-Atmos.
    Invoke-AtmosMp4Signal -File $finalOut
    # v88: sursa cu grup Eclipsa/IAMF -> ffmpeg l-a aplatizat la remux -> re-grefeaza
    # grupul INTREG din sursa (atomic). -AllowNoAudio: userul a cerut audio dar compat-ul
    # l-a dropat la ffmpeg (opus->MOV). No-op pe non-IAMF; warn onest pe non-ISO.
    Invoke-IamfPreserve -Source $File -Output $finalOut -AllowNoAudio:([bool]$Sel.IamfWantAudio) | Out-Null
    $elapsed = [int]((Get-Date) - $startTs).TotalSeconds
    $szOrig = (Get-Item -LiteralPath $File).Length
    $szNew = (Get-Item -LiteralPath $finalOut).Length
    Write-Host ("  OK Remux in {0}s | {1} MB -> {2} MB" -f $elapsed, [int]($szOrig/1MB), [int]($szNew/1MB)) -ForegroundColor Green
    return $true
}

function Invoke-RemuxFlow {
    $candidates = Get-MuxCandidates
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  REMUX CONTAINER                             ║" -ForegroundColor Cyan
    Write-Host "║  No re-encode. Selectie streams per fisier.  ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $selectedFiles = Show-FilePicker -Candidates $candidates
    if ($selectedFiles.Count -eq 0) { return }

    Write-Host ""
    Write-Host "Container tinta:"
    Write-Host "  1) mkv   - permisiv (recomandat pt streams diverse)"
    Write-Host "  2) mp4   - distribute / web / mobile"
    Write-Host "  3) mov   - Apple ecosystem (Final Cut, QuickTime)"
    Write-Host "  4) webm  - web open (VP9/AV1 + Opus only)"
    Write-Host ""
    $tc = Read-Host "Alege 1-4 [implicit: 1]"
    $Target = switch ($tc) { "2" {"mp4"} "3" {"mov"} "4" {"webm"} default {"mkv"} }

    $total = 0; $ok = 0; $skip = 0; $fail = 0
    foreach ($f in $selectedFiles) {
        $total++
        $sel = Show-RemuxStreamSelection -File $f -Target $Target
        if ($null -eq $sel) { $skip++; continue }
        $pre = Get-RemuxPreflight -File $f -TargetContainer $Target
        if ($pre.level -ge 2) {
            Write-Host ""
            Write-Host "PRE-FLIGHT FAIL — abort fisier:" -ForegroundColor Red
            foreach ($n in $pre.notes) { Write-Host "    - $n" -ForegroundColor Red }
            $fail++; continue
        }
        if (Invoke-RemuxFile -File $f -Target $Target -Sel $sel) { $ok++ } else { $fail++ }
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  REMUX BATCH SUMMARY                         ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host ("║  Total: {0,-3}  OK: {1,-3}  Skip: {2,-3}  Fail: {3,-3}   ║" -f $total, $ok, $skip, $fail)
    Write-Host "║  Output: $OutputDir"
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
}

# ══════════════════════════════════════════════════════════════════════
# DEMUX FLOW
# ══════════════════════════════════════════════════════════════════════

function Get-DemuxSubtitleExt {
    param([string]$Codec)
    switch ($Codec.ToLowerInvariant()) {
        "subrip"            { return "srt" }
        "srt"               { return "srt" }
        "ass"               { return "ass" }
        "ssa"               { return "ass" }
        "webvtt"            { return "vtt" }
        "hdmv_pgs_subtitle" { return "sup" }
        "dvd_subtitle"      { return "sub" }
        "mov_text"          { return "srt" }
        "tx3g"              { return "srt" }
        default             { return "bin" }
    }
}

function Get-DemuxCoverExt {
    param([string]$Codec)
    switch ($Codec.ToLowerInvariant()) {
        "mjpeg" { return "jpg" }
        "jpeg"  { return "jpg" }
        "png"   { return "png" }
        "webp"  { return "webp" }
        "bmp"   { return "bmp" }
        default { return "img" }
    }
}

# Detect cover art (attached_pic) + data streams (DJI/timecode)
function Get-DemuxSpecialStreams {
    param([string]$File)
    $result = @{
        Cover = New-Object System.Collections.Generic.List[object]
        Data  = New-Object System.Collections.Generic.List[object]
    }
    # v59 audit: TrimEnd(',') pe disposition + tag — csv=p=0 emite trailing comma
    # pe HDR sources, .Trim() doar strip whitespace, NU virgula → compare "1" esua
    # silentios pe cover art pe HDR/HEVC HDR sources.
    $raw = (& ffprobe -v error -select_streams v -show_entries stream=index,codec_name:stream_disposition=attached_pic -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 3
        if ($parts.Count -lt 3) { continue }
        $disp = $parts[2].Trim().TrimEnd(',')
        if ($disp -eq "1") {
            $result.Cover.Add([PSCustomObject]@{ AbsIndex=$parts[0]; Codec=$parts[1] }) | Out-Null
        }
    }
    $raw = (& ffprobe -v error -select_streams d -show_entries stream=index,codec_tag_string -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 2
        if ($parts.Count -lt 1) { continue }
        $tag = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1].Trim().TrimEnd(',') } else { "data" }
        $result.Data.Add([PSCustomObject]@{ AbsIndex=$parts[0]; Tag=$tag }) | Out-Null
    }
    return $result
}

# Genereaza Matroska chapter XML din ffprobe JSON
function New-ChaptersXml {
    param([string]$File, [string]$OutputXml)
    $json = (& ffprobe -v error -show_chapters -of json -- $File 2>$null) | Out-String
    if (-not $json) { return $false }
    try {
        $obj = $json | ConvertFrom-Json
    } catch {
        return $false
    }
    if (-not $obj.chapters -or $obj.chapters.Count -eq 0) { return $false }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine('<!DOCTYPE Chapters SYSTEM "matroskachapters.dtd">')
    [void]$sb.AppendLine('<Chapters>')
    [void]$sb.AppendLine('  <EditionEntry>')
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($ch in $obj.chapters) {
        $startSec = 0.0; $endSec = 0.0
        if ($ch.start_time) { [double]::TryParse($ch.start_time, [System.Globalization.NumberStyles]::Float, $inv, [ref]$startSec) | Out-Null }
        if ($ch.end_time)   { [double]::TryParse($ch.end_time,   [System.Globalization.NumberStyles]::Float, $inv, [ref]$endSec)   | Out-Null }
        $h1 = [int]($startSec / 3600); $rem1 = $startSec - $h1 * 3600
        $m1 = [int]($rem1 / 60); $s1 = $rem1 - $m1 * 60
        $h2 = [int]($endSec / 3600); $rem2 = $endSec - $h2 * 3600
        $m2 = [int]($rem2 / 60); $s2 = $rem2 - $m2 * 60
        $tsStart = ("{0:D2}:{1:D2}:{2:00.000000000}" -f $h1, $m1, $s1)
        $tsEnd   = ("{0:D2}:{1:D2}:{2:00.000000000}" -f $h2, $m2, $s2)
        # InvariantCulture decimal point
        $tsStart = $tsStart -replace ',', '.'
        $tsEnd   = $tsEnd   -replace ',', '.'
        $title = ""
        if ($ch.tags -and $ch.tags.title) { $title = [string]$ch.tags.title }
        $titleEsc = $title -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
        [void]$sb.AppendLine('    <ChapterAtom>')
        [void]$sb.AppendLine("      <ChapterTimeStart>$tsStart</ChapterTimeStart>")
        [void]$sb.AppendLine("      <ChapterTimeEnd>$tsEnd</ChapterTimeEnd>")
        if ($titleEsc) {
            [void]$sb.AppendLine('      <ChapterDisplay>')
            [void]$sb.AppendLine("        <ChapterString>$titleEsc</ChapterString>")
            [void]$sb.AppendLine('        <ChapterLanguage>eng</ChapterLanguage>')
            [void]$sb.AppendLine('      </ChapterDisplay>')
        }
        [void]$sb.AppendLine('    </ChapterAtom>')
    }
    [void]$sb.AppendLine('  </EditionEntry>')
    [void]$sb.AppendLine('</Chapters>')
    [System.IO.File]::WriteAllText($OutputXml, $sb.ToString(), [System.Text.Encoding]::UTF8)
    return (Test-Path -LiteralPath $OutputXml) -and ((Get-Item -LiteralPath $OutputXml).Length -gt 0)
}

function Show-DemuxStreamSelection {
    param([string]$File)
    $base = [System.IO.Path]::GetFileName($File)
    $szMB = [int]((Get-Item -LiteralPath $File).Length / 1MB)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    Write-Host ("  {0} ({1} MB)" -f $base, $szMB) -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor DarkGray

    $streams = Get-RemuxStreams -File $File
    $special = Get-DemuxSpecialStreams -File $File

    # Filtreaza video real (exclude attached_pic cover art)
    $coverAbs = @($special.Cover | ForEach-Object { $_.AbsIndex })
    $realVideo = @($streams.Video | Where-Object { $coverAbs -notcontains $_.AbsIndex })

    # ── VIDEO real ──
    $videoRel = @()
    if ($realVideo.Count -gt 0) {
        Write-Host ""
        Write-Host "VIDEO STREAMS ($($realVideo.Count), exclud cover art):"
        for ($i = 0; $i -lt $realVideo.Count; $i++) {
            $s = $realVideo[$i]
            $langPart = if ($s.Lang) { "[$($s.Lang)] " } else { "" }
            Write-Host ("  {0,2}) {1,-10} {2,-10} {3}{4}" -f ($i+1), $s.Codec, $s.Extra, $langPart, $s.Title)
        }
        $inp = Read-Host "Extrage video (ex: 1,3 sau ALL/NONE) [ALL]"
        $videoRel = ConvertFrom-Selection -Text $inp -Max $realVideo.Count
        if ($null -eq $videoRel) { Write-Host "Selectie invalida." -ForegroundColor Red; return $null }
    } else {
        Write-Host ""
        Write-Host "VIDEO: niciun stream real." -ForegroundColor DarkGray
    }

    # ── Cover art ──
    if ($special.Cover.Count -gt 0) {
        Write-Host ""
        Write-Host "COVER ART: $($special.Cover.Count) (attached_pic) -> extrageri automate"
    }

    # ── AUDIO ──
    $audioRel = @()
    if ($streams.Audio.Count -gt 0) {
        Write-Host ""
        Write-Host "AUDIO STREAMS ($($streams.Audio.Count)):"
        for ($i = 0; $i -lt $streams.Audio.Count; $i++) {
            $s = $streams.Audio[$i]
            $langPart = if ($s.Lang) { "[$($s.Lang)] " } else { "" }
            # v87: marcheaza pistele cu obiecte spatiale (Atmos / DTS:X) — extract=copy le pastreaza
            $spMark = switch (Get-AudioSpatialKind -File $File -AIdx $i) { "atmos" { "  ← ATMOS" } "dtsx" { "  ← DTS:X" } default { "" } }
            Write-Host ("  {0,2}) {1,-10} {2,-6} {3}{4}{5}" -f ($i+1), $s.Codec, $s.Extra, $langPart, $s.Title, $spMark)
        }
        $inp = Read-Host "Extrage audio (ex: 1,3 sau ALL/NONE) [ALL]"
        $audioRel = ConvertFrom-Selection -Text $inp -Max $streams.Audio.Count
        if ($null -eq $audioRel) { Write-Host "Selectie invalida." -ForegroundColor Red; return $null }
    } else {
        Write-Host ""
        Write-Host "AUDIO: niciun stream." -ForegroundColor DarkGray
    }

    # ── SUBTITLE ──
    $subRel = @()
    if ($streams.Subtitle.Count -gt 0) {
        Write-Host ""
        Write-Host "SUBTITRARI ($($streams.Subtitle.Count)):"
        for ($i = 0; $i -lt $streams.Subtitle.Count; $i++) {
            $s = $streams.Subtitle[$i]
            $extNative = Get-DemuxSubtitleExt -Codec $s.Codec
            $langPart = if ($s.Lang) { "[$($s.Lang)] " } else { "" }
            Write-Host ("  {0,2}) {1,-15} {2}{3} -> .{4}" -f ($i+1), $s.Codec, $langPart, $s.Title, $extNative)
        }
        $inp = Read-Host "Extrage subtitrari (ex: 1,3 sau ALL/NONE) [ALL]"
        $subRel = ConvertFrom-Selection -Text $inp -Max $streams.Subtitle.Count
        if ($null -eq $subRel) { Write-Host "Selectie invalida." -ForegroundColor Red; return $null }
    }

    # ── Attachments ──
    $extractAttach = $false
    if ($streams.Attachment.Count -gt 0) {
        Write-Host ""
        Write-Host "ATTACHMENTS: $($streams.Attachment.Count) fisier(e) (fonts/imagini)"
        $inp = Read-Host "Extrage atasamente in <name>_attach/? (D/n) [D]"
        $extractAttach = -not ($inp -match '^[nN]')
    }

    # ── Chapters ──
    $extractChapters = $false
    if ($streams.ChapterCount -gt 0) {
        Write-Host ""
        Write-Host "CHAPTERS: $($streams.ChapterCount) marker(e)"
        $inp = Read-Host "Genereaza <name>_chapters.xml (Matroska)? (D/n) [D]"
        $extractChapters = -not ($inp -match '^[nN]')
    }

    # ── Data streams (opt-in) ──
    $extractData = $false
    if ($special.Data.Count -gt 0) {
        Write-Host ""
        $tags = ($special.Data | ForEach-Object { $_.Tag }) -join ', '
        Write-Host "DATA STREAMS: $($special.Data.Count) (codec_tags: $tags)"
        Write-Host "  Nota: pentru telemetrie DJI/GoPro folosibila (CSV/SRT/GPX), foloseste opt 4" -ForegroundColor DarkGray
        Write-Host "        'Telemetrie video' din meniul principal. Aici e doar binary dump." -ForegroundColor DarkGray
        $inp = Read-Host "Extrage binary in <name>_data/? (d/N) [N]"
        $extractData = ($inp -match '^[dD]')
    }

    return @{
        Streams         = $streams
        Special         = $special
        RealVideo       = $realVideo
        VideoRel        = @($videoRel)
        AudioRel        = @($audioRel)
        SubRel          = @($subRel)
        ExtractAttach   = $extractAttach
        ExtractChapters = $extractChapters
        ExtractData     = $extractData
    }
}

function Invoke-DemuxFile {
    param([string]$File, [hashtable]$Sel)
    $base = [System.IO.Path]::GetFileName($File)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($base)
    $count = 0; $fail = 0

    # ── Video → mkv wrapper ──
    foreach ($rel in $Sel.VideoRel) {
        $s = $Sel.RealVideo[$rel]
        $out = Join-Path $OutputDir ("{0}_v{1}_{2}.mkv" -f $name, $rel, (Get-SanitizedFilename $s.Codec))
        & ffmpeg -y -v warning -nostats -i $File -map "0:$($s.AbsIndex)" -c copy $out 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out) -and (Get-Item -LiteralPath $out).Length -gt 0) {
            Write-Host ("  OK video #{0} ({1}) -> {2}" -f $rel, $s.Codec, [System.IO.Path]::GetFileName($out)) -ForegroundColor Green
            $count++
        } else {
            Write-Host ("  FAIL video #{0} ({1})" -f $rel, $s.Codec) -ForegroundColor Red
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
            $fail++
        }
    }

    # ── Audio → mka wrapper ──
    foreach ($rel in $Sel.AudioRel) {
        $s = $Sel.Streams.Audio[$rel]
        $langSuffix = if ($s.Lang) { "_$(Get-SanitizedFilename $s.Lang)" } else { "" }
        $out = Join-Path $OutputDir ("{0}_a{1}_{2}{3}.mka" -f $name, $rel, (Get-SanitizedFilename $s.Codec), $langSuffix)
        & ffmpeg -y -v warning -nostats -i $File -map "0:$($s.AbsIndex)" -c copy $out 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out) -and (Get-Item -LiteralPath $out).Length -gt 0) {
            $langDisp = if ($s.Lang) { ", $($s.Lang)" } else { "" }
            Write-Host ("  OK audio #{0} ({1}{2}) -> {3}" -f $rel, $s.Codec, $langDisp, [System.IO.Path]::GetFileName($out)) -ForegroundColor Green
            $count++
        } else {
            Write-Host ("  FAIL audio #{0} ({1})" -f $rel, $s.Codec) -ForegroundColor Red
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
            $fail++
        }
    }

    # ── Subtitle → native ext ──
    foreach ($rel in $Sel.SubRel) {
        $s = $Sel.Streams.Subtitle[$rel]
        $extNative = Get-DemuxSubtitleExt -Codec $s.Codec
        $langSuffix = if ($s.Lang) { "_$(Get-SanitizedFilename $s.Lang)" } else { "" }
        $out = Join-Path $OutputDir ("{0}_s{1}_{2}{3}.{4}" -f $name, $rel, (Get-SanitizedFilename $s.Codec), $langSuffix, $extNative)
        $codecArg = if ($s.Codec -in @("mov_text","tx3g")) { "srt" } else { "copy" }
        if ($s.Codec -eq "dvd_subtitle") {
            & ffmpeg -y -v warning -nostats -i $File -map "0:$($s.AbsIndex)" -c copy $out 2>&1 | Out-Null
        } else {
            & ffmpeg -y -v warning -nostats -i $File -map "0:$($s.AbsIndex)" -c:s $codecArg $out 2>&1 | Out-Null
        }
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out) -and (Get-Item -LiteralPath $out).Length -gt 0) {
            $langDisp = if ($s.Lang) { ", $($s.Lang)" } else { "" }
            Write-Host ("  OK subtitle #{0} ({1}{2}) -> {3}" -f $rel, $s.Codec, $langDisp, [System.IO.Path]::GetFileName($out)) -ForegroundColor Green
            $count++
        } else {
            Write-Host ("  FAIL subtitle #{0} ({1})" -f $rel, $s.Codec) -ForegroundColor Red
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
            $fail++
        }
    }

    # ── Cover art auto-extract ──
    for ($i = 0; $i -lt $Sel.Special.Cover.Count; $i++) {
        $c = $Sel.Special.Cover[$i]
        $cext = Get-DemuxCoverExt -Codec $c.Codec
        $out = Join-Path $OutputDir ("{0}_cover_{1}.{2}" -f $name, $i, $cext)
        & ffmpeg -y -v warning -nostats -i $File -map "0:$($c.AbsIndex)" -c copy -frames:v 1 $out 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out)) {
            Write-Host ("  OK cover #{0} ({1}) -> {2}" -f $i, $c.Codec, [System.IO.Path]::GetFileName($out)) -ForegroundColor Green
            $count++
        } else {
            Write-Host ("  FAIL cover #{0} ({1})" -f $i, $c.Codec) -ForegroundColor Red
            $fail++
        }
    }

    # ── Chapters XML ──
    if ($Sel.ExtractChapters) {
        $chOut = Join-Path $OutputDir ("{0}_chapters.xml" -f $name)
        if (New-ChaptersXml -File $File -OutputXml $chOut) {
            Write-Host ("  OK chapters -> {0} ({1} capitole)" -f [System.IO.Path]::GetFileName($chOut), $Sel.Streams.ChapterCount) -ForegroundColor Green
            $count++
        } else {
            Write-Host "  FAIL chapters — generare XML esuata" -ForegroundColor Red
            $fail++
        }
    }

    # ── Attachments dump ──
    # v59 audit: dedup pe filename + path explicit (nu cwd-based) — MKV-uri cu nume
    # duplicate de atasament (ex: 2× Arial.ttf) faceau ca al doilea sa suprascrie
    # tacit pe primul. Acum: numele tinta luat din metadata, sanitize, dedup cu _N.
    if ($Sel.ExtractAttach -and $Sel.Streams.Attachment.Count -gt 0) {
        $attachDir = Join-Path $OutputDir ("{0}_attach" -f $name)
        New-Item -ItemType Directory -Force -Path $attachDir | Out-Null
        $nOk = 0
        for ($t = 0; $t -lt $Sel.Streams.Attachment.Count; $t++) {
            $att = $Sel.Streams.Attachment[$t]
            $rawName = if ($att.Title) { $att.Title } else { "attachment_{0}.bin" -f $t }
            $sanName = Get-SanitizedFilename -Text $rawName
            $finalName = $sanName
            $target = Join-Path $attachDir $finalName
            if (Test-Path -LiteralPath $target) {
                $b = [System.IO.Path]::GetFileNameWithoutExtension($sanName)
                $e = [System.IO.Path]::GetExtension($sanName)
                $i = 2
                do {
                    $finalName = if ($e) { "{0}_{1}{2}" -f $b, $i, $e } else { "{0}_{1}" -f $b, $i }
                    $target = Join-Path $attachDir $finalName
                    $i++
                } while (Test-Path -LiteralPath $target)
            }
            & ffmpeg -y -v error -dump_attachment:t:$t $target -i $File -loglevel quiet 2>&1 | Out-Null
            if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -gt 0) {
                $nOk++
            }
        }
        if ($nOk -gt 0) {
            Write-Host ("  OK attachments -> {0}/ ({1} fisiere)" -f [System.IO.Path]::GetFileName($attachDir), $nOk) -ForegroundColor Green
            $count++
        } else {
            Write-Host "  FAIL attachments — niciun fisier extras" -ForegroundColor Red
            Remove-Item -LiteralPath $attachDir -Force -Recurse -ErrorAction SilentlyContinue
            $fail++
        }
    }

    # ── Data streams binary dump (opt-in) ──
    if ($Sel.ExtractData -and $Sel.Special.Data.Count -gt 0) {
        $dataDir = Join-Path $OutputDir ("{0}_data" -f $name)
        New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
        for ($i = 0; $i -lt $Sel.Special.Data.Count; $i++) {
            $d = $Sel.Special.Data[$i]
            $out = Join-Path $dataDir ("track_d{0}_{1}.bin" -f $i, (Get-SanitizedFilename $d.Tag))
            & ffmpeg -y -v warning -nostats -i $File -map "0:$($d.AbsIndex)" -c copy -f data $out 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out) -and (Get-Item -LiteralPath $out).Length -gt 0) {
                Write-Host ("  OK data #{0} ({1}) -> {2}" -f $i, $d.Tag, [System.IO.Path]::GetFileName($out)) -ForegroundColor Green
                $count++
            } else {
                Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
                $fail++
            }
        }
    }

    Write-Host ("  Total: {0} extras, {1} esuate" -f $count, $fail)
    return ($fail -eq 0)
}

function Invoke-DemuxFlow {
    $candidates = Get-MuxCandidates
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  DEMUX STREAMS                               ║" -ForegroundColor Cyan
    Write-Host "║  Extract streams ca fisiere separate.        ║" -ForegroundColor Cyan
    Write-Host "║  Video -> .mkv | Audio -> .mka | Sub native  ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $selectedFiles = Show-FilePicker -Candidates $candidates
    if ($selectedFiles.Count -eq 0) { return }

    $total = 0; $ok = 0; $skip = 0; $fail = 0
    foreach ($f in $selectedFiles) {
        $total++
        $sel = Show-DemuxStreamSelection -File $f
        if ($null -eq $sel) { $skip++; continue }
        if (Invoke-DemuxFile -File $f -Sel $sel) { $ok++ } else { $fail++ }
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  DEMUX BATCH SUMMARY                         ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host ("║  Total: {0,-3}  OK: {1,-3}  Skip: {2,-3}  Fail: {3,-3}   ║" -f $total, $ok, $skip, $fail)
    Write-Host "║  Output: $OutputDir"
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
}

# ══════════════════════════════════════════════════════════════════════
# MUX FLOW (v50)
# ══════════════════════════════════════════════════════════════════════
# Manual selection. Scan doar InputVideos. Output: <video_base>_mux.<ext>
# Streams ordering = ordinea introdusa de user in prompts.

$MuxExtVideo    = @("mkv","webm","mp4","m4v","mov","ts","m2ts","mts","vob","mxf","hevc","h265","h264","265","264","av1","ivf","vp9")
$MuxExtAudio    = @("mka","m4a","eac3","ac3","aac","flac","opus","mp3","wav","oga","ogg")
$MuxExtSub      = @("srt","ass","ssa","vtt","sup","idx")
$MuxExtChapters = @("xml","txt")
$MuxExtAttach   = @("ttf","otf","ttc","png","jpg","jpeg","webp","bmp")

# Scan $InputDir pentru fisiere matching extensiile date.
# Exclude propriile output-uri (_mux/_remux/_v<idx>_/etc).
function Get-MuxInputFiles {
    param([string[]]$Extensions)
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $InputDir)) { return ,$list }
    Get-ChildItem -LiteralPath $InputDir -File | ForEach-Object {
        $ext = $_.Extension.TrimStart('.').ToLowerInvariant()
        if ($Extensions -contains $ext) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
            if ($name -like "*_mux" -or $name -like "*_remux") { return }
            if ($name -match '_v\d+_' -or $name -match '_a\d+_' -or $name -match '_s\d+_') { return }
            if ($name -match '_cover_\d+') { return }
            $list.Add([PSCustomObject]@{ Path = $_.FullName; Name = $_.Name }) | Out-Null
        }
    }
    return ,$list
}

# Codec detect pe input (raw stream sau container).
# v59 audit: switch la default= — bash mux_codec_of (av_mux.sh) folosea deja default=
# din v57, dar PS1 a ramas pe csv=p=0 → pe video stream produce "hevc," cu trailing
# comma → Trim() nu strip → array compare @("hevc","h264","av1") esua silentios →
# codec_tag (hvc1/av01/avc1) lipsea din output → playere DV-aware nu engajau modul DV.
# Aceeasi familie de bug ca v57 av_check + v58 detect_source_info.
function Get-MuxCodec {
    param([string]$File, [string]$Type)
    $spec = switch ($Type) { "video" {"v:0"} "audio" {"a:0"} "subtitle" {"s:0"} default {"v:0"} }
    $c = ((& ffprobe -v error -select_streams $spec -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 -- $File 2>$null) | Out-String).Trim()
    return $c.ToLowerInvariant()
}

# Extract lang code (2-3 letter ISO) din numele fisierului.
# Acceptate: name.eng.srt | name_eng.mka. Returneaza string gol daca nu detecteaza.
function Get-MuxLangFromFilename {
    param([string]$File)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($File)
    if ($base -match '\.([a-z]{2,3})$') { return $Matches[1] }
    if ($base -match '_([a-z]{2,3})$') {
        $lang = $Matches[1]
        $exclude = @("mkv","mp4","mov","aac","ac3","mp3","srt","ass","sup","idx","sub","hd","sd","hq","lq")
        if ($exclude -notcontains $lang) { return $lang }
    }
    return ""
}

# Converteste Matroska chapter XML (output din Demux opt 2) la FFMETADATA1.
# ffmpeg nu citeste XML chapter direct, doar FFMETADATA. Returneaza $true daca OK.
function Convert-XmlChaptersToFFMetadata {
    param([string]$XmlIn, [string]$OutFile)
    # v59 audit: fail loud cu motiv specific in $script:LastChapterParseError pentru
    # ca caller-ul sa poata afisa exact ce nu a mers (gol / fara root / fara ChapterAtom
    # / parse fail). Pana acum returna doar $false fara explicatie.
    $script:LastChapterParseError = ""
    if (-not (Test-Path -LiteralPath $XmlIn)) {
        $script:LastChapterParseError = "fisier inexistent"
        return $false
    }
    $fileSize = (Get-Item -LiteralPath $XmlIn).Length
    if ($fileSize -eq 0) {
        $script:LastChapterParseError = "XML gol"
        return $false
    }
    try {
        [xml]$doc = Get-Content -LiteralPath $XmlIn -Raw -ErrorAction Stop
    } catch {
        $script:LastChapterParseError = "XML malformat ($($_.Exception.Message))"
        return $false
    }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(";FFMETADATA1")
    # v59 audit: namespace-agnostic XPath. XML cu <Chapters xmlns="..."> default
    # namespace facea XPath "//ChapterAtom" sa returneze 0 noduri (XPath default
    # cere prefix explicit pentru namespaces). Folosim local-name() ca sa match-uim
    # indiferent de namespace. Bash version (awk regex) nu avea problema.
    $atoms = $doc.SelectNodes("//*[local-name()='ChapterAtom']")
    if ($null -eq $atoms -or $atoms.Count -eq 0) {
        $script:LastChapterParseError = "niciun <ChapterAtom> in XML"
        return $false
    }
    $emitted = 0
    foreach ($a in $atoms) {
        # v59: namespace-agnostic child accessors (dot notation rateaza pe namespaced nodes)
        $tsStartNode = $a.SelectSingleNode("*[local-name()='ChapterTimeStart']")
        $tsEndNode   = $a.SelectSingleNode("*[local-name()='ChapterTimeEnd']")
        $tsStart = if ($tsStartNode) { $tsStartNode.InnerText } else { "" }
        $tsEnd   = if ($tsEndNode)   { $tsEndNode.InnerText }   else { "" }
        if (-not $tsStart -or -not $tsEnd) { continue }
        # HH:MM:SS.fff... -> millisec
        $partsS = $tsStart -split ':'
        $partsE = $tsEnd -split ':'
        if ($partsS.Count -ne 3 -or $partsE.Count -ne 3) { continue }
        $hS = 0; $mS = 0; $sS = 0.0
        $hE = 0; $mE = 0; $sE = 0.0
        [void][int]::TryParse($partsS[0], [ref]$hS)
        [void][int]::TryParse($partsS[1], [ref]$mS)
        [void][double]::TryParse($partsS[2], [System.Globalization.NumberStyles]::Float, $inv, [ref]$sS)
        [void][int]::TryParse($partsE[0], [ref]$hE)
        [void][int]::TryParse($partsE[1], [ref]$mE)
        [void][double]::TryParse($partsE[2], [System.Globalization.NumberStyles]::Float, $inv, [ref]$sE)
        $startMs = [int][Math]::Round(($hS * 3600 + $mS * 60 + $sS) * 1000)
        $endMs   = [int][Math]::Round(($hE * 3600 + $mE * 60 + $sE) * 1000)
        $title = ""
        # v59: namespace-agnostic — XPath fara prefix nu match-uia <ChapterDisplay> namespaced
        $disp = $a.SelectSingleNode("*[local-name()='ChapterDisplay']/*[local-name()='ChapterString']")
        if ($disp) { $title = [string]$disp.InnerText }
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("[CHAPTER]")
        [void]$sb.AppendLine("TIMEBASE=1/1000")
        [void]$sb.AppendLine("START=$startMs")
        [void]$sb.AppendLine("END=$endMs")
        if ($title) {
            # Escape FFMETADATA: \ ; # =
            $titleEsc = $title -replace '\\','\\\\' -replace ';','\;' -replace '#','\#' -replace '=','\='
            [void]$sb.AppendLine("title=$titleEsc")
        }
        $emitted++
    }
    if ($emitted -eq 0) {
        $script:LastChapterParseError = "ChapterAtom prezent dar fara ChapterTimeStart/End valide"
        return $false
    }
    [System.IO.File]::WriteAllText($OutFile, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    return (Test-Path -LiteralPath $OutFile) -and ((Get-Item -LiteralPath $OutFile).Length -gt 0)
}

# Mime type pentru attachments (MKV).
function Get-MuxAttachMime {
    param([string]$Ext)
    switch ($Ext.ToLowerInvariant()) {
        "ttf" { return "application/x-truetype-font" }
        "otf" { return "application/vnd.ms-opentype" }
        "ttc" { return "font/collection" }
        "png" { return "image/png" }
        "jpg" { return "image/jpeg" }
        "jpeg" { return "image/jpeg" }
        "webp" { return "image/webp" }
        "bmp" { return "image/bmp" }
        default { return "application/octet-stream" }
    }
}

# Display lista + selectie ordonata.
# Returneaza array de Path-uri (in ordinea introdusa de user) sau $null pe eroare,
# sau @() pentru NONE (cand AllowNone=true).
function Read-MuxPickList {
    param(
        [object]$Files,        # System.Collections.Generic.List sau array
        [string]$Mode,         # "single" / "multi"
        [bool]$AllowNone,
        [string]$Label
    )
    $arr = @($Files)
    if ($arr.Count -eq 0) {
        Write-Host "  ($Label`: niciun fisier disponibil in InputVideos)" -ForegroundColor DarkGray
        if ($AllowNone) { return ,@() }
        return $null
    }
    Write-Host ""
    Write-Host "$Label disponibile in InputVideos:"
    for ($i = 0; $i -lt $arr.Count; $i++) {
        Write-Host ("  {0,2}) {1}" -f ($i+1), $arr[$i].Name)
    }
    $promptText = if ($Mode -eq "single") {
        if ($AllowNone) { "Pick $Label (ex: 2) sau NONE [NONE]" }
        else { "Pick $Label (1 index, ex: 2)" }
    } else {
        if ($AllowNone) { "Pick $Label (ex: 1,3,2 — ordinea conteaza) sau NONE [NONE]" }
        else { "Pick $Label (ex: 1,3,2 — ordinea conteaza)" }
    }
    $inp = Read-Host $promptText
    $clean = ($inp -replace '\s', '')
    if ([string]::IsNullOrEmpty($clean) -or $clean -match '^(?i)none$') {
        if ($AllowNone) { return ,@() }
        Write-Host "  Selectie obligatorie pentru $Label." -ForegroundColor Red
        return $null
    }
    $parts = $clean -split ','
    if ($Mode -eq "single" -and $parts.Count -gt 1) {
        Write-Host "  Eroare: doar un fisier permis pentru $Label." -ForegroundColor Red
        return $null
    }
    $picks = New-Object System.Collections.Generic.List[object]
    foreach ($p in $parts) {
        if ($p -notmatch '^\d+$') {
            Write-Host "  Index invalid: $p" -ForegroundColor Red
            return $null
        }
        $idx = [int]$p - 1
        if ($idx -lt 0 -or $idx -ge $arr.Count) {
            Write-Host "  Index in afara range: $p" -ForegroundColor Red
            return $null
        }
        $picks.Add($arr[$idx]) | Out-Null
    }
    return ,@($picks | ForEach-Object { $_.Path })
}

function Invoke-MuxFlow {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  MUX STREAMS                                 ║" -ForegroundColor Cyan
    Write-Host "║  Combina fisiere raw/wrapped intr-un         ║" -ForegroundColor Cyan
    Write-Host "║  container nou. Manual selection.            ║" -ForegroundColor Cyan
    Write-Host "║  Source: InputVideos                         ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan

    # ── Step 1: VIDEO (mandatory, single) ──
    $videoFiles = Get-MuxInputFiles -Extensions $MuxExtVideo
    $pickedVideo = Read-MuxPickList -Files $videoFiles -Mode "single" -AllowNone $false -Label "VIDEO"
    if ($null -eq $pickedVideo -or $pickedVideo.Count -eq 0) { Write-Host "Abort: video lipsa." -ForegroundColor Red; return }
    $video = $pickedVideo[0]
    $videoName = [System.IO.Path]::GetFileNameWithoutExtension($video)

    # ── Step 2: AUDIO (optional, multi) ──
    $audioFiles = Get-MuxInputFiles -Extensions $MuxExtAudio
    $pickedAudio = Read-MuxPickList -Files $audioFiles -Mode "multi" -AllowNone $true -Label "AUDIO"
    if ($null -eq $pickedAudio) { return }

    # ── Step 3: SUBTITRARI (optional, multi) ──
    $subFilesAll = Get-MuxInputFiles -Extensions $MuxExtSub
    # Filtreaza .sub orfan (pastreaza .sub doar daca nu exista .idx pereche)
    $subFiles = New-Object System.Collections.Generic.List[object]
    foreach ($sf in $subFilesAll) {
        $sfExt = [System.IO.Path]::GetExtension($sf.Path).TrimStart('.').ToLowerInvariant()
        if ($sfExt -eq "sub") {
            $sfBase = [System.IO.Path]::GetFileNameWithoutExtension($sf.Path)
            $sfDir  = [System.IO.Path]::GetDirectoryName($sf.Path)
            $idxPath = Join-Path $sfDir "$sfBase.idx"
            if (Test-Path -LiteralPath $idxPath) { continue }
        }
        $subFiles.Add($sf) | Out-Null
    }
    $pickedSubs = Read-MuxPickList -Files $subFiles -Mode "multi" -AllowNone $true -Label "SUBTITRARI"
    if ($null -eq $pickedSubs) { return }

    # ── Step 4: CHAPTERS (optional, single) ──
    $chapterFiles = Get-MuxInputFiles -Extensions $MuxExtChapters
    $pickedChapters = Read-MuxPickList -Files $chapterFiles -Mode "single" -AllowNone $true -Label "CHAPTERS (xml/txt)"
    if ($null -eq $pickedChapters) { return }

    # ── Step 5: ATTACHMENTS (optional, multi) ──
    $attachFiles = Get-MuxInputFiles -Extensions $MuxExtAttach
    $pickedAttach = Read-MuxPickList -Files $attachFiles -Mode "multi" -AllowNone $true -Label "ATTACHMENTS (fonts/images)"
    if ($null -eq $pickedAttach) { return }

    # ── Step 6: Container target ──
    Write-Host ""
    Write-Host "Container tinta:"
    Write-Host "  1) mkv   - permisiv (recomandat pt streams diverse) [implicit]"
    Write-Host "  2) mp4   - distribute / web / mobile"
    Write-Host "  3) mov   - Apple ecosystem"
    Write-Host "  4) webm  - VP8/VP9/AV1 + Opus/Vorbis"
    Write-Host ""
    $tc = Read-Host "Alege 1-4 [implicit: 1]"
    $Target = switch ($tc) { "2" {"mp4"} "3" {"mov"} "4" {"webm"} "" {"mkv"} "1" {"mkv"} default { $null } }
    if ($null -eq $Target) { Write-Host "Optiune invalida." -ForegroundColor Red; return }

    # ── Output overwrite check (earlier — sa nu pierdem timpul cu metadata daca user anuleaza) ──
    $finalOut = Join-Path $OutputDir ("{0}_mux.{1}" -f $videoName, $Target)
    if (Test-Path -LiteralPath $finalOut) {
        $ow = Read-Host "$([System.IO.Path]::GetFileName($finalOut)) exista. Suprascriu? (d/N) [N]"
        if ($ow -notmatch '^[dD]') { Write-Host "Sarit." -ForegroundColor Yellow; return }
        Remove-Item -LiteralPath $finalOut -Force
    }

    # ── Step 7: Per-stream compat check ──
    $vc = Get-MuxCodec -File $video -Type "video"
    if (-not $vc) { Write-Host "  EROARE: nu pot detecta codec video pentru $([System.IO.Path]::GetFileName($video))." -ForegroundColor Red; return }
    $vCompat = Get-RemuxStreamCompat -Codec $vc -CodecType "video" -Target $Target
    if ($vCompat -eq "drop") {
        Write-Host ""
        Write-Host "PRE-FLIGHT FAIL: codec video '$vc' incompatibil cu .$Target — abort." -ForegroundColor Red
        return
    }

    # v69 audit FIX: video elementary BRUT annexb/OBU (hevc/h264/av1 — FARA PTS
    # pe frame-uri reordonate) → muxerul matroska/webm refuza ("unknown
    # timestamp", output gol). Pre-wrap in MP4 temporar, apoi mux normal.
    # IVF si containerele NU sunt afectate (poarta PTS). Mirror av_mux.sh.
    $rawWrap = ""
    $dvRawSrc = ""
    $vExt = [System.IO.Path]::GetExtension($video).TrimStart('.').ToLowerInvariant()
    if ($Target -in @('mkv','webm') -and $vExt -in @('hevc','h265','265','h264','264','av1')) {
        Write-Host "  Video brut .$vExt → pas intermediar MP4 (matroska/webm cer PTS)..." -ForegroundColor DarkGray
        $rawWrap = Join-Path $TempBase ("muxwrap_" + [guid]::NewGuid().ToString("N") + ".mp4")
        $wTag = switch ($vc) {
            "hevc" { @("-tag:v","hvc1") }
            "h264" { @("-tag:v","avc1") }
            "av1"  { @("-tag:v","av01") }
            default { @() }
        }
        $wArgs = @("-v","error","-y","-i",$video,"-map","0:v:0","-c","copy") + $wTag + @($rawWrap)
        & ffmpeg @wArgs 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $rawWrap) -and (Get-Item $rawWrap).Length -gt 0) {
            # v70 (HEVC) / v71 (AV1 .av1 OBU): video brut -> MKV -> pastram calea raw pt
            # post-procesare dvcC (mkvmerge scrie DOVI config din RPU pe HEVC SI AV1).
            if ($Target -eq 'mkv' -and $vExt -in @('hevc','h265','265','av1')) { $dvRawSrc = $video }
            $video = $rawWrap
        } else {
            Remove-Item $rawWrap -Force -ErrorAction SilentlyContinue
            Write-Host "  EROARE: impachetarea intermediara a video-ului brut a esuat — abort." -ForegroundColor Red
            return
        }
    }
    # v71: AV1 IVF -> MKV (IVF poarta PTS -> sare raw-wrap-ul) -> pastram calea raw pt dvcC
    # (mkvmerge scrie DOVI config din RPU). MP4 ramane HEVC-only.
    if ($Target -eq 'mkv' -and $vExt -eq 'ivf') { $dvRawSrc = $video }
    # v71 (HEVC) / v72 (AV1): pe tinta MP4/MOV, video brut DV -> pastram calea raw pt
    # post-procesare dvcC (MP4Box scrie box-ul dvcC din RPU; AV1 cere dvp= explicit).
    # MP4/MOV nu necesita raw-wrap (deriva PTS).
    if ($Target -in @('mp4','mov','m4v') -and $vExt -in @('hevc','h265','265','av1','ivf')) { $dvRawSrc = $video }

    $audioDropIdx = New-Object System.Collections.Generic.HashSet[int]
    $audioCodec = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $pickedAudio.Count; $i++) {
        $ac = Get-MuxCodec -File $pickedAudio[$i] -Type "audio"
        $audioCodec.Add($ac) | Out-Null
        $aCompat = Get-RemuxStreamCompat -Codec $ac -CodecType "audio" -Target $Target
        if ($aCompat -eq "drop") {
            Write-Host "  WARN: audio '$([System.IO.Path]::GetFileName($pickedAudio[$i]))' ($ac) incompatibil cu .$Target — va fi sarit." -ForegroundColor Yellow
            $audioDropIdx.Add($i) | Out-Null
        }
    }

    $subDropIdx = New-Object System.Collections.Generic.HashSet[int]
    $subCodec = New-Object System.Collections.Generic.List[string]
    $subAction = New-Object System.Collections.Generic.List[string]
    $needMovText = $false
    for ($i = 0; $i -lt $pickedSubs.Count; $i++) {
        $sc = Get-MuxCodec -File $pickedSubs[$i] -Type "subtitle"
        $sfExt = [System.IO.Path]::GetExtension($pickedSubs[$i]).TrimStart('.').ToLowerInvariant()
        if (-not $sc -and $sfExt -eq "idx") { $sc = "dvd_subtitle" }
        if (-not $sc -and $sfExt -eq "sup") { $sc = "hdmv_pgs_subtitle" }
        $subCodec.Add($sc) | Out-Null
        $sCompat = Get-RemuxStreamCompat -Codec $sc -CodecType "subtitle" -Target $Target
        $subAction.Add($sCompat) | Out-Null
        if ($sCompat -eq "drop") {
            Write-Host "  WARN: sub '$([System.IO.Path]::GetFileName($pickedSubs[$i]))' ($sc) incompatibil cu .$Target — va fi sarit." -ForegroundColor Yellow
            $subDropIdx.Add($i) | Out-Null
        } elseif ($sCompat -like "convert:*") {
            Write-Host "  Sub '$([System.IO.Path]::GetFileName($pickedSubs[$i]))' ($sc) -> $($sCompat.Substring(8))"
            if ($sCompat -eq "convert:mov_text") { $needMovText = $true }
        }
    }

    if ($pickedAttach.Count -gt 0 -and $Target -ne "mkv") {
        Write-Host "  WARN: attachments ($($pickedAttach.Count)) suportate doar pe MKV — ignorate pe .$Target." -ForegroundColor Yellow
        $pickedAttach = @()
    }

    # ── Step 8: Per-track metadata edit (opt-in) ──
    $audioLang = New-Object System.Collections.Generic.List[string]
    $audioTitle = New-Object System.Collections.Generic.List[string]
    $audioDefault = New-Object System.Collections.Generic.List[string]
    $firstAudioSet = $false
    for ($i = 0; $i -lt $pickedAudio.Count; $i++) {
        $audioLang.Add((Get-MuxLangFromFilename -File $pickedAudio[$i])) | Out-Null
        $audioTitle.Add("") | Out-Null
        if ($audioDropIdx.Contains($i)) {
            $audioDefault.Add("no") | Out-Null
        } elseif (-not $firstAudioSet) {
            $audioDefault.Add("yes") | Out-Null
            $firstAudioSet = $true
        } else {
            $audioDefault.Add("no") | Out-Null
        }
    }
    $subLang = New-Object System.Collections.Generic.List[string]
    $subTitle = New-Object System.Collections.Generic.List[string]
    $subDefault = New-Object System.Collections.Generic.List[string]
    $subForced = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $pickedSubs.Count; $i++) {
        $subLang.Add((Get-MuxLangFromFilename -File $pickedSubs[$i])) | Out-Null
        $subTitle.Add("") | Out-Null
        $subDefault.Add("no") | Out-Null
        $subForced.Add("no") | Out-Null
    }

    Write-Host ""
    $editMd = Read-Host "Editezi metadata per-track (lang/title/default/forced)? (d/N) [N]"
    if ($editMd -match '^[dD]') {
        for ($i = 0; $i -lt $pickedAudio.Count; $i++) {
            if ($audioDropIdx.Contains($i)) { continue }
            Write-Host ""
            Write-Host ("  Audio #{0}: {1} ({2})" -f ($i+1), [System.IO.Path]::GetFileName($pickedAudio[$i]), $audioCodec[$i])
            $defLang = if ($audioLang[$i]) { $audioLang[$i] } else { "und" }
            $v = Read-Host "    language [$defLang]"; if ($v) { $audioLang[$i] = $v }
            $v = Read-Host "    title [$($audioTitle[$i])]"; if ($v) { $audioTitle[$i] = $v }
            $v = Read-Host "    default flag (d/n) [$($audioDefault[$i])]"
            if ($v -match '^(d|y|yes)$') { $audioDefault[$i] = "yes" }
            elseif ($v -match '^(n|no)$') { $audioDefault[$i] = "no" }
        }
        for ($i = 0; $i -lt $pickedSubs.Count; $i++) {
            if ($subDropIdx.Contains($i)) { continue }
            Write-Host ""
            Write-Host ("  Subtitle #{0}: {1} ({2})" -f ($i+1), [System.IO.Path]::GetFileName($pickedSubs[$i]), $subCodec[$i])
            $defLang = if ($subLang[$i]) { $subLang[$i] } else { "und" }
            $v = Read-Host "    language [$defLang]"; if ($v) { $subLang[$i] = $v }
            $v = Read-Host "    title [$($subTitle[$i])]"; if ($v) { $subTitle[$i] = $v }
            $v = Read-Host "    default flag (d/n) [$($subDefault[$i])]"
            if ($v -match '^(d|y|yes)$') { $subDefault[$i] = "yes" }
            elseif ($v -match '^(n|no)$') { $subDefault[$i] = "no" }
            $v = Read-Host "    forced flag (d/n) [$($subForced[$i])]"
            if ($v -match '^(d|y|yes)$') { $subForced[$i] = "yes" }
            elseif ($v -match '^(n|no)$') { $subForced[$i] = "no" }
        }
    }

    # ── Step 9: Build ffmpeg command ──
    $inArgs = New-Object System.Collections.Generic.List[string]
    $inArgs.Add("-i") | Out-Null; $inArgs.Add($video) | Out-Null
    $inputIdx = 1
    $audioInputIdx = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $pickedAudio.Count; $i++) {
        if ($audioDropIdx.Contains($i)) { $audioInputIdx.Add(-1) | Out-Null; continue }
        $inArgs.Add("-i") | Out-Null; $inArgs.Add($pickedAudio[$i]) | Out-Null
        $audioInputIdx.Add($inputIdx) | Out-Null
        $inputIdx++
    }
    $subInputIdx = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $pickedSubs.Count; $i++) {
        if ($subDropIdx.Contains($i)) { $subInputIdx.Add(-1) | Out-Null; continue }
        $inArgs.Add("-i") | Out-Null; $inArgs.Add($pickedSubs[$i]) | Out-Null
        $subInputIdx.Add($inputIdx) | Out-Null
        $inputIdx++
    }
    $chaptersInputIdx = -1
    $chaptersTmpFFMeta = $null
    if ($pickedChapters.Count -gt 0) {
        $chFile = $pickedChapters[0]
        $chExt = [System.IO.Path]::GetExtension($chFile).TrimStart('.').ToLowerInvariant()
        if ($chExt -eq "xml") {
            # Convert Matroska XML → FFMETADATA1 (ffmpeg nu citeste XML direct)
            $chaptersTmpFFMeta = Join-Path $TempBase ("av_mux_ch_" + [guid]::NewGuid().ToString('N') + ".ffmetadata")
            if (Convert-XmlChaptersToFFMetadata -XmlIn $chFile -OutFile $chaptersTmpFFMeta) {
                $inArgs.Add("-i") | Out-Null; $inArgs.Add($chaptersTmpFFMeta) | Out-Null
                $chaptersInputIdx = $inputIdx
                $inputIdx++
                Write-Host "  Chapters XML convertit la FFMETADATA1 (temp)." -ForegroundColor DarkGray
            } else {
                Write-Host "  WARN: nu pot converti $([System.IO.Path]::GetFileName($chFile)) la FFMETADATA1 — chapters ignorate." -ForegroundColor Yellow
                if ($script:LastChapterParseError) {
                    Write-Host "    Motiv: $($script:LastChapterParseError)" -ForegroundColor Yellow
                }
                Remove-Item -LiteralPath $chaptersTmpFFMeta -Force -ErrorAction SilentlyContinue
                $chaptersTmpFFMeta = $null
            }
        } else {
            $inArgs.Add("-i") | Out-Null; $inArgs.Add($chFile) | Out-Null
            $chaptersInputIdx = $inputIdx
            $inputIdx++
        }
    }

    $mapArgs = New-Object System.Collections.Generic.List[string]
    $mapArgs.Add("-map") | Out-Null; $mapArgs.Add("0:v:0") | Out-Null
    $outAudioIdx = 0
    for ($i = 0; $i -lt $pickedAudio.Count; $i++) {
        if ($audioInputIdx[$i] -eq -1) { continue }
        $mapArgs.Add("-map") | Out-Null; $mapArgs.Add("$($audioInputIdx[$i]):a") | Out-Null
        $outAudioIdx++
    }
    $outSubIdx = 0
    for ($i = 0; $i -lt $pickedSubs.Count; $i++) {
        if ($subInputIdx[$i] -eq -1) { continue }
        $mapArgs.Add("-map") | Out-Null; $mapArgs.Add("$($subInputIdx[$i]):s") | Out-Null
        $outSubIdx++
    }

    $chaptersArgs = if ($chaptersInputIdx -ge 0) { @("-map_chapters", "$chaptersInputIdx") } else { @("-map_chapters", "-1") }

    $codecArgs = @("-c:v","copy","-c:a","copy")
    if ($Target -in @("mp4","mov")) {
        if ($needMovText) { $codecArgs += @("-c:s","mov_text") } else { $codecArgs += @("-c:s","copy") }
    } else {
        $codecArgs += @("-c:s","copy")
    }

    $extraArgs = @()
    if ($Target -in @("mp4","mov")) {
        switch ($vc) {
            "hevc" { $extraArgs += @("-tag:v","hvc1") }
            "av1"  { $extraArgs += @("-tag:v","av01") }
            "h264" { $extraArgs += @("-tag:v","avc1") }
        }
        $extraArgs += @("-movflags","+faststart")
    }

    $metaArgs = New-Object System.Collections.Generic.List[string]
    $outAudioIdx = 0
    for ($i = 0; $i -lt $pickedAudio.Count; $i++) {
        if ($audioInputIdx[$i] -eq -1) { continue }
        $lang = if ($audioLang[$i]) { $audioLang[$i] } else { "und" }
        $metaArgs.Add("-metadata:s:a:$outAudioIdx") | Out-Null; $metaArgs.Add("language=$lang") | Out-Null
        if ($audioTitle[$i]) { $metaArgs.Add("-metadata:s:a:$outAudioIdx") | Out-Null; $metaArgs.Add("title=$($audioTitle[$i])") | Out-Null }
        $metaArgs.Add("-disposition:a:$outAudioIdx") | Out-Null
        if ($audioDefault[$i] -eq "yes") { $metaArgs.Add("default") | Out-Null } else { $metaArgs.Add("0") | Out-Null }
        $outAudioIdx++
    }
    $outSubIdx = 0
    for ($i = 0; $i -lt $pickedSubs.Count; $i++) {
        if ($subInputIdx[$i] -eq -1) { continue }
        $lang = if ($subLang[$i]) { $subLang[$i] } else { "und" }
        $metaArgs.Add("-metadata:s:s:$outSubIdx") | Out-Null; $metaArgs.Add("language=$lang") | Out-Null
        if ($subTitle[$i]) { $metaArgs.Add("-metadata:s:s:$outSubIdx") | Out-Null; $metaArgs.Add("title=$($subTitle[$i])") | Out-Null }
        $disp = ""
        if ($subDefault[$i] -eq "yes") { $disp += "default+" }
        if ($subForced[$i] -eq "yes") { $disp += "forced+" }
        $metaArgs.Add("-disposition:s:$outSubIdx") | Out-Null
        if ($disp) { $metaArgs.Add($disp.TrimEnd('+')) | Out-Null } else { $metaArgs.Add("0") | Out-Null }
        $outSubIdx++
    }

    # Attachments (doar MKV). Mimetype per-index — fara index, ffmpeg aplica
    # global la toate attachment streams si ultimul override-aza pe restul.
    $attachArgs = New-Object System.Collections.Generic.List[string]
    if ($Target -eq "mkv" -and $pickedAttach.Count -gt 0) {
        $attachIdx = 0
        foreach ($af in $pickedAttach) {
            $afExt = [System.IO.Path]::GetExtension($af).TrimStart('.')
            $mime = Get-MuxAttachMime -Ext $afExt
            $attachArgs.Add("-attach") | Out-Null; $attachArgs.Add($af) | Out-Null
            $attachArgs.Add("-metadata:s:t:$attachIdx") | Out-Null; $attachArgs.Add("mimetype=$mime") | Out-Null
            $attachIdx++
        }
    }

    Write-Host ""
    Write-Host "  -> $finalOut" -ForegroundColor Cyan
    Write-Host ("  Video:       {0} ({1})" -f $videoName, $vc)
    Write-Host ("  Audio:       {0} track(s)" -f $outAudioIdx)
    Write-Host ("  Subtitle:    {0} track(s)" -f $outSubIdx)
    $chMsg = if ($chaptersInputIdx -ge 0) { "1 file" } else { "none" }
    Write-Host ("  Chapters:    {0}" -f $chMsg)
    Write-Host ("  Attachments: {0}" -f $pickedAttach.Count)

    $startTs = Get-Date
    $allArgs = @("-y","-v","warning","-nostats") + @($inArgs) + @($mapArgs) + $chaptersArgs + $codecArgs + $extraArgs + @($metaArgs) + @($attachArgs) + @($finalOut)
    & ffmpeg @allArgs
    $rc = $LASTEXITCODE
    # Cleanup temp FFMETADATA daca a fost generat + MP4-ul intermediar (v69)
    if ($chaptersTmpFFMeta) { Remove-Item -LiteralPath $chaptersTmpFFMeta -Force -ErrorAction SilentlyContinue }
    if ($rawWrap) { Remove-Item -LiteralPath $rawWrap -Force -ErrorAction SilentlyContinue }
    if ($rc -ne 0 -or -not (Test-Path -LiteralPath $finalOut) -or (Get-Item -LiteralPath $finalOut).Length -eq 0) {
        Write-Host "  EROARE: mux esuat." -ForegroundColor Red
        Remove-Item -LiteralPath $finalOut -Force -ErrorAction SilentlyContinue
        return
    }
    # v70/v71: video brut HEVC DV -> scrie dvcC de container (DV pe TV, daca sursa avea
    # DV). Dispatch mkv->mkvmerge / mp4-mov->MP4Box via Invoke-AvMuxDvSignal (DRY cu Remux).
    if ($dvRawSrc) { Invoke-AvMuxDvSignal -Raw $dvRawSrc -Built $finalOut -Target $Target }
    # v87: semnalizare Atmos de container pe MP4/MOV (dec3 JOC). No-op pe MKV/non-Atmos.
    Invoke-AtmosMp4Signal -File $finalOut
    $elapsed = [int]((Get-Date) - $startTs).TotalSeconds
    $szNew = (Get-Item -LiteralPath $finalOut).Length
    Write-Host ("  OK Mux in {0}s | output: {1} MB" -f $elapsed, [int]($szNew/1MB)) -ForegroundColor Green
}

# ══════════════════════════════════════════════════════════════════════
# MAIN SUBMENU
# ══════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  MUX TOOLS                           ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  1) Remux  - repackage in container  ║"
Write-Host "║     (mkv/mp4/mov/webm, stream sel)   ║"
Write-Host "║  2) Demux  - extract streams separat ║"
Write-Host "║     (.mkv/.mka/native + attach/cover)║"
Write-Host "║  3) Mux    - combina streams separate║"
Write-Host "║     (video + audio[N] + sub[N] +     ║"
Write-Host "║      chapters + attachments)         ║"
Write-Host "║  4) Anulare                          ║"
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
$muxChoice = Read-Host "Alege 1-4 [implicit: 1]"

switch ($muxChoice) {
    "" { Invoke-RemuxFlow }
    "1" { Invoke-RemuxFlow }
    "2" { Invoke-DemuxFlow }
    "3" { Invoke-MuxFlow }
    "4" { Write-Host "Anulat."; exit 0 }
    default { Write-Host "Optiune invalida." -ForegroundColor Red; exit 1 }
}

exit 0
