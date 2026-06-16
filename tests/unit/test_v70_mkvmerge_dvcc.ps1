# v70 — mirror al test_v70_mkvmerge_dvcc.sh (PS1).
#   mkvmerge soft-optional pt semnalizare dvcC de container pe hibridele HEVC DV.
#   Source-level (mereu) + functional (cand exista ffmpeg+dovi_tool+mkvmerge):
#   construieste un hibrid HEVC mic self-contained → muxeaza via Invoke-DvMkvMux
#   (AST import) → asserteaza "DOVI configuration record".
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }

$enc    = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
$common = Get-Content (Join-Path $SRC "av_common.sh") -Raw

# ── 1. AV_TOOL_MKVMERGE in config (canon partajat) + resolver PS1 inline ──
Assert-Match $common ([regex]::Escape('AV_TOOL_MKVMERGE="${AV_TOOL_MKVMERGE:-mkvmerge}"')) "AV_TOOL_MKVMERGE in blocul config (canon bash)"
Assert-Match $enc ([regex]::Escape('if ($env:AV_TOOL_MKVMERGE) { $env:AV_TOOL_MKVMERGE } else { "mkvmerge" }')) "resolver PS1 inline env-overridable (AST-safe)"

# ── 2. Invoke-DvMkvMux: definit + --default-duration + --no-video ──────────
Assert-Match $enc 'function Invoke-DvMkvMux' "Invoke-DvMkvMux definit"
Assert-Match $enc ([regex]::Escape('--default-duration')) "Invoke-DvMkvMux: --default-duration (raw nu poarta timing)"
Assert-Match $enc ([regex]::Escape('--no-video $donor')) "Invoke-DvMkvMux: non-video din donor"
Assert-Match $enc ([regex]::Escape('-map 0:a? -map 0:s? -map 0:t? -map_chapters 0')) "Invoke-DvMkvMux: donor MKV non-video pe surse non-MKV (#2)"

# ── 3. mkvmerge-FIRST (fallback pas MP4 v69) in cele 2 situri PS1 ──────────
Assert-Match $enc ([regex]::Escape('if (Invoke-DvMkvMux -RawHevc $Modified -Original $Original -Output $Output) { return $true }')) "Invoke-HdvCombineWithOriginal: mkvmerge inainte de pas MP4"
Assert-Match $enc ([regex]::Escape('$container -eq "mkv" -and (Invoke-DvMkvMux -RawHevc $injectedTemp -Original $outFile -Output $finalTemp)')) "triple-layer: mkvmerge pe ramura mkv (HEVC+AV1 v71)"

# ── 4. installer-ele exista ───────────────────────────────────────────────
Assert-Eq $true (Test-Path (Join-Path $SRC "tools\mkvmerge_installer.ps1")) "installer PS1 exista"
Assert-Eq $true (Test-Path (Join-Path $SRC "tools\mkvmerge_installer.sh")) "installer bash exista"

# ── 4b. #3: av_mux post-process dvcC pe raw HEVC DV -> MKV ─────────────
$muxPs = Get-Content (Join-Path $SRC "av_mux.ps1") -Raw
Assert-Match $muxPs ([regex]::Escape('$dvRawSrc = $video')) "av_mux: salveaza calea raw HEVC pt dvcC (#3)"
Assert-Match $muxPs ([regex]::Escape('Invoke-AvMuxDvSignal -Raw $dvRawSrc -Built $finalOut -Target $Target')) "av_mux Mux: post-process via Invoke-AvMuxDvSignal (#3)"
Assert-Match $muxPs ([regex]::Escape('--no-video $Built')) "av_mux dispatch: mkvmerge --no-video"

