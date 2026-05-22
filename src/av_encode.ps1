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

$InputDir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutputDir       = Join-Path $InputDir "output"
$LutsDir         = Join-Path $InputDir "Luts"
$ToolsDir        = Join-Path $PSScriptRoot "tools"
$ProfilesDir     = Join-Path $PSScriptRoot "profiles"
$UserProfilesDir = Join-Path $InputDir "UserProfiles"
# v36: Folder temporar (Trim & Concat) — creat lazy la prima folosire
$AV_TEMP_DIR     = Join-Path $InputDir "Temp"
function Ensure-TempDir {
    if (-not (Test-Path $AV_TEMP_DIR)) {
        New-Item -ItemType Directory -Force -Path $AV_TEMP_DIR | Out-Null
    }
}

# ── Trim & Concat helpers (v36) ───────────────────────────────────────
function ConvertFrom-FlexibleTime {
    param([string]$t)
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    $t = $t.Trim() -replace '\s',''
    $h = 0; $m = 0; $s = 0
    if ($t -match '^(\d+):(\d+):(\d+)$') {
        $h = [int]$Matches[1]; $m = [int]$Matches[2]; $s = [int]$Matches[3]
    } elseif ($t -match '^(\d+):(\d+)$') {
        $m = [int]$Matches[1]; $s = [int]$Matches[2]
    } elseif ($t -match '^(\d+)$') {
        $s = [int]$Matches[1]
    } else { return $null }
    if ($m -gt 59 -or $s -gt 59) { return $null }
    return ($h * 3600 + $m * 60 + $s)
}

function Format-Seconds {
    param([int]$s)
    "{0:D2}:{1:D2}:{2:D2}" -f [int][math]::Floor($s/3600), [int][math]::Floor(($s%3600)/60), [int]($s%60)
}

function Get-DurationSeconds {
    param([string]$file)
    $d = (& ffprobe -v error -show_entries format=duration -of csv=p=0 $file 2>$null) -as [double]
    if (-not $d) { return 0 }
    return [int][math]::Floor($d)
}

function Expand-RangeSelection {
    param([string]$raw, [int]$max)
    $raw = $raw -replace '\s',''
    if ($raw.ToLower() -eq 'all') { return 1..$max }
    $out = [System.Collections.ArrayList]@()
    foreach ($part in ($raw -split ',')) {
        if ($part -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
            for ($i = $a; $i -le $b -and $i -le $max; $i++) {
                if ($i -ge 1) { [void]$out.Add($i) }
            }
        } elseif ($part -match '^\d+$') {
            $n = [int]$part
            if ($n -ge 1 -and $n -le $max) { [void]$out.Add($n) }
        }
    }
    return ($out | Select-Object -Unique)
}

function Read-ValidatedTime {
    param([string]$prompt, [int]$defaultSeconds, [int]$maxSeconds)
    $defFmt = Format-Seconds $defaultSeconds
    while ($true) {
        $raw = Read-Host "$prompt [default: $defFmt]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $defaultSeconds }
        $parsed = ConvertFrom-FlexibleTime $raw
        if ($null -eq $parsed) {
            Write-Host "  Format invalid. Exemple: 45 / 1:30 / 1:05:30 / 01:05:30" -ForegroundColor Yellow
            continue
        }
        if ($parsed -gt $maxSeconds) {
            Write-Host "  Timp > durata (${maxSeconds}s). Clamp la durata maxima." -ForegroundColor Yellow
            return $maxSeconds
        }
        if ($parsed -lt 0) { return 0 }
        return $parsed
    }
}

function Resolve-OutputCollision {
    param([string]$target)
    if (-not (Test-Path $target)) { return $target }
    Write-Host ""
    Write-Host "  ⚠ Fisierul exista deja: $(Split-Path -Leaf $target)" -ForegroundColor Yellow
    Write-Host "  1) Suprascrie"
    Write-Host "  2) Auto-suffix (_1, _2, ...)"
    Write-Host "  3) Rename manual"
    $ch = Read-Host "  Alege [default: 2]"
    $dir = Split-Path -Parent $target
    $base = Split-Path -Leaf $target
    $ext = [System.IO.Path]::GetExtension($base)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($base)
    switch ($ch) {
        "1" { return $target }
        "3" {
            $nn = Read-Host "  Nume nou (fara extensie)"
            return (Join-Path $dir "$nn$ext")
        }
        default {
            $n = 1
            while (Test-Path (Join-Path $dir "${name}_${n}${ext}")) { $n++ }
            return (Join-Path $dir "${name}_${n}${ext}")
        }
    }
}

function Get-TcInputVideos {
    $exts = @("mp4","mov","mkv","m2ts","mts","mxf","webm","avi")
    $files = @()
    foreach ($e in $exts) {
        $files += Get-ChildItem -Path $InputDir -Filter "*.$e" -File -ErrorAction SilentlyContinue
    }
    return $files | Sort-Object Name
}

function New-TempSubdir {
    param([string]$prefix = "trim")
    Ensure-TempDir
    $guid = [guid]::NewGuid().ToString("N").Substring(0,8)
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $sub = Join-Path $AV_TEMP_DIR "${prefix}_${ts}_${guid}"
    New-Item -ItemType Directory -Force -Path $sub | Out-Null
    return $sub
}

function Invoke-TcTempCleanupPrompt {
    if (-not (Test-Path $AV_TEMP_DIR)) { return }
    $leftover = @(Get-ChildItem -Path $AV_TEMP_DIR -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(trim|concat|pipeline|preview)_' })
    if ($leftover.Count -eq 0) { return }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Temp — foldere reziduale detectate          ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    $now = Get-Date
    foreach ($d in $leftover) {
        $ageH = [int]($now - $d.LastWriteTime).TotalHours
        $sz = 0
        Get-ChildItem -Path $d.FullName -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $sz += $_.Length }
        $szMB = [int]($sz / 1MB)
        $ageStr = if ($ageH -ge 24) { "{0}z" -f [int]($ageH/24) } else { "${ageH}h" }
        $nm = if ($d.Name.Length -gt 30) { $d.Name.Substring(0,30) } else { $d.Name }
        Write-Host ("║  {0,-30} {1,4}MB  {2}" -f $nm, $szMB, $ageStr) -ForegroundColor White
    }
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "  1) Pastreaza toate"
    Write-Host "  2) Sterge pe cele > 24h [default]"
    Write-Host "  3) Sterge toate"
    $ch = Read-Host "Alege 1-3"
    if (-not $ch) { $ch = "2" }
    switch ($ch) {
        "2" {
            foreach ($d in $leftover) {
                if (($now - $d.LastWriteTime).TotalHours -ge 24) {
                    Remove-Item -Recurse -Force $d.FullName -ErrorAction SilentlyContinue
                    Write-Host "  sters: $($d.Name)" -ForegroundColor Gray
                }
            }
        }
        "3" {
            foreach ($d in $leftover) {
                Remove-Item -Recurse -Force $d.FullName -ErrorAction SilentlyContinue
            }
            Write-Host "  toate sterse" -ForegroundColor Gray
        }
        default { }
    }
}

function Get-PipelineHdrMode {
    param([string[]]$Files)
    $hasHdr10 = $false; $hasHlg = $false; $hasDv = $false
    $hasSdr = $false; $hasHdr10Plus = $false
    foreach ($f in $Files) {
        $ct = & ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer `
            -of default=nw=1:nk=1 $f 2>$null
        $sd = & ffprobe -v error -select_streams v:0 -read_intervals "%+#1" `
            -show_entries frame=side_data_list -of default=nw=1 $f 2>$null
        switch -regex ($ct) {
            'smpte2084'    { $hasHdr10 = $true }
            'arib-std-b67' { $hasHlg = $true }
            default        { $hasSdr = $true }
        }
        if ($sd -match '(?i)dolby vision|dovi') { $hasDv = $true }
        if ($sd -match '(?i)hdr dynamic metadata|hdr10\+') { $hasHdr10Plus = $true }
    }
    if ($hasDv) { return "dv" }
    if ($hasSdr -and ($hasHdr10 -or $hasHlg)) { return "mixed" }
    if ($hasHdr10Plus) { return "hdr10plus" }
    if ($hasHdr10) { return "hdr10" }
    if ($hasHlg) { return "hlg" }
    return "sdr"
}

function Test-TcInputHDR {
    param([string[]]$files)
    foreach ($f in $files) {
        $ct = & ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer `
            -of default=nw=1:nk=1 $f 2>$null
        if ($ct -match 'smpte2084|arib-std-b67') { return $true }
    }
    return $false
}

function Remove-TempSubdirSafe {
    param([string]$subdir, [string]$output)
    $ok = $false
    if ($output -and (Test-Path -LiteralPath $output)) {
        if ((Get-Item -LiteralPath $output).Length -gt 0) { $ok = $true }
    }
    if ($ok) {
        Remove-Item -Recurse -Force -LiteralPath $subdir -ErrorAction SilentlyContinue
        Write-Host "  Temp cleanup: sters." -ForegroundColor DarkGray
    } else {
        Write-Host ""
        Write-Host "  ⚠ EROARE: output final esuat sau gol." -ForegroundColor Red
        Write-Host "  Fisierele temporare pastrate in: $subdir" -ForegroundColor Yellow
    }
}

# v36: Scriere concat.txt cu UTF-8 fara BOM (ffmpeg concat demuxer nu tolereaza BOM)
function Write-ConcatTxtUtf8NoBom {
    param([string]$path, [string[]]$lines)
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($path, $lines, $enc)
}

# ── v36: Flow Trim (opțiunea 1) ───────────────────────────────────────
function Invoke-TrimFlow {
    $files = @(Get-TcInputVideos)
    if ($files.Count -eq 0) {
        Write-Host "Nu exista fisiere video in $InputDir" -ForegroundColor Yellow
        return
    }
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  TRIM — Selectare fisier                     ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    for ($i = 0; $i -lt $files.Count; $i++) {
        $f = $files[$i]
        $dur = Get-DurationSeconds $f.FullName
        $nm = if ($f.Name.Length -gt 32) { $f.Name.Substring(0,32) } else { $f.Name }
        Write-Host ("║  {0,2}) {1,-32} {2}" -f ($i+1), $nm, (Format-Seconds $dur)) -ForegroundColor White
    }
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $sel = Read-Host "Alege 1-$($files.Count)"
    if (-not ($sel -match '^\d+$') -or [int]$sel -lt 1 -or [int]$sel -gt $files.Count) {
        Write-Host "Selectie invalida." -ForegroundColor Red; return
    }
    $src = $files[[int]$sel - 1]
    $srcName = [System.IO.Path]::GetFileNameWithoutExtension($src.Name)
    $srcExt = $src.Extension.TrimStart('.')
    $totalS = Get-DurationSeconds $src.FullName

    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }

    $cutIdx = 1
    while ($true) {
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║  TRIM #$cutIdx — $($src.Name)" -ForegroundColor Cyan
        Write-Host "║  Durata totala: $(Format-Seconds $totalS)" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan

        $startS = 0; $endS = $totalS
        while ($true) {
            $startS = Read-ValidatedTime "Start" 0 $totalS
            $endS   = Read-ValidatedTime "End  " $totalS $totalS
            if ($startS -ge $endS) {
                Write-Host "  EROARE: start >= end. Reintrodu." -ForegroundColor Red
                continue
            }
            break
        }
        $clipS = $endS - $startS
        Write-Host ""
        Write-Host "  Clip rezultat: $(Format-Seconds $clipS) (din $(Format-Seconds $startS) la $(Format-Seconds $endS))" -ForegroundColor Green
        $conf = Read-Host "  Confirma? (d/n) [default: d]"
        if ($conf -ieq "n") { Write-Host "  Anulat." -ForegroundColor Yellow; continue }

        Write-Host ""
        Write-Host "  Precizie trim:" -ForegroundColor Cyan
        Write-Host "    1) Stream copy (instant, lossless, ±1-2s la keyframe) [default]"
        Write-Host "    2) Re-encode (exact, frame-accurate, mai lent)"
        $mode = Read-Host "  Alege 1-2 [default: 1]"

        $suffix = "_trim${cutIdx}_$((Format-Seconds $startS) -replace ':','-')"
        $outPath = Join-Path $OutputDir "${srcName}${suffix}.${srcExt}"
        $outPath = Resolve-OutputCollision $outPath

        if ($mode -eq "2") {
            Write-Host ""
            Write-Host "  Re-encode: 1-libx265 [default]  2-libx264" -ForegroundColor Cyan
            $ec = Read-Host "  Codec"
            $codec = if ($ec -eq "2") { "libx264" } else { "libx265" }
            $crf = Read-Host "  CRF [default: 22]"
            if (-not $crf) { $crf = "22" }
            Write-Host "  Audio: 1-copy [default]  2-aac 192k  3-eac3 224k" -ForegroundColor Cyan
            $ac = Read-Host "  Alege"
            $aArgs = @("-c:a","copy")
            if ($ac -eq "2") { $aArgs = @("-c:a","aac","-b:a","192k") }
            if ($ac -eq "3") { $aArgs = @("-c:a","eac3","-b:a","224k") }
            Write-Host "  Encoding... $(Format-Seconds $clipS)" -ForegroundColor Green
            $ffArgs = @("-y","-ss",$startS,"-to",$endS,"-i",$src.FullName,
                "-map","0","-map_metadata","0","-c:v",$codec,"-crf",$crf,"-preset","medium") +
                $aArgs + @("-c:s","copy","-avoid_negative_ts","make_zero",$outPath)
            Invoke-FfmpegWithProgress -Label "Trim re-encode" -TotalSeconds ([int]$clipS) -Arguments $ffArgs | Out-Null
        } else {
            Write-Host ""
            Write-Host "  NOTA: Stream copy taie la cel mai apropiat keyframe." -ForegroundColor Yellow
            Write-Host "  Taietura poate diferi cu 1-2 secunde fata de timpul exact." -ForegroundColor Yellow
            Write-Host "  Stream copy... (instant)" -ForegroundColor Green
            & ffmpeg -y -ss $startS -to $endS -i $src.FullName `
                -map 0 -map_metadata 0 -c copy `
                -avoid_negative_ts make_zero -copyts `
                $outPath 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }

        if ((Test-Path $outPath) -and ((Get-Item $outPath).Length -gt 0)) {
            $osize = (Get-Item $outPath).Length
            Write-Host ""
            Write-Host "  ✓ Output: $outPath" -ForegroundColor Green
            Write-Host "  ✓ Size: $(Format-Bytes $osize)" -ForegroundColor Green
        } else {
            Write-Host "  ✗ EROARE: output-ul nu a fost creat." -ForegroundColor Red
        }

        Write-Host ""
        $again = Read-Host "Vrei sa tai alta sectiune din acelasi fisier? (d/n) [default: n]"
        if ($again -ine "d") { break }
        $cutIdx++
    }
    Write-Host ""
    Write-Host "  Trim terminat. $cutIdx clip-uri generate." -ForegroundColor Cyan
}

# ── v36: Video signature pt compat concat ────────────────────────────
function New-PreviewThumbnails {
    param([System.IO.FileInfo[]]$Files)
    if ($Files.Count -eq 0) { return }
    $subdir = New-TempSubdir "preview"
    Write-Host "  Generez $($Files.Count) preview-uri (3-frame tile, 320p)..." -ForegroundColor Cyan
    $ok = 0; $fail = 0
    for ($i = 0; $i -lt $Files.Count; $i++) {
        $f = $Files[$i]
        $fn = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $out = Join-Path $subdir "${fn}_preview.png"
        $dur = Get-DurationSeconds $f.FullName
        if ($dur -lt 3) {
            Write-Host "    [$($i+1)/$($Files.Count)] $($f.Name) — skip (durata < 3s)" -ForegroundColor DarkGray
            continue
        }
        $t1 = "{0:F2}" -f ($dur * 0.05)
        $t2 = "{0:F2}" -f ($dur * 0.5)
        $t3 = "{0:F2}" -f ($dur * 0.95)
        & ffmpeg -y -hide_banner -loglevel error `
            -ss $t1 -i $f.FullName -ss $t2 -i $f.FullName -ss $t3 -i $f.FullName `
            -filter_complex "[0:v]scale=320:-1[a];[1:v]scale=320:-1[b];[2:v]scale=320:-1[c];[a][b][c]hstack=3" `
            -frames:v 1 $out 2>$null
        if ((Test-Path $out) -and ((Get-Item $out).Length -gt 0)) {
            $ok++
            Write-Host "    [$($i+1)/$($Files.Count)] $($f.Name) → $(Split-Path $out -Leaf)" -ForegroundColor Gray
        } else {
            $fail++
            Write-Host "    [$($i+1)/$($Files.Count)] $($f.Name) — esuat" -ForegroundColor Yellow
        }
    }
    Write-Host "  ✓ Preview-uri: $ok OK, $fail esuate" -ForegroundColor Green
    Write-Host "  Locatie: $subdir" -ForegroundColor Green
}

function Get-VideoSignature {
    param([string]$file)
    $out = & ffprobe -v error -select_streams v:0 `
        -show_entries stream=codec_name,width,height,r_frame_rate,pix_fmt `
        -of default=noprint_wrappers=1:nokey=1 $file 2>$null
    return ($out -join "|")
}

function Test-ConcatCompatibility {
    param([string[]]$files)
    $first = $null
    foreach ($f in $files) {
        $sig = Get-VideoSignature $f
        if ($null -eq $first) { $first = $sig }
        elseif ($sig -ne $first) { return $false }
    }
    return $true
}

# ── v37: Flow Batch Trim (aceleași cuturi pe N fisiere) ───────────────
function Invoke-BatchTrimFlow {
    $files = @(Get-TcInputVideos)
    if ($files.Count -eq 0) {
        Write-Host "Nu exista fisiere video in $InputDir" -ForegroundColor Yellow
        return
    }
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  BATCH TRIM — Selectare fisiere              ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    for ($i = 0; $i -lt $files.Count; $i++) {
        $dur = Get-DurationSeconds $files[$i].FullName
        $nm = if ($files[$i].Name.Length -gt 32) { $files[$i].Name.Substring(0,32) } else { $files[$i].Name }
        Write-Host ("║  {0,2}) {1,-32} {2}" -f ($i+1), $nm, (Format-Seconds $dur)) -ForegroundColor White
    }
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "Exemple: all / 1,3,5 / 1-5 / 1-3,7,10-12" -ForegroundColor Gray
    $selRaw = Read-Host "Selecteaza fisiere"
    $indices = Expand-RangeSelection $selRaw $files.Count
    if ($indices.Count -eq 0) {
        Write-Host "Selectie invalida." -ForegroundColor Red; return
    }

    $selected = @()
    $minDur = [int]::MaxValue
    foreach ($idx in $indices) {
        $f = $files[$idx-1]
        $selected += $f
        $d = Get-DurationSeconds $f.FullName
        if ($d -lt $minDur) { $minDur = $d }
    }
    Write-Host ""
    Write-Host "  $($selected.Count) fisiere selectate. Cea mai scurta durata: $(Format-Seconds $minDur)" -ForegroundColor Green

    # Cuts comune
    $cuts = @()
    $cutIdx = 1
    while ($true) {
        Write-Host ""
        Write-Host "  Segment #$cutIdx (aplicat la toate fisierele):" -ForegroundColor Cyan
        $startS = 0; $endS = $minDur
        while ($true) {
            $startS = Read-ValidatedTime "Start" 0 $minDur
            $endS   = Read-ValidatedTime "End  " $minDur $minDur
            if ($startS -ge $endS) {
                Write-Host "  EROARE: start >= end. Reintrodu." -ForegroundColor Red; continue
            }
            break
        }
        $cuts += [pscustomobject]@{ Start = $startS; End = $endS }
        Write-Host "  → $(Format-Seconds $startS) - $(Format-Seconds $endS) ($(Format-Seconds ($endS - $startS)))" -ForegroundColor Green
        $again = Read-Host "  Mai adaugi un segment? (d/n) [default: n]"
        if ($again -ine "d") { break }
        $cutIdx++
    }

    Write-Host ""
    Write-Host "  Precizie trim:" -ForegroundColor Cyan
    Write-Host "    1) Stream copy (instant, lossless, ±1-2s la keyframe) [default]"
    Write-Host "    2) Re-encode (exact, frame-accurate, mai lent)"
    $mode = Read-Host "  Alege 1-2 [default: 1]"
    $reCodec = "libx265"; $reCrf = "22"; $reAArgs = @("-c:a","copy")
    if ($mode -eq "2") {
        Write-Host "  Codec: 1-libx265 [default]  2-libx264" -ForegroundColor Cyan
        $ec = Read-Host "  Alege"
        if ($ec -eq "2") { $reCodec = "libx264" }
        $c2 = Read-Host "  CRF [default: 22]"
        if ($c2) { $reCrf = $c2 }
        Write-Host "  Audio: 1-copy [default]  2-aac 192k  3-eac3 224k" -ForegroundColor Cyan
        $ac = Read-Host "  Alege"
        if ($ac -eq "2") { $reAArgs = @("-c:a","aac","-b:a","192k") }
        if ($ac -eq "3") { $reAArgs = @("-c:a","eac3","-b:a","224k") }
    }

    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }

    $totalOps = $selected.Count * $cuts.Count
    $op = 0; $ok = 0; $fail = 0; $skip = 0
    foreach ($src in $selected) {
        $sn = [System.IO.Path]::GetFileNameWithoutExtension($src.Name)
        $sext = $src.Extension.TrimStart('.')
        $sdur = Get-DurationSeconds $src.FullName
        $ci = 1
        foreach ($cut in $cuts) {
            $op++
            if ($cut.End -gt $sdur) {
                Write-Host "[$op/$totalOps] $($src.Name) seg${ci} — SKIP (durata $(Format-Seconds $sdur) < end $(Format-Seconds $cut.End))" -ForegroundColor Yellow
                $skip++; $ci++; continue
            }
            $clipS = $cut.End - $cut.Start
            $suffix = "_btrim${ci}_$((Format-Seconds $cut.Start) -replace ':','-')"
            $outPath = Join-Path $OutputDir "${sn}${suffix}.${sext}"
            $outPath = Resolve-OutputCollision $outPath
            Write-Host ""
            Write-Host "[$op/$totalOps] $($src.Name) seg${ci}: $(Format-Seconds $cut.Start) → $(Format-Seconds $cut.End)" -ForegroundColor White
            $rc = 1
            if ($mode -eq "2") {
                $ffArgs = @("-y","-ss",$cut.Start,"-to",$cut.End,"-i",$src.FullName,
                    "-map","0","-map_metadata","0","-c:v",$reCodec,"-crf",$reCrf,"-preset","medium") +
                    $reAArgs + @("-c:s","copy","-avoid_negative_ts","make_zero",$outPath)
                $rc = Invoke-FfmpegWithProgress -Label "Batch trim ($op/$totalOps)" -TotalSeconds ([int]$clipS) -Arguments $ffArgs
            } else {
                & ffmpeg -y -ss $cut.Start -to $cut.End -i $src.FullName `
                    -map 0 -map_metadata 0 -c copy `
                    -avoid_negative_ts make_zero -copyts `
                    $outPath 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                $rc = $LASTEXITCODE
            }
            if ($rc -eq 0 -and (Test-Path $outPath) -and ((Get-Item $outPath).Length -gt 0)) {
                $ok++
                Write-Host "  ✓ $(Split-Path $outPath -Leaf)" -ForegroundColor Green
            } else {
                $fail++
                Write-Host "  ✗ EROARE: $(Split-Path $outPath -Leaf)" -ForegroundColor Red
            }
            $ci++
        }
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  BATCH TRIM — Sumar                          ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  Fisiere: $($selected.Count) | Segmente: $($cuts.Count) | Total: $totalOps" -ForegroundColor Cyan
    Write-Host "║  ✓ OK: $ok    ✗ FAIL: $fail    → SKIP: $skip" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
}

