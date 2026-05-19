# av_mux.ps1 — Mux tools (v49) — PS1 mirror al av_mux.sh
# Submeniu: 1) Remux 2) Demux 3) Anulare
# Input:  mkv, webm, mp4, m4v, mov, ts, m2ts, mts, vob, mxf
# Output remux: <name>_remux.<ext>
# Output demux: <name>_v<idx>_<codec>.mkv / <name>_a<idx>_<codec>_<lang>.mka /
#               <name>_s<idx>_<codec>_<lang>.<ext> / <name>_cover_<idx>.<ext> /
#               <name>_chapters.xml / <name>_attach/* / <name>_data/* (opt-in)

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$InputDir  = Join-Path $ScriptDir "InputVideos"
$OutputDir = Join-Path $ScriptDir "OutputVideos"
New-Item -ItemType Directory -Force -Path $InputDir, $OutputDir | Out-Null

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
    $c = (& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 -- $File 2>$null) | Out-String
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
    $raw = (& ffprobe -v error -select_streams v -show_entries stream=index,codec_name,width,height:stream_tags=language,title -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 6
        $idx = $parts[0]
        $codec = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $w = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $h = if ($parts.Count -gt 3) { $parts[3] } else { "" }
        $lang = if ($parts.Count -gt 4) { $parts[4] } else { "" }
        $title = if ($parts.Count -gt 5) { $parts[5] } else { "" }
        $result.Video.Add([PSCustomObject]@{ AbsIndex=$idx; Codec=$codec; Lang=$lang; Title=$title; Extra="${w}x${h}" }) | Out-Null
    }
    $raw = (& ffprobe -v error -select_streams a -show_entries stream=index,codec_name,channels:stream_tags=language,title -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 5
        $idx = $parts[0]
        $codec = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $ch = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $lang = if ($parts.Count -gt 3) { $parts[3] } else { "" }
        $title = if ($parts.Count -gt 4) { $parts[4] } else { "" }
        $result.Audio.Add([PSCustomObject]@{ AbsIndex=$idx; Codec=$codec; Lang=$lang; Title=$title; Extra="${ch}ch" }) | Out-Null
    }
    $raw = (& ffprobe -v error -select_streams s -show_entries stream=index,codec_name:stream_tags=language,title -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 4
        $idx = $parts[0]
        $codec = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $lang = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $title = if ($parts.Count -gt 3) { $parts[3] } else { "" }
        $result.Subtitle.Add([PSCustomObject]@{ AbsIndex=$idx; Codec=$codec; Lang=$lang; Title=$title; Extra="" }) | Out-Null
    }
    $raw = (& ffprobe -v error -select_streams t -show_entries stream=index,codec_name:stream_tags=filename -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 3
        $idx = $parts[0]
        $codec = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $title = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $result.Attachment.Add([PSCustomObject]@{ AbsIndex=$idx; Codec=$codec; Lang=""; Title=$title; Extra="" }) | Out-Null
    }
    $rawCh = (& ffprobe -v error -show_chapters -of csv=p=0 -- $File 2>$null) | Out-String
    $result.ChapterCount = ($rawCh -split "`r?`n" | Where-Object { $_ }).Count
    return $result
}

