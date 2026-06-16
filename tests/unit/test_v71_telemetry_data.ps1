# v71 — mirror al test_v71_telemetry_data.sh (PS1).
#   embed/strip: ffmpeg NU poate re-muxa pistele de date proprietare (djmd/dbgi/tmcd/
#   gpmd, codec=none) → `-c copy` esueaza. Fix: `-dn` (drop data); telemetria ramane
#   ca SRT/CSV/GPX. Source-level (mereu) + functional (sample DJI cu data + ffmpeg).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$tel  = Get-Content (Join-Path $SRC 'av_telemetry.sh')  -Raw
$telp = Get-Content (Join-Path $SRC 'av_telemetry.ps1') -Raw
# count literal (escape → wildcard/regex chars tratate literal; Assert-Contains foloseste -clike → nesigur cu ?/[)
function CountOf($h, $n) { [regex]::Matches($h, [regex]::Escape($n)).Count }

# ── 1. embed: -dn, FARA -map 0:d? (bash + PS1) ────────────────────────────
Assert-Match $tel  ([regex]::Escape('ff_args+=("${ff_maps[@]}" -dn -c:v copy -c:a copy)')) "embed bash: -dn (drop data ne-muxabil)"
Assert-Eq 0 (CountOf $tel  '-map "0:d?"')      "embed bash: nu mai mapeaza data (codec none)"
Assert-Match $telp ([regex]::Escape('"-dn","-c:v","copy","-c:a","copy"')) "embed PS1: -dn"
Assert-Eq 0 (CountOf $telp '"-map","0:d?"')    "embed PS1: nu mai mapeaza data"

# ── 2. strip: -dn in toate cele 3 cai (bash + PS1) ────────────────────────
Assert-Eq 3 (CountOf $tel  'maps="-map 0 -dn"')   "strip bash: -dn in toate 3 caile (dji/gopro/telem)"
Assert-Eq 3 (CountOf $telp '@("-map","0","-dn")') "strip PS1: -dn in toate 3 caile"

# ── 3. meniul DJI nu mai promite fals 'keep GPS' (imposibil la re-mux) ─────
Assert-Eq 0 (CountOf $tel 'Doar debug (dbgi ~295 MB)') "meniu bash: optiunea inselatoare scoasa"
Assert-Match $telp ([regex]::Escape('GPS-ul djmd NU poate ramane la re-mux')) "meniu PS1: nota onesta DJI"

# ── 4. FUNCTIONAL — sample DJI cu data stream (codec none) → embed/strip reusesc ──
$dji = Get-ChildItem $SRC -Filter 'DJI_*.MP4' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($dji -and (Get-Command ffmpeg -ErrorAction SilentlyContinue) -and (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    $hasData = @(& ffprobe -v error -select_streams d -show_entries stream=index -of csv=p=0 $dji.FullName 2>$null).Count
    if ($hasData -gt 0) {
        $td = Join-Path $env:TEMP ("v71tel_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force $td | Out-Null
        "1`n00:00:00,000 --> 00:00:01,000`nt`n" | Set-Content "$td\t.srt" -Encoding ascii
        # embed pattern (ca Invoke-EmbedTelemetryLossless, -dn) → MKV reuseste pe data codec none
        & ffmpeg -v error -y -t 1 -i $dji.FullName -i "$td\t.srt" -map 0:v -map 0:a? -map 1:s -dn -c:v copy -c:a copy -c:s srt "$td\embed.mkv" 2>$null
        $ok = ($LASTEXITCODE -eq 0 -and (Test-Path "$td\embed.mkv") -and (Get-Item "$td\embed.mkv").Length -gt 0)
        Assert-Eq $true $ok "functional: embed -dn -> MKV reuseste pe DJI (data codec none)"
        $ns = @(& ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$td\embed.mkv" 2>$null).Count
        Assert-Eq 1 $ns "functional: SRT-ul de telemetrie pastrat"
        $nd = @(& ffprobe -v error -select_streams d -show_entries stream=index -of csv=p=0 "$td\embed.mkv" 2>$null).Count
        Assert-Eq 0 $nd "functional: data ne-muxabil dropat (matroska)"
        # strip mode 1 pattern (-map 0 -dn) → reuseste (inainte: "Remux esuat")
        & ffmpeg -v error -y -t 1 -i $dji.FullName -map 0 -dn -c copy -map_metadata 0 "$td\strip.mp4" 2>$null
        $ok2 = ($LASTEXITCODE -eq 0 -and (Test-Path "$td\strip.mp4") -and (Get-Item "$td\strip.mp4").Length -gt 0)
        Assert-Eq $true $ok2 "functional: strip -map 0 -dn reuseste pe DJI"
        Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
    } else { Write-Host "  (functional sarit: DJI fara data stream)" -ForegroundColor DarkGray }
} else { Write-Host "  (functional sarit: niciun DJI_*.MP4 in src/ sau ffmpeg/ffprobe lipsesc)" -ForegroundColor DarkGray }

Invoke-TestSummary