# ── v36: Flow Concat (opțiunea 2) ─────────────────────────────────────
function Invoke-ConcatFlow {
    $files = @(Get-TcInputVideos)
    if ($files.Count -eq 0) {
        Write-Host "Nu exista fisiere video in $InputDir" -ForegroundColor Yellow
        return
    }
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  CONCAT — Listare fisiere                    ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    for ($i = 0; $i -lt $files.Count; $i++) {
        $f = $files[$i]
        $dur = Get-DurationSeconds $f.FullName
        $nm = if ($f.Name.Length -gt 32) { $f.Name.Substring(0,32) } else { $f.Name }
        Write-Host ("║  {0,2}) {1,-32} {2}" -f ($i+1), $nm, (Format-Seconds $dur)) -ForegroundColor White
    }
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "Exemple: all / 1,3,5 / 1-5 / 1-3,7,10-12" -ForegroundColor DarkGray
    $selRaw = Read-Host "Selecteaza"
    $indices = @(Expand-RangeSelection $selRaw $files.Count)
    if ($indices.Count -eq 0) { Write-Host "Selectie invalida." -ForegroundColor Red; return }

    Write-Host ""
    Write-Host "Ordine fisiere:" -ForegroundColor Cyan
    Write-Host "  1) Nume (alfabetic) [default]"
    Write-Host "  2) Data modificare"
    Write-Host "  3) Dimensiune"
    Write-Host "  4) Manual (introdu ordinea)"
    Write-Host "  5) Pastreaza ordinea selectiei"
    $sortMode = Read-Host "Alege 1-5 [default: 1]"
    if (-not $sortMode) { $sortMode = "1" }

    $selected = @()
    foreach ($idx in $indices) { $selected += $files[$idx - 1] }

    switch ($sortMode) {
        "1" { $selected = $selected | Sort-Object Name }
        "2" { $selected = $selected | Sort-Object LastWriteTime }
        "3" { $selected = $selected | Sort-Object Length }
        "4" {
            Write-Host ""
            for ($i = 0; $i -lt $selected.Count; $i++) {
                Write-Host "  $($i+1)) $($selected[$i].Name)" -ForegroundColor White
            }
            $newOrder = Read-Host "Ordinea noua (ex: 3,1,2)"
            $reordered = @()
            foreach ($p in ($newOrder -split ',')) {
                $p = $p.Trim()
                if ($p -match '^\d+$') {
                    $n = [int]$p
                    if ($n -ge 1 -and $n -le $selected.Count) { $reordered += $selected[$n - 1] }
                }
            }
            if ($reordered.Count -eq 0) {
                Write-Host "Ordine invalida, pastrez ordinea initiala." -ForegroundColor Yellow
            } else { $selected = $reordered }
        }
        "5" { }
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Ordine concat:                              ║" -ForegroundColor Cyan
    $totalS = 0
    for ($i = 0; $i -lt $selected.Count; $i++) {
        $d = Get-DurationSeconds $selected[$i].FullName
        $totalS += $d
        $nm = if ($selected[$i].Name.Length -gt 32) { $selected[$i].Name.Substring(0,32) } else { $selected[$i].Name }
        Write-Host ("║  {0,2}. {1,-32} {2}" -f ($i+1), $nm, (Format-Seconds $d)) -ForegroundColor White
    }
    Write-Host "║  Durata totala: $(Format-Seconds $totalS)" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan

    Write-Host ""
    $pv = Read-Host "Generezi preview thumbnails (3-frame tile per fisier)? (d/n) [default: n]"
    if ($pv -ieq "d") {
        New-PreviewThumbnails -Files $selected
    }

    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $outName = Read-Host "Nume fisier output (fara extensie) [default: concat_${ts}]"
    if (-not $outName) { $outName = "concat_${ts}" }

    Write-Host ""
    Write-Host "Container output:" -ForegroundColor Cyan
    Write-Host "  1) mkv [default — flexibil, orice codec]"
    Write-Host "  2) mp4"
    Write-Host "  3) mov"
    $contCh = Read-Host "Alege 1-3 [default: 1]"
    $container = switch ($contCh) { "2" {"mp4"} "3" {"mov"} default {"mkv"} }

    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    $outPath = Join-Path $OutputDir "${outName}.${container}"
    $outPath = Resolve-OutputCollision $outPath

    Write-Host ""
    Write-Host "  Verific compatibilitate codec/rez/fps/pix_fmt..." -ForegroundColor Cyan
    $useFilter = $false
    if (Test-ConcatCompatibility ($selected | ForEach-Object { $_.FullName })) {
        Write-Host "  ✓ Fisierele sunt identice — pot folosi stream copy." -ForegroundColor Green
        Write-Host ""
        Write-Host "  1) Stream copy (concat demuxer, instant, lossless) [default]"
        Write-Host "  2) Re-encode (compresie suplimentara)"
        $cmode = Read-Host "  Alege 1-2"
        if ($cmode -eq "2") { $useFilter = $true }
    } else {
        Write-Host "  ⚠ Fisierele NU sunt identice (codec/rez/fps/pix_fmt difera)." -ForegroundColor Yellow
        Write-Host "  Re-encode OBLIGATORIU via concat filter." -ForegroundColor Yellow
        $useFilter = $true
    }

    $subdir = New-TempSubdir "concat"

    if (-not $useFilter) {
        $concatTxt = Join-Path $subdir "concat.txt"
        $lines = foreach ($s in $selected) {
            # Escape apostrofuri: ' → '\''
            $esc = $s.FullName -replace "'","'\''"
            "file '$esc'"
        }
        Write-ConcatTxtUtf8NoBom $concatTxt $lines
        Write-Host "  Concat stream copy..." -ForegroundColor Green
        $ffArgs = @("-y","-f","concat","-safe","0","-i",$concatTxt,
            "-map","0","-map_metadata","0","-c","copy",
            "-avoid_negative_ts","make_zero",$outPath)
        Invoke-FfmpegWithProgress -Label "Concat (copy)" -TotalSeconds ([int]$totalS) -Arguments $ffArgs | Out-Null
    } else {
        Write-Host ""
        Write-Host "  Re-encode: 1-libx265 [default]  2-libx264" -ForegroundColor Cyan
        $ec = Read-Host "  Codec"
        $codec = if ($ec -eq "2") { "libx264" } else { "libx265" }
        $crf = Read-Host "  CRF [default: 22]"
        if (-not $crf) { $crf = "22" }
        Write-Host "  Audio: 1-aac 192k [default]  2-eac3 224k  3-copy" -ForegroundColor Cyan
        $ac = Read-Host "  Alege"
        $aArgs = @("-c:a","aac","-b:a","192k")
        if ($ac -eq "2") { $aArgs = @("-c:a","eac3","-b:a","224k") }
        if ($ac -eq "3") { $aArgs = @("-c:a","copy") }

        $ffIn = @()
        $fcMap = ""
        for ($i = 0; $i -lt $selected.Count; $i++) {
            $ffIn += @("-i", $selected[$i].FullName)
            $fcMap += "[${i}:v:0][${i}:a:0?]"
        }
        $n = $selected.Count
        $fc = "${fcMap}concat=n=${n}:v=1:a=1[outv][outa]"

        Write-Host "  Concat re-encode ($codec CRF $crf)... durata totala $(Format-Seconds $totalS)" -ForegroundColor Green
        $ffArgs = @("-y") + $ffIn + @(
            "-filter_complex",$fc,
            "-map","[outv]","-map","[outa]",
            "-c:v",$codec,"-crf",$crf,"-preset","medium") +
            $aArgs + @("-map_metadata","0",$outPath)
        Invoke-FfmpegWithProgress -Label "Concat ($codec)" -TotalSeconds ([int]$totalS) -Arguments $ffArgs | Out-Null
    }

    Remove-TempSubdirSafe $subdir $outPath

    if ((Test-Path $outPath) -and ((Get-Item $outPath).Length -gt 0)) {
        $osize = (Get-Item $outPath).Length
        Write-Host ""
        Write-Host "  ✓ Output: $outPath" -ForegroundColor Green
        Write-Host "  ✓ Size: $(Format-Bytes $osize)" -ForegroundColor Green
        Write-Host "  ✓ Fisiere concatenate: $($selected.Count)" -ForegroundColor Green
        Write-Host "  ✓ Durata totala: $(Format-Seconds $totalS)" -ForegroundColor Green
    }
}

# ── v36: Flow Pipeline (opțiunea 3): Trim → Concat → Encode ──────────
function Invoke-PipelineFlow {
    $files = @(Get-TcInputVideos)
    if ($files.Count -eq 0) {
        Write-Host "Nu exista fisiere video in $InputDir" -ForegroundColor Yellow
        return
    }

    # Pas 1: selectie fisiere
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  PIPELINE — Selectare fisiere                ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    for ($i = 0; $i -lt $files.Count; $i++) {
        $f = $files[$i]
        $dur = Get-DurationSeconds $f.FullName
        $nm = if ($f.Name.Length -gt 32) { $f.Name.Substring(0,32) } else { $f.Name }
        Write-Host ("║  {0,2}) {1,-32} {2}" -f ($i+1), $nm, (Format-Seconds $dur)) -ForegroundColor White
    }
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "Exemple: all / 1,3,5 / 1-5 / 1-3,7,10-12" -ForegroundColor DarkGray
    $selRaw = Read-Host "Selecteaza fisierele incluse"
    $indices = @(Expand-RangeSelection $selRaw $files.Count)
    if ($indices.Count -eq 0) { Write-Host "Selectie invalida." -ForegroundColor Red; return }

    $chosen = @()
    foreach ($idx in $indices) { $chosen += $files[$idx - 1] }

    # Sort
    Write-Host ""
    Write-Host "Ordine fisiere:" -ForegroundColor Cyan
    Write-Host "  1) Nume (alfabetic) [default]"
    Write-Host "  2) Data modificare"
    Write-Host "  3) Dimensiune"
    Write-Host "  4) Manual (introdu ordinea)"
    Write-Host "  5) Pastreaza ordinea selectiei"
    $sortMode = Read-Host "Alege 1-5 [default: 1]"
    if (-not $sortMode) { $sortMode = "1" }
    switch ($sortMode) {
        "1" { $chosen = $chosen | Sort-Object Name }
        "2" { $chosen = $chosen | Sort-Object LastWriteTime }
        "3" { $chosen = $chosen | Sort-Object Length }
        "4" {
            Write-Host ""
            for ($i = 0; $i -lt $chosen.Count; $i++) {
                Write-Host "  $($i+1)) $($chosen[$i].Name)" -ForegroundColor White
            }
            $newOrder = Read-Host "Ordinea noua (ex: 3,1,2)"
            $reordered = @()
            foreach ($p in ($newOrder -split ',')) {
                $p = $p.Trim()
                if ($p -match '^\d+$') {
                    $n = [int]$p
                    if ($n -ge 1 -and $n -le $chosen.Count) { $reordered += $chosen[$n - 1] }
                }
            }
            if ($reordered.Count -eq 0) {
                Write-Host "Ordine invalida, pastrez ordinea initiala." -ForegroundColor Yellow
            } else { $chosen = $reordered }
        }
        "5" { }
    }
    # Re-normalizare la array (Sort-Object poate returna scalar la 1 element)
    $chosen = @($chosen)

    # Pas 2: care au nevoie de trim?
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  PIPELINE — Care fisiere au nevoie de TRIM?  ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    for ($i = 0; $i -lt $chosen.Count; $i++) {
        $f = $chosen[$i]
        $dur = Get-DurationSeconds $f.FullName
        $nm = if ($f.Name.Length -gt 32) { $f.Name.Substring(0,32) } else { $f.Name }
        Write-Host ("║  {0,2}) {1,-32} {2}" -f ($i+1), $nm, (Format-Seconds $dur)) -ForegroundColor White
    }
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "Exemple: none / 1,3 / 1-2 / all" -ForegroundColor DarkGray
    $trimSel = Read-Host "Indici"
    if (-not $trimSel) { $trimSel = "none" }

    $trimIndices = @()
    if ($trimSel.ToLower() -ne "none") {
        $trimIndices = @(Expand-RangeSelection $trimSel $chosen.Count)
    }

    # segments[i] = array de @{Start=...; End=...}  (goala = full file)
    $segments = @()
    for ($i = 0; $i -lt $chosen.Count; $i++) { $segments += ,@() }

    foreach ($idx in $trimIndices) {
        $i = $idx - 1
        $src = $chosen[$i]
        $totalS = Get-DurationSeconds $src.FullName
        $segs = @()
        $cutIdx = 1
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║  TRIM — $($src.Name)" -ForegroundColor Cyan
        Write-Host "║  Durata totala: $(Format-Seconds $totalS)" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
        while ($true) {
            Write-Host ""
            Write-Host "  Segment #$cutIdx" -ForegroundColor Cyan
            $startS = 0; $endS = $totalS
            while ($true) {
                $startS = Read-ValidatedTime "Start" 0 $totalS
                $endS   = Read-ValidatedTime "End  " $totalS $totalS
                if ($startS -ge $endS) {
                    Write-Host "  EROARE: start >= end. Reintrodu." -ForegroundColor Red
                    continue
                }
                break
            }
            $clipS = $endS - $startS
            Write-Host "  Segment: $(Format-Seconds $clipS) (din $(Format-Seconds $startS) la $(Format-Seconds $endS))" -ForegroundColor Green
            $segs += @{ Start = $startS; End = $endS }
            Write-Host ""
            $again = Read-Host "  Mai adaugi un segment din acest fisier? (d/n) [default: n]"
            if ($again -ine "d") { break }
            $cutIdx++
        }
        $segments[$i] = $segs
    }

    # Pas 3: setari encode
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  PIPELINE — Setari encode (global)           ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "Mod encode:" -ForegroundColor Cyan
    Write-Host "  1) Video + Audio re-encode [default]"
    Write-Host "  2) Audio-only re-encode (video stream copy, instant)"
    $modeCh = Read-Host "Alege 1-2"
    $audioOnly = ($modeCh -eq "2")
    $codec = "libx265"; $crf = "22"; $preset = "medium"
    if (-not $audioOnly) {
        Write-Host "Codec:" -ForegroundColor Cyan
        Write-Host "  1) libx265 (HEVC) [default]"
        Write-Host "  2) libx264 (H.264)"
        Write-Host "  3) libsvtav1 (AV1)"
        $cc = Read-Host "Alege 1-3"
        $codec = switch ($cc) { "2" {"libx264"} "3" {"libsvtav1"} default {"libx265"} }
        $crf = Read-Host "CRF [default: 22]"
        if (-not $crf) { $crf = "22" }
        Write-Host "Preset:" -ForegroundColor Cyan
        Write-Host "  1) medium [default]"
        Write-Host "  2) slow (calitate mai buna)"
        Write-Host "  3) fast"
        $pp = Read-Host "Alege 1-3"
        $preset = switch ($pp) { "2" {"slow"} "3" {"fast"} default {"medium"} }
    } else {
        Write-Host "  → Video: stream copy. Defaults fallback (dacă incompat): libx265 CRF 22 medium" -ForegroundColor Gray
    }
    Write-Host "Audio:" -ForegroundColor Cyan
    Write-Host "  1) aac 192k [default]"
    Write-Host "  2) eac3 224k"
    Write-Host "  3) copy"
    $ac = Read-Host "Alege 1-3"
    $aArgs = @("-c:a","aac","-b:a","192k")
    if ($ac -eq "2") { $aArgs = @("-c:a","eac3","-b:a","224k") }
    if ($ac -eq "3") { $aArgs = @("-c:a","copy") }

    # Pas 4: output
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    Write-Host ""
    $outName = Read-Host "Nume fisier output (fara extensie) [default: pipeline_${ts}]"
    if (-not $outName) { $outName = "pipeline_${ts}" }
    Write-Host "Container output:" -ForegroundColor Cyan
    Write-Host "  1) mkv [default]"
    Write-Host "  2) mp4"
    Write-Host "  3) mov"
    $contCh = Read-Host "Alege 1-3"
    $container = switch ($contCh) { "2" {"mp4"} "3" {"mov"} default {"mkv"} }

    Write-Host "Capitole automate (1 capitol per segment, marker timeline)?" -ForegroundColor Cyan
    Write-Host "  1) Da [default]"
    Write-Host "  2) Nu"
    $chCh = Read-Host "Alege 1-2"
    $makeChapters = ($chCh -ne "2")

    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    $outPath = Join-Path $OutputDir "${outName}.${container}"
    $outPath = Resolve-OutputCollision $outPath

    # Estimare temp + durata
    $estTempMB = 0
    $pipelineTotalS = 0
    for ($i = 0; $i -lt $chosen.Count; $i++) {
        $f = $chosen[$i]
        $segs = $segments[$i]
        $fsize = $f.Length
        $fdur = Get-DurationSeconds $f.FullName
        if ($segs.Count -eq 0) {
            # FULL file — referinta directa in concat.txt, nu ocupa temp
            $pipelineTotalS += $fdur
        } else {
            foreach ($s in $segs) {
                $sdur = $s.End - $s.Start
                $pipelineTotalS += $sdur
                if ($fdur -gt 0) {
                    $estTempMB += [int](($fsize / 1MB) * $sdur / $fdur)
                }
            }
        }
    }

    # Pas 5: rezumat
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  PIPELINE — Rezumat pre-executie             ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    for ($i = 0; $i -lt $chosen.Count; $i++) {
        $f = $chosen[$i]
        $segs = $segments[$i]
        $nm = if ($f.Name.Length -gt 30) { $f.Name.Substring(0,30) } else { $f.Name }
        if ($segs.Count -eq 0) {
            Write-Host ("║  {0,2}. {1,-30} [FULL]" -f ($i+1), $nm) -ForegroundColor White
        } else {
            Write-Host ("║  {0,2}. {1,-30} [TRIM x{2}]" -f ($i+1), $nm, $segs.Count) -ForegroundColor White
        }
    }
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "║  Durata finala estimata: $(Format-Seconds $pipelineTotalS)" -ForegroundColor Cyan
    Write-Host "║  Temp estimat: ~${estTempMB} MB" -ForegroundColor Cyan
    if ($audioOnly) {
        Write-Host "║  Encode: AUDIO-ONLY (video stream copy)" -ForegroundColor Cyan
    } else {
        Write-Host "║  Encode: $codec CRF $crf ($preset)" -ForegroundColor Cyan
    }
    Write-Host "║  Output: $(Split-Path $outPath -Leaf)" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan

    # HDR info (v37: detecția detaliată + auto-injectare se face pre-Pass 3)
    if (Test-TcInputHDR ($chosen | ForEach-Object { $_.FullName })) {
        Write-Host ""
        Write-Host "  ℹ HDR detectat în input — modul HDR va fi auto-detectat înainte de Pass 3." -ForegroundColor Cyan
        if (-not $audioOnly -and $codec -ne "libx265") {
            Write-Host "    ATENTIE: codec=$codec nu suporta HDR10 — output va fi SDR-like." -ForegroundColor Yellow
        }
    }

    Write-Host ""
    $pv = Read-Host "Generezi preview thumbnails (3-frame tile per fisier)? (d/n) [default: n]"
    if ($pv -ieq "d") {
        New-PreviewThumbnails -Files $chosen
    }

    $go = Read-Host "Continua? (d/n) [default: d]"
    if ($go -ieq "n") { Write-Host "Anulat." -ForegroundColor Yellow; return }

    # Pas 6: executie
    $subdir = New-TempSubdir "pipeline"

    # Pass 1/3
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  [Pass 1/3] Trim stream copy" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
    $trimmedFiles = @()
    $segDurations = @()
    for ($i = 0; $i -lt $chosen.Count; $i++) {
        $f = $chosen[$i]
        $segs = $segments[$i]
        $ext = $f.Extension.TrimStart('.')
        if ($segs.Count -eq 0) {
            $trimmedFiles += $f.FullName
            $segDurations += [int](Get-DurationSeconds $f.FullName)
            Write-Host "  [$($i+1)/$($chosen.Count)] $($f.Name) — FULL (fara trim)" -ForegroundColor Gray
        } else {
            $si = 1
            foreach ($s in $segs) {
                $segOut = Join-Path $subdir ("{0:D2}_seg{1}.{2}" -f ($i+1), $si, $ext)
                Write-Host "  [$($i+1)/$($chosen.Count)] $($f.Name) seg${si}: $(Format-Seconds $s.Start) → $(Format-Seconds $s.End)" -ForegroundColor White
                & ffmpeg -y -ss $s.Start -to $s.End -i $f.FullName `
                    -map 0 -map_metadata 0 -c copy `
                    -avoid_negative_ts make_zero -copyts `
                    $segOut 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                if ((Test-Path $segOut) -and ((Get-Item $segOut).Length -gt 0)) {
                    $trimmedFiles += $segOut
                    # v37: foloseste durata REALA a segmentului trimuit (keyframe snap)
                    $realDur = [int](Get-DurationSeconds $segOut)
                    if ($realDur -le 0) { $realDur = [int]($s.End - $s.Start) }
                    $segDurations += $realDur
                } else {
                    Write-Host "  ✗ EROARE trim: $segOut" -ForegroundColor Red
                    Remove-TempSubdirSafe $subdir ""
                    return
                }
                $si++
            }
        }
    }

    if ($trimmedFiles.Count -eq 0) {
        Write-Host "Nu s-au generat fisiere pentru concat." -ForegroundColor Red
        Remove-TempSubdirSafe $subdir ""
        return
    }

    # Pass 2/3 — verific compat signature si generez concat.txt DACA compat
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  [Pass 2/3] Verificare compat + pregatire concat" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
    $useFilter = -not (Test-ConcatCompatibility $trimmedFiles)
    $smartCopy = $false
    if ($useFilter) {
        Write-Host "  ⚠ Fisiere cu codec/rez/fps diferit — folosesc concat filter" -ForegroundColor Yellow
        if ($audioOnly) {
            Write-Host "  ⚠ Audio-only mode: concat filter cere video re-encode." -ForegroundColor Yellow
            Write-Host "  → Fallback la full re-encode ($codec CRF $crf $preset)." -ForegroundColor Yellow
            $audioOnly = $false
        }
        if ($aArgs.Count -ge 2 -and $aArgs[0] -eq "-c:a" -and $aArgs[1] -eq "copy") {
            Write-Host "  ⚠ Audio copy nu functioneaza cu concat filter. Fallback: aac 192k." -ForegroundColor Yellow
            $aArgs = @("-c:a","aac","-b:a","192k")
        }
    } else {
        # Smart stream copy detection (dacă nu e audio-only): sursa = target codec → oferă skip re-encode
        if (-not $audioOnly) {
            $srcCodec = (& ffprobe -v error -select_streams v:0 `
                -show_entries stream=codec_name `
                -of default=noprint_wrappers=1:nokey=1 $trimmedFiles[0] 2>$null)
            $targetCodecName = switch ($codec) {
                "libx265"   { "hevc" }
                "libx264"   { "h264" }
                "libsvtav1" { "av1" }
                "libaom-av1"{ "av1" }
                default     { "" }
            }
            if ($targetCodecName -and ($srcCodec -eq $targetCodecName)) {
                Write-Host ""
                Write-Host "  ⚡ SMART COPY: sursa este deja $srcCodec, identic cu targetul ($codec)." -ForegroundColor Cyan
                Write-Host "    Stream copy direct → instant, lossless, fără re-encode." -ForegroundColor Cyan
                $sc = Read-Host "  Folosesti stream copy in loc de re-encode? (D/n) [default: D]"
                if ($sc -ine "n") { $smartCopy = $true }
            }
        }
        $concatTxt = Join-Path $subdir "concat.txt"
        $lines = foreach ($tf in $trimmedFiles) {
            $esc = $tf -replace "'","'\''"
            "file '$esc'"
        }
        Write-ConcatTxtUtf8NoBom $concatTxt $lines
        Write-Host "  $($trimmedFiles.Count) intrari in $concatTxt" -ForegroundColor Gray
    }

    # Generare chapters file (FFMETADATA1) dacă user a optat și avem >=2 segmente
    $chaptersFile = ""
    if ($makeChapters -and $trimmedFiles.Count -ge 2) {
        $chaptersFile = Join-Path $subdir "chapters.txt"
        $chLines = New-Object System.Collections.Generic.List[string]
        $chLines.Add(";FFMETADATA1")
        $cumMs = 0
        for ($i = 0; $i -lt $trimmedFiles.Count; $i++) {
            $dMs = [int]$segDurations[$i] * 1000
            $endMs = $cumMs + $dMs
            $chLines.Add("")
            $chLines.Add("[CHAPTER]")
            $chLines.Add("TIMEBASE=1/1000")
            $chLines.Add("START=$cumMs")
            $chLines.Add("END=$endMs")
            $chLines.Add("title=Segment $($i+1)")
            $cumMs = $endMs
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllLines($chaptersFile, $chLines, $utf8NoBom)
        Write-Host "  ✓ Capitole generate: $($trimmedFiles.Count) markeri în $(Split-Path $chaptersFile -Leaf)" -ForegroundColor Green
    }

    # HDR-aware (v37): detectare mod HDR + injectare params x265 dacă re-encode
    $hdrColorArgs = @()
    $hdrPixArgs = @()
    $hdrX265Args = @()
    if (-not $smartCopy -and -not $audioOnly) {
        $hdrMode = Get-PipelineHdrMode ($chosen | ForEach-Object { $_.FullName })
        switch ($hdrMode) {
            "sdr" { }
            "mixed" {
                Write-Host ""
                Write-Host "  ⚠ HDR MIXED: input contine atat SDR cat si HDR." -ForegroundColor Yellow
                Write-Host "    HDR metadata NU va fi pastrat. Output = SDR-like." -ForegroundColor Yellow
            }
            default {
                if ($codec -ne "libx265") {
                    Write-Host ""
                    Write-Host "  ⚠ HDR detectat ($hdrMode), dar codec=$codec nu suporta HDR10." -ForegroundColor Yellow
                    Write-Host "    HDR metadata NU va fi pastrat. Pentru HDR10, foloseste libx265." -ForegroundColor Yellow
                } else {
                    $trc = if ($hdrMode -eq "hlg") { "arib-std-b67" } else { "smpte2084" }
                    $hdrPixArgs   = @("-pix_fmt","yuv420p10le")
                    $hdrColorArgs = @("-color_primaries","bt2020","-color_trc",$trc,"-colorspace","bt2020nc")
                    if ($hdrMode -eq "hlg") {
                        # v39: HLG NU foloseste hdr10=1 (signaling in transfer chars)
                        $x265Extra = "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=$trc:colormatrix=bt2020nc"
                    } else {
                        $x265Extra = "hdr10=1:hdr10-opt=1:repeat-headers=1:colorprim=bt2020:transfer=$trc:colormatrix=bt2020nc"
                    }
                    if ($hdrMode -eq "dv") {
                        Write-Host ""
                        Write-Host "  ⚠ DOLBY VISION detectat. Re-encode -> fallback HDR10 (DV RPU nu se pastreaza)." -ForegroundColor Yellow
                    } elseif ($hdrMode -eq "hdr10plus") {
                        Write-Host ""
                        Write-Host "  ⚡ HDR10+ detectat. Vrei sa pastrezi metadata dinamica? (necesita hdr10plus_tool)" -ForegroundColor Cyan
                        Write-Host "     1) Da [default]   2) Nu (doar HDR10 static)"
                        $hdr10pCh = Read-Host "     Alege 1-2"
                        if (-not $hdr10pCh -or $hdr10pCh -eq "1") {
                            $toolAvail = [bool](Get-Command "hdr10plus_tool" -ErrorAction SilentlyContinue)
                            if ($toolAvail) {
                                $hdr10pJson = Extract-Hdr10PlusMetadata $trimmedFiles[0]
                                if ($hdr10pJson -and (Test-Path $hdr10pJson) -and (Get-Item $hdr10pJson).Length -gt 0) {
                                    $x265Extra = "${x265Extra}:dhdr10-info=${hdr10pJson}"
                                    Write-Host "     ✓ HDR10+ JSON extras: $hdr10pJson" -ForegroundColor Green
                                } else {
                                    Write-Host "     ⚠ Extragere HDR10+ esuata. Fallback HDR10 static." -ForegroundColor Yellow
                                }
                            } else {
                                Write-Host "     ⚠ hdr10plus_tool NU este instalat. Fallback HDR10 static." -ForegroundColor Yellow
                                Write-Host "       Instaleaza: $ToolsDir\hdr10plus_parser.ps1" -ForegroundColor DarkGray
                            }
                        }
                    } elseif ($hdrMode -eq "hlg") {
                        Write-Host ""
                        Write-Host "  ⚡ AUTO HLG: pix_fmt=yuv420p10le, transfer=arib-std-b67, color=bt2020" -ForegroundColor Cyan
                    } else {
                        Write-Host ""
                        Write-Host "  ⚡ AUTO HDR10: pix_fmt=yuv420p10le, transfer=$trc, color=bt2020" -ForegroundColor Cyan
                    }
                    $hdrX265Args = @("-x265-params",$x265Extra)
                }
            }
        }
    }

    # Pass 3/3
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
    if ($smartCopy) {
        Write-Host "  [Pass 3/3] Concat stream copy (smart)" -ForegroundColor Cyan
    } elseif ($audioOnly) {
        Write-Host "  [Pass 3/3] Concat + Audio re-encode (video copy)" -ForegroundColor Cyan
    } else {
        Write-Host "  [Pass 3/3] Concat + Encode ($codec CRF $crf, $preset)" -ForegroundColor Cyan
    }
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Durata totala: $(Format-Seconds $pipelineTotalS)" -ForegroundColor Green
    if ($smartCopy) {
        $chapIn = @(); $chapMap = @()
        if ($chaptersFile) { $chapIn = @("-i",$chaptersFile); $chapMap = @("-map_chapters","1") }
        $ffArgs = @("-y","-f","concat","-safe","0","-i",$concatTxt) + $chapIn + @(
            "-map","0","-map_metadata","0") + $chapMap + @(
            "-c","copy","-avoid_negative_ts","make_zero",$outPath)
        Invoke-FfmpegWithProgress -Label "Pass 3/3 (copy)" -TotalSeconds ([int]$pipelineTotalS) -Arguments $ffArgs | Out-Null
    } elseif ($audioOnly) {
        $chapIn = @(); $chapMap = @()
        if ($chaptersFile) { $chapIn = @("-i",$chaptersFile); $chapMap = @("-map_chapters","1") }
        $ffArgs = @("-y","-f","concat","-safe","0","-i",$concatTxt) + $chapIn + @(
            "-map","0","-map_metadata","0") + $chapMap + @("-c:v","copy") +
            $aArgs + @("-avoid_negative_ts","make_zero",$outPath)
        Invoke-FfmpegWithProgress -Label "Pass 3/3 (audio-only)" -TotalSeconds ([int]$pipelineTotalS) -Arguments $ffArgs | Out-Null
    } elseif ($useFilter) {
        $ffIn = @()
        $fcMap = ""
        for ($i = 0; $i -lt $trimmedFiles.Count; $i++) {
            $ffIn += @("-i", $trimmedFiles[$i])
            $fcMap += "[${i}:v:0][${i}:a:0?]"
        }
        $n = $trimmedFiles.Count
        $fc = "${fcMap}concat=n=${n}:v=1:a=1[outv][outa]"
        $chapIn = @(); $chapMap = @()
        if ($chaptersFile) { $chapIn = @("-i",$chaptersFile); $chapMap = @("-map_chapters","$n") }
        $ffArgs = @("-y") + $ffIn + $chapIn + @(
            "-filter_complex",$fc,
            "-map","[outv]","-map","[outa]") + $chapMap + @(
            "-c:v",$codec,"-crf",$crf,"-preset",$preset) +
            $hdrPixArgs + $hdrColorArgs + $hdrX265Args +
            $aArgs + @("-map_metadata","0",$outPath)
        Invoke-FfmpegWithProgress -Label "Pass 3/3 ($codec)" -TotalSeconds ([int]$pipelineTotalS) -Arguments $ffArgs | Out-Null
    } else {
        $chapIn = @(); $chapMap = @()
        if ($chaptersFile) { $chapIn = @("-i",$chaptersFile); $chapMap = @("-map_chapters","1") }
        $ffArgs = @("-y","-f","concat","-safe","0","-i",$concatTxt) + $chapIn + @(
            "-map","0","-map_metadata","0") + $chapMap + @(
            "-c:v",$codec,"-crf",$crf,"-preset",$preset) +
            $hdrPixArgs + $hdrColorArgs + $hdrX265Args +
            $aArgs + @($outPath)
        Invoke-FfmpegWithProgress -Label "Pass 3/3 ($codec)" -TotalSeconds ([int]$pipelineTotalS) -Arguments $ffArgs | Out-Null
    }

    Remove-TempSubdirSafe $subdir $outPath

    # Stats finale
    if ((Test-Path $outPath) -and ((Get-Item $outPath).Length -gt 0)) {
        $osize = (Get-Item $outPath).Length
        $totIn = 0
        foreach ($c in $chosen) { $totIn += $c.Length }
        $ratio = if ($totIn -gt 0) { [int]($osize * 100 / $totIn) } else { 0 }
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║  PIPELINE — Terminat                         ║" -ForegroundColor Cyan
        Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
        Write-Host "║  ✓ Output: $(Split-Path $outPath -Leaf)" -ForegroundColor Green
        Write-Host "║  ✓ Size: $(Format-Bytes $osize) (input: $(Format-Bytes $totIn), ${ratio}%)" -ForegroundColor Green
        Write-Host "║  ✓ Durata: $(Format-Seconds $pipelineTotalS)" -ForegroundColor Green
        Write-Host "║  ✓ Fisiere sursa: $($chosen.Count), segmente: $($trimmedFiles.Count)" -ForegroundColor Green
        Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    } else {
        Write-Host "  ✗ EROARE: output final lipsa sau 0 bytes." -ForegroundColor Red
    }
}
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

# ══════════════════════════════════════════════════════════════════════
# v51: 2-PASS VBR INFRASTRUCTURE (mirror av_common.sh)
# Encoderele setează:
#   $script:ffmpegCmdPass1 (array)
#   $script:ffmpegCmdPass2 (array)
#   $script:statsFile (path stats partajat)
#   $script:use2Pass = $true
# Invoke-2PassEncode rulează cele 2 passuri; Pass 1 self-contained la NUL,
# Pass 2 primește output + audio/sub args appendate de chemator.
# ══════════════════════════════════════════════════════════════════════

function Initialize-2PassState {
    param([string]$File)
    $name = [IO.Path]::GetFileNameWithoutExtension($File)
    $name = $name -replace '[^A-Za-z0-9._-]','_'
    $script:statsDir = Join-Path $env:TEMP ("av2pass_"+[guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $script:statsDir -Force | Out-Null
    $script:statsFile = Join-Path $script:statsDir "$name.passlog"
    $script:use2Pass = $true
}

function Clear-2PassState {
    if ($script:statsDir -and (Test-Path $script:statsDir)) {
        Remove-Item -Recurse -Force $script:statsDir -ErrorAction SilentlyContinue
    }
    $script:statsDir = ""; $script:statsFile = ""
    $script:use2Pass = $false
    $script:ffmpegCmdPass1 = @(); $script:ffmpegCmdPass2 = @()
}

# Rulează 2-pass cu progress per pass. Args: $File, $Label, $TrailingArgs2 (array
# care se appendează la pass 2: audio, loudnorm, sub, container, progress, output).
function Invoke-2PassEncode {
    param(
        [string]$File,
        [string]$Label,
        [int]$DurationSec,
        [array]$TrailingArgs2,
        [string]$ProgressFile,
        [string]$LogFile
    )
    if (-not $script:ffmpegCmdPass1 -or $script:ffmpegCmdPass1.Count -eq 0) {
        Write-Host "  EROARE: ffmpegCmdPass1 array gol" -ForegroundColor Red; return 1
    }
    if (-not $script:ffmpegCmdPass2 -or $script:ffmpegCmdPass2.Count -eq 0) {
        Write-Host "  EROARE: ffmpegCmdPass2 array gol" -ForegroundColor Red; return 1
    }
    if (-not $script:statsFile) {
        Write-Host "  EROARE: statsFile neinitializat (Initialize-2PassState)" -ForegroundColor Red; return 1
    }

    Write-Host ""
    Write-Host "  -- 2-PASS: Pass 1/2 (analiza, fara audio, output NUL) --" -ForegroundColor Cyan
    $errFile1 = "$env:TEMP\fferr_p1_$PID.txt"
    $prog1 = "$env:TEMP\ffprog_p1_$PID.txt"
    $p1Args = $script:ffmpegCmdPass1 + @("-progress",$prog1,"-nostats")
    $startP1 = Get-Date
    $proc1 = Start-Process ffmpeg -ArgumentList $p1Args -NoNewWindow -PassThru -RedirectStandardError $errFile1
    Show-Progress -proc $proc1 -progFile $prog1 -durSec $DurationSec -startTime $startP1 -Label "$Label P1"
    $proc1.WaitForExit()
    if (Test-Path $errFile1) { Get-Content $errFile1 | Add-Content -Path $LogFile }
    if ($proc1.ExitCode -ne 0) {
        Write-Host "  EROARE Pass 1 (exit $($proc1.ExitCode)):" -ForegroundColor Red
        if (Test-Path $errFile1) {
            Get-Content $errFile1 -Tail 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
        Remove-Item $errFile1,$prog1 -Force -ErrorAction SilentlyContinue
        return $proc1.ExitCode
    }
    Remove-Item $errFile1,$prog1 -Force -ErrorAction SilentlyContinue

    Write-Host "  -- 2-PASS: Pass 2/2 (encodare finala + audio) --" -ForegroundColor Cyan
    $errFile2 = "$env:TEMP\fferr_p2_$PID.txt"
    $p2Args = $script:ffmpegCmdPass2 + $TrailingArgs2 + @("-progress",$ProgressFile,"-nostats")
    $startP2 = Get-Date
    $proc2 = Start-Process ffmpeg -ArgumentList $p2Args -NoNewWindow -PassThru -RedirectStandardError $errFile2
    Show-Progress -proc $proc2 -progFile $ProgressFile -durSec $DurationSec -startTime $startP2 -Label "$Label P2"
    $proc2.WaitForExit()
    if (Test-Path $errFile2) { Get-Content $errFile2 | Add-Content -Path $LogFile }
    if ($proc2.ExitCode -ne 0) {
        Write-Host "  EROARE Pass 2 (exit $($proc2.ExitCode)):" -ForegroundColor Red
        if (Test-Path $errFile2) {
            Get-Content $errFile2 -Tail 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
        Remove-Item $errFile2 -Force -ErrorAction SilentlyContinue
        return $proc2.ExitCode
    }
    Remove-Item $errFile2 -Force -ErrorAction SilentlyContinue
    return 0
}

# SVT-AV1 v1.4+ inline pass=N:stats= caps
# Strategy 4 (v52): parse libsvtav1 version din ffmpeg -version; fallback
# optimist (assume modern) cand version nedetectata.
function Test-SvtAv1TwoPassCaps {
    if ($script:svtav1TwoPassChecked) { return $script:svtav1TwoPassSupported }
    $script:svtav1TwoPassChecked = $true
    $script:svtav1TwoPassSupported = $false
    $script:svtav1DetectSource = ""
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { return $false }
    $verOutput = & ffmpeg -version 2>$null | Out-String
    if ($verOutput -match 'libsvtav1\s+(\d+)\.(\d+)') {
        $major = [int]$Matches[1]; $minor = [int]$Matches[2]
        $script:svtav1TwoPassSupported = ($major -gt 1) -or ($major -eq 1 -and $minor -ge 4)
        $script:svtav1DetectSource = "version=$major.$minor"
    } else {
        # Fallback optimist: assume modern build
        $script:svtav1TwoPassSupported = $true
        $script:svtav1DetectSource = "assumed-modern"
    }
    return $script:svtav1TwoPassSupported
}

# ══════════════════════════════════════════════════════════════════════
# v51: VBV / LEVEL AUTOMATION
# ══════════════════════════════════════════════════════════════════════

function Get-VbvCaps {
    param([string]$Codec, [string]$Level, [string]$Tier = "main")
    switch ($Codec) {
        "hevc" {
            switch ($Level) {
                "3.0" { return @{ MaxBR = 6000;   MaxCPB = 6000 } }
                "3.1" { return @{ MaxBR = 10000;  MaxCPB = 10000 } }
                "4.0" { if ($Tier -eq "high") { return @{ MaxBR = 30000;  MaxCPB = 30000 } }  else { return @{ MaxBR = 12000;  MaxCPB = 12000 } } }
                "4.1" { if ($Tier -eq "high") { return @{ MaxBR = 50000;  MaxCPB = 50000 } }  else { return @{ MaxBR = 20000;  MaxCPB = 20000 } } }
                "5.0" { if ($Tier -eq "high") { return @{ MaxBR = 100000; MaxCPB = 100000 } } else { return @{ MaxBR = 25000;  MaxCPB = 25000 } } }
                "5.1" { if ($Tier -eq "high") { return @{ MaxBR = 160000; MaxCPB = 160000 } } else { return @{ MaxBR = 40000;  MaxCPB = 40000 } } }
                "5.2" { if ($Tier -eq "high") { return @{ MaxBR = 240000; MaxCPB = 240000 } } else { return @{ MaxBR = 60000;  MaxCPB = 60000 } } }
                "6.0" { if ($Tier -eq "high") { return @{ MaxBR = 240000; MaxCPB = 240000 } } else { return @{ MaxBR = 60000;  MaxCPB = 60000 } } }
                "6.1" { if ($Tier -eq "high") { return @{ MaxBR = 480000; MaxCPB = 480000 } } else { return @{ MaxBR = 120000; MaxCPB = 120000 } } }
                "6.2" { if ($Tier -eq "high") { return @{ MaxBR = 800000; MaxCPB = 800000 } } else { return @{ MaxBR = 240000; MaxCPB = 240000 } } }
                default { return @{ MaxBR = 40000; MaxCPB = 40000 } }
            }
        }
        "h264" {
            switch ($Level) {
                "3.0" { return @{ MaxBR = 12500;   MaxCPB = 12500 } }
                "3.1" { return @{ MaxBR = 17500;   MaxCPB = 17500 } }
                "3.2" { return @{ MaxBR = 25000;   MaxCPB = 25000 } }
                "4.0" { return @{ MaxBR = 25000;   MaxCPB = 25000 } }
                "4.1" { return @{ MaxBR = 62500;   MaxCPB = 62500 } }
                "4.2" { return @{ MaxBR = 62500;   MaxCPB = 62500 } }
                "5.0" { return @{ MaxBR = 168750;  MaxCPB = 168750 } }
                "5.1" { return @{ MaxBR = 300000;  MaxCPB = 300000 } }
                "5.2" { return @{ MaxBR = 300000;  MaxCPB = 300000 } }
                "6.0" { return @{ MaxBR = 300000;  MaxCPB = 300000 } }
                "6.1" { return @{ MaxBR = 600000;  MaxCPB = 600000 } }
                "6.2" { return @{ MaxBR = 1200000; MaxCPB = 1200000 } }
                default { return @{ MaxBR = 62500; MaxCPB = 62500 } }
            }
        }
        "av1" {
            switch ($Level) {
                "4.0" { return @{ MaxBR = 12000;  MaxCPB = 30000 } }
                "4.1" { return @{ MaxBR = 20000;  MaxCPB = 50000 } }
                "5.0" { return @{ MaxBR = 30000;  MaxCPB = 100000 } }
                "5.1" { return @{ MaxBR = 40000;  MaxCPB = 160000 } }
                "5.2" { return @{ MaxBR = 60000;  MaxCPB = 240000 } }
                "5.3" { return @{ MaxBR = 60000;  MaxCPB = 240000 } }
                "6.0" { return @{ MaxBR = 60000;  MaxCPB = 240000 } }
                "6.1" { return @{ MaxBR = 100000; MaxCPB = 480000 } }
                "6.2" { return @{ MaxBR = 160000; MaxCPB = 800000 } }
                "6.3" { return @{ MaxBR = 160000; MaxCPB = 800000 } }
                default { return @{ MaxBR = 30000; MaxCPB = 100000 } }
            }
        }
        default { return @{ MaxBR = 0; MaxCPB = 0 } }
    }
}

function Get-MinLevelForResolution {
    param([string]$Codec, [int]$Width, [int]$Height, [double]$Fps = 30)
    $fpsInt = [int][Math]::Round($Fps)
    if ($fpsInt -lt 1) { $fpsInt = 30 }
    switch ($Codec) {
        "hevc" {
            if     ($Width -ge 7680) { return "6.1" }
            elseif ($Width -ge 3840 -and $fpsInt -gt 60) { return "5.2" }
            elseif ($Width -ge 3840 -and $fpsInt -gt 30) { return "5.1" }
            elseif ($Width -ge 3840) { return "5.0" }
            elseif ($Width -ge 1920 -and $fpsInt -gt 30) { return "4.1" }
            elseif ($Width -ge 1920) { return "4.0" }
            elseif ($Width -ge 1280) { return "3.1" }
            else { return "3.0" }
        }
        "h264" {
            if     ($Width -ge 3840 -and $fpsInt -gt 60) { return "6.0" }
            elseif ($Width -ge 3840) { return "5.1" }
            elseif ($Width -ge 2560) { return "5.0" }
            elseif ($Width -ge 1920 -and $fpsInt -gt 30) { return "4.2" }
            elseif ($Width -ge 1920) { return "4.1" }
            elseif ($Width -ge 1280) { return "3.1" }
            else { return "3.0" }
        }
        "av1" {
            if     ($Width -ge 7680) { return "6.1" }
            elseif ($Width -ge 3840 -and $fpsInt -gt 60) { return "5.2" }
            elseif ($Width -ge 3840 -and $fpsInt -gt 30) { return "5.1" }
            elseif ($Width -ge 3840) { return "5.0" }
            elseif ($Width -ge 1920 -and $fpsInt -gt 30) { return "4.1" }
            elseif ($Width -ge 1920) { return "4.0" }
            else { return "4.0" }
        }
    }
}

function Suggest-VbvForTarget {
    param(
        [string]$Codec,
        [int]$TargetKbps,
        [int]$Width,
        [int]$Height,
        [double]$Fps = 30
    )
    $level = Get-MinLevelForResolution -Codec $Codec -Width $Width -Height $Height -Fps $Fps
    $tier = "main"
    $desiredMaxrate = [int]($TargetKbps * 1.5)
    $desiredBufsize = $TargetKbps * 2
    $caps = $null

    for ($i = 0; $i -lt 8; $i++) {
        $caps = Get-VbvCaps -Codec $Codec -Level $level -Tier $tier
        if ($desiredMaxrate -le $caps.MaxBR) { break }
        if ($Codec -eq "hevc" -and $tier -eq "main") {
            $tier = "high"
        } else {
            switch ($level) {
                "3.0" { $level = "3.1" }
                "3.1" { $level = "4.0" }
                "4.0" { $level = "4.1" }
                "4.1" { $level = "5.0" }
                "5.0" { $level = "5.1" }
                "5.1" { $level = "5.2" }
                "5.2" { $level = "6.0" }
                "6.0" { $level = "6.1" }
                "6.1" { $level = "6.2" }
                default { break }
            }
            if ($Codec -eq "hevc") { $tier = "main" }
        }
    }

    $finalMaxrate = [Math]::Min($desiredMaxrate, $caps.MaxBR)
    $finalBufsize = [Math]::Min($desiredBufsize, $caps.MaxCPB)
    return @{
        Level   = $level
        Tier    = $tier
        Maxrate = $finalMaxrate
        Bufsize = $finalBufsize
    }
}

function Get-BitrateKbps {
    param([string]$Bitrate)
    if (-not $Bitrate) { return 0 }
    if ($Bitrate -match '^(\d+)[mM]$') { return [int]$Matches[1] * 1000 }
    if ($Bitrate -match '^(\d+)[kK]$') { return [int]$Matches[1] }
    if ($Bitrate -match '^(\d+)$') {
        $n = [int]$Matches[1]
        if ($n -lt 100000) { return $n } else { return [int]($n / 1000) }
    }
    return 0
}

# ══════════════════════════════════════════════════════════════════════
# v51: HDR10 STATIC METADATA EXTRACTION (mirror extract_hdr10_static_metadata)
# Setează:
#   $script:hdr10StaticAvailable     ([bool])
#   $script:hdr10MasterDisplayX265   (string format chromaticity ×50000)
#   $script:hdr10MasterDisplaySvtAv1 (string format float)
#   $script:hdr10MaxCll              ("MaxCLL,MaxFALL" sau gol)
#   $script:hdr10StaticSource        ("probe" / "default-*")
# ══════════════════════════════════════════════════════════════════════

function Get-Hdr10StaticMetadata {
    param([string]$File)
    $script:hdr10StaticAvailable = $false
    $script:hdr10MasterDisplayX265 = ""
    $script:hdr10MasterDisplaySvtAv1 = ""
    $script:hdr10MaxCll = ""

    if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Test-Path $File)) { return $false }

    $probe = & ffprobe -v error -select_streams v:0 `
        -read_intervals "%+#1" `
        -show_entries frame=side_data_list `
        -of default=noprint_wrappers=1 `
        $File 2>$null | Out-String
    if (-not $probe) { return $false }

    $mode = ""
    $vals = @{}
    foreach ($line in ($probe -split "`r?`n")) {
        if ($line -match 'side_data_type=Mastering display metadata') { $mode = "m"; continue }
        if ($line -match 'side_data_type=Content light level metadata') { $mode = "c"; continue }
        if ($line -match 'side_data_type=') { $mode = ""; continue }
        $i = $line.IndexOf("=")
        if ($i -lt 0) { continue }
        $key = $line.Substring(0, $i).Trim()
        $val = $line.Substring($i + 1).Trim()
        if ($mode -eq "m") {
            if ($val -match '^(\d+)/(\d+)$') {
                $num = [double]$Matches[1]; $den = [double]$Matches[2]
            } else { continue }
            $vals[$key] = @{ Num = $num; Den = $den }
        } elseif ($mode -eq "c") {
            if ($key -eq "max_content") { $vals.maxc = $val }
            elseif ($key -eq "max_average") { $vals.maxa = $val }
        }
    }

    $required = @("red_x","red_y","green_x","green_y","blue_x","blue_y","white_point_x","white_point_y","max_luminance","min_luminance")
    $haveAll = $true
    foreach ($k in $required) { if (-not $vals.ContainsKey($k)) { $haveAll = $false; break } }

    if ($haveAll) {
        $fI = { param($v, $scale) [int][Math]::Round($v.Num * $scale / $v.Den) }
        $fF = { param($v) [Math]::Round($v.Num / $v.Den, 4) }
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        # v51 audit: format "0.0000" pentru paritate cu bash awk %.4f (4 zecimale fixe,
        # inclusiv trailing zeros). Anterior "0.0###" strip-uia trailing zeros pe svtav1.
        $fmt = { param($d) ([double]$d).ToString("0.0000", $inv) }

        $gxi = & $fI $vals.green_x 50000; $gyi = & $fI $vals.green_y 50000
        $bxi = & $fI $vals.blue_x  50000; $byi = & $fI $vals.blue_y  50000
        $rxi = & $fI $vals.red_x   50000; $ryi = & $fI $vals.red_y   50000
        $wxi = & $fI $vals.white_point_x 50000; $wyi = & $fI $vals.white_point_y 50000
        $mxi = & $fI $vals.max_luminance 10000
        $mni = & $fI $vals.min_luminance 10000
        $script:hdr10MasterDisplayX265 = "G($gxi,$gyi)B($bxi,$byi)R($rxi,$ryi)WP($wxi,$wyi)L($mxi,$mni)"

        $gxf = & $fmt (& $fF $vals.green_x); $gyf = & $fmt (& $fF $vals.green_y)
        $bxf = & $fmt (& $fF $vals.blue_x);  $byf = & $fmt (& $fF $vals.blue_y)
        $rxf = & $fmt (& $fF $vals.red_x);   $ryf = & $fmt (& $fF $vals.red_y)
        $wxf = & $fmt (& $fF $vals.white_point_x); $wyf = & $fmt (& $fF $vals.white_point_y)
        $mxf = & $fmt (& $fF $vals.max_luminance)
        $mnf = & $fmt (& $fF $vals.min_luminance)
        $script:hdr10MasterDisplaySvtAv1 = "G($gxf,$gyf)B($bxf,$byf)R($rxf,$ryf)WP($wxf,$wyf)L($mxf,$mnf)"

        $script:hdr10StaticAvailable = $true
    }
    if ($vals.maxc -and $vals.maxa) {
        $script:hdr10MaxCll = "$($vals.maxc),$($vals.maxa)"
    }
    return $script:hdr10StaticAvailable
}

function Set-Hdr10StaticDefaults {
    $script:hdr10StaticAvailable = $true
    $script:hdr10MasterDisplayX265 = "G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1)"
    $script:hdr10MasterDisplaySvtAv1 = "G(0.1700,0.7970)B(0.1310,0.0460)R(0.7080,0.2920)WP(0.3127,0.3290)L(1000.0000,0.0001)"
    $script:hdr10MaxCll = "1000,400"
}

function Resolve-Hdr10Static {
    param([string]$File)
    Get-Hdr10StaticMetadata -File $File | Out-Null
    if ($script:hdr10StaticAvailable) {
        $script:hdr10StaticSource = "probe"
    } else {
        Set-Hdr10StaticDefaults
        $script:hdr10StaticSource = "default-bt2020-1000nit"
    }
    if (-not $script:hdr10MaxCll) { $script:hdr10MaxCll = "1000,400" }
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
    # HLG: BT.2100 HLG signaling. Mutual-exclusive cu HDR10/HDR10+.
    # Apple Log poate raporta arib-std-b67 — refinare la Get-SourceInfoExtended cu logProfile.
    $isHLG    = ($transfer -eq "arib-std-b67") -and (-not $isHDRPlus) -and ($transfer -ne "smpte2084")
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
        isHLG    = $isHLG
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

# v35: Detectie capabilitati GPU (NVIDIA/Intel/AMD) + suport AV1 per-generatie
# Filtreaza adaptoare virtuale (RDP/VM/DisplayLink) — doar GPU-uri fizice reale
function Get-GPUCapabilities {
    $virtualRx = "Basic Display|Remote Display|Virtual|VMware|VirtualBox|Hyper-V|Citrix|DisplayLink|Parsec|Oracle"
    $allAdapters = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
    $gpus = @($allAdapters | Where-Object { $_.Name -and ($_.Name -notmatch $virtualRx) })
    $isVM = ($allAdapters | Where-Object { $_.Name -match $virtualRx }).Count -gt 0 -and $gpus.Count -eq 0

    # Regex AV1 encode per-vendor (generatii care suporta hardware AV1 encode)
    $nvAv1Rx    = "RTX\s*40\d{2}|RTX\s*50\d{2}|RTX\s*4000\s*Ada|RTX\s*5000\s*Ada|L40|L4\b"
    $intelAv1Rx = "Arc\s*[AB]\d{3}|Core\s*Ultra|Meteor\s*Lake|Arrow\s*Lake|Lunar\s*Lake|Panther\s*Lake"
    $amdAv1Rx   = "RX\s*7\d{3}|RX\s*8\d{3}|RX\s*9\d{3}|W7\d{3}|740M|760M|780M|860M|880M|890M|Radeon\s*AI\s*PRO"

    $gpuList = @()
    $hasNvidia = $false; $hasIntel = $false; $hasAmd = $false
    $nvAv1 = $false; $intelAv1 = $false; $amdAv1 = $false
    foreach ($g in $gpus) {
        $n = $g.Name
        if ($n -match "NVIDIA|GeForce|RTX|GTX|Quadro|Tesla") {
            $hasNvidia = $true
            $av1 = ($n -match $nvAv1Rx)
            if ($av1) { $nvAv1 = $true }
            $gpuList += @{ vendor="NVIDIA"; name=$n; av1=$av1 }
        } elseif ($n -match "Intel") {
            $hasIntel = $true
            $av1 = ($n -match $intelAv1Rx)
            if ($av1) { $intelAv1 = $true }
            $gpuList += @{ vendor="Intel"; name=$n; av1=$av1 }
        } elseif ($n -match "AMD|Radeon|ATI") {
            $hasAmd = $true
            $av1 = ($n -match $amdAv1Rx)
            if ($av1) { $amdAv1 = $true }
            $gpuList += @{ vendor="AMD"; name=$n; av1=$av1 }
        }
    }

    return @{
        gpus        = $gpuList
        hasNvidia   = $hasNvidia
        hasIntel    = $hasIntel
        hasAmd      = $hasAmd
        isVM        = $isVM
        # H.264/H.265: orice GPU modern al vendor-ului e compatibil
        h264Support = @{ nvidia=$hasNvidia; intel=$hasIntel; amd=$hasAmd }
        h265Support = @{ nvidia=$hasNvidia; intel=$hasIntel; amd=$hasAmd }
        av1Support  = @{ nvidia=$nvAv1;     intel=$intelAv1; amd=$amdAv1 }
    }
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
    param([string]$file, [bool]$keepDjmd, [bool]$keepDbgi, [bool]$keepTmcd, $djiInfo, [string]$cont)
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
        if     ($tag -imatch "djmd" -and $keepDjmd -and $cont -eq "mkv")      { $maps.AddRange([string[]]@("-map","0:$idx")) }
        elseif ($tag -imatch "djmd" -and $cont -ne "mkv")                     { Write-Host "  NOTA: djmd (GPS) omis — incompatibil cu $cont (doar mkv)" -ForegroundColor Yellow }
        elseif ($tag -imatch "dbgi" -and $keepDbgi -and $cont -eq "mkv")      { $maps.AddRange([string[]]@("-map","0:$idx")) }
        elseif ($tag -imatch "dbgi" -and $cont -ne "mkv")                     { Write-Host "  NOTA: dbgi (debug) omis — incompatibil cu $cont (doar mkv)" -ForegroundColor Yellow }
        elseif ($tag -imatch "tmcd" -and $keepTmcd -and $cont -eq "mkv")      { $maps.AddRange([string[]]@("-map","0:$idx")) }
        elseif ($tag -imatch "tmcd" -and $cont -ne "mkv")                     { Write-Host "  NOTA: tmcd (timecode) omis — incompatibil cu $cont (doar mkv)" -ForegroundColor Yellow }
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

    # HLG refined: doar daca transfer e arib-std-b67 si NU e LOG/DV/HDR10+/HDR10
    $isHLG = ($srcColorTrc -eq "arib-std-b67") -and (-not $logProfile) `
             -and (-not $dovi) -and (-not $isHdrPlus) -and ($transfer -ne "smpte2084")

    return @{
        logProfile  = $logProfile
        cameraMake  = $cameraMake
        srcColorTrc = $srcColorTrc
        srcIsVfr    = $srcIsVfr
        isHLG       = $isHLG
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

# ── v39: Find-HlgLutForBrand — cauta LUT-uri Log → HLG ─────────────
# Convenție: hlg_<brand>_*.cube (ex: hlg_apple_log_v1.cube)
function Find-HlgLutForBrand {
    param([string]$brand, [string]$inputDir)
    $prefix = switch ($brand) {
        "apple"   { "hlg_apple_log_" }
        "samsung" { "hlg_samsung_log_" }
        "dji"     { "hlg_dji_dlog_m_" }
        default   { "hlg_" }
    }
    $lutsDir = Join-Path $inputDir "Luts"
    if (-not (Test-Path $lutsDir)) { return @{ files = @(); dir = "" } }
    $found = @(Get-ChildItem -Path $lutsDir -Filter "${prefix}*.cube" -ErrorAction SilentlyContinue)
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
    $scErrFile = "$env:TEMP\fferr_sc_$PID.txt"
    $scProc = Start-Process ffmpeg -ArgumentList $scArgs -NoNewWindow -PassThru `
        -RedirectStandardError $scErrFile
    Show-Progress -proc $scProc -progFile $scProgFile -durSec $durSec -startTime $scStart -Label "Stream copy"
    $scProc.WaitForExit()
    if ($scProc.ExitCode -ne 0) {
        if (Test-Path $scErrFile) {
            Write-Host "  ⚠ ffmpeg exit $($scProc.ExitCode) — ultimele linii stderr:" -ForegroundColor Yellow
            Get-Content $scErrFile -Tail 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Remove-Item $scErrFile -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
    if (Test-Path $scErrFile) { Remove-Item $scErrFile -Force -ErrorAction SilentlyContinue }

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

# ══════════════════════════════════════════════════════════════════════
# v44: CODEC-AWARE TOOL DISPATCHERS (PS1 mirror al av_common.sh)
# Selecteaza binarul corect (HEVC: quietvoid; AV1: sven-pke fork) pentru
# RPU Dolby Vision si metadata HDR10+. Binarele AV1 sunt instalate cu
# rename (av1dovi_tool / av1hdr10plus_tool) pentru a nu intra in coliziune.
# ══════════════════════════════════════════════════════════════════════

# Returneaza codec-ul stream-ului video (hevc / av1 / h264 / ...).
function Get-SourceCodec {
    param([string]$File)
    if (-not $File -or -not (Test-Path -LiteralPath $File)) { return "" }
    return (& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 -- "$File" 2>$null).Trim()
}

# Get-ToolForExtract -Codec <hevc|av1|...> -Kind <dovi|hdr10plus>
function Get-ToolForExtract {
    param(
        [string]$Codec = "hevc",
        [string]$Kind = "dovi"
    )
    if ($Codec -eq "av1") {
        switch ($Kind) {
            "dovi"      { return "av1dovi_tool" }
            "hdr10plus" { return "av1hdr10plus_tool" }
            default     { return "" }
        }
    } else {
        switch ($Kind) {
            "dovi"      { return "dovi_tool" }
            "hdr10plus" { return "hdr10plus_tool" }
            default     { return "" }
        }
    }
}

# Acelasi dispatch pentru injectare (decuplat pentru future-proofing).
function Get-ToolForInject {
    param(
        [string]$Codec = "hevc",
        [string]$Kind = "dovi"
    )
    return (Get-ToolForExtract -Codec $Codec -Kind $Kind)
}

function Test-Av1DoviTool {
    return [bool](Get-Command "av1dovi_tool" -ErrorAction SilentlyContinue)
}

function Test-Av1Hdr10PlusTool {
    return [bool](Get-Command "av1hdr10plus_tool" -ErrorAction SilentlyContinue)
}

# v44: detecteaza daca SVT-AV1 din ffmpeg curent suporta hdr10plus-json
# (introdus in SVT-AV1 v1.5+). Cache-eaza rezultatul intr-o variabila script.
$script:_SvtAv1Hdr10PlusCaps = $null
function Test-SvtAv1Hdr10PlusCaps {
    if ($null -ne $script:_SvtAv1Hdr10PlusCaps) { return $script:_SvtAv1Hdr10PlusCaps }
    $help = & ffmpeg -hide_banner -h encoder=libsvtav1 2>&1 | Out-String
    $script:_SvtAv1Hdr10PlusCaps = [bool]($help -match "(?i)hdr10plus")
    return $script:_SvtAv1Hdr10PlusCaps
}

# Wrapper unificat — verifica binarul potrivit pentru codec-ul cerut.
function Test-DoviToolFor {
    param([string]$Codec = "hevc")
    if ($Codec -eq "av1") { return (Test-Av1DoviTool) }
    return [bool](Get-Command "dovi_tool" -ErrorAction SilentlyContinue)
}

function Test-Hdr10PlusToolFor {
    param([string]$Codec = "hevc")
    if ($Codec -eq "av1") { return (Test-Av1Hdr10PlusTool) }
    return [bool](Get-Command "hdr10plus_tool" -ErrorAction SilentlyContinue)
}

# ── Show-Hdr10PlusDialog — HDR10+ dialog per fisier ────────────────
# v44: param 2 optional = -TargetCodec (hevc default | av1) — controleaza
# disponibilitatea triple-layer si binarele afisate.
# Return: "static" | "preserve" | "copy" | "triple" | "skip"
function Show-Hdr10PlusDialog {
    param(
        [string]$file,
        [string]$TargetCodec = "hevc"
    )
    # v45: extract are nevoie de source-codec tool, triple-layer inject de target-codec tool
    $srcCodec = Get-SourceCodec $file
    $hdr10plusToolAvail = Test-Hdr10PlusToolFor -Codec $srcCodec
    $doviToolAvail      = Test-DoviToolFor    -Codec $TargetCodec

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
            $tlLabel = if ($TargetCodec -eq "av1") { "DV P10 + HDR10 + HDR10+ (AV1)" } else { "DV 8.1 + HDR10 + HDR10+ (HEVC)" }
            Write-Host "  ║  4) Triple-layer (Hibrid 8.1)                ║" -ForegroundColor White
            Write-Host "  ║     → $tlLabel" -ForegroundColor DarkGray
            $maxOpt = 4
        } else {
            $needTool = if ($TargetCodec -eq "av1") { "av1dovi_tool" } else { "dovi_tool" }
            $hint     = if ($TargetCodec -eq "av1") { "av1dovi_parser.ps1" } else { "dovi_parser.ps1" }
            Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Magenta
            Write-Host "  ║  $needTool NU este instalat." -ForegroundColor Yellow
            Write-Host "  ║  Fara el, Triple-layer NU este disponibil.   ║" -ForegroundColor Yellow
            Write-Host "  ║  Instaleaza cu: .\$(Split-Path $ToolsDir -Leaf)\$hint" -ForegroundColor DarkGray
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
        # v45: tool-ul lipsa e pt source-codec (extract), nu target-codec
        $needHp = if ($srcCodec -eq "av1") { "av1hdr10plus_tool" } else { "hdr10plus_tool" }
        $hintHp = if ($srcCodec -eq "av1") { "av1hdr10plus_parser.ps1" } else { "hdr10plus_parser.ps1" }
        Write-Host "  ║  $needHp NU este instalat (necesar pt sursa $srcCodec)" -ForegroundColor Yellow
        Write-Host "  ║  Fara el, metadata dinamica se pierde.       ║" -ForegroundColor Yellow
        Write-Host "  ║  Instaleaza cu: .\$(Split-Path $ToolsDir -Leaf)\$hintHp" -ForegroundColor DarkGray
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
# v44: foloseste Get-ToolForExtract pentru a alege binarul corect (HEVC vs AV1).
function Extract-Hdr10PlusMetadata {
    param([string]$file)
    $jsonFile = Join-Path $env:TEMP ("hdr10plus_"+[guid]::NewGuid().ToString("N")+".json")
    $srcCodec = Get-FFprobeValue $file "v:0" "codec_name"
    $hpTool   = Get-ToolForExtract -Codec $srcCodec -Kind "hdr10plus"
    Write-Host "  HDR10+: Extrag metadata dinamica (codec=$srcCodec, tool=$hpTool)..." -ForegroundColor Cyan
    if ($srcCodec -eq "av1") {
        & ffmpeg -v error -i "$file" -c:v copy -f ivf - 2>$null |
            & $hpTool extract -i - -o "$jsonFile" 2>$null
    } else {
        & ffmpeg -v error -i "$file" -c:v copy -bsf:v hevc_mp4toannexb -f hevc - 2>$null |
            & $hpTool extract -i - -o "$jsonFile" 2>$null
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
# v44: parametru optional -TargetCodec (hevc default / av1) pentru sven-pke fork.
# Note: RPU-ul e profile-agnostic; diferenta e doar in binarul de generate +
# ulterior in injectie.
function Generate-DvRpuFromHdr10Plus {
    param(
        [string]$hdr10plusJson,
        [string]$TargetCodec = "hevc"
    )
    $doviBin = Get-ToolForExtract -Codec $TargetCodec -Kind "dovi"
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
    Write-Host "  DV: Generez RPU din HDR10+ metadata (codec=$TargetCodec, tool=$doviBin)..." -ForegroundColor Cyan
    & $doviBin generate -j "$configFile" --hdr10plus-json "$hdr10plusJson" -o "$rpuFile" 2>$null
    $genRc = $LASTEXITCODE
    Remove-Item $configFile -Force -ErrorAction SilentlyContinue
    if ($genRc -eq 0 -and (Test-Path $rpuFile) -and (Get-Item $rpuFile).Length -gt 0) {
        $profLabel = if ($TargetCodec -eq "av1") { "Profile 10 (AV1)" } else { "Profile 8.1 (HEVC)" }
        Write-Host "  DV: RPU generat cu succes ($profLabel)" -ForegroundColor Green
        return $rpuFile
    } else {
        Write-Host "  DV: Generare RPU esuata" -ForegroundColor Yellow
        Remove-Item $rpuFile -Force -ErrorAction SilentlyContinue
        return ""
    }
}

# ── Inject-DvRpu — injecteaza DV RPU in HEVC sau AV1 stream ────────
# v44: parametru optional -TargetCodec pentru a alege binarul potrivit.
function Inject-DvRpu {
    param(
        [string]$hevcFile,
        [string]$rpuFile,
        [string]$outputFile,
        [string]$TargetCodec = "hevc"
    )
    $doviBin = Get-ToolForInject -Codec $TargetCodec -Kind "dovi"
    Write-Host "  DV: Injectez RPU in bitstream $TargetCodec (tool=$doviBin)..." -ForegroundColor Cyan
    & $doviBin inject-rpu -i "$hevcFile" --rpu-in "$rpuFile" -o "$outputFile" 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $outputFile) -and (Get-Item $outputFile).Length -gt 0) {
        Write-Host "  DV: Injectare RPU reusita" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  DV: Injectare RPU esuata" -ForegroundColor Yellow
        return $false
    }
}

# ══════════════════════════════════════════════════════════════════════
# v44: HDR/DV TOOLS — convert RPU profile / extract raw video / remux
# ══════════════════════════════════════════════════════════════════════

# Extract-DvRpu — extract RPU dintr-un container sau stream raw.
# -InputFile, -RpuOut, -SourceCodec ("hevc" default | "av1")
function Get-DvRpu {
    param(
        [string]$InputFile,
        [string]$RpuOut,
        [string]$SourceCodec = "hevc"
    )
    $doviBin = Get-ToolForExtract -Codec $SourceCodec -Kind "dovi"
    if (-not $doviBin) { return $false }
    $ext = [System.IO.Path]::GetExtension($InputFile).TrimStart('.').ToLowerInvariant()
    $rawTmp = $null
    $useInput = $InputFile
    if ($ext -notin @("hevc","h265","265","ivf","obu")) {
        $rawExt = if ($SourceCodec -eq "av1") { "ivf" } else { "hevc" }
        $rawTmp = Join-Path $env:TEMP ("raw_"+[guid]::NewGuid().ToString("N")+".$rawExt")
        if ($SourceCodec -eq "av1") {
            & ffmpeg -v error -i $InputFile -c:v copy -f ivf $rawTmp 2>$null
        } else {
            & ffmpeg -v error -i $InputFile -c:v copy -bsf:v hevc_mp4toannexb -f hevc $rawTmp 2>$null
        }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $rawTmp)) {
            Remove-Item $rawTmp -Force -ErrorAction SilentlyContinue
            return $false
        }
        $useInput = $rawTmp
    }
    & $doviBin extract-rpu -i $useInput -o $RpuOut 2>$null
    $rc = $LASTEXITCODE
    if ($rawTmp) { Remove-Item $rawTmp -Force -ErrorAction SilentlyContinue }
    return ($rc -eq 0 -and (Test-Path $RpuOut) -and (Get-Item $RpuOut).Length -gt 0)
}

# Convert-RpuProfile — converteste RPU intre profile (ex: 7→8.1, force 8.1).
# Modes (ref dovi_tool 2.x): 1=8.1 single-layer, 2=force 8.1, 3=5→8.1, 4=7→8.1.
function Convert-RpuProfile {
    param(
        [string]$RpuIn,
        [string]$RpuOut,
        [int]$Mode = 2,
        [string]$TargetCodec = "hevc"
    )
    if (-not (Test-Path -LiteralPath $RpuIn)) { return $false }
    $doviBin = Get-ToolForInject -Codec $TargetCodec -Kind "dovi"
    if (-not $doviBin) { return $false }
    Write-Host "  RPU convert: $RpuIn -> $RpuOut (mode=$Mode, codec=$TargetCodec, tool=$doviBin)" -ForegroundColor Cyan
    if ($script:LogFile -and (Test-Path -LiteralPath (Split-Path -Parent $script:LogFile))) {
        & $doviBin convert -m $Mode --rpu-out $RpuOut $RpuIn 2>>$script:LogFile | Out-Null
    } else {
        & $doviBin convert -m $Mode --rpu-out $RpuOut $RpuIn 2>$null | Out-Null
    }
    return ($LASTEXITCODE -eq 0 -and (Test-Path $RpuOut) -and (Get-Item $RpuOut).Length -gt 0)
}

# Get-RawVideo — extract video raw codec-aware (HEVC annex-B / AV1 IVF).
function Get-RawVideo {
    param(
        [string]$InputFile,
        [string]$OutputFile,
        [string]$Codec = ""
    )
    if (-not $Codec) { $Codec = Get-SourceCodec $InputFile }
    switch ($Codec) {
        "av1"  { & ffmpeg -v error -i $InputFile -c:v copy -f ivf $OutputFile 2>$null }
        "hevc" { & ffmpeg -v error -i $InputFile -c:v copy -bsf:v hevc_mp4toannexb -f hevc $OutputFile 2>$null }
        "h264" { & ffmpeg -v error -i $InputFile -c:v copy -bsf:v h264_mp4toannexb -f h264 $OutputFile 2>$null }
        default { & ffmpeg -v error -i $InputFile -c:v copy $OutputFile 2>$null }
    }
    return ($LASTEXITCODE -eq 0 -and (Test-Path $OutputFile) -and (Get-Item $OutputFile).Length -gt 0)
}

# Get-RemuxPreflight — returneaza @{ level=0|1|2; notes=@(...) }
# 0=ok, 1=warn (incompat tracks vor fi strip-uite/convertite), 2=fail (abort).
function Get-RemuxPreflight {
    param(
        [string]$File,
        [string]$TargetContainer
    )
    $notes = New-Object System.Collections.Generic.List[string]
    $level = 0
    $target = $TargetContainer.ToLowerInvariant()

    $videoCodec = ((& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 -- $File 2>$null) | Out-String).Trim()
    $audioCodecsRaw = (& ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 -- $File 2>$null) | Out-String
    $subCodecsRaw   = (& ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 -- $File 2>$null) | Out-String
    $codecTags      = (& ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 -- $File 2>$null) | Out-String
    $attachIdxRaw   = (& ffprobe -v error -select_streams t -show_entries stream=index -of csv=p=0 -- $File 2>$null) | Out-String

    $audioCodecs = $audioCodecsRaw -split "`r?`n" | Where-Object { $_ }
    $subCodecs   = $subCodecsRaw   -split "`r?`n" | Where-Object { $_ }
    $attachCount = ($attachIdxRaw -split "`r?`n" | Where-Object { $_ }).Count
    $djiPresent = $codecTags -match "(?i)\b(djmd|dbgi)\b"

    function _Matches([string[]]$list, [string]$pat) {
        foreach ($c in $list) { if ($c -match $pat) { return $true } }
        return $false
    }

    switch ($target) {
        "mp4" {
            if (_Matches $audioCodecs '^(truehd|dts|pcm_s24le|pcm_s16be)$') {
                $notes.Add("Audio lossless (TrueHD/DTS-HD/PCM) — incompatibil cu MP4, va fi strip-uit") | Out-Null
                if ($level -lt 1) { $level = 1 }
            }
            if (_Matches $subCodecs '^(subrip|srt|ass|ssa)$') {
                $notes.Add("Subtitrari text necompatibile direct cu MP4 — vor fi convertite la mov_text") | Out-Null
                if ($level -lt 1) { $level = 1 }
            }
            if (_Matches $subCodecs '^(dvd_subtitle|hdmv_pgs_subtitle)$') {
                $notes.Add("Subtitrari bitmap (PGS/VobSub) incompatibile cu MP4 — vor fi strip-uite") | Out-Null
                if ($level -lt 1) { $level = 1 }
            }
            if ($djiPresent) {
                $notes.Add("Track-uri DJI (djmd/dbgi) incompatibile cu MP4 — vor fi strip-uite") | Out-Null
                if ($level -lt 1) { $level = 1 }
            }
            if ($attachCount -gt 0) {
                $notes.Add("$attachCount atasament(e) — doar MKV suporta atasamente, vor fi strip-uite") | Out-Null
                if ($level -lt 1) { $level = 1 }
            }
        }
        "mov" {
            if (_Matches $audioCodecs '^eac3$') {
                $notes.Add("E-AC3 audio incompatibil cu .mov — converteste audio sau alege .mp4") | Out-Null
                $level = 2
            }
            if (_Matches $audioCodecs '^(truehd|dts|opus)$') {
                $notes.Add("Audio (TrueHD/DTS/Opus) incompatibil cu MOV — va fi strip-uit") | Out-Null
                if ($level -lt 1) { $level = 1 }
            }
            if (_Matches $subCodecs '^(subrip|srt|ass|ssa)$') {
                $notes.Add("Subtitrari text vor fi convertite la mov_text pentru MOV") | Out-Null
                if ($level -lt 1) { $level = 1 }
            }
            if (_Matches $subCodecs '^(dvd_subtitle|hdmv_pgs_subtitle)$') {
                $notes.Add("Subtitrari bitmap (PGS/VobSub) incompatibile cu MOV — vor fi strip-uite") | Out-Null
                if ($level -lt 1) { $level = 1 }
            }
            if ($djiPresent) {
                $notes.Add("Track-uri DJI (djmd/dbgi) incompatibile cu MOV — vor fi strip-uite") | Out-Null
                if ($level -lt 1) { $level = 1 }
            }
            if ($attachCount -gt 0) {
                $notes.Add("$attachCount atasament(e) — doar MKV suporta atasamente, vor fi strip-uite") | Out-Null
                if ($level -lt 1) { $level = 1 }
            }
        }
        "webm" {
            if ($videoCodec -and $videoCodec -notmatch '^(vp8|vp9|av1)$') {
                $notes.Add("Video '$videoCodec' incompatibil cu WEBM (doar VP8/VP9/AV1 suportate) — abort") | Out-Null
                $level = 2
            }
            if (_Matches $audioCodecs '^(aac|ac3|eac3|mp3|dts|truehd|alac|pcm_s16le|pcm_s24le)$') {
                $notes.Add("Audio incompatibil cu WEBM (doar Opus/Vorbis suportate) — va fi strip-uit") | Out-Null
                if ($level -lt 1) { $level = 1 }
            }
            if (_Matches $subCodecs '^(subrip|srt|ass|ssa|dvd_subtitle|hdmv_pgs_subtitle|mov_text)$') {
                $notes.Add("Subtitrari incompatibile cu WEBM (doar WebVTT) — vor fi strip-uite") | Out-Null
                if ($level -lt 1) { $level = 1 }
            }
            if ($attachCount -gt 0) {
                $notes.Add("$attachCount atasament(e) — WEBM nu suporta, vor fi strip-uite") | Out-Null
                if ($level -lt 1) { $level = 1 }
            }
        }
        "mkv" { }
        default {
            $notes.Add("Container '$target' nesuportat (foloseste mkv/mp4/mov/webm)") | Out-Null
            $level = 2
        }
    }
    return @{ level = $level; notes = @($notes) }
}

# v49: clasificare per-stream pentru target container.
function Get-RemuxStreamCompat {
    param([string]$Codec, [string]$CodecType, [string]$Target)
    $codec = $Codec.ToLowerInvariant()
    $ctype = $CodecType.ToLowerInvariant()
    $t = $Target.ToLowerInvariant()
    if ($t -eq "mkv") { return "copy" }
    switch ($ctype) {
        "video" {
            switch ($t) {
                "mp4" {
                    if ($codec -in @("hevc","h264","av1","mpeg4","mpeg2video","vp9","prores")) { return "copy" }
                    return "drop"
                }
                "mov" {
                    if ($codec -in @("hevc","h264","prores","dnxhd","dnxhr","mpeg4","mjpeg")) { return "copy" }
                    return "drop"
                }
                "webm" {
                    if ($codec -in @("vp8","vp9","av1")) { return "copy" }
                    return "drop"
                }
            }
            return "drop"
        }
        "audio" {
            switch ($t) {
                "mp4" {
                    if ($codec -in @("aac","ac3","eac3","mp3","opus","alac","flac")) { return "copy" }
                    return "drop"
                }
                "mov" {
                    if ($codec -in @("aac","ac3","mp3","alac","pcm_s16be","pcm_s24be","pcm_s16le","pcm_s24le")) { return "copy" }
                    return "drop"
                }
                "webm" {
                    if ($codec -in @("opus","vorbis")) { return "copy" }
                    return "drop"
                }
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
                "webm" {
                    if ($codec -eq "webvtt") { return "copy" }
                    return "drop"
                }
            }
            return "drop"
        }
        "attachment" { return "drop" }
    }
    return "drop"
}

# v49: enumerate streams + chapters din ffprobe (JSON-style via csv multiple queries).
# Return: hashtable cu Video[]/Audio[]/Subtitle[]/Attachment[] + ChapterCount.
# Fiecare element: @{ AbsIndex; Codec; Lang; Title; Extra }
function Get-RemuxStreams {
    param([string]$File)
    $result = @{
        Video = New-Object System.Collections.Generic.List[object]
        Audio = New-Object System.Collections.Generic.List[object]
        Subtitle = New-Object System.Collections.Generic.List[object]
        Attachment = New-Object System.Collections.Generic.List[object]
        ChapterCount = 0
    }
    # Video: index,codec_name,width,height,language,title
    $raw = (& ffprobe -v error -select_streams v -show_entries stream=index,codec_name,width,height:stream_tags=language,title -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 6
        if ($parts.Count -lt 1) { continue }
        $idx = $parts[0]
        $codec = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $w = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $h = if ($parts.Count -gt 3) { $parts[3] } else { "" }
        $lang = if ($parts.Count -gt 4) { $parts[4] } else { "" }
        $title = if ($parts.Count -gt 5) { $parts[5] } else { "" }
        $result.Video.Add([PSCustomObject]@{
            AbsIndex = $idx; Codec = $codec; Lang = $lang; Title = $title; Extra = "${w}x${h}"
        }) | Out-Null
    }
    # Audio
    $raw = (& ffprobe -v error -select_streams a -show_entries stream=index,codec_name,channels:stream_tags=language,title -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 5
        if ($parts.Count -lt 1) { continue }
        $idx = $parts[0]
        $codec = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $ch = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $lang = if ($parts.Count -gt 3) { $parts[3] } else { "" }
        $title = if ($parts.Count -gt 4) { $parts[4] } else { "" }
        $result.Audio.Add([PSCustomObject]@{
            AbsIndex = $idx; Codec = $codec; Lang = $lang; Title = $title; Extra = "${ch}ch"
        }) | Out-Null
    }
    # Subtitle
    $raw = (& ffprobe -v error -select_streams s -show_entries stream=index,codec_name:stream_tags=language,title -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 4
        if ($parts.Count -lt 1) { continue }
        $idx = $parts[0]
        $codec = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $lang = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $title = if ($parts.Count -gt 3) { $parts[3] } else { "" }
        $result.Subtitle.Add([PSCustomObject]@{
            AbsIndex = $idx; Codec = $codec; Lang = $lang; Title = $title; Extra = ""
        }) | Out-Null
    }
    # Attachments
    $raw = (& ffprobe -v error -select_streams t -show_entries stream=index,codec_name:stream_tags=filename -of csv=p=0 -- $File 2>$null) | Out-String
    foreach ($line in ($raw -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ',', 3
        if ($parts.Count -lt 1) { continue }
        $idx = $parts[0]
        $codec = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        $title = if ($parts.Count -gt 2) { $parts[2] } else { "" }
        $result.Attachment.Add([PSCustomObject]@{
            AbsIndex = $idx; Codec = $codec; Lang = ""; Title = $title; Extra = ""
        }) | Out-Null
    }
    # Chapters
    $rawCh = (& ffprobe -v error -show_chapters -of csv=p=0 -- $File 2>$null) | Out-String
    $result.ChapterCount = ($rawCh -split "`r?`n" | Where-Object { $_ }).Count
    return $result
}

# Invoke-Remux — re-mux container cu tag:v + faststart, no re-encode.
function Invoke-Remux {
    param(
        [string]$InputFile,
        [string]$OutputFile,
        [string]$TargetContainer
    )
    $target = $TargetContainer.ToLowerInvariant()
    $srcCodec = Get-SourceCodec $InputFile

    $extra = @()
    $subArgs = @("-c:s","copy")   # MKV permisiv — copy nativ pentru SRT/ASS/PGS
    if ($target -in @("mp4","mov")) {
        switch ($srcCodec) {
            "hevc" { $extra = @("-tag:v","hvc1","-movflags","+faststart") }
            "av1"  { $extra = @("-tag:v","av01","-movflags","+faststart") }
            "h264" { $extra = @("-tag:v","avc1","-movflags","+faststart") }
            default { $extra = @("-movflags","+faststart") }
        }
        $subArgs = @("-c:s","mov_text")
    }

    $args1 = @("-v","error","-i",$InputFile,"-map","0","-c","copy") + $subArgs + $extra + @($OutputFile)
    & ffmpeg @args1 2>$null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutputFile) -or (Get-Item $OutputFile).Length -eq 0) {
        # Retry fara subtitrari (subs incompat cu target)
        Remove-Item $OutputFile -Force -ErrorAction SilentlyContinue
        $args2 = @("-v","error","-i",$InputFile,"-map","0:v","-map","0:a?","-map","0:t?","-c","copy") + $extra + @($OutputFile)
        & ffmpeg @args2 2>$null
    }
    return ($LASTEXITCODE -eq 0 -and (Test-Path $OutputFile) -and (Get-Item $OutputFile).Length -gt 0)
}

# ── HDR/DV Tools — sub-meniu UI ───────────────────────────────────────
function _Hdv-PickFile {
    param([string]$Prompt = "Alege fisier", [string]$Dir = $InputDir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        Write-Host "Folderul nu exista: $Dir" -ForegroundColor Red
        return $null
    }
    # NOTE: -Include cu Get-ChildItem cere wildcard in -Path SAU -Recurse,
    # altfel returneaza gol. Folosim Where-Object pe extensie ca workaround.
    $validExt = '.mp4','.mov','.mkv','.m2ts','.mts','.hevc','.h265','.265','.ivf'
    $files = @(Get-ChildItem -LiteralPath $Dir -File | Where-Object { $validExt -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name)
    if ($files.Count -eq 0) { Write-Host "Niciun fisier in $Dir" -ForegroundColor Yellow; return $null }
    Write-Host ""
    Write-Host "${Prompt}:" -ForegroundColor Cyan
    for ($i=0; $i -lt $files.Count; $i++) {
        Write-Host ("  {0,2}) {1}" -f ($i+1), $files[$i].Name)
    }
    $idx = Read-Host "Alege [1-$($files.Count)]"
    if ($idx -notmatch '^\d+$') { return $null }
    $n = [int]$idx
    if ($n -lt 1 -or $n -gt $files.Count) { return $null }
    return $files[$n-1].FullName
}

function Invoke-TransformRpu {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  TRANSFORM RPU PROFILE                       ║" -ForegroundColor Cyan
    Write-Host "║  Converteste RPU intre Profile 7/8.1/10      ║" -ForegroundColor Cyan
    Write-Host "║  Fara re-encode video.                       ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $file = _Hdv-PickFile -Prompt "Alege fisier sursa (cu DV)"
    if (-not $file) { Write-Host "Anulat." -ForegroundColor Yellow; return }
    $srcCodec = Get-SourceCodec $file
    Write-Host "  Codec sursa: $srcCodec"

    Write-Host ""
    Write-Host "  Mode dovi_tool convert (filtrate dupa codec sursa: $srcCodec):" -ForegroundColor White
    $defaultChoice = "1"
    if ($srcCodec -eq "hevc") {
        Write-Host "    1) Force 8.1 (HEVC, single-layer + HDR10 base)  [-m 2]"
        Write-Host "    2) DV 5 -> 8.1                                  [-m 3]"
        Write-Host "    3) DV 7 -> 8.1 (drop EL, MEL only)              [-m 4]"
    } elseif ($srcCodec -eq "av1") {
        Write-Host "    4) AV1: profile 10 (sven-pke fork)              [-m 2 + tool av1]"
        $defaultChoice = "4"
    } else {
        Write-Host "  EROARE: Codec sursa '$srcCodec' nu suporta DV transform." -ForegroundColor Red
        Write-Host "         Doar HEVC (DV 5/7/8.1) si AV1 (DV 10) sunt suportate." -ForegroundColor Red
        return
    }
    $modeChoice = Read-Host "  Alege [implicit: $defaultChoice]"
    if (-not $modeChoice) { $modeChoice = $defaultChoice }
    $mode = 2; $targetCodec = "hevc"
    switch ($modeChoice) {
        "1" {
            if ($srcCodec -ne "hevc") { Write-Host "Mod 1 doar pentru HEVC." -ForegroundColor Red; return }
            $mode = 2; $targetCodec = "hevc"
        }
        "2" {
            if ($srcCodec -ne "hevc") { Write-Host "Mod 2 doar pentru HEVC." -ForegroundColor Red; return }
            $mode = 3; $targetCodec = "hevc"
        }
        "3" {
            if ($srcCodec -ne "hevc") { Write-Host "Mod 3 doar pentru HEVC." -ForegroundColor Red; return }
            $mode = 4; $targetCodec = "hevc"
        }
        "4" {
            if ($srcCodec -ne "av1") { Write-Host "Mod 4 doar pentru AV1." -ForegroundColor Red; return }
            $mode = 2; $targetCodec = "av1"
        }
        default { Write-Host "Optiune invalida." -ForegroundColor Red; return }
    }
    if (-not (Test-DoviToolFor -Codec $targetCodec)) {
        $t = if ($targetCodec -eq "av1") { "av1dovi_tool" } else { "dovi_tool" }
        Write-Host "  EROARE: $t nu este instalat. Vezi src/tools/." -ForegroundColor Red
        return
    }

    $rpuSrc = Join-Path $env:TEMP ("rpu_"+[guid]::NewGuid().ToString("N")+".bin")
    $rpuOut = Join-Path $env:TEMP ("rpu_"+[guid]::NewGuid().ToString("N")+".bin")

    Write-Host ""
    Write-Host "  [1/3] Extract RPU sursa..." -ForegroundColor Cyan
    if (-not (Get-DvRpu -InputFile $file -RpuOut $rpuSrc -SourceCodec $srcCodec)) {
        Write-Host "  EROARE: Extract RPU esuat." -ForegroundColor Red
        Remove-Item $rpuSrc -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Host ""
    Write-Host "  [2/3] Convert RPU (mode=$mode, target=$targetCodec)..." -ForegroundColor Cyan
    if (-not (Convert-RpuProfile -RpuIn $rpuSrc -RpuOut $rpuOut -Mode $mode -TargetCodec $targetCodec)) {
        Write-Host "  EROARE: Convert RPU esuat." -ForegroundColor Red
        Remove-Item $rpuSrc,$rpuOut -Force -ErrorAction SilentlyContinue
        return
    }

    $rawExt = if ($targetCodec -eq "av1") { "ivf" } else { "hevc" }
    $rawVideo = Join-Path $env:TEMP ("raw_"+[guid]::NewGuid().ToString("N")+".$rawExt")
    $injected = Join-Path $env:TEMP ("inj_"+[guid]::NewGuid().ToString("N")+".$rawExt")
    $outExt = [System.IO.Path]::GetExtension($file).TrimStart('.')
    $finalOut = Join-Path $OutputDir ("{0}_rpu{1}.{2}" -f [System.IO.Path]::GetFileNameWithoutExtension($file), $mode, $outExt)
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }

    Write-Host ""
    Write-Host "  [3/3] Inject RPU + re-mux..." -ForegroundColor Cyan
    if (-not (Get-RawVideo -InputFile $file -OutputFile $rawVideo -Codec $srcCodec)) {
        Write-Host "  EROARE: Extract raw video esuat." -ForegroundColor Red
        Remove-Item $rpuSrc,$rpuOut,$rawVideo -Force -ErrorAction SilentlyContinue
        return
    }
    if (-not (Inject-DvRpu $rawVideo $rpuOut $injected -TargetCodec $targetCodec)) {
        Write-Host "  EROARE: Inject RPU esuat." -ForegroundColor Red
        Remove-Item $rpuSrc,$rpuOut,$rawVideo,$injected -Force -ErrorAction SilentlyContinue
        return
    }
    $contFlags = Get-ContainerFlags $outExt
    $args = @("-v","error","-i",$injected,"-i",$file,
              "-map","0:v:0","-map","1:a","-map","1:s?","-map","1:t?",
              "-c","copy") + $contFlags + @($finalOut)
    & ffmpeg @args 2>$null
    $rc = $LASTEXITCODE
    Remove-Item $rpuSrc,$rpuOut,$rawVideo,$injected -Force -ErrorAction SilentlyContinue
    if ($rc -eq 0 -and (Test-Path $finalOut) -and (Get-Item $finalOut).Length -gt 0) {
        Write-Host ""
        Write-Host "  ✓ Transform RPU complet: $finalOut" -ForegroundColor Green
    } else {
        Write-Host "  EROARE: Re-mux final esuat." -ForegroundColor Red
        Remove-Item $finalOut -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-InspectMetadata {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  INSPECT METADATA                            ║" -ForegroundColor Cyan
    Write-Host "║  Dump RPU + HDR10+ info, read-only.          ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $file = _Hdv-PickFile -Prompt "Alege fisier"
    if (-not $file) { Write-Host "Anulat." -ForegroundColor Yellow; return }
    $srcCodec = Get-SourceCodec $file
    Write-Host ""
    Write-Host "  Codec sursa: $srcCodec"
    Write-Host "  Container:   $([System.IO.Path]::GetExtension($file).TrimStart('.'))"

    Write-Host ""
    Write-Host "── ffprobe summary ──" -ForegroundColor Cyan
    & ffprobe -v error -show_entries stream=index,codec_name,codec_type,width,height,pix_fmt,color_transfer,color_primaries,color_space,r_frame_rate -of compact=p=1:nk=0 $file 2>&1 | Select-Object -First 20

    if (Test-DoviToolFor -Codec $srcCodec) {
        $doviBin = Get-ToolForExtract -Codec $srcCodec -Kind "dovi"
        $rpuTmp = Join-Path $env:TEMP ("rpu_"+[guid]::NewGuid().ToString("N")+".bin")
        if (Get-DvRpu -InputFile $file -RpuOut $rpuTmp -SourceCodec $srcCodec) {
            Write-Host ""
            Write-Host "── DV RPU info ($doviBin) ──" -ForegroundColor Cyan
            & $doviBin info -i $rpuTmp 2>&1 | Select-Object -First 30
        } else {
            Write-Host ""
            Write-Host "── DV: nu am putut extrage RPU (probabil sursa nu este DV) ──" -ForegroundColor DarkGray
        }
        Remove-Item $rpuTmp -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host ""
        Write-Host "── DV: tool negasit pentru codec=$srcCodec ──" -ForegroundColor DarkGray
    }

    if (Test-Hdr10PlusToolFor -Codec $srcCodec) {
        $hpBin = Get-ToolForExtract -Codec $srcCodec -Kind "hdr10plus"
        $hpJson = Extract-Hdr10PlusMetadata $file
        if ($hpJson -and (Test-Path $hpJson)) {
            $scenes = (Select-String -Path $hpJson -Pattern "BezierCurveData|TargetedSystemDisplay" -AllMatches).Matches.Count
            Write-Host ""
            Write-Host "── HDR10+ ($hpBin) ──" -ForegroundColor Cyan
            Write-Host "  Scene descriptors: $scenes"
            Remove-Item $hpJson -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host ""
            Write-Host "── HDR10+: nu am detectat metadata dinamica ──" -ForegroundColor DarkGray
        }
    }
}

# v45: HDR10+ → DV hybrid (no re-encode) — sintetizeaza DV RPU din HDR10+
# metadata si il injecteaza in bitstream-ul existent. Acopera HEVC + AV1.
function Invoke-Hdr10PlusToDv {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  HDR10+ → DV HYBRID (no re-encode)           ║" -ForegroundColor Cyan
    Write-Host "║  Sintetizeaza DV RPU din HDR10+ metadata     ║" -ForegroundColor Cyan
    Write-Host "║  si il injecteaza in bitstream existent.     ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $file = _Hdv-PickFile -Prompt "Alege fisier sursa (cu HDR10+)"
    if (-not $file) { Write-Host "Anulat." -ForegroundColor Yellow; return }
    $srcCodec = Get-SourceCodec $file
    Write-Host "  Codec sursa: $srcCodec"

    if ($srcCodec -ne "hevc" -and $srcCodec -ne "av1") {
        Write-Host "  EROARE: Doar HEVC si AV1 sunt suportate (sursa: $srcCodec)." -ForegroundColor Red
        return
    }
    if (-not (Test-Hdr10PlusToolFor -Codec $srcCodec)) {
        $hp = if ($srcCodec -eq "av1") { "av1hdr10plus_tool" } else { "hdr10plus_tool" }
        Write-Host "  EROARE: $hp nu este instalat (necesar pt sursa $srcCodec)." -ForegroundColor Red
        return
    }
    if (-not (Test-DoviToolFor -Codec $srcCodec)) {
        $dv = if ($srcCodec -eq "av1") { "av1dovi_tool" } else { "dovi_tool" }
        Write-Host "  EROARE: $dv nu este instalat (necesar pt sinteza DV RPU)." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "  [1/4] Extract HDR10+ JSON..." -ForegroundColor Cyan
    $hpJson = Extract-Hdr10PlusMetadata $file
    if (-not $hpJson -or -not (Test-Path $hpJson) -or (Get-Item $hpJson).Length -eq 0) {
        Write-Host "  EROARE: Extract HDR10+ esuat (sursa nu are metadata dinamica?)." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "  [2/4] Sintetizez DV RPU din HDR10+..." -ForegroundColor Cyan
    $rpuOut = Generate-DvRpuFromHdr10Plus -hdr10plusJson $hpJson -TargetCodec $srcCodec
    if (-not $rpuOut -or -not (Test-Path $rpuOut) -or (Get-Item $rpuOut).Length -eq 0) {
        Write-Host "  EROARE: Sinteza DV RPU esuata." -ForegroundColor Red
        Remove-Item $hpJson -Force -ErrorAction SilentlyContinue
        return
    }

    $rawExt = if ($srcCodec -eq "av1") { "ivf" } else { "hevc" }
    $rawVideo = Join-Path $env:TEMP ("raw_"+[guid]::NewGuid().ToString("N")+".$rawExt")
    $injected = Join-Path $env:TEMP ("inj_"+[guid]::NewGuid().ToString("N")+".$rawExt")

    Write-Host ""
    Write-Host "  [3/4] Extract raw video ($srcCodec) + inject RPU..." -ForegroundColor Cyan
    if (-not (Get-RawVideo -InputFile $file -OutputFile $rawVideo -Codec $srcCodec)) {
        Write-Host "  EROARE: Extract raw video esuat." -ForegroundColor Red
        Remove-Item $hpJson,$rpuOut,$rawVideo -Force -ErrorAction SilentlyContinue
        return
    }
    if (-not (Inject-DvRpu $rawVideo $rpuOut $injected -TargetCodec $srcCodec)) {
        Write-Host "  EROARE: Inject RPU esuat." -ForegroundColor Red
        Remove-Item $hpJson,$rpuOut,$rawVideo,$injected -Force -ErrorAction SilentlyContinue
        return
    }

    $outExt = [System.IO.Path]::GetExtension($file).TrimStart('.')
    $finalOut = Join-Path $OutputDir ("{0}_dvhybrid.{1}" -f [System.IO.Path]::GetFileNameWithoutExtension($file), $outExt)
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    $contFlags = Get-ContainerFlags $outExt

    Write-Host ""
    Write-Host "  [4/4] Re-mux final..." -ForegroundColor Cyan
    $args = @("-v","error","-i",$injected,"-i",$file,
              "-map","0:v:0","-map","1:a","-map","1:s?","-map","1:t?",
              "-c","copy") + $contFlags + @($finalOut)
    & ffmpeg @args 2>$null
    $rc = $LASTEXITCODE
    Remove-Item $hpJson,$rpuOut,$rawVideo,$injected -Force -ErrorAction SilentlyContinue
    if ($rc -eq 0 -and (Test-Path $finalOut) -and (Get-Item $finalOut).Length -gt 0) {
        $label = if ($srcCodec -eq "av1") { "DV P10 + HDR10 + HDR10+ (AV1)" } else { "DV 8.1 + HDR10 + HDR10+ (HEVC)" }
        Write-Host ""
        Write-Host "  ✓ HDR10+ → DV hybrid complet: $finalOut" -ForegroundColor Green
        Write-Host "    $label" -ForegroundColor DarkGray
    } else {
        Write-Host "  EROARE: Re-mux final esuat." -ForegroundColor Red
        Remove-Item $finalOut -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-HdrDvTools {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  HDR/DV TOOLS                        ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  1) Transform RPU profile            ║"
    Write-Host "║     (cross-codec convert, no encode) ║"
    Write-Host "║  2) Inspect metadata (read-only)     ║"
    Write-Host "║  3) HDR10+ → DV hybrid (no re-encode)║"
    Write-Host "║  4) Inapoi                           ║"
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "  Nota: Remux container e acum in 'Mux tools' (opt 7 meniu principal)." -ForegroundColor DarkGray
    $ch = Read-Host "Alege 1-4"
    switch ($ch) {
        "1" { Invoke-TransformRpu }
        "2" { Invoke-InspectMetadata }
        "3" { Invoke-Hdr10PlusToDv }
        "4" { return }
        default { Write-Host "Optiune invalida." -ForegroundColor Red }
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

# ── Show-HLGDialog — v39: ANALIZA SURSA HLG (BT.2100 HLG) per fisier ──
# Return: "hlg_native" | "hlg_to_hdr10" | "hlg_to_sdr" | "copy" | "skip"
function Show-HLGDialog {
    param([string]$file, [string]$filename, [string]$encoderType)
    $w = Get-FFprobeValue $file "v:0" "width"
    $h = Get-FFprobeValue $file "v:0" "height"
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  ANALIZA SURSA — HLG (BT.2100 HLG)           ║" -ForegroundColor Cyan
    Write-Host ("  ║  Fisier: {0,-37}║" -f $filename) -ForegroundColor White
    Write-Host ("  ║  Sursa : HLG 10-bit {0,-25}║" -f "${w}x${h}") -ForegroundColor White
    Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "  ║  1) Encodeaza HLG nativ (recomandat)         ║" -ForegroundColor White
    Write-Host "  ║  2) Converteste la HDR10 (PQ)                ║" -ForegroundColor White
    Write-Host "  ║  3) Tonemap la SDR (Rec.709)                 ║" -ForegroundColor White
    Write-Host "  ║  4) Stream copy video                        ║" -ForegroundColor White
    Write-Host "  ║  5) Sari acest fisier                        ║" -ForegroundColor White
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    $ch = Read-Host "  Alege 1-5 [implicit: 1]"
    switch ($ch) {
        "2" { Write-Host "  Ales: HLG → HDR10 (PQ)" -ForegroundColor Green; return "hlg_to_hdr10" }
        "3" { Write-Host "  Ales: HLG → SDR tonemap" -ForegroundColor Green; return "hlg_to_sdr" }
        "4" { Write-Host "  Ales: Stream copy video" -ForegroundColor Green; return "copy" }
        "5" { Write-Host "  Sarit de utilizator" -ForegroundColor DarkYellow; return "skip" }
        default { Write-Host "  Ales: HLG nativ" -ForegroundColor Green; return "hlg_native" }
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
    $hlgLutResult = Find-HlgLutForBrand $cameraMake $InputDir
    $hasHlgLut = ($hlgLutResult.files.Count -gt 0)
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
    $optLut = 0; $optSdr = 0; $optHdr = 0; $optHlgLut = 0; $optHlg = 0; $optPreserve = 0; $optCopy = 0; $optSkip = 0

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
        if ($hasHlgLut) {
            $optHlgLut = $optNum
            if ($hlgLutResult.files.Count -eq 1) {
                Write-Host ("  ║  {0}) Apply LUT Log→HLG → 10-bit BT.2100      ║" -f $optNum) -ForegroundColor White
                Write-Host ("  ║     [✓ {0,-38}]║" -f $hlgLutResult.files[0].Name) -ForegroundColor DarkGray
            } else {
                Write-Host ("  ║  {0}) Apply LUT Log→HLG → 10-bit BT.2100      ║" -f $optNum) -ForegroundColor White
                Write-Host ("  ║     [{0} HLG LUT-uri gasite — selectie]        ║" -f $hlgLutResult.files.Count) -ForegroundColor DarkGray
            }
            $optNum++
        }
        $optHlg = $optNum
        Write-Host ("  ║  {0}) Convert HLG (fara LUT) → 10-bit         ║" -f $optNum) -ForegroundColor White
        Write-Host "  ║     BT.2020 / HLG (arib-std-b67)             ║" -ForegroundColor DarkGray
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
    elseif ($logChoice -eq $optHlgLut -and $optHlgLut -gt 0) {
        # v39: Apply LUT Log → HLG
        $selectedHlgLut = $null
        if ($hlgLutResult.files.Count -eq 1) {
            $selectedHlgLut = $hlgLutResult.files[0].FullName
        } else {
            Write-Host ""
            Write-Host "  HLG LUT-uri disponibile:" -ForegroundColor Cyan
            for ($hi = 0; $hi -lt $hlgLutResult.files.Count; $hi++) {
                Write-Host "  $($hi+1)) $($hlgLutResult.files[$hi].Name)" -ForegroundColor White
            }
            $hlgSel = Read-Host "  Alege HLG LUT [implicit: 1]"
            if (-not $hlgSel) { $hlgSel = "1" }
            if ($hlgSel -match '^\d+$' -and [int]$hlgSel -ge 1 -and [int]$hlgSel -le $hlgLutResult.files.Count) {
                $selectedHlgLut = $hlgLutResult.files[[int]$hlgSel - 1].FullName
            } else {
                $selectedHlgLut = $hlgLutResult.files[0].FullName
            }
        }
        Write-Host "  LOG: Apply HLG LUT — $(Split-Path -Leaf $selectedHlgLut)" -ForegroundColor Green
        $script:selectedLutPath = $selectedHlgLut
        $hlgLutEscaped = $selectedHlgLut -replace '\\','/'
        $script:logVideoFilter = "lut3d='$hlgLutEscaped',format=yuv420p10le"
        $script:logPixFmt = "yuv420p10le"
        $script:logColorFlags = @("-color_primaries","bt2020","-color_trc","arib-std-b67","-colorspace","bt2020nc")
        if ($encoderType -eq "x265") {
            $script:logExtraX265 = "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc"
        }
        return "hlg"
    }
    elseif ($logChoice -eq $optHlg -and $optHlg -gt 0) {
        # v39: Convert HLG (no LUT) — best-effort
        Write-Host "  LOG: Convert HLG (best-effort, fara LUT)" -ForegroundColor Green
        $script:logVideoFilter = "zscale=t=linear:npl=1000,zscale=t=arib-std-b67:p=bt2020:m=bt2020nc:r=tv,format=yuv420p10le"
        $script:logPixFmt = "yuv420p10le"
        $script:logColorFlags = @("-color_primaries","bt2020","-color_trc","arib-std-b67","-colorspace","bt2020nc")
        if ($encoderType -eq "x265") {
            $script:logExtraX265 = "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc"
        }
        return "hlg"
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
        [datetime]$startTime,
        [string]$Label = "Progres"
    )
    $initialized = $false
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 500
        if (-not (Test-Path $progFile)) {
            if (-not $initialized) {
                Write-Host -NoNewline ("`r  {0}: se initializeaza...                                 " -f $Label)
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
        $etaStr = "{0:D2}:{1:D2}:{2:D2}" -f ([int]($eta/3600)), ([int](($eta%3600)/60)), [int]($eta%60)
        Write-Host -NoNewline ("`r  {0}: {1,3}% | FPS: {2,5} | ETA: {3}   " -f $Label, $pct, $fpsStr, $etaStr)
    }
    Write-Host ""
    if (Test-Path $progFile) { Remove-Item $progFile -Force -ErrorAction SilentlyContinue }
}

# v37: Reusable helper — rulează ffmpeg cu progress bar + label custom.
# Folosit de Trim/Concat/Pipeline cu durata totală explicită.
# Parameters:
#   -Label          (string) — ex "Pass 3/3", "Trim seg1"
#   -TotalSeconds   (int)    — durata totală (0 = initializing permanent)
#   -Arguments      (string[]) — args ffmpeg (fara -progress / -nostats)
# Return: exit code ffmpeg
function Invoke-FfmpegWithProgress {
    param(
        [string]$Label,
        [int]$TotalSeconds,
        [string[]]$Arguments
    )
    $progFile = [System.IO.Path]::GetTempFileName()
    $errFile  = "$env:TEMP\fferr_$PID.txt"
    $allArgs  = @("-progress", $progFile, "-nostats") + $Arguments
    $proc = Start-Process -FilePath ffmpeg -ArgumentList $allArgs -NoNewWindow -PassThru `
        -RedirectStandardError $errFile
    $startTime = Get-Date
    Show-Progress -proc $proc -progFile $progFile -durSec $TotalSeconds -startTime $startTime -Label $Label
    $proc.WaitForExit()
    $rc = $proc.ExitCode
    if ($rc -ne 0 -and (Test-Path $errFile)) {
        Write-Host "  ⚠ ffmpeg exit code $rc — ultimele linii stderr:" -ForegroundColor Yellow
        Get-Content $errFile -Tail 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    if (Test-Path $progFile) { Remove-Item $progFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $errFile)  { Remove-Item $errFile  -Force -ErrorAction SilentlyContinue }
    return $rc
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
$inputFiles = Get-ChildItem -Path (Join-Path $InputDir '*') -Include "*.mp4","*.mov","*.mkv","*.m2ts","*.mts","*.vob","*.mxf","*.apv" -File
$fileCount  = $inputFiles.Count
$totalSz    = ($inputFiles | Measure-Object -Property Length -Sum).Sum
Write-Host "INPUT: $InputDir | Fisiere: $fileCount | $(Format-Bytes $totalSz)" -ForegroundColor Yellow
if ($fileCount -eq 0) { Write-Host "Nu am gasit fisiere." -ForegroundColor Red; Read-Host; exit }

# ══════════════════════════════════════════════════════════════════════
# Meniu principal INAINTE de configurarea encoderului
# Daca utilizatorul alege Verifica sau Iesire, nu mai parcurge intrebarile
# ══════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "1-Encode video+audio  2-Encode doar audio (video copy)  3-Verifica media  4-Telemetrie video  5-Import GPS extern  6-Trim & Concat  7-Mux tools (remux/demux)  8-HDR/DV tools  9-Burn-in (HUD/SRT/ASS/Image)  10-Iesire" -ForegroundColor Cyan
$mainChoice = Read-Host "Selecteaza"
if ($mainChoice -eq "10") { exit }
if ($mainChoice -eq "8") { Invoke-HdrDvTools; exit }
if ($mainChoice -eq "7") {
    $muxScript = Join-Path $PSScriptRoot "av_mux.ps1"
    if (-not (Test-Path $muxScript)) {
        Write-Host "[EROARE] av_mux.ps1 nu a fost gasit langa av_encode.ps1" -ForegroundColor Red
        exit 1
    }
    & pwsh -NoProfile -File $muxScript
    exit $LASTEXITCODE
}
if ($mainChoice -eq "9") {
    $burninScript = Join-Path $PSScriptRoot "av_burnin.ps1"
    if (-not (Test-Path $burninScript)) {
        Write-Host "[EROARE] av_burnin.ps1 nu a fost gasit langa av_encode.ps1" -ForegroundColor Red
        exit 1
    }
    & pwsh -NoProfile -File $burninScript
    exit $LASTEXITCODE
}

# ── Import GPS extern (GPX/FIT/KML → CSV/SRT) ─────────────────────
# v40: logica mutata in av_extractor_gps.ps1 (paritate cu av_extractor_gps.sh)
if ($mainChoice -eq "5") {
    $extScript = Join-Path $PSScriptRoot "av_extractor_gps.ps1"
    if (-not (Test-Path $extScript)) {
        Write-Host "[EROARE] av_extractor_gps.ps1 nu a fost gasit langa av_encode.ps1" -ForegroundColor Red
        Read-Host; exit
    }
    & $extScript
    exit
}


# ── Telemetrie video (DJI/GoPro/...) ─────────────────────────────────
# v40: logica mutata in av_telemetry.ps1 (paritate cu av_telemetry.sh)
if ($mainChoice -eq "4") {
    $extScript = Join-Path $PSScriptRoot "av_telemetry.ps1"
    if (-not (Test-Path $extScript)) {
        Write-Host "[EROARE] av_telemetry.ps1 nu a fost gasit langa av_encode.ps1" -ForegroundColor Red
        Read-Host; exit
    }
    & $extScript
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
    $outFiles = Get-ChildItem -Path (Join-Path $OutputDir '*') -Include "*.mp4","*.mov","*.mkv","*.mxf","*.webm" -File -ErrorAction SilentlyContinue
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

# ══════════════════════════════════════════════════════════════════════
# TRIM & CONCAT (v36) — Submeniu + Flows
# ══════════════════════════════════════════════════════════════════════
if ($mainChoice -eq "6") {
    # v36: curatenie temp rezidual la intrare
    Invoke-TcTempCleanupPrompt
    Write-Host ""
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  TRIM & CONCAT                       ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  1) Trim clip (un fisier)            ║" -ForegroundColor White
    Write-Host "║  2) Concat clips (unire)             ║" -ForegroundColor White
    Write-Host "║  3) Trim + Concat + Encode           ║" -ForegroundColor White
    Write-Host "║  4) Batch trim (N fisiere, cuts comune)" -ForegroundColor White
    Write-Host "║  5) Inapoi                           ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
    $tcChoice = Read-Host "Alege 1-5"
    switch ($tcChoice) {
        "1" { Invoke-TrimFlow }
        "2" { Invoke-ConcatFlow }
        "3" { Invoke-PipelineFlow }
        "4" { Invoke-BatchTrimFlow }
        "5" { Write-Host "Inapoi." -ForegroundColor Gray }
        default { Write-Host "Optiune invalida." -ForegroundColor Red }
    }
    Read-Host "Apasa Enter"; exit
}

# v35: Detectie GPU o singura data la startul fluxului de encode
$gpuCaps = Get-GPUCapabilities
Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  GPU DETECTAT                                ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
if ($gpuCaps.gpus.Count -eq 0) {
    if ($gpuCaps.isVM) {
        Write-Host "║  Mediu virtual (VM/RDP) — fara GPU fizic     ║" -ForegroundColor Yellow
    } else {
        Write-Host "║  Niciun GPU fizic detectat                   ║" -ForegroundColor Yellow
    }
    Write-Host "║  HW Encode: indisponibil (doar SW)           ║" -ForegroundColor Yellow
} else {
    foreach ($g in $gpuCaps.gpus) {
        $nm = $g.name
        if ($nm.Length -gt 44) { $nm = $nm.Substring(0, 44) }
        Write-Host ("║  {0,-44}  ║" -f $nm) -ForegroundColor White
    }
    Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  HW Encode disponibil:                       ║" -ForegroundColor Cyan
    $h264List = @()
    if ($gpuCaps.h264Support.nvidia) { $h264List += "NVENC" }
    if ($gpuCaps.h264Support.intel)  { $h264List += "QSV" }
    if ($gpuCaps.h264Support.amd)    { $h264List += "AMF" }
    $h265List = @()
    if ($gpuCaps.h265Support.nvidia) { $h265List += "NVENC" }
    if ($gpuCaps.h265Support.intel)  { $h265List += "QSV" }
    if ($gpuCaps.h265Support.amd)    { $h265List += "AMF" }
    $av1List = @()
    if ($gpuCaps.av1Support.nvidia) { $av1List += "NVENC" }
    if ($gpuCaps.av1Support.intel)  { $av1List += "QSV" }
    if ($gpuCaps.av1Support.amd)    { $av1List += "AMF" }
    $h264Str = if ($h264List.Count) { $h264List -join ", " } else { "-" }
    $h265Str = if ($h265List.Count) { $h265List -join ", " } else { "-" }
    $av1Str  = if ($av1List.Count)  { $av1List  -join ", " } else { "- (GPU nu suporta)" }
    Write-Host ("║  H.264: {0,-37}  ║" -f $h264Str) -ForegroundColor White
    Write-Host ("║  H.265: {0,-37}  ║" -f $h265Str) -ForegroundColor White
    Write-Host ("║  AV1  : {0,-37}  ║" -f $av1Str)  -ForegroundColor White
}
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan

# ══════════════════════════════════════════════════════════════════════
# v43 — Profile schema + validation (mirror al av_common.sh::validate_profile)
# ══════════════════════════════════════════════════════════════════════
function Get-ProfileSchema {
    param([string]$Key)
    switch ($Key) {
        'ENCODER_NAME'         { 'enum:libx265,libx264,av1,dnxhr,prores,apv,hwenc'; return }
        'ENCODER'              { 'enum:libx265,libx264,av1,dnxhr,prores,apv,hwenc'; return }
        'AV1_ENCODER_NAME'     { 'enum:,libsvtav1,libaom-av1'; return }
        'AV1_IMPL'             { 'enum:,libsvtav1,libaom-av1'; return }
        'DNXHR_PROFILE'        { 'enum:,lb,sq,hq,hqx,444'; return }
        'APV_PROFILE'          { 'enum:,light,standard,high,422_10,444_10'; return }
        'PRORES_PROFILE'       { 'enum:,proxy,lt,standard,hq,4444,4444xq'; return }
        'X264_PROFILE'         { 'enum:,auto,high,high10,high422'; return }
        'CONTAINER'            { 'enum:mkv,mp4,mov,mxf,webm'; return }
        'HW_ENC_CODEC'         { 'enum:,hevc_nvenc,h264_nvenc,av1_nvenc,hevc_qsv,h264_qsv,av1_qsv,hevc_amf,h264_amf,av1_amf'; return }
        'HW_BACKEND'           { 'enum:,sw,nvenc,vaapi,qsv,videotoolbox,amf,mediacodec'; return }
        'HW_PRESET_SLOT'       { 'enum:,1,2,3,4,5,6,7'; return }
        'HW_HDR_POLICY'        { 'enum:,sw_full,sw_degraded,hw_hdr10,hw_hlg,hw_sdr,hw_repair,hw_preserve,skip'; return }
        'MEDIACODEC_HDR_POLICY'{ 'enum:,sw_full,sw_degraded,hw_repair,hw_hlg,hw_sdr,hw_preserve,skip'; return }
        'DOVI_PRESERVE_POLICY' { 'enum:,auto,preserve,convert,copy,skip'; return }
        'HW_FORCE'             { 'enum:0,1'; return }
        'AUDIO_NORMALIZE'      { 'enum:0,1'; return }
        'ENCODE_MODE'          { 'enum:1,2,3'; return }
        'FORCE_LOG_DETECTION'  { 'enum:0,1'; return }
        'INTERACTIVE_MODE'     { 'enum:0,1'; return }
        'LOG_PROFILE'          { 'enum:,apple_log,samsung_log,dlog_m'; return }
        'FPS_METHOD'           { 'enum:,drop,minterpolate'; return }
        'VIDEO_FILTER_PRESET'  { 'regex:^(denoise_light|denoise_medium|denoise_strong|sharpen_light|sharpen_medium|deinterlace|upscale_4k|vidstab|custom:.*)?$'; return }
        'VF_PRESET'            { 'regex:^(denoise_light|denoise_medium|denoise_strong|sharpen_light|sharpen_medium|deinterlace|upscale_4k|vidstab|custom:.*|scale=.*)?$'; return }
        'AUDIO_CODEC_ARG'      { 'regex:^(copy|aac:[0-9]+k|opus:[0-9]+k|flac:[0-9]+|eac3:[0-9]+k|ac3:[0-9]+k)?$'; return }
        'AUDIO_CODEC'          { 'enum:,aac,opus,flac,eac3,ac3,pcm,copy'; return }
        'AUDIO_BITRATE'        { 'regex:^([0-9]+k)?$'; return }
        'AUDIO_COPY'           { 'enum:0,1'; return }
        'AUDIO_FLAC_LEVEL'     { 'regex:^([0-9]{1,2})?$'; return }
        'PCM_DEPTH'            { 'enum:,16le,24le,32le,16be,24be,32be'; return }
        'SCALE_WIDTH'          { 'regex:^([0-9]{2,5})?$'; return }
        'TARGET_FPS'           { 'regex:^([0-9]+(\.[0-9]+)?|[0-9]+/[0-9]+)?$'; return }
        'CRF_PARAM'            { 'regex:^([0-9]+)?$'; return }
        'CUSTOM_CRF'           { 'regex:^([0-9]+)?$'; return }
        'PRESET_PARAM'         { 'regex:^(ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow|[1-9])?$'; return }
        'PRESET'               { 'regex:^(ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow|[1-9])?$'; return }
        'TUNE_PARAM'           { 'regex:^(animation|grain|film|stillimage|fastdecode|[0-9]{1,2})?$'; return }
        'TUNE'                 { 'regex:^(animation|grain|film|stillimage|fastdecode|[0-9]{1,2})?$'; return }
        'VBR_PARAM'            { 'regex:^([0-9]+[kMmKgG]?)?$'; return }
        'VBR_TARGET'           { 'regex:^([0-9]+[kMmKgG]?)?$'; return }
        'VBR_MAXRATE'          { 'regex:^([0-9]+[kMmKgG]?)?$'; return }
        'VBR_BUFSIZE'          { 'regex:^([0-9]+[kMmKgG]?)?$'; return }
        'HW_ENC_QP'            { 'regex:^([0-9]+)?$'; return }
        'HW_ENC_PRESET'        { 'string:'; return }
        'EXTRA_PARAM'          { 'string:'; return }
        'EXTRA_PARAMS'         { 'string:'; return }
        'LUT_PATH'             { 'path:'; return }
        'EXTENDS'              { 'path:'; return }
        default                { ''; return }
    }
}

function Test-ProfileFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Host "  X Profil inexistent: $Path" -ForegroundColor Red
        return @{ ok = $false; errors = 1 }
    }
    $errors = 0
    $lineno = 0
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $lineno++
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*"?([^"]*)"?\s*$') {
            $key = $Matches[1]
            $value = $Matches[2]
            $schema = Get-ProfileSchema -Key $key
            if (-not $schema) {
                Write-Host "  ! [linia $lineno] cheie necunoscuta: $key (ignor)" -ForegroundColor DarkYellow
                continue
            }
            $stype = ($schema -split ':',2)[0]
            $sconstraint = ($schema -split ':',2)[1]
            switch ($stype) {
                'enum' {
                    $allowed = $sconstraint -split ','
                    if ($allowed -notcontains $value) {
                        Write-Host "  X [linia $lineno] $key=`"$value`" - valori permise: $sconstraint" -ForegroundColor Red
                        $errors++
                    }
                }
                'regex' {
                    if ($value -notmatch $sconstraint) {
                        Write-Host "  X [linia $lineno] $key=`"$value`" - nu corespunde pattern: $sconstraint" -ForegroundColor Red
                        $errors++
                    }
                }
                default { }
            }
        }
    }
    return @{ ok = ($errors -eq 0); errors = $errors }
}

# ──────────────────────────────────────────────────────────────────────
# v43 - EXTENDS chain helpers (single-parent inheritance)
# ──────────────────────────────────────────────────────────────────────
function Resolve-ExtendsPath {
    param(
        [string]$Ref,
        [string]$ChildDir
    )
    if ([string]::IsNullOrEmpty($Ref)) { return $null }
    $base = $Ref -replace '\.conf$',''

    # Absolute path
    if ([System.IO.Path]::IsPathRooted($Ref)) {
        foreach ($cand in @($Ref, "$Ref.conf")) {
            if (Test-Path -LiteralPath $cand -PathType Leaf) { return (Resolve-Path -LiteralPath $cand).Path }
        }
        return $null
    }

    # 1) Sibling
    if ($ChildDir -and (Test-Path -LiteralPath (Join-Path $ChildDir "$base.conf") -PathType Leaf)) {
        return (Resolve-Path -LiteralPath (Join-Path $ChildDir "$base.conf")).Path
    }
    # 2) UserProfiles
    if ($script:UserProfilesDir -and (Test-Path -LiteralPath (Join-Path $script:UserProfilesDir "$base.conf") -PathType Leaf)) {
        return (Resolve-Path -LiteralPath (Join-Path $script:UserProfilesDir "$base.conf")).Path
    }
    # 3) Builtin (root + 1-level subdirs)
    if ($script:ProfilesDir -and (Test-Path -LiteralPath $script:ProfilesDir)) {
        $rootCand = Join-Path $script:ProfilesDir "$base.conf"
        if (Test-Path -LiteralPath $rootCand -PathType Leaf) { return (Resolve-Path -LiteralPath $rootCand).Path }
        $sub = Get-ChildItem -LiteralPath $script:ProfilesDir -Directory -ErrorAction SilentlyContinue
        foreach ($d in $sub) {
            $cand = Join-Path $d.FullName "$base.conf"
            if (Test-Path -LiteralPath $cand -PathType Leaf) { return (Resolve-Path -LiteralPath $cand).Path }
        }
    }
    return $null
}

function Get-ExtendsField {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*EXTENDS\s*=\s*"?([^"]*)"?\s*$') {
            return $Matches[1]
        }
    }
    return $null
}

function Get-CanonicalPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return "" }
    try { $abs = [System.IO.Path]::GetFullPath($Path) } catch { $abs = $Path }
    # Windows + macOS APFS default = case-insensitive: normalize for cycle compare.
    return $abs.ToLowerInvariant()
}

# Returns @{ ok = $true/$false; chain = @(root..leaf); error = "..." }
function Build-ExtendsChain {
    param([string]$LeafPath)
    if ([string]::IsNullOrEmpty($LeafPath) -or -not (Test-Path -LiteralPath $LeafPath -PathType Leaf)) {
        $shown = if ([string]::IsNullOrEmpty($LeafPath)) { "<empty>" } else { $LeafPath }
        return @{ ok = $false; chain = @(); error = "EXTENDS: profil leaf inexistent: $shown" }
    }
    $chain = New-Object System.Collections.Generic.List[string]
    $visited = New-Object System.Collections.Generic.List[string]
    $current = [System.IO.Path]::GetFullPath($LeafPath)
    $depth = 0; $maxDepth = 5

    while ($current) {
        if ($depth -ge $maxDepth) {
            return @{ ok = $false; chain = @(); error = "EXTENDS: depasire adancime maxima ($maxDepth) - verifica $current" }
        }
        $canon = Get-CanonicalPath $current
        if ($visited -contains $canon) {
            return @{ ok = $false; chain = @(); error = "EXTENDS: ciclu detectat la $current" }
        }
        $visited.Add($canon) | Out-Null
        $chain.Insert(0, $current)  # prepend → root first

        $parentRef = Get-ExtendsField -Path $current
        if ([string]::IsNullOrEmpty($parentRef)) { break }

        $childDir = Split-Path -Parent $current
        $parentPath = Resolve-ExtendsPath -Ref $parentRef -ChildDir $childDir
        if (-not $parentPath) {
            return @{ ok = $false; chain = @(); error = "EXTENDS: parinte negasit '$parentRef' (referit din $([System.IO.Path]::GetFileName($current)))" }
        }
        $current = $parentPath
        $depth++
    }

    return @{ ok = $true; chain = @($chain); error = $null }
}

# ── Profil salvat (load) ─────────────────────────────────────────────
if (-not (Test-Path $UserProfilesDir)) { New-Item -ItemType Directory -Force -Path $UserProfilesDir | Out-Null }

# Colecteaza profile: user (UserProfiles/) + pre-definite (profiles/*/)
$userProfiles = @(Get-ChildItem -Path $UserProfilesDir -Filter "*.conf" -ErrorAction SilentlyContinue)
$builtinProfiles = @()
if (Test-Path $ProfilesDir) {
    $builtinProfiles = @(Get-ChildItem -Path $ProfilesDir -Filter "*.conf" -Recurse -ErrorAction SilentlyContinue)
}
$profiles = @($userProfiles) + @($builtinProfiles)
$profLoaded = $false

# Folder Luts pentru verificare LUT (definit sus)

# ── v52: AV_PROFILE env var (non-interactive profile auto-load pentru CI/cron) ──
# Acceptat formate: path absolut .conf / nume cu .conf / nume fara .conf
# Cautare: path direct -> UserProfiles\<name>.conf -> profiles\*\<name>.conf
$avProfileAuto = $false
if ($env:AV_PROFILE) {
    $avProfilePath = ""
    if (Test-Path -LiteralPath $env:AV_PROFILE -PathType Leaf) {
        $avProfilePath = (Resolve-Path -LiteralPath $env:AV_PROFILE).Path
    } elseif (Test-Path -LiteralPath "$($env:AV_PROFILE).conf" -PathType Leaf) {
        $avProfilePath = (Resolve-Path -LiteralPath "$($env:AV_PROFILE).conf").Path
    } else {
        $apName = [System.IO.Path]::GetFileNameWithoutExtension($env:AV_PROFILE)
        $candidate = Join-Path $UserProfilesDir "$apName.conf"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $avProfilePath = $candidate
        } elseif (Test-Path $ProfilesDir) {
            $found = Get-ChildItem -Path $ProfilesDir -Filter "$apName.conf" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $avProfilePath = $found.FullName }
        }
    }
    if (-not $avProfilePath) {
        Write-Host "EROARE: AV_PROFILE='$($env:AV_PROFILE)' nu a fost gasit" -ForegroundColor Red
        Write-Host "  Cautat in: path direct, UserProfiles\, profiles\*\" -ForegroundColor Red
        exit 1
    }
    Write-Host ""
    Write-Host "  ⓘ AV_PROFILE: auto-load $([System.IO.Path]::GetFileNameWithoutExtension($avProfilePath))" -ForegroundColor Cyan

    # Build EXTENDS chain + validate (paritate cu flow interactive)
    $chainRes = Build-ExtendsChain -LeafPath $avProfilePath
    if (-not $chainRes.ok) {
        Write-Host "EROARE: $($chainRes.error)" -ForegroundColor Red
        exit 1
    }
    $loadChain = $chainRes.chain
    $totalErrors = 0
    foreach ($link in $loadChain) {
        $vr = Test-ProfileFile -Path $link
        if (-not $vr.ok) { $totalErrors += $vr.errors }
    }
    if ($totalErrors -gt 0) {
        Write-Host "EROARE: AV_PROFILE='$($env:AV_PROFILE)' nu a trecut validarea schemei ($totalErrors erori)" -ForegroundColor Red
        exit 1
    }
    # Parse .conf (key=value) — root..leaf, leaf overrides parent
    foreach ($link in $loadChain) {
        Get-Content -LiteralPath $link | ForEach-Object {
            if ($_ -match '^([A-Za-z_]\w*)=(.*)$') {
                Set-Variable -Name $Matches[1] -Value $Matches[2] -Scope Script
            }
        }
    }
    $loadFile = $avProfilePath
    $avProfileAuto = $true
}

if ($profiles.Count -gt 0 -and -not $avProfileAuto) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Profile disponibile                  ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════╣" -ForegroundColor Cyan
    $pIdx = 1
    foreach ($pf in $profiles) {
        # Marcheaza profilele pre-definite cu [DJI] etc.
        if ($pf.DirectoryName.StartsWith((Join-Path $ProfilesDir "dji_action6"))) {
            Write-Host "║  $pIdx) [DJI] $($pf.BaseName)" -ForegroundColor White
        } else {
            Write-Host "║  $pIdx) $($pf.BaseName)" -ForegroundColor White
        }
        $pIdx++
    }
    Write-Host "║  N) Configurare noua (meniu normal)  ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
    $profChoice = Read-Host "Alege profil sau N [implicit: N]"
    if ($profChoice -match '^\d+$' -and [int]$profChoice -ge 1 -and [int]$profChoice -le $profiles.Count) {
        $loadFile = $profiles[[int]$profChoice - 1].FullName
        Write-Host "  Incarc profil: $($profiles[[int]$profChoice - 1].BaseName)" -ForegroundColor Green

        # v43: rezolva lant EXTENDS (root -> leaf)
        $chainRes = Build-ExtendsChain -LeafPath $loadFile
        if (-not $chainRes.ok) {
            Write-Host "  X $($chainRes.error)" -ForegroundColor Red
            Write-Host "  Profil anulat - continuam cu meniu normal." -ForegroundColor Yellow
            $loadFile = $null
        }
        if ($loadFile) {
            $loadChain = $chainRes.chain

            # v43: validare schema pentru fiecare link
            $totalErrors = 0
            foreach ($link in $loadChain) {
                $vr = Test-ProfileFile -Path $link
                if (-not $vr.ok) { $totalErrors += $vr.errors }
            }
            if ($totalErrors -gt 0) {
                Write-Host ""
                # Non-interactive guard: fail-fast in scripts/CI.
                $isNonInteractive = ($env:AV_NONINTERACTIVE -eq '1') -or [Console]::IsInputRedirected
                if ($isNonInteractive) {
                    Write-Host "  X Erori in profil/parinti - abort (mod non-interactiv)." -ForegroundColor Red
                    $loadFile = $null
                } else {
                    $cont = Read-Host "  Profilul (sau parintii) au erori. Continui oricum? (d/N)"
                    if ($cont -ine "d") {
                        Write-Host "  Profil anulat - continuam cu meniu normal." -ForegroundColor Yellow
                        $loadFile = $null
                    }
                }
            }
        }
        if ($loadFile) {
            if ($loadChain.Count -gt 1) {
                Write-Host "  Lant EXTENDS (root -> leaf):" -ForegroundColor Cyan
                $i = 1
                foreach ($link in $loadChain) {
                    Write-Host "    $i) $([System.IO.Path]::GetFileNameWithoutExtension($link))" -ForegroundColor White
                    $i++
                }
            }
            # Parse .conf (key=value) — root..leaf, leaf overrides parent
            foreach ($link in $loadChain) {
                Get-Content -LiteralPath $link | ForEach-Object {
                    if ($_ -match '^([A-Za-z_]\w*)=(.*)$') {
                        Set-Variable -Name $Matches[1] -Value $Matches[2] -Scope Script
                    }
                }
            }

        # Map ENCODER_NAME to ENCODER (bash profiles use ENCODER_NAME, ps1 uses ENCODER)
        if ($ENCODER_NAME -and -not $ENCODER) { $script:ENCODER = $ENCODER_NAME }

        # Verifica LUT daca profilul necesita unul
        if ($LUT_PATH) {
            $LutFullPath = Join-Path $LutsDir $LUT_PATH
            if (-not (Test-Path $LutFullPath)) {
                Write-Host ""
                Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
                Write-Host "  ║  ⚠ ATENTIE: LUT-ul nu a fost gasit!                       ║" -ForegroundColor Yellow
                Write-Host "  ╠══════════════════════════════════════════════════════════╣" -ForegroundColor Yellow
                Write-Host "  ║  Fisier: $LUT_PATH" -ForegroundColor White
                Write-Host "  ║  Locatie asteptata: $LutsDir\" -ForegroundColor White
                Write-Host "  ║                                                          ║" -ForegroundColor Yellow
                Write-Host "  ║  Descarca LUT-ul de pe dji.com si pune-l in:             ║" -ForegroundColor White
                Write-Host "  ║  $LutsDir\" -ForegroundColor White
                Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
                Write-Host ""
                $continueNoLut = Read-Host "  Continui fara LUT? (d/N)"
                if ($continueNoLut -ine "d") {
                    Write-Host "  Profil anulat — instaleaza LUT-ul si incearca din nou." -ForegroundColor Red
                    Read-Host "Apasa Enter"; exit
                }
                # Dezactiveaza LUT daca utilizatorul continua fara el
                $script:LUT_PATH = ""
                $script:FORCE_LOG_DETECTION = "0"
            } else {
                Write-Host "  LUT gasit: $LUT_PATH" -ForegroundColor Green
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
        $hwForce     = ($HW_FORCE -eq "1")

        # v35: Validare HW encoder din profil vs capabilitate GPU reala
        if ($useHWEnc -and $hwEncCodec) {
            $profVendor = switch -Regex ($hwEncCodec) { "nvenc" { "nvidia" } "qsv" { "intel" } "amf" { "amd" } default { "" } }
            $profCodec  = switch -Regex ($hwEncCodec) { "^hevc" { "h265Support" } "^h264" { "h264Support" } "^av1"  { "av1Support"  } default { "" } }
            $gpuOk = $false
            if ($profVendor -and $profCodec) { $gpuOk = [bool]$gpuCaps.$profCodec[$profVendor] }
            if (-not $gpuOk) {
                Write-Host ""
                Write-Host "  ⚠ Profil cere HW encoder '$hwEncCodec' — GPU-ul curent nu-l suporta." -ForegroundColor Yellow
                if ($hwForce) {
                    Write-Host "  HW_FORCE=1 — bypass validare, incerc oricum (encode-ul poate esua)." -ForegroundColor Yellow
                } else {
                    # Fallback la SW echivalent
                    $fallback = switch -Regex ($hwEncCodec) {
                        "^hevc" { "libx265" }
                        "^h264" { "libx264" }
                        "^av1"  { "libsvtav1" }
                        default { "libx265" }
                    }
                    Write-Host "  Fallback la software: $fallback (seteaza HW_FORCE=1 in profil pt bypass)" -ForegroundColor Yellow
                    $useHWEnc = $false
                    $hwEncCodec = ""; $hwEncName = ""; $hwEncPreset = ""
                    if ($fallback -eq "libx264")    { $useX264 = $true }
                    elseif ($fallback -eq "libsvtav1") { $useAV1 = $true; $av1Impl = "libsvtav1" }
                    # libx265 = default (niciun flag)
                }
            }
        }

        $encoderName = if ($useX264) { "libx264" } elseif ($useAV1) { "av1 ($av1Impl)" } elseif ($useDNxHR) { "dnxhr" } elseif ($useProRes) { "prores ($proresProfile)" } elseif ($useHWEnc) { $hwEncName } else { "libx265" }
        $outSuffix   = if ($useX264) { "_x264" } elseif ($useAV1) { "_av1" } elseif ($useDNxHR) { "_dnxhr" } elseif ($useProRes) { "_prores" } elseif ($useHWEnc) { "_hwenc" } else { "_x265" }
        $containerFlags = Get-ContainerFlags $container
        $LogFile = Join-Path $OutputDir "av_encode_log_$encoderName.txt"

        Write-Host "  Encoder      : $encoderName" -ForegroundColor White
        Write-Host "  Container    : $container" -ForegroundColor White
        Write-Host "  Audio        : $audioCodec $audioBitrate" -ForegroundColor White
        Write-Host "  Filtru video : $(if ($vfPreset) { $vfPreset } elseif ($vfIsVidstab) { 'vidstab' } else { 'fara' })" -ForegroundColor White
        Write-Host "  Normalizare  : $audioNormalize" -ForegroundColor White
        if ($LUT_PATH) {
            $logLabel = if ($LOG_PROFILE) { $LOG_PROFILE } else { "auto" }
            Write-Host "  LOG/LUT      : $logLabel + $LUT_PATH" -ForegroundColor Cyan
        }
        if ($forceLogDetection) { Write-Host "  Force LOG    : ACTIV" -ForegroundColor Yellow }
        if ($interactiveMode) { Write-Host "  Interactiv   : ACTIV" -ForegroundColor Green }
        $profConfirm = Read-Host "Lanseaza cu aceste setari? (D/n)"
        if ($profConfirm -ine "n") {
            $profLoaded = $true
        } else {
            Write-Host "  Profil anulat — continuam cu meniu normal." -ForegroundColor Yellow
        }
        }  # if ($loadFile)
    }
}

# ── v52: AV_PROFILE auto-confirm — bypass user confirm prompt + map vars ────
if ($avProfileAuto -and $loadFile) {
    # Map loaded conf vars la $script: (identic cu interactive load)
    if ($ENCODER_NAME -and -not $ENCODER) { $script:ENCODER = $ENCODER_NAME }
    # Verifica LUT (fail-fast — non-interactive)
    if ($LUT_PATH) {
        $LutFullPath = Join-Path $LutsDir $LUT_PATH
        if (-not (Test-Path $LutFullPath)) {
            Write-Host "EROARE: AV_PROFILE cere LUT '$LUT_PATH' dar lipseste din $LutsDir\" -ForegroundColor Red
            exit 1
        }
    }
    # Map vars (paritate cu blocul interactive ~line 4255-4292)
    $useX264   = ($ENCODER -eq "libx264")
    $useAV1    = ($ENCODER -eq "av1")
    $useDNxHR  = ($ENCODER -eq "dnxhr")
    $useProRes = ($ENCODER -eq "prores")
    $useHWEnc  = ($ENCODER -eq "hwenc")
    $av1Impl   = if ($AV1_IMPL) { $AV1_IMPL } else { "libsvtav1" }
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
    $hwForce     = ($HW_FORCE -eq "1")

    $encoderName = if ($useX264) { "libx264" } elseif ($useAV1) { "av1 ($av1Impl)" } elseif ($useDNxHR) { "dnxhr" } elseif ($useProRes) { "prores ($proresProfile)" } elseif ($useHWEnc) { $hwEncName } else { "libx265" }
    $outSuffix   = if ($useX264) { "_x264" } elseif ($useAV1) { "_av1" } elseif ($useDNxHR) { "_dnxhr" } elseif ($useProRes) { "_prores" } elseif ($useHWEnc) { "_hwenc" } else { "_x265" }
    $containerFlags = Get-ContainerFlags $container
    $LogFile = Join-Path $OutputDir "av_encode_log_$encoderName.txt"

    Write-Host "  AV_PROFILE auto-confirm — skip meniu, lansare directa" -ForegroundColor Cyan
    Write-Host "  Encoder      : $encoderName" -ForegroundColor White
    Write-Host "  Container    : $container" -ForegroundColor White
    Write-Host "  Mod          : $encMode $(if ($vbrTarget) { '(VBR ' + $vbrTarget + ')' } else { '' })" -ForegroundColor White
    $profLoaded = $true
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
    # v35: Catalog complet + cross-check cu $gpuCaps (GPU fizic detectat)
    $hwCatalog = @(
        @{id="hevc_nvenc"; label="NVIDIA NVENC H.265"; vendor="nvidia"; codec="hevc"}
        @{id="h264_nvenc"; label="NVIDIA NVENC H.264"; vendor="nvidia"; codec="h264"}
        @{id="av1_nvenc";  label="NVIDIA NVENC AV1";   vendor="nvidia"; codec="av1" }
        @{id="hevc_qsv";   label="Intel QSV H.265";    vendor="intel";  codec="hevc"}
        @{id="h264_qsv";   label="Intel QSV H.264";    vendor="intel";  codec="h264"}
        @{id="av1_qsv";    label="Intel QSV AV1";      vendor="intel";  codec="av1" }
        @{id="hevc_amf";   label="AMD AMF H.265";      vendor="amd";    codec="hevc"}
        @{id="h264_amf";   label="AMD AMF H.264";      vendor="amd";    codec="h264"}
        @{id="av1_amf";    label="AMD AMF AV1";        vendor="amd";    codec="av1" }
    )
    $hwUnavail = @()  # pentru mesaje informative
    foreach ($entry in $hwCatalog) {
        $inFfmpeg  = ($hwEncoders -match $entry.id)
        $supportKey = switch ($entry.codec) { "h264" { "h264Support" } "hevc" { "h265Support" } "av1" { "av1Support" } }
        $gpuOk = [bool]$gpuCaps.$supportKey[$entry.vendor]
        if ($inFfmpeg -and $gpuOk) {
            $hwAvail += $entry
        } elseif ($inFfmpeg -and -not $gpuOk) {
            # ffmpeg suporta dar GPU nu — adaugi la lista "indisponibil cu motiv"
            $reason = switch ($entry.vendor) {
                "nvidia" { if (-not $gpuCaps.hasNvidia) { "GPU NVIDIA absent" } else { "necesita RTX 40+ (Ada)" } }
                "intel"  { if (-not $gpuCaps.hasIntel)  { "GPU Intel absent" }  else { "necesita Arc/Core Ultra" } }
                "amd"    { if (-not $gpuCaps.hasAmd)    { "GPU AMD absent" }    else { "necesita RDNA3+ (RX 7000)" } }
            }
            $hwUnavail += @{ label=$entry.label; reason=$reason }
        }
    }
    if ($hwAvail.Count -eq 0) {
        Write-Host "║  NU s-au gasit encodere GPU compatibile!     ║" -ForegroundColor Red
        Write-Host "║  Necesita: NVIDIA GPU + drivers CUDA         ║" -ForegroundColor Yellow
        Write-Host "║           sau Intel iGPU + drivers QSV       ║" -ForegroundColor Yellow
        Write-Host "║           sau AMD GPU + drivers AMF          ║" -ForegroundColor Yellow
        if ($hwUnavail.Count -gt 0) {
            Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
            Write-Host "║  Indisponibil pe GPU-ul curent:              ║" -ForegroundColor DarkGray
            foreach ($u in $hwUnavail) {
                Write-Host ("║  - {0,-28} ({1})" -f $u.label, $u.reason) -ForegroundColor DarkGray
            }
        }
        Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
        Read-Host; exit
    }
    for ($hi = 0; $hi -lt $hwAvail.Count; $hi++) {
        Write-Host ("║  {0}) {1,-37}   ║" -f ($hi+1), $hwAvail[$hi].label) -ForegroundColor White
    }
    if ($hwUnavail.Count -gt 0) {
        Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
        foreach ($u in $hwUnavail) {
            Write-Host ("║  - {0,-28} ({1,-10})" -f $u.label, $u.reason) -ForegroundColor DarkGray
        }
    }
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
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

Write-Host ""
$isHwActive = $useHWEnc
if ($isHwActive) {
    Write-Host "Mod: 1-CRF [implicit]  2-VBR 1-pass" -ForegroundColor Cyan
    Write-Host "  ⓘ 2-pass dezactivat — HW backend activ nu suporta 2-pass." -ForegroundColor DarkGray
    $encMode = Read-Host "Alege [implicit: 1]"
    if ($encMode -notin @("1","2")) { $encMode = "1" }
} else {
    Write-Host "Mod: 1-CRF [implicit]  2-VBR 1-pass  3-VBR 2-pass" -ForegroundColor Cyan
    $encMode = Read-Host "Alege [implicit: 1]"
    if ($encMode -notin @("1","2","3")) { $encMode = "1" }
}
# Defensive: respinge mode=3 cu HW activ (profile bypass safety)
if ($encMode -eq "3" -and $isHwActive) {
    Write-Host "  ⚠ 2-pass nu e suportat pe HW backend — fallback la VBR 1-pass." -ForegroundColor Yellow
    $encMode = "2"
}
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
    $modeLabel = if ($encMode -eq "3") { "2-pass" } else { "1-pass" }
    $vi = Read-Host "VBR $modeLabel — Bitrate tinta (ex: 4000k, 4M)"
    if (-not (Test-BitrateFormat $vi)) { Write-Host "Format invalid!" -ForegroundColor Red; Read-Host; exit }
    $vbrTarget = $vi; $kbps = Convert-ToKbps $vi
    $vbrMaxrate = "$([int]($kbps*1.5))k"; $vbrBufsize = "$($kbps*2)k"
    Write-Host "  VBR $modeLabel : $vbrTarget / max $vbrMaxrate" -ForegroundColor Green
    $ov = Read-Host "Modifica maxrate/bufsize? (d/N)"
    if ($ov -ieq "d") {
        $mr = Read-Host "Maxrate"; $bs = Read-Host "Bufsize"
        if (Test-BitrateFormat $mr) { $vbrMaxrate = $mr }
        else { Write-Host "  AVERTISMENT: Maxrate invalid — se pastreaza $vbrMaxrate" -ForegroundColor Yellow }
        if (Test-BitrateFormat $bs) { $vbrBufsize = $bs }
        else { Write-Host "  AVERTISMENT: Bufsize invalid — se pastreaza $vbrBufsize" -ForegroundColor Yellow }
    }
    Write-Host "  VBR $modeLabel final: $vbrTarget / max $vbrMaxrate / buf $vbrBufsize" -ForegroundColor Green
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
        $profFile = Join-Path $UserProfilesDir "$profName.conf"
        # v43: confirm overwrite
        if (Test-Path -LiteralPath $profFile) {
            $ow = Read-Host "  Profilul exista deja. Suprascriu? (d/N)"
            if ($ow -ine "d") {
                Write-Host "  Anulat - profilul nu a fost suprascris." -ForegroundColor Yellow
                $profFile = $null
            }
        }
        if ($profFile) {
        $encShort = if ($useX264) { "libx264" } elseif ($useAV1) { "av1" } elseif ($useDNxHR) { "dnxhr" } elseif ($useProRes) { "prores" } elseif ($useHWEnc) { "hwenc" } else { "libx265" }
        $vfSave = if ($vfIsVidstab) { "vidstab" } elseif ($vfPreset) { $vfPreset } else { "" }
        $logProfileSave = if ($script:LOG_PROFILE) { $script:LOG_PROFILE } else { "" }
        $lutPathSave = if ($script:LUT_PATH) { $script:LUT_PATH } else { "" }
        @(
            "# AV Encoder Suite - Profil salvat: $profName"
            "# Generat: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "ENCODER=$encShort"
            "AV1_IMPL=$av1Impl"
            "DNXHR_PROFILE=$dnxhrProfile"
            "PRORES_PROFILE=$proresProfile"
            "X264_PROFILE=$x264ProfileGlobal"
            "HW_ENC_CODEC=$hwEncCodec"
            "HW_ENC_PRESET=$hwEncPreset"
            "HW_ENC_QP=$hwEncQP"
            "HW_FORCE=0"
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
            "LOG_PROFILE=$logProfileSave"
            "LUT_PATH=$lutPathSave"
            "INTERACTIVE_MODE=$(if ($interactiveMode) { '1' } else { '0' })"
            "DOVI_PRESERVE_POLICY=$(if ($env:DOVI_PRESERVE_POLICY) { $env:DOVI_PRESERVE_POLICY } else { '' })"
            "HW_HDR_POLICY=$(if ($env:HW_HDR_POLICY) { $env:HW_HDR_POLICY } else { '' })"
            "MEDIACODEC_HDR_POLICY=$(if ($env:MEDIACODEC_HDR_POLICY) { $env:MEDIACODEC_HDR_POLICY } else { '' })"
        ) | Out-File $profFile -Encoding UTF8
        Write-Host "  Profil salvat: $profFile" -ForegroundColor Green
        # v43: post-save validation feedback
        $valRes = Test-ProfileFile -Path $profFile
        if ($valRes.ok) {
            Write-Host "  Validare schema: OK" -ForegroundColor Green
        } else {
            Write-Host "  Validare schema: AVERTISMENT ($($valRes.errors) erori)" -ForegroundColor Yellow
        }
        }
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

# ── Pastrare structura foldere ────────────────────────────────────────
Write-Host ""
Write-Host "Pastrezi structura de foldere din input? (d/n) [implicit: n]" -ForegroundColor Cyan
Write-Host "  d = Scanare recursiva, output pastreaza structura subfoldere" -ForegroundColor DarkGray
Write-Host "  n = Toate fisierele in acelasi folder output" -ForegroundColor DarkGray
$folderStructChoice = Read-Host "Alege"
$preserveFolderStructure = ($folderStructChoice -ieq "d")
if ($preserveFolderStructure) {
    Write-Host "  Structura foldere: PASTRATA (recursiv)" -ForegroundColor Green
    "Structura foldere: PASTRATA" | Out-File $LogFile -Append -Encoding UTF8
    # Re-scan cu -Recurse
    $inputFiles = @(Get-ChildItem -Path $InputDir -Include "*.mp4","*.mov","*.mkv","*.m2ts","*.mts","*.vob","*.mxf","*.apv" -File -Recurse)
    $fileCount = $inputFiles.Count
    $subfolderCount = ($inputFiles | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique).Count
    Write-Host "  Gasite: $fileCount fisiere in $subfolderCount foldere" -ForegroundColor Yellow
} else {
    Write-Host "  Structura foldere: FLAT (toate in output/)" -ForegroundColor Yellow
    "Structura foldere: FLAT" | Out-File $LogFile -Append -Encoding UTF8
}

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

    # Calculeaza output path (cu sau fara structura foldere)
    if ($preserveFolderStructure) {
        # Calculeaza calea relativa fata de InputDir
        $relPath = $f.DirectoryName.Substring($InputDir.Length).TrimStart('\', '/')
        if ($relPath) {
            $outputSubdir = Join-Path $OutputDir $relPath
            if (-not (Test-Path $outputSubdir)) {
                New-Item -ItemType Directory -Force -Path $outputSubdir | Out-Null
            }
            $outFile = Join-Path $outputSubdir ($f.BaseName + $outSuffix + "." + $container)
        } else {
            $outFile = Join-Path $OutputDir ($f.BaseName + $outSuffix + "." + $container)
        }
    } else {
        $outFile = Join-Path $OutputDir ($f.BaseName + $outSuffix + "." + $container)
    }

    Write-Host "`n══════════════════════════════════════════" -ForegroundColor Cyan
    $outRelPath = $outFile.Substring($OutputDir.Length).TrimStart('\', '/')
    Write-Host "Procesam: $($f.Name) → $outRelPath" -ForegroundColor Yellow
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
    $keepDjmd = $true; $keepDbgi = $false; $keepTmcd = $true
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
            } else {
                $keepDjmd = $false; $keepDbgi = $false; $keepTmcd = $false
            }
        }
        # MKV: dialog selectie track-uri DJI in output
        if ($container -eq "mkv") {
            if ($dji.hasDbgi) {
                Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Yellow
                Write-Host "  ║  Track-uri DJI in output:                    ║" -ForegroundColor White
                Write-Host "  ║  1) Pastreaza tot                             ║" -ForegroundColor White
                Write-Host "  ║  2) Fara debug (dbgi ~295 MB) [recomandat]    ║" -ForegroundColor White
                Write-Host "  ║  3) Fara GPS/locatie (elimina djmd + dbgi)    ║" -ForegroundColor White
                Write-Host "  ║  4) Elimina tot (fara track-uri DJI)          ║" -ForegroundColor White
                Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Yellow
                $djiTrackChoice = Read-Host "  Alege 1-4 [implicit: 2]"
                if (-not $djiTrackChoice) { $djiTrackChoice = "2" }
                switch ($djiTrackChoice) {
                    "1" { $keepDjmd = $true;  $keepDbgi = $true;  $keepTmcd = $true  }
                    "3" { $keepDjmd = $false; $keepDbgi = $false; $keepTmcd = $true  }
                    "4" { $keepDjmd = $false; $keepDbgi = $false; $keepTmcd = $false }
                    default { $keepDjmd = $true;  $keepDbgi = $false; $keepTmcd = $true  }
                }
            } else {
                Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Yellow
                Write-Host "  ║  Track-uri DJI in output:                    ║" -ForegroundColor White
                Write-Host "  ║  1) Pastreaza tot [implicit]                  ║" -ForegroundColor White
                Write-Host "  ║  2) Fara GPS/locatie (elimina djmd)           ║" -ForegroundColor White
                Write-Host "  ║  3) Elimina tot (fara track-uri DJI)          ║" -ForegroundColor White
                Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Yellow
                $djiTrackChoice = Read-Host "  Alege 1-3 [implicit: 1]"
                if (-not $djiTrackChoice) { $djiTrackChoice = "1" }
                switch ($djiTrackChoice) {
                    "2" { $keepDjmd = $false; $keepDbgi = $false; $keepTmcd = $true  }
                    "3" { $keepDjmd = $false; $keepDbgi = $false; $keepTmcd = $false }
                    default { $keepDjmd = $true;  $keepDbgi = $false; $keepTmcd = $true  }
                }
            }
        }
        "DJI: djmd=$keepDjmd dbgi=$keepDbgi tmcd=$keepTmcd container=$container" | Out-File $LogFile -Append -Encoding UTF8
    }

    $mapFlags  = Get-DJIMapFlags $f.FullName $keepDjmd $keepDbgi $keepTmcd $dji $container
    $si        = Get-SourceInfo $f.FullName
    $width     = Get-FFprobeValue $f.FullName "v:0" "width"
    $height    = Get-FFprobeValue $f.FullName "v:0" "height"
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
    $is2Pass = ($encMode -eq "3")
    if ($encMode -eq "2" -or $encMode -eq "3") {
        $rateParams = @("-b:v",$vbrTarget,"-maxrate",$vbrMaxrate,"-bufsize",$vbrBufsize)
        if ($is2Pass) { Write-Host "  VBR 2-pass: $vbrTarget" -ForegroundColor White }
        else { Write-Host "  VBR 1-pass: $vbrTarget" -ForegroundColor White }
    } else {
        $crf = if ($customCrf) { [int]$customCrf }
               elseif ($useX264) { if ([int]$width -ge 3840){20}elseif([int]$width -ge 1920){19}else{18} }
               elseif ($useAV1)  { if ([int]$width -ge 3840){30}elseif([int]$width -ge 1920){28}else{26} }
               else              { if ([int]$width -ge 3840){22}elseif([int]$width -ge 1920){21}else{20} }
        $crfFlag = @("-crf",$crf)
        Write-Host "  CRF: $crf | ${width}px" -ForegroundColor White
    }

    # v51: VBV/Level suggestion (informational pe CRF, HRD-binding pe VBR/2-pass)
    $targetKbpsV = 0
    if ($encMode -eq "2" -or $encMode -eq "3") { $targetKbpsV = Get-BitrateKbps $vbrTarget }
    # $srcFpsDec si $height sunt computate mai sus in run loop (FPS section + sourceInfo)
    $srcFps = if ($srcFpsDec -and $srcFpsDec -gt 0) { [double]$srcFpsDec } else { 30.0 }
    $heightV = if ($height -and ([int]$height) -gt 0) { [int]$height } else { 1080 }
    $codecKey = if ($useX264) { "h264" } elseif ($useAV1) { "av1" } else { "hevc" }
    $vbvSug = Suggest-VbvForTarget -Codec $codecKey -TargetKbps $targetKbpsV -Width ([int]$width) -Height $heightV -Fps $srcFps
    $script:autoLevel = $vbvSug.Level
    $script:autoTier  = $vbvSug.Tier
    Write-Host "  $($codecKey.ToUpper()) level: $($vbvSug.Level) $($vbvSug.Tier.ToUpper()) tier" -ForegroundColor DarkGray
    # Reset 2-pass state per fisier
    Clear-2PassState
    # Reset HDR10 static state per fisier
    $script:hdr10StaticAvailable = $false
    $script:hdr10MasterDisplayX265 = ""
    $script:hdr10MasterDisplaySvtAv1 = ""
    $script:hdr10MaxCll = ""
    $script:hdr10StaticSource = ""

    $progFile  = Join-Path $env:TEMP ("ffprog_"+[guid]::NewGuid().ToString("N")+".txt")
    $startTime = Get-Date

    # ══════════════════════════════════════════════════════════════════
    # v32: LOG detect + per-file dialogs (portat din bash)
    # Ordinea: DV → HDR10+ → LOG → HLG → HDR10/SDR (identic cu SH)
    # ══════════════════════════════════════════════════════════════════
    $logInfo = Get-SourceInfoExtended $f.FullName $dji
    $skipFile = $false
    $doStreamCopy = $false
    $tripleLayerMode = $false
    $tripleLayerTargetCodec = "hevc"
    $hdr10PlusJson = ""
    $doviRpuFile = ""
    # Reset LOG vars per fisier — previne contaminare din fisierul anterior
    $script:logVideoFilter = ""
    $script:logColorFlags  = @()
    $script:logPixFmt      = ""
    $script:logExtraX265   = ""
    $script:selectedLutPath = ""

    # v38: Smart stream copy detection — daca source codec == target codec
    # si nu sunt transformari planificate, propune stream copy total
    $tgtCodecMap = @{ "libx265" = "hevc"; "libx264" = "h264"; "libsvtav1" = "av1"; "libaom-av1" = "av1" }
    $tgtCodecSmart = $tgtCodecMap[$rtEncoder]
    $vfActiveSmart = ($vfParts.Count -gt 0) -or $vfIsVidstab -or [bool]$vfPreset
    $doviSmart = & ffprobe -v error -show_entries stream=codec_tag_string `
        -of default=nw=1:nk=1 $f.FullName 2>$null |
        Select-String -Pattern "dovi|dvhe|dvh1" -CaseSensitive:$false
    if ($tgtCodecSmart -and ($si.codec -eq $tgtCodecSmart) `
        -and -not $vfActiveSmart `
        -and -not $audioNormalize `
        -and -not $logInfo.logProfile `
        -and -not $si.isHDRPlus `
        -and -not $doviSmart `
        -and -not $targetFps `
        -and ($encMode -ne "3")) {
        $srcBr = Get-FFprobeValue $f.FullName "v:0" "bit_rate"
        $brStr = if ($srcBr -match '^\d+$') { " (bitrate sursa ~$([int]([int]$srcBr/1000)) kbps)" } else { "" }
        Write-Host ""
        Write-Host "  SMART COPY: source este deja $($si.codec), identic cu target ($rtEncoder)$brStr." -ForegroundColor Cyan
        Write-Host "    Re-encode redundant — pierde calitate fara beneficiu real de compresie." -ForegroundColor Cyan
        $smartCh = Read-Host "  Stream copy total in loc de re-encode? (D/n) [default: D]"
        if ($smartCh -ine "n") {
            Write-Host "  -> Smart stream copy aplicat" -ForegroundColor Green
            $scOk = Invoke-StreamCopy $f $outFile $mapFlags $container $LogFile $audioParams
            if (-not $scOk) { $totalErrors++ }
            continue
        }
    }

    if ($useX264) {
        # ── x264 per-file dialog ─────────────────────────────────────
        $hlgResultX264 = ""
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
        } elseif ($logInfo.isHLG) {
            # v39: HLG dialog
            $hlgResultX264 = Show-HLGDialog $f.FullName $f.Name "x264"
            if ($hlgResultX264 -eq "hlg_to_hdr10") {
                Write-Host "  ⚠ x264 nu suporta SEI HDR10 — pastrez HLG nativ" -ForegroundColor Yellow
                $hlgResultX264 = "hlg_native"
            }
            switch ($hlgResultX264) {
                "copy" { $doStreamCopy = $true }
                "skip" { $skipFile = $true }
                "hlg_native" {
                    $script:logColorFlags = @("-color_primaries","bt2020","-color_trc","arib-std-b67","-colorspace","bt2020nc")
                }
                "hlg_to_sdr" {
                    $script:logColorFlags = @("-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709")
                    $hlgSdrVf = "zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709:r=tv,format=yuv420p"
                    if ($videoFilter.Count -gt 0) { $videoFilter = @("-vf","$hlgSdrVf,$($videoFilter[1])") }
                    else { $videoFilter = @("-vf",$hlgSdrVf) }
                }
            }
        }
        if (-not $skipFile -and -not $doStreamCopy -and -not $logInfo.logProfile -and -not $logInfo.isHLG) {
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
        } elseif ($hlgResultX264 -eq "hlg_native") {
            $x264Profile = "high10"; $x264PixFmt = "yuv420p10le"
        } elseif ($hlgResultX264 -eq "hlg_to_sdr") {
            $x264Profile = "high"; $x264PixFmt = "yuv420p"
        } elseif ($x264Result -eq "10bit") {
            $x264Profile = "high10"; $x264PixFmt = "yuv420p10le"
        } else {
            $x264Profile = "high"; $x264PixFmt = "yuv420p"
        }
        if (-not $x264PixFmt) { $x264PixFmt = switch ($x264Profile) { "high422"{"yuv422p10le"} "high10"{"yuv420p10le"} default{"yuv420p"} } }
        # v51: level via Suggest-VbvForTarget (rezolutie + fps + target_kbps)
        $x264Level = $script:autoLevel
        if ($x264Profile -eq "high422" -and $x264Level -in @("3.0","3.1","3.2","4.0","4.1","4.2","5.0")) { $x264Level = "5.1" }
        $x264BF = @("-bf","3")
        $x264Refs = if ($x264Profile -in @("high10","high422")) { @("-refs","4") } else { @("-refs","3") }
        # v51: HRD compliance pe VBR/2-pass — append nal-hrd=vbr la -x264-params
        $x264HrdParam = ""
        if ($encMode -eq "2" -or $encMode -eq "3") { $x264HrdParam = "nal-hrd=vbr" }
        $x264ExtraFlag = @()
        # v51 fix: auto HRD primul, EXTRA user LAST (x264 ia ultima valoare la chei
        # duplicate — user-ul poate suprascrie nal-hrd=vbr cu propria valoare)
        if ($extraParams -and $x264HrdParam) {
            $x264ExtraFlag = @("-x264-params","${x264HrdParam}:${extraParams}")
        } elseif ($extraParams) {
            $x264ExtraFlag = @("-x264-params",$extraParams)
        } elseif ($x264HrdParam) {
            $x264ExtraFlag = @("-x264-params",$x264HrdParam)
        }
        $x264ColorFlags = if ($script:logColorFlags) { $script:logColorFlags } else { @() }
        if ($encMode -eq "2" -or $encMode -eq "3") {
            Write-Host "  Profil: $x264Profile | Level: $x264Level | HRD=vbr | Container: $container" -ForegroundColor White
        } else {
            Write-Host "  Profil: $x264Profile | Level: $x264Level | Container: $container" -ForegroundColor White
        }

        if ($is2Pass) {
            # v51: 2-pass x264 — -pass N + -passlogfile
            Initialize-2PassState -File $f.FullName
            $script:ffmpegCmdPass1 = @("-y","-threads","0","-i",$f.FullName) + $mapFlags +
                @("-c:v","libx264","-preset",$selectedPreset) + $tuneFlag +
                @("-profile:v",$x264Profile,"-level:v",$x264Level,"-pix_fmt",$x264PixFmt) +
                $x264BF + $x264Refs + $x264ExtraFlag + $x264ColorFlags +
                $videoFilter + $fpsFlag + $rateParams +
                @("-pass","1","-passlogfile",$script:statsFile,"-an","-sn","-f","null","NUL")
            $script:ffmpegCmdPass2 = @("-y","-threads","0","-i",$f.FullName) + $mapFlags +
                @("-c:v","libx264","-preset",$selectedPreset) + $tuneFlag +
                @("-profile:v",$x264Profile,"-level:v",$x264Level,"-pix_fmt",$x264PixFmt) +
                $x264BF + $x264Refs + $x264ExtraFlag + $x264ColorFlags +
                $videoFilter + $fpsFlag + $rateParams +
                @("-pass","2","-passlogfile",$script:statsFile) + $audioParams
        } else {
            $ffArgs = @("-threads","0","-i",$f.FullName) + $mapFlags +
                      @("-c:v","libx264","-preset",$selectedPreset) + $tuneFlag + $crfFlag +
                      @("-profile:v",$x264Profile,"-level:v",$x264Level,"-pix_fmt",$x264PixFmt) +
                      $x264BF + $x264Refs + $x264ExtraFlag + $x264ColorFlags +
                      $videoFilter + $fpsFlag + $rateParams + $audioParams + $loudnormFlag +
                      (Get-SubtitleCodec $f.FullName $container) + @("-c:t","copy") +
                      $containerFlags + @("-progress",$progFile,"-nostats",$outFile)
        }

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

        # DV check — v44: cu optiune Profile 10 (AV1) prin sven-pke fork
        $doViAv1 = & ffprobe -v error -show_entries stream=codec_tag_string `
            -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null |
            Select-String -Pattern "dovi|dvhe|dvh1" -CaseSensitive:$false
        if ($doViAv1) {
            $av1DoviAvail = (Test-Av1DoviTool) -and ($av1Impl -eq "libsvtav1")
            $hevcDoviAvail = [bool](Get-Command "dovi_tool" -ErrorAction SilentlyContinue)
            Write-Host ""
            Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Magenta
            Write-Host "  ║  DOLBY VISION detectat                       ║" -ForegroundColor Magenta
            Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Magenta
            Write-Host "  ║  1) Converteste la HDR10 (pierde layer DV)   ║" -ForegroundColor White
            Write-Host "  ║  2) Sari acest fisier                        ║" -ForegroundColor White
            $maxDv = 2
            if ($av1DoviAvail) {
                Write-Host "  ║  3) DV Profile 10 (AV1) — re-encode + inject ║" -ForegroundColor White
                Write-Host "  ║     extrage RPU sursa → encode AV1 → inject  ║" -ForegroundColor DarkGray
                $maxDv = 3
            }
            Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Magenta
            # v45: profile bypass — DOVI_PRESERVE_POLICY mapped to AV1 dialog
            # AV1: 1=convert HDR10, 2=skip, 3=preserve P10. `copy` nu e suportat → fallback convert.
            $dvPolicyAv1 = if ($env:DOVI_PRESERVE_POLICY) { $env:DOVI_PRESERVE_POLICY } else { "auto" }
            $dvAv1 = switch ($dvPolicyAv1) {
                "preserve" { Write-Host "  DV policy=preserve P10 (DOVI_PRESERVE_POLICY)" -ForegroundColor Cyan; "3" }
                "convert"  { Write-Host "  DV policy=convert HDR10 (DOVI_PRESERVE_POLICY)" -ForegroundColor Cyan; "1" }
                "copy"     { Write-Host "  DV policy=copy nu e suportat pe AV1 — fallback convert" -ForegroundColor Yellow; "1" }
                "skip"     { Write-Host "  DV policy=skip (DOVI_PRESERVE_POLICY)" -ForegroundColor Cyan; "2" }
                default    { Read-Host "  Alege 1-$maxDv [implicit: 2]" }
            }
            if (-not $dvAv1) { $dvAv1 = "2" }
            if ($dvAv1 -eq "3" -and -not $av1DoviAvail) {
                Write-Host "  DV preserve P10 cerut prin policy dar tool/encoder indisponibil — fallback convert" -ForegroundColor Yellow
                $dvAv1 = "1"
            }
            if ($dvAv1 -eq "3" -and $av1DoviAvail) {
                # Detect source codec si foloseste Get-DvRpu codec-aware
                # (dovi_tool pt HEVC, av1dovi_tool pt AV1)
                $srcCodec = Get-SourceCodec $f.FullName
                $hasDoviForSrc = if ($srcCodec -eq "av1") { Test-Av1DoviTool } else { $hevcDoviAvail }
                if (-not $hasDoviForSrc) {
                    Write-Host "  DV (AV1 P10): tool DV pt sursa $srcCodec negasit — fallback HDR10." -ForegroundColor Yellow
                    $av1Color = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                } else {
                    Write-Host "  DV (AV1 P10): Extrag RPU din sursa ($srcCodec)..." -ForegroundColor Cyan
                    $srcRpu = Join-Path $env:TEMP ("rpu_"+[guid]::NewGuid().ToString("N")+".bin")
                    if (Get-DvRpu -InputFile $f.FullName -RpuOut $srcRpu -SourceCodec $srcCodec) {
                        $doviRpuFile = $srcRpu
                        $tripleLayerMode = $true
                        $tripleLayerTargetCodec = "av1"
                        Write-Host "  DV (AV1 P10): RPU sursa extras — re-encode + inject post-encode" -ForegroundColor Green

                        # v45: daca sursa are AMANDOUA DV + HDR10+ embedded, extrage si
                        # HDR10+ JSON pentru inline injection (svtav1-params hdr10plus-json=)
                        # — pastreaza toate 3 straturile: DV RPU + HDR10 base + HDR10+ dinamic.
                        if ($si.isHDRPlus -and ($av1Impl -eq "libsvtav1") -and (Test-SvtAv1Hdr10PlusCaps) -and (Test-Hdr10PlusToolFor -Codec $srcCodec)) {
                            Write-Host "  HDR10+ embedded + DV preserve: extragand HDR10+ JSON pentru inline injection..." -ForegroundColor Cyan
                            $hdr10PlusJson = Extract-Hdr10PlusMetadata $f.FullName
                            if ($hdr10PlusJson) {
                                $hdr10PlusAv1Param = ":hdr10plus-json=$hdr10PlusJson"
                                Write-Host "  HDR10+ inline pregatit (langa DV RPU real)" -ForegroundColor Green
                            }
                        }
                    } else {
                        Write-Host "  DV (AV1 P10): Extract RPU esuat — fallback HDR10" -ForegroundColor Yellow
                        Remove-Item $srcRpu -Force -ErrorAction SilentlyContinue
                    }
                    $av1Color = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                }
            }
            elseif ($dvAv1 -eq "1") {
                $av1Color = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
            }
            else {
                $totalSkipped++; continue
            }
        }
        # HDR10+ dialog — v44: codec-aware. Caps check afecteaza doar inline injection;
        # dialog ruleaza intotdeauna ca user-ul sa pastreze stream copy / skip / Triple-layer.
        elseif ($si.isHDRPlus) {
            $hdr10pInlineOk = $true
            if ($av1Impl -ne "libsvtav1") {
                Write-Host "  HDR10+: libaom-av1 nu suporta hdr10plus-json inline" -ForegroundColor Yellow
                $hdr10pInlineOk = $false
            }
            elseif (-not (Test-SvtAv1Hdr10PlusCaps)) {
                Write-Host "  HDR10+: SVT-AV1 curent nu suporta hdr10plus-json (necesita v1.5+)" -ForegroundColor Yellow
                $hdr10pInlineOk = $false
            }
            $hdr10pResult = Show-Hdr10PlusDialog $f.FullName -TargetCodec "av1"
            switch ($hdr10pResult) {
                "copy"    { $doStreamCopy = $true }
                "static"  { $av1Color = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc") }
                "triple"  {
                    $av1Color = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                    $jsonPath = Extract-Hdr10PlusMetadata $f.FullName
                    if ($jsonPath) {
                        if ($hdr10pInlineOk) {
                            $hdr10PlusAv1Param = ":hdr10plus-json=$jsonPath"
                            $hdr10PlusJson = $jsonPath
                        } else {
                            Write-Host "  HDR10+: Inline injection indisponibila — DV RPU post-encode ramane functional" -ForegroundColor Yellow
                        }
                        $rpuPath = Generate-DvRpuFromHdr10Plus $jsonPath -TargetCodec "av1"
                        if ($rpuPath) {
                            $doviRpuFile = $rpuPath
                            $tripleLayerMode = $true
                            $tripleLayerTargetCodec = "av1"
                        }
                    }
                }
                default   {
                    $av1Color = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                    if ($hdr10pResult -eq "preserve") {
                        $jsonPath = Extract-Hdr10PlusMetadata $f.FullName
                        if ($jsonPath -and $hdr10pInlineOk) {
                            $hdr10PlusAv1Param = ":hdr10plus-json=$jsonPath"
                            $hdr10PlusJson = $jsonPath
                        } elseif ($jsonPath) {
                            Write-Host "  HDR10+: Metadata extrasa dar inline injection indisponibila — fallback HDR10 static" -ForegroundColor Yellow
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
        # v39: HLG dialog (BT.2100 HLG)
        elseif ($logInfo.isHLG) {
            $hlgResult = Show-HLGDialog $f.FullName $f.Name "av1"
            switch ($hlgResult) {
                "copy" { $doStreamCopy = $true }
                "skip" { $skipFile = $true }
                "hlg_native" {
                    $av1Color = @("-color_primaries","bt2020","-color_trc","arib-std-b67","-colorspace","bt2020nc")
                }
                "hlg_to_hdr10" {
                    $av1Color = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                    $hlgVf = "zscale=t=linear:npl=1000,zscale=t=smpte2084:p=bt2020:m=bt2020nc:r=tv,format=yuv420p10le"
                    if ($videoFilter.Count -gt 0) { $videoFilter = @("-vf","$hlgVf,$($videoFilter[1])") }
                    else { $videoFilter = @("-vf",$hlgVf) }
                }
                "hlg_to_sdr" {
                    $av1Color = @("-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709")
                    $hlgSdrVf = "zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709:r=tv,format=yuv420p10le"
                    if ($videoFilter.Count -gt 0) { $videoFilter = @("-vf","$hlgSdrVf,$($videoFilter[1])") }
                    else { $videoFilter = @("-vf",$hlgSdrVf) }
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
        $isVbr = ($encMode -eq "2" -or $encMode -eq "3")
        # v51: HDR10 static — pe branch-uri PQ (color_trc=smpte2084)
        $av1Hdr10StaticParam = ""
        $av1HasPq = ($av1Color -join " ") -match "smpte2084"
        if ($av1HasPq -and $av1Impl -eq "libsvtav1") {
            $isRealHdr10 = $si.isHDRPlus -or $doViAv1
            if ($isRealHdr10) { Resolve-Hdr10Static -File $f.FullName }
            else { Set-Hdr10StaticDefaults; $script:hdr10StaticSource = "default-bt2020-1000nit" }
            if ($script:hdr10StaticAvailable) {
                $av1Hdr10StaticParam = ":mastering-display=$($script:hdr10MasterDisplaySvtAv1)"
                if ($script:hdr10MaxCll) { $av1Hdr10StaticParam += ":content-light=$($script:hdr10MaxCll)" }
                Write-Host "  HDR10 static (AV1): $($script:hdr10StaticSource) | content-light=$($script:hdr10MaxCll)" -ForegroundColor DarkGray
            }
        } elseif ($av1HasPq -and $av1Impl -eq "libaom-av1") {
            Write-Host "  ⓘ libaom-av1: mastering-display + content-light nu se pot injecta prin ffmpeg (HDR10 color signaling ramane functional)" -ForegroundColor DarkGray
        }
        # v52: VUI color signaling EXPLICIT in svtav1-params — ffmpeg -color_primaries
        # / -color_trc nu propaga la libsvtav1. Valori numerice AV1 spec.
        $av1VuiParam = ""
        $av1ColorJoined = if ($av1Color) { $av1Color -join " " } else { "" }
        if ($av1ColorJoined -match "smpte2084") {
            $av1VuiParam = ":color-primaries=9:transfer-characteristics=16:matrix-coefficients=9"
        } elseif ($av1ColorJoined -match "arib-std-b67") {
            $av1VuiParam = ":color-primaries=9:transfer-characteristics=18:matrix-coefficients=9"
        } elseif ($av1ColorJoined -match "bt709") {
            $av1VuiParam = ":color-primaries=1:transfer-characteristics=1:matrix-coefficients=1"
        }
        $svtParams = if ($isVbr) {
            "preset=${av1Preset}:rc=1:lp=$([Environment]::ProcessorCount)${fgSuffix}${av1VuiParam}${hdr10PlusAv1Param}${av1Hdr10StaticParam}"
        } else {
            "preset=${av1Preset}:lp=$([Environment]::ProcessorCount)${fgSuffix}${av1VuiParam}${hdr10PlusAv1Param}${av1Hdr10StaticParam}"
        }
        if ($extraParams -and $av1Impl -eq "libsvtav1") { $svtParams += ":$extraParams" }
        $libaomExtra = if ($extraParams -and $av1Impl -eq "libaom-av1") { $extraParams -split '\s+' | Where-Object { $_ } } else { @() }
        # v51: -level pe libsvtav1
        $av1LevelFlag = @()
        if ($av1Impl -eq "libsvtav1") { $av1LevelFlag = @("-level",$script:autoLevel) }

        if ($av1Impl -eq "libsvtav1") {
            if ($is2Pass) {
                Initialize-2PassState -File $f.FullName
                Test-SvtAv1TwoPassCaps | Out-Null
                $svtParamsP1 = $svtParams; $svtParamsP2 = $svtParams
                $passFlagP1 = @(); $passFlagP2 = @()
                if ($script:svtav1TwoPassSupported) {
                    $svtParamsP1 = "${svtParams}:pass=1:stats=$($script:statsFile)"
                    $svtParamsP2 = "${svtParams}:pass=2:stats=$($script:statsFile)"
                } else {
                    # Inline `pass=N:stats=PATH` (libsvtav1 v1.4+) nedetectat in
                    # ffmpeg help — folosim sintaxa generica `-pass/-passlogfile`
                    # tradusa intern de ffmpeg catre svtav1-params pe versiuni
                    # compatibile.
                    Write-Host "  ℹ SVT-AV1 2-pass: folosesc sintaxa generica -pass/-passlogfile" -ForegroundColor DarkGray
                    $passFlagP1 = @("-pass","1","-passlogfile",$script:statsFile)
                    $passFlagP2 = @("-pass","2","-passlogfile",$script:statsFile)
                }
                # v52: NU adaugam $av1Color la libsvtav1 (VUI deja in svtav1-params;
                # ffmpeg -color_primaries scrie Matroska "Colour" element care override
                # VUI stream pe MKV → rezultat anterior bt2020nc/unknown/unknown).
                $script:ffmpegCmdPass1 = @("-y","-threads","0","-i",$f.FullName) + $mapFlags +
                    @("-c:v","libsvtav1") + $av1LevelFlag +
                    @("-pix_fmt",$av1PixFmt,"-svtav1-params",$svtParamsP1) +
                    $videoFilter + $fpsFlag + $rateParams + $passFlagP1 +
                    @("-an","-sn","-f","null","NUL")
                $script:ffmpegCmdPass2 = @("-y","-threads","0","-i",$f.FullName) + $mapFlags +
                    @("-c:v","libsvtav1") + $av1LevelFlag +
                    @("-pix_fmt",$av1PixFmt,"-svtav1-params",$svtParamsP2) +
                    $videoFilter + $fpsFlag + $rateParams + $passFlagP2 + $audioParams
            } else {
                # v52: NU adaugam $av1Color (vezi nota la 2-pass branch)
                $ffArgs = @("-threads","0","-i",$f.FullName) + $mapFlags +
                          @("-c:v","libsvtav1") + $av1LevelFlag + $crfFlag +
                          @("-pix_fmt",$av1PixFmt,"-svtav1-params",$svtParams) +
                          $videoFilter + $fpsFlag + $rateParams + $audioParams + $loudnormFlag +
                          (Get-SubtitleCodec $f.FullName $container) + @("-c:t","copy") +
                          $containerFlags + @("-progress",$progFile,"-nostats",$outFile)
            }
        } else {
            $libaomBv = if (-not $isVbr) { @("-b:v","0") } else { @() }
            $libaomFg = if ($fgLevel -gt 0) { @("-denoise-noise-level",$fgLevel) } else { @() }
            if ($is2Pass) {
                Initialize-2PassState -File $f.FullName
                $script:ffmpegCmdPass1 = @("-y","-threads","0","-i",$f.FullName) + $mapFlags +
                    @("-c:v","libaom-av1") + $libaomBv +
                    @("-pix_fmt",$av1PixFmt,"-cpu-used",$av1Preset,"-row-mt","1") +
                    $libaomFg + $libaomExtra + $videoFilter + $fpsFlag + $av1Color + $rateParams +
                    @("-pass","1","-passlogfile",$script:statsFile,"-an","-sn","-f","null","NUL")
                $script:ffmpegCmdPass2 = @("-y","-threads","0","-i",$f.FullName) + $mapFlags +
                    @("-c:v","libaom-av1") + $libaomBv +
                    @("-pix_fmt",$av1PixFmt,"-cpu-used",$av1Preset,"-row-mt","1") +
                    $libaomFg + $libaomExtra + $videoFilter + $fpsFlag + $av1Color + $rateParams +
                    @("-pass","2","-passlogfile",$script:statsFile) + $audioParams
            } else {
                $ffArgs = @("-threads","0","-i",$f.FullName) + $mapFlags +
                          @("-c:v","libaom-av1") + $crfFlag + $libaomBv +
                          @("-pix_fmt",$av1PixFmt,"-cpu-used",$av1Preset,"-row-mt","1") +
                          $libaomFg + $libaomExtra + $videoFilter + $fpsFlag + $av1Color + $rateParams + $audioParams + $loudnormFlag +
                          (Get-SubtitleCodec $f.FullName $container) + @("-c:t","copy") +
                          $containerFlags + @("-progress",$progFile,"-nostats",$outFile)
            }
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
        # 10-bit for NVENC/QSV/AV1-AMF if source is 10-bit (h264_amf/hevc_amf raman 8-bit)
        $hwSupports10bit = ($hwEncCodec -match "nvenc|qsv" -or $hwEncCodec -eq "av1_amf")
        if ($si.is10bit -and $hwSupports10bit) {
            $hwPixFmt = "p010le"
        }

        # v46: DV source detection + DV preserve via HW (HEVC/AV1 target only)
        $hwColorFlags = @()
        $hwDoVi = & ffprobe -v error -show_entries stream=codec_tag_string `
            -of default=noprint_wrappers=1:nokey=1 $f.FullName 2>$null |
            Select-String -Pattern "dovi|dvhe|dvh1" -CaseSensitive:$false
        if ($hwDoVi) {
            $hwTargetCodec = if ($hwEncCodec -match "^hevc_") { "hevc" } elseif ($hwEncCodec -match "^av1_") { "av1" } else { "" }
            $hwSrcCodec = Get-SourceCodec $f.FullName
            $hwCanDvPreserve = ($hwTargetCodec -in @("hevc","av1")) -and (Test-DoviToolFor -Codec $hwSrcCodec) -and (Test-DoviToolFor -Codec $hwTargetCodec)
            $dvP = Get-DVProfile $f.FullName
            Write-Host ""
            Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Magenta
            Write-Host "  ║  DOLBY VISION detectat (profil $dvP)" -ForegroundColor Magenta
            Write-Host "  ║  HW $hwEncCodec — optiuni:" -ForegroundColor Magenta
            Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Magenta
            Write-Host "  ║  1) HW — strip DV → HDR10 (pierde RPU)       ║" -ForegroundColor White
            $maxHwDv = 2
            if ($hwCanDvPreserve) {
                Write-Host "  ║  2) HW — DV preserve (HDR10 base + inject)   ║" -ForegroundColor White
                Write-Host "  ║     extrage RPU ($hwSrcCodec) → HW → inject  ║" -ForegroundColor DarkGray
                Write-Host "  ║  3) HW — strip DV → SDR tonemap 8-bit        ║" -ForegroundColor White
                Write-Host "  ║  4) Sari acest fisier                        ║" -ForegroundColor White
                $maxHwDv = 4
            } else {
                Write-Host "  ║  2) HW — strip DV → SDR tonemap 8-bit        ║" -ForegroundColor White
                Write-Host "  ║  3) Sari acest fisier                        ║" -ForegroundColor White
                $maxHwDv = 3
            }
            Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Magenta
            # Policy bypass: HW_HDR_POLICY ({sw_full,sw_degraded,hw_hdr10,hw_sdr,hw_preserve,skip})
            $hwPolicy = if ($env:HW_HDR_POLICY) { $env:HW_HDR_POLICY } else { "" }
            $hwDvc = ""
            if ($hwPolicy) {
                switch ($hwPolicy) {
                    "hw_preserve" {
                        if ($hwCanDvPreserve) { $hwDvc = "2"; Write-Host "  HW HDR policy: hw_preserve" -ForegroundColor Cyan }
                        else { $hwDvc = "1"; Write-Host "  HW policy=hw_preserve dar tool indisponibil — fallback hw_hdr10" -ForegroundColor Yellow }
                    }
                    "hw_hdr10"    { $hwDvc = "1"; Write-Host "  HW HDR policy: hw_hdr10" -ForegroundColor Cyan }
                    "hw_sdr"      { $hwDvc = if ($hwCanDvPreserve) { "3" } else { "2" }; Write-Host "  HW HDR policy: hw_sdr" -ForegroundColor Cyan }
                    "skip"        { $hwDvc = if ($hwCanDvPreserve) { "4" } else { "3" }; Write-Host "  HW HDR policy: skip" -ForegroundColor Cyan }
                    default       { $hwDvc = "1" }
                }
            } else {
                $hwDvc = Read-Host "  Alege 1-$maxHwDv [implicit: 1]"
                if (-not $hwDvc) { $hwDvc = "1" }
            }
            $isSkip = ($hwCanDvPreserve -and $hwDvc -eq "4") -or ((-not $hwCanDvPreserve) -and $hwDvc -eq "3")
            if ($isSkip) { $totalSkipped++; continue }

            if ($hwCanDvPreserve -and $hwDvc -eq "2") {
                # v46: extract RPU + setup triple-layer; HW produce HDR10 base layer
                $srcRpu = Join-Path $env:TEMP ("rpu_"+[guid]::NewGuid().ToString("N")+".bin")
                Write-Host "  v46 HW DV preserve: Extrag RPU sursa ($hwSrcCodec)..." -ForegroundColor Cyan
                if (Get-DvRpu -InputFile $f.FullName -RpuOut $srcRpu -SourceCodec $hwSrcCodec) {
                    $doviRpuFile = $srcRpu
                    $tripleLayerMode = $true
                    $tripleLayerTargetCodec = $hwTargetCodec
                    Write-Host "  v46 HW DV preserve: RPU extras — HW encode + inject post-encode ($hwTargetCodec)" -ForegroundColor Green
                } else {
                    Write-Host "  v46 HW DV preserve: Extract RPU esuat — fallback HDR10" -ForegroundColor Yellow
                    Remove-Item $srcRpu -Force -ErrorAction SilentlyContinue
                }
                $hwColorFlags = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                if ($hwSupports10bit) { $hwPixFmt = "p010le" }
            }
            elseif ($hwDvc -eq "1") {
                # Strip DV → HDR10
                $hwColorFlags = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                if ($hwSupports10bit) { $hwPixFmt = "p010le" }
            }
            else {
                # SDR tonemap
                $hwColorFlags = @("-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709")
                $hwPixFmt = "yuv420p"
                $tmHwVf = "zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709:r=tv,format=yuv420p"
                if ($videoFilter.Count -gt 0) { $videoFilter = @("-vf","$tmHwVf,$($videoFilter[1])") }
                else { $videoFilter = @("-vf",$tmHwVf) }
            }
        }

        # v39: HLG dialog pentru HW encode (signaling via color_trc, fara SEI repair)
        if ($logInfo.isHLG) {
            $isH264HW = ($hwEncCodec -match "^h264_")
            $hlgResultHw = Show-HLGDialog $f.FullName $f.Name $hwEncCodec
            if ($hlgResultHw -eq "hlg_to_hdr10" -and $isH264HW) {
                Write-Host "  ⚠ H.264 HW nu suporta SEI HDR10 — pastrez HLG nativ" -ForegroundColor Yellow
                $hlgResultHw = "hlg_native"
            }
            switch ($hlgResultHw) {
                "copy" {
                    $scOk = Invoke-StreamCopy $f $outFile $mapFlags $container $LogFile $audioParams
                    if (-not $scOk) { $totalErrors++ }
                    continue
                }
                "skip" { $totalSkipped++; continue }
                "hlg_native" {
                    $hwColorFlags = @("-color_primaries","bt2020","-color_trc","arib-std-b67","-colorspace","bt2020nc")
                    if ($hwSupports10bit) { $hwPixFmt = "p010le" }
                }
                "hlg_to_hdr10" {
                    $hwColorFlags = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                    if ($hwSupports10bit) { $hwPixFmt = "p010le" }
                    $hlgVf = "zscale=t=linear:npl=1000,zscale=t=smpte2084:p=bt2020:m=bt2020nc:r=tv,format=p010le"
                    if ($videoFilter.Count -gt 0) { $videoFilter = @("-vf","$hlgVf,$($videoFilter[1])") }
                    else { $videoFilter = @("-vf",$hlgVf) }
                }
                "hlg_to_sdr" {
                    $hwColorFlags = @("-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709")
                    $hwPixFmt = "yuv420p"
                    $hlgSdrVf = "zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709:r=tv,format=yuv420p"
                    if ($videoFilter.Count -gt 0) { $videoFilter = @("-vf","$hlgSdrVf,$($videoFilter[1])") }
                    else { $videoFilter = @("-vf",$hlgSdrVf) }
                }
            }
        }

        $ffArgs = @("-threads","0","-i",$f.FullName) + $mapFlags +
                  @("-c:v",$hwEncCodec) + $hwQpFlag + $hwPresetFlag +
                  @("-pix_fmt",$hwPixFmt) +
                  $videoFilter + $fpsFlag + $hwColorFlags + $audioParams + $loudnormFlag +
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
            # Dolby Vision dialog (v45: + opt 3 DV preserve HEVC 8.1)
            $dvP = Get-DVProfile $f.FullName
            $dvSrcCodec = Get-SourceCodec $f.FullName
            $canDvPreserve = (Test-DoviToolFor -Codec $dvSrcCodec) -and (Test-DoviToolFor -Codec "hevc")
            Write-Host ""; Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Magenta
            Write-Host "  ║  DOLBY VISION: $($f.Name)" -ForegroundColor Magenta
            Write-Host "  ║  Profil sursa: $dvP" -ForegroundColor Magenta
            Write-Host "  ╠══════════════════════════════════════════════╣" -ForegroundColor Magenta
            Write-Host "  ║  1) Stream copy video + reencodeaza audio    ║" -ForegroundColor White
            Write-Host "  ║  2) Converteste la HDR10 (best-effort)       ║" -ForegroundColor White
            if ($canDvPreserve) {
                Write-Host "  ║  3) DV preserve (HEVC 8.1) — re-encode+inject║" -ForegroundColor White
                Write-Host "  ║     extrage RPU sursa ($dvSrcCodec) → encode → inject" -ForegroundColor DarkGray
            }
            Write-Host "  ║  4) Sari acest fisier                        ║" -ForegroundColor White
            Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Magenta
            # v45: profile bypass — DOVI_PRESERVE_POLICY={auto|preserve|convert|copy|skip}
            $dvPolicy = if ($env:DOVI_PRESERVE_POLICY) { $env:DOVI_PRESERVE_POLICY } else { "auto" }
            $dvc = switch ($dvPolicy) {
                "preserve" { Write-Host "  DV policy=preserve (DOVI_PRESERVE_POLICY)" -ForegroundColor Cyan; "3" }
                "convert"  { Write-Host "  DV policy=convert HDR10 (DOVI_PRESERVE_POLICY)" -ForegroundColor Cyan; "2" }
                "copy"     { Write-Host "  DV policy=stream copy (DOVI_PRESERVE_POLICY)" -ForegroundColor Cyan; "1" }
                "skip"     { Write-Host "  DV policy=skip (DOVI_PRESERVE_POLICY)" -ForegroundColor Cyan; "4" }
                default    { Read-Host "  Alege [implicit: 2]" }
            }
            if (-not $dvc) { $dvc = "2" }
            if ($dvc -eq "3" -and -not $canDvPreserve) {
                Write-Host "  DV preserve cerut prin policy dar tool indisponibil — fallback convert HDR10" -ForegroundColor Yellow
                $dvc = "2"
            }
            if ($dvc -eq "4") { $totalSkipped++; continue }
            if ($dvc -eq "1") {
                $scOk = Invoke-StreamCopy $f $outFile $mapFlags $container $LogFile $audioParams
                if (-not $scOk) { $totalErrors++ }
                continue
            }
            if ($dvc -eq "3" -and $canDvPreserve) {
                $srcRpu = Join-Path $env:TEMP ("rpu_"+[guid]::NewGuid().ToString("N")+".bin")
                Write-Host "  DV preserve (HEVC): Extrag RPU din sursa ($dvSrcCodec)..." -ForegroundColor Cyan
                if (Get-DvRpu -InputFile $f.FullName -RpuOut $srcRpu -SourceCodec $dvSrcCodec) {
                    $doviRpuFile = $srcRpu
                    $tripleLayerMode = $true
                    $tripleLayerTargetCodec = "hevc"
                    Write-Host "  DV preserve (HEVC): RPU extras — re-encode + inject post-encode" -ForegroundColor Green
                } else {
                    Write-Host "  DV preserve: Extract RPU esuat — fallback HDR10 (best-effort)" -ForegroundColor Yellow
                    Remove-Item $srcRpu -Force -ErrorAction SilentlyContinue
                }
            }
            # DV re-encode → HDR10 base layer (preserve sau best-effort)
            $colorParams = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
            $x265Hdr = "hdr-opt=1:repeat-headers=1:hdr10=1:"

            # v45: daca sursa are AMANDOUA DV + HDR10+ embedded, extrage si
            # HDR10+ JSON pentru inline injection (dhdr10-info) — pastreaza
            # toate 3 straturile: DV RPU + HDR10 base + HDR10+ dinamic.
            # NU sintetizam DV din JSON (am DV-ul real); doar add-on inline.
            if ($si.isHDRPlus -and $tripleLayerMode -and (Test-Hdr10PlusToolFor -Codec $dvSrcCodec)) {
                Write-Host "  HDR10+ embedded + DV preserve: extragand HDR10+ JSON pentru inline injection..." -ForegroundColor Cyan
                $hdr10PlusJson = Extract-Hdr10PlusMetadata $f.FullName
                if ($hdr10PlusJson) {
                    $x265Hdr += "dhdr10-info=${hdr10PlusJson}:"
                    Write-Host "  HDR10+ inline pregatit (langa DV RPU real)" -ForegroundColor Green
                }
            }

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

        } elseif ($logInfo.isHLG) {
            # v39: HLG dialog (BT.2100 HLG)
            $hlgResult = Show-HLGDialog $f.FullName $f.Name "x265"
            switch ($hlgResult) {
                "copy" {
                    $scOk = Invoke-StreamCopy $f $outFile $mapFlags $container $LogFile $audioParams
                    if (-not $scOk) { $totalErrors++ }
                    continue
                }
                "skip" { $totalSkipped++; continue }
                "hlg_native" {
                    $colorParams = @("-color_primaries","bt2020","-color_trc","arib-std-b67","-colorspace","bt2020nc")
                    $x265Hdr = "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:"
                }
                "hlg_to_hdr10" {
                    $colorParams = @("-color_primaries","bt2020","-color_trc","smpte2084","-colorspace","bt2020nc")
                    $x265Hdr = "hdr-opt=1:repeat-headers=1:hdr10=1:"
                    $hlgVf = "zscale=t=linear:npl=1000,zscale=t=smpte2084:p=bt2020:m=bt2020nc:r=tv,format=yuv420p10le"
                    if ($videoFilter.Count -gt 0) { $videoFilter = @("-vf","$hlgVf,$($videoFilter[1])") }
                    else { $videoFilter = @("-vf",$hlgVf) }
                }
                "hlg_to_sdr" {
                    $colorParams = @("-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709")
                    $hlgSdrVf = "zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709:r=tv,format=yuv420p10le"
                    if ($videoFilter.Count -gt 0) { $videoFilter = @("-vf","$hlgSdrVf,$($videoFilter[1])") }
                    else { $videoFilter = @("-vf",$hlgSdrVf) }
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
        # v51: Level / Tier / HRD (informational pe CRF, HRD-binding pe VBR/2-pass)
        $x265LvlIdc = ($script:autoLevel -replace '\.','')
        $x265HighTier = if ($script:autoTier -eq "high") { 1 } else { 0 }
        $x265LevelParams = "level-idc=${x265LvlIdc}:high-tier=${x265HighTier}"
        if ($encMode -eq "2" -or $encMode -eq "3") {
            $x265LevelParams += ":hrd=1"
        }
        # v52: VUI color signaling EXPLICIT in x265-params — ffmpeg -color_primaries
        # / -color_trc nu propaga la libx265 (x265 dezactiveaza hdr10-opt automat
        # fara VUI corect). Derive din $colorParams setat per branch.
        $x265VuiParams = ""
        $colorJoined = if ($colorParams) { $colorParams -join " " } else { "" }
        if ($colorJoined -match "smpte2084") {
            $x265VuiParams = "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
        } elseif ($colorJoined -match "arib-std-b67") {
            $x265VuiParams = "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc"
        } elseif ($colorJoined -match "bt709") {
            $x265VuiParams = "colorprim=bt709:transfer=bt709:colormatrix=bt709"
        }
        # v51: HDR10 static metadata pe branch-uri HDR10 (PQ transfer)
        $x265StaticParams = ""
        if ($x265Hdr -match "hdr10=1") {
            $isRealHdr10 = ($srcResult -eq "hdr10") -or $si.isHDRPlus -or $doVi
            if ($isRealHdr10) { Resolve-Hdr10Static -File $f.FullName }
            else { Set-Hdr10StaticDefaults; $script:hdr10StaticSource = "default-bt2020-1000nit" }
            if ($script:hdr10StaticAvailable) {
                $x265StaticParams = "master-display=$($script:hdr10MasterDisplayX265)"
                if ($script:hdr10MaxCll) { $x265StaticParams += ":max-cll=$($script:hdr10MaxCll)" }
                Write-Host "  HDR10 static: $($script:hdr10StaticSource) | max-cll=$($script:hdr10MaxCll)" -ForegroundColor DarkGray
            }
        }
        $x265Params = "${x265Hdr}pools=${nProc}:aq-mode=3:aq-strength=1.0:${x265LevelParams}"
        if ($x265VuiParams) { $x265Params += ":${x265VuiParams}" }
        if ($x265StaticParams) { $x265Params += ":${x265StaticParams}" }
        if ($extraParams) { $x265Params += ":$extraParams" }
        # Remove trailing colon if present
        $x265Params = $x265Params -replace '::+',':'
        $x265Params = $x265Params.TrimEnd(':')
        Write-Host "  Container: $container | Preset: $selectedPreset" -ForegroundColor White

        if ($is2Pass) {
            # v51: 2-pass x265 — pass=N:stats= injectat in x265-params
            # v52: NU adaugam $colorParams (VUI deja in x265-params; ffmpeg
            # -color_primaries scrie Matroska "Colour" element care override
            # VUI stream pe MKV → rezultat anterior bt2020nc/unknown/unknown).
            Initialize-2PassState -File $f.FullName
            $x265ParamsP1 = "${x265Params}:pass=1:stats=$($script:statsFile):slow-firstpass=0"
            $x265ParamsP2 = "${x265Params}:pass=2:stats=$($script:statsFile)"
            $script:ffmpegCmdPass1 = @("-y","-threads","0","-i",$f.FullName) + $mapFlags +
                @("-c:v","libx265","-preset",$selectedPreset) + $tuneFlag +
                @("-pix_fmt",$x265PixFmt,"-x265-params",$x265ParamsP1) +
                $videoFilter + $fpsFlag + $rateParams + @("-an","-sn","-f","null","NUL")
            $script:ffmpegCmdPass2 = @("-y","-threads","0","-i",$f.FullName) + $mapFlags +
                @("-c:v","libx265","-preset",$selectedPreset) + $tuneFlag +
                @("-pix_fmt",$x265PixFmt,"-x265-params",$x265ParamsP2) +
                $videoFilter + $fpsFlag + $rateParams + $audioParams
        } else {
            # v52: NU adaugam $colorParams (vezi nota la 2-pass branch)
            $ffArgs = @("-threads","0","-i",$f.FullName) + $mapFlags +
                      @("-c:v","libx265","-preset",$selectedPreset) + $tuneFlag + $crfFlag +
                      @("-pix_fmt",$x265PixFmt,"-x265-params",$x265Params) +
                      $videoFilter + $fpsFlag + $rateParams + $audioParams + $loudnormFlag +
                      (Get-SubtitleCodec $f.FullName $container) + @("-c:t","copy") +
                      $containerFlags + @("-progress",$progFile,"-nostats",$outFile)
        }
    }

    # v38: label dinamic pentru progress bar — bazat pe $rtEncoder (var globala)
    $encLabel = switch -Wildcard ($rtEncoder) {
        "libx265"   { "HEVC" }
        "libx264"   { "H264" }
        "libsvtav1" { "AV1-SVT" }
        "libaom-av1"{ "AV1-AOM" }
        "dnxhd"     { "DNxHR" }
        "prores_ks" { "ProRes" }
        "apv"       { "APV" }
        "*nvenc"    { (($rtEncoder -replace "_nvenc","").ToUpper()) + "-NVENC" }
        "*qsv"      { (($rtEncoder -replace "_qsv","").ToUpper()) + "-QSV" }
        "*amf"      { (($rtEncoder -replace "_amf","").ToUpper()) + "-AMF" }
        default     { if ($rtEncoder) { $rtEncoder.ToUpper() } else { "FFmpeg" } }
    }
    $errFile = "$env:TEMP\fferr_$PID.txt"
    $exitCode = 0
    if ($script:use2Pass) {
        # v51: 2-pass branch — encoderul a populat ffmpegCmdPass1/Pass2 + statsFile.
        # NOTA: $audioParams e DEJA inclus in ffmpegCmdPass2 de encoder branches
        # (paritate cu bash AUDIO_PARAMS in FFMPEG_CMD_PASS2). Aici adaugam doar
        # loudnorm + sub + container + output (paritate cu trailing eval bash).
        $trailing2 = $loudnormFlag +
            (Get-SubtitleCodec $f.FullName $container) + @("-c:t","copy") +
            $containerFlags + @($outFile)
        $exitCode = Invoke-2PassEncode -File $f.FullName -Label $encLabel -DurationSec $durSec `
            -TrailingArgs2 $trailing2 -ProgressFile $progFile -LogFile $LogFile
        Clear-2PassState
    } else {
        $proc = Start-Process ffmpeg -ArgumentList $ffArgs -NoNewWindow -PassThru `
            -RedirectStandardError $errFile
        Show-Progress -proc $proc -progFile $progFile -durSec $durSec -startTime $startTime -Label $encLabel
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
    }

    # Cleanup vidstab .trf
    if ($trfFile -and (Test-Path $trfFile)) { Remove-Item $trfFile -Force -ErrorAction SilentlyContinue }

    if ($exitCode -ne 0) {
        Write-Host "  EROARE encode!" -ForegroundColor Red
        # v38: tail stderr inline pentru diagnoza rapida
        if (Test-Path $errFile) {
            Write-Host "  ⚠ ffmpeg exit $exitCode — ultimele linii stderr:" -ForegroundColor Yellow
            Get-Content $errFile -Tail 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $outFile) { Remove-Item $outFile -Force }
        if ($hdr10PlusJson -and (Test-Path $hdr10PlusJson)) { Remove-Item $hdr10PlusJson -Force -ErrorAction SilentlyContinue }
        if ($doviRpuFile -and (Test-Path $doviRpuFile)) { Remove-Item $doviRpuFile -Force -ErrorAction SilentlyContinue }
        $totalErrors++; continue
    }
    if (Test-Path $errFile) { Remove-Item $errFile -Force -ErrorAction SilentlyContinue }

    # ── Triple-layer: injecteaza DV RPU in output (HEVC sau AV1) ─────
    if ($tripleLayerMode -and $doviRpuFile) {
        $tlCodec = if ($tripleLayerTargetCodec) { $tripleLayerTargetCodec } else { "hevc" }
        $tlLabel = if ($tlCodec -eq "av1") { "DV P10 + HDR10 + HDR10+ (AV1)" } else { "DV 8.1 + HDR10 + HDR10+ (HEVC)" }
        Write-Host "  Triple-layer: Injectez DV RPU in output ($tlCodec)..." -ForegroundColor Cyan
        $rawExt = if ($tlCodec -eq "av1") { "ivf" } else { "hevc" }
        $rawTemp = Join-Path $env:TEMP ("raw_"+[guid]::NewGuid().ToString("N")+".$rawExt")
        $extractArgs = if ($tlCodec -eq "av1") {
            @("-c:v","copy","-f","ivf",$rawTemp)
        } else {
            @("-c:v","copy","-bsf:v","hevc_mp4toannexb","-f","hevc",$rawTemp)
        }
        & ffmpeg -v error -i $outFile @extractArgs 2>>"$LogFile"
        if ($LASTEXITCODE -eq 0 -and (Test-Path $rawTemp)) {
            $injectedTemp = Join-Path $env:TEMP ("injected_"+[guid]::NewGuid().ToString("N")+".$rawExt")
            if (Inject-DvRpu $rawTemp $doviRpuFile $injectedTemp -TargetCodec $tlCodec) {
                $finalTemp = Join-Path $env:TEMP ("final_"+[guid]::NewGuid().ToString("N")+".$container")
                $tlContFlags = Get-ContainerFlags $container
                $tlArgs = @("-v","error","-i",$injectedTemp,"-i",$outFile,
                           "-map","0:v:0","-map","1:a","-map","1:s?","-map","1:t?",
                           "-c","copy") + $tlContFlags + @($finalTemp)
                & ffmpeg @tlArgs 2>>"$LogFile"
                if ($LASTEXITCODE -eq 0 -and (Test-Path $finalTemp) -and (Get-Item $finalTemp).Length -gt 0) {
                    Move-Item -Force $finalTemp $outFile
                    Write-Host "  Triple-layer: $tlLabel — OK" -ForegroundColor Green
                    "  Triple-layer: $tlLabel" | Out-File $LogFile -Append -Encoding UTF8
                } else {
                    Write-Host "  Triple-layer: Re-mux esuat — output fara DV (HDR10+ pastrat)" -ForegroundColor Yellow
                    Remove-Item $finalTemp -Force -ErrorAction SilentlyContinue
                }
            } else {
                Write-Host "  Triple-layer: Injectare RPU esuata — output fara DV" -ForegroundColor Yellow
            }
            Remove-Item $injectedTemp -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "  Triple-layer: Extractie raw $tlCodec esuata" -ForegroundColor Yellow
        }
        Remove-Item $rawTemp -Force -ErrorAction SilentlyContinue
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
    # Afiseaza structura de foldere daca a fost pastrata
    if ($preserveFolderStructure) {
        $outputDirs = @(Get-ChildItem -Path $OutputDir -Directory -Recurse -ErrorAction SilentlyContinue)
        $dirCount = $outputDirs.Count + 1  # +1 pentru folderul root
        Write-Host "  Structura foldere: PASTRATA ($dirCount foldere)" -ForegroundColor Cyan
        "Structura foldere: $dirCount foldere create" | Out-File $LogFile -Append -Encoding UTF8
    }
}

Write-Host "  Log: $LogFile" -ForegroundColor White
"FINAL: $totalDone procesate $(Format-Bytes $totalSaved) [$encoderName/$container]" |
    Out-File $LogFile -Append -Encoding UTF8
Read-Host "`nApasa Enter"