function Get-RemuxPreflight {
    param([string]$File, [string]$TargetContainer)
    $notes = New-Object System.Collections.Generic.List[string]
    $level = 0
    $target = $TargetContainer.ToLowerInvariant()
    $videoCodec = ((& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 -- $File 2>$null) | Out-String).Trim()
    $audioCodecs = ((& ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 -- $File 2>$null) | Out-String) -split "`r?`n" | Where-Object { $_ }
    $subCodecs   = ((& ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 -- $File 2>$null) | Out-String) -split "`r?`n" | Where-Object { $_ }
    $codecTags   = (& ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 -- $File 2>$null) | Out-String
    $attachCount = (((& ffprobe -v error -select_streams t -show_entries stream=index -of csv=p=0 -- $File 2>$null) | Out-String) -split "`r?`n" | Where-Object { $_ }).Count
    $djiPresent = $codecTags -match "(?i)\b(djmd|dbgi)\b"
    function _Matches([string[]]$list, [string]$pat) { foreach ($c in $list) { if ($c -match $pat) { return $true } }; return $false }
    switch ($target) {
        "mp4" {
            if (_Matches $audioCodecs '^(truehd|dts|pcm_s24le|pcm_s16be)$') { $notes.Add("Audio lossless (TrueHD/DTS-HD/PCM) incompatibil cu MP4 — strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
            if (_Matches $subCodecs '^(subrip|srt|ass|ssa)$') { $notes.Add("Subtitrari text vor fi convertite la mov_text pentru MP4") | Out-Null; if ($level -lt 1) { $level = 1 } }
            if (_Matches $subCodecs '^(dvd_subtitle|hdmv_pgs_subtitle)$') { $notes.Add("Subtitrari bitmap (PGS/VobSub) incompatibile cu MP4 — strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
            if ($djiPresent) { $notes.Add("Track-uri DJI (djmd/dbgi) incompatibile cu MP4 — strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
            if ($attachCount -gt 0) { $notes.Add("$attachCount atasament(e) — doar MKV suporta, strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
        }
        "mov" {
            if (_Matches $audioCodecs '^eac3$') { $notes.Add("E-AC3 audio incompatibil cu .mov — abort"); $level = 2 }
            if (_Matches $audioCodecs '^(truehd|dts|opus)$') { $notes.Add("Audio (TrueHD/DTS/Opus) incompatibil cu MOV — strip") | Out-Null; if ($level -lt 1) { $level = 1 } }
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
                # Exclude propriile output-uri remux/demux
                if ($name -notlike "*_remux" -and $name -notmatch '_v\d+_' -and $name -notmatch '_a\d+_' -and $name -notmatch '_s\d+_' -and $name -notlike "*_cover_*") {
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
    if ($audioCount -gt 0) {
        Write-Host ""
        Write-Host "AUDIO ($audioCount):"
        for ($i = 0; $i -lt $audioCount; $i++) {
            $s = $streams.Audio[$i]
            $compat = Get-RemuxStreamCompat -Codec $s.Codec -CodecType "audio" -Target $Target
            $warn = if ($compat -eq "drop") { " WARN incompat -> drop" } else { "" }
            $langPart = if ($s.Lang) { "[$($s.Lang)] " } else { "" }
            Write-Host ("  {0,2}) {1,-10} {2,-6} {3}{4}{5}" -f ($i+1), $s.Codec, $s.Extra, $langPart, $s.Title, $warn)
        }
        $inp = Read-Host "Pastreaza audio (ex: 1,3 sau ALL/NONE) [ALL]"
        $audioRel = ConvertFrom-Selection -Text $inp -Max $audioCount
        if ($null -eq $audioRel) { Write-Host "Selectie invalida." -ForegroundColor Red; return $null }
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
        Streams      = $streams
        VideoRel     = @($videoRel)
        AudioRel     = @($audioRel)
        SubRel       = @($subRel)
        SubAction    = @($subAction)
        KeepAttach   = $keepAttach
        KeepChapters = $keepChapters
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
    $raw = (& ffprobe -v error -select_streams v -show_entries stream=index,codec_name:stream_disposition=attached_pic -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 3
        if ($parts.Count -lt 3) { continue }
        $disp = $parts[2].Trim()
        if ($disp -eq "1") {
            $result.Cover.Add([PSCustomObject]@{ AbsIndex=$parts[0]; Codec=$parts[1] }) | Out-Null
        }
    }
    $raw = (& ffprobe -v error -select_streams d -show_entries stream=index,codec_tag_string -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 2
        if ($parts.Count -lt 1) { continue }
        $tag = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1].Trim() } else { "data" }
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
            Write-Host ("  {0,2}) {1,-10} {2,-6} {3}{4}" -f ($i+1), $s.Codec, $s.Extra, $langPart, $s.Title)
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
    if ($Sel.ExtractAttach -and $Sel.Streams.Attachment.Count -gt 0) {
        $attachDir = Join-Path $OutputDir ("{0}_attach" -f $name)
        New-Item -ItemType Directory -Force -Path $attachDir | Out-Null
        # ffmpeg -dump_attachment:t:N "" -i input — necesita cwd = attachDir
        $origLoc = Get-Location
        try {
            Set-Location -LiteralPath $attachDir
            for ($t = 0; $t -lt $Sel.Streams.Attachment.Count; $t++) {
                & ffmpeg -y -v error -dump_attachment:t:$t "" -i $File -loglevel quiet 2>&1 | Out-Null
            }
        } finally {
            Set-Location -LiteralPath $origLoc
        }
        $nExtracted = @(Get-ChildItem -LiteralPath $attachDir -File -ErrorAction SilentlyContinue).Count
        if ($nExtracted -gt 0) {
            Write-Host ("  OK attachments -> {0}/ ({1} fisiere)" -f [System.IO.Path]::GetFileName($attachDir), $nExtracted) -ForegroundColor Green
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
Write-Host "║  3) Anulare                          ║"
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
$muxChoice = Read-Host "Alege 1-3 [implicit: 1]"

switch ($muxChoice) {
    "" { Invoke-RemuxFlow }
    "1" { Invoke-RemuxFlow }
    "2" { Invoke-DemuxFlow }
    "3" { Write-Host "Anulat."; exit 0 }
    default { Write-Host "Optiune invalida." -ForegroundColor Red; exit 1 }
}

exit 0