# ── 5. FUNCTIONAL — hibrid HEVC mic self-contained → dvcC via Invoke-DvMkvMux ──
$mkvm = if ($env:AV_TOOL_MKVMERGE) { $env:AV_TOOL_MKVMERGE } else { "mkvmerge" }
$dovi = if ($env:AV_TOOL_DOVI) { $env:AV_TOOL_DOVI } else { "dovi_tool" }
$haveAll = (Get-Command ffmpeg -ErrorAction SilentlyContinue) -and (Get-Command ffprobe -ErrorAction SilentlyContinue) `
           -and (Get-Command $dovi -ErrorAction SilentlyContinue) -and (Get-Command $mkvm -ErrorAction SilentlyContinue)
if ($haveAll) {
    Import-AvEncodeFunctions -Names @('Invoke-DvMkvMux') | Out-Null
    $td = Join-Path $env:TEMP ("v70_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $td | Out-Null
    # clip PQ cu audio (lang=fre) + sub mov_text (lang=spa) — exercita donor-ul (#2):
    # mov_text forteaza ramura -c:s srt din donor.
    "1`n00:00:00,000 --> 00:00:01,000`nhi`n" | Set-Content "$td\s.srt" -Encoding ascii
    & ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=320x240:rate=12:duration=1" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=1" -i "$td\s.srt" -map 0:v -map 1:a -map 2:s -c:v libx265 -pix_fmt yuv420p10le -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" -c:a aac -c:s mov_text -metadata:s:a:0 language=fre -metadata:s:s:0 language=spa -t 1 "$td\t.mp4" 2>$null
    & ffmpeg -y -loglevel error -i "$td\t.mp4" -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb "$td\t.hevc" 2>$null
    Set-Content "$td\cfg.json" '{ "cm_version": "V40", "length": 12, "level6": { "max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 1, "max_content_light_level": 1000, "max_frame_average_light_level": 400 } }' -Encoding ascii
    & $dovi generate -j "$td\cfg.json" -o "$td\rpu.bin" 2>$null | Out-Null
    & $dovi inject-rpu -i "$td\t.hevc" --rpu-in "$td\rpu.bin" -o "$td\hybrid.hevc" 2>$null | Out-Null
    if ((Test-Path "$td\hybrid.hevc") -and (Get-Item "$td\hybrid.hevc").Length -gt 0) {
        $r = Invoke-DvMkvMux -RawHevc "$td\hybrid.hevc" -Original "$td\t.mp4" -Output "$td\out.mkv"
        Assert-Eq $true $r "functional: Invoke-DvMkvMux reuseste pe hibrid HEVC"
        $probe = ((& ffprobe -v error -select_streams v:0 -show_streams -show_entries stream_side_data=side_data_type "$td\out.mkv" 2>$null) -join "`n")
        Assert-Match $probe "DOVI configuration record" "functional: dvcC scris in MKV"
        # #2: donor-ul pastreaza pista audio + limba pe sursa non-MKV (consistent cu calea ffmpeg)
        $alang = (& ffprobe -v error -select_streams a:0 -show_entries stream_tags=language -of default=noprint_wrappers=1:nokey=1 "$td\out.mkv" 2>$null | Select-Object -First 1)
        if ($alang) { $alang = $alang.Trim() }
        Assert-Eq "fre" $alang "functional #2: donor pastreaza limba audio pe sursa non-MKV"
        $ssub = (& ffprobe -v error -select_streams s:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$td\out.mkv" 2>$null | Select-Object -First 1)
        if ($ssub) { $ssub = $ssub.Trim() }
        Assert-Eq "subrip" $ssub "functional #2: donor pastreaza subtitrarea (mov_text->srt via -c:s srt) pe non-MKV"
        $old = $env:AV_TOOL_MKVMERGE; $env:AV_TOOL_MKVMERGE = "C:\nonexistent\zz_mux.exe"
        $r2 = Invoke-DvMkvMux -RawHevc "$td\hybrid.hevc" -Original "$td\t.mp4" -Output "$td\fb.mkv"
        $env:AV_TOOL_MKVMERGE = $old
        Assert-Eq $false $r2 "functional: fallback (tool absent) -> false"
        Assert-Eq $false (Test-Path "$td\fb.mkv") "functional: fallback nu lasa output partial"
    } else {
        Write-Host "  (functional sarit: build hibrid esuat)" -ForegroundColor DarkGray
    }
    Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "  (functional sarit: ffmpeg/ffprobe/dovi_tool/mkvmerge lipsesc)" -ForegroundColor DarkGray
}

Invoke-TestSummary
