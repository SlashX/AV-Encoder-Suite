# v71 — mirror al test_v71_mp4box_dvcc.sh (PS1).
#   MP4Box (GPAC) soft-optional pt dvcC de container pe hibridele HEVC DV → MP4/MOV.
#   Source-level (mereu) + functional (cand exista ffmpeg+dovi_tool+MP4Box):
#   hibrid HEVC multi-track → Invoke-DvMp4Mux (AST) → dvcC + audio/sub pastrate.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }

$enc    = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
$common = Get-Content (Join-Path $SRC "av_common.sh") -Raw
$muxPs  = Get-Content (Join-Path $SRC "av_mux.ps1") -Raw

# ── 1. AV_TOOL_MP4BOX in config (canon partajat) + resolver PS1 inline ────
Assert-Match $common ([regex]::Escape('AV_TOOL_MP4BOX="${AV_TOOL_MP4BOX:-mp4box}"')) "AV_TOOL_MP4BOX in blocul config (canon bash)"
Assert-Match $enc ([regex]::Escape('if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } elseif ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "GPAC\mp4box.exe"))) { Join-Path $PSScriptRoot "GPAC\mp4box.exe" } else { "mp4box" }')) "resolver PS1 inline env-overridable + fallback co-locat src\GPAC (AST-safe, v93)"
Assert-Match $common ([regex]::Escape('-f "$SCRIPT_DIR/GPAC/mp4box.exe"')) "v93: fallback co-locat src/GPAC si in canonul bash (relativ, fara cai absolute)"

# ── 2. Invoke-DvMp4Mux: definit + gating MP4/MOV + :fps + #trackID ────────
Assert-Match $enc 'function Invoke-DvMp4Mux' "Invoke-DvMp4Mux definit"
Assert-Match $enc ([regex]::Escape("@('mp4','mov','m4v','qt')")) "Invoke-DvMp4Mux: gating pe surse ISO"
Assert-Match $enc ([regex]::Escape('${RawHevc}:fps=${afr}')) "Invoke-DvMp4Mux: :fps (raw nu poarta timing)"
Assert-Match $enc ([regex]::Escape('${Original}#${dec}')) "Invoke-DvMp4Mux: -add per track ID (#N)"

# ── 3. mp4/mov in cele 2 situri PS1 + av_mux ──────────────────────────────
Assert-Match $enc ([regex]::Escape('if (Invoke-DvMp4Mux -RawHevc $Modified -Original $Original -Output $Output) { return $true }')) "Invoke-HdvCombineWithOriginal: MP4Box pe ramura mp4/mov"
Assert-Match $enc ([regex]::Escape('Invoke-DvMp4Mux -RawHevc $injectedTemp -Original $outFile -Output $finalTemp')) "triple-layer: MP4Box pe ramura mp4/mov"
Assert-Match $muxPs 'function Invoke-AvMuxDvSignal' "av_mux: dispatch Invoke-AvMuxDvSignal definit (DRY Mux+Remux)"
Assert-Match $muxPs ([regex]::Escape('if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } elseif ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "GPAC\mp4box.exe"))) { Join-Path $PSScriptRoot "GPAC\mp4box.exe" } else { "mp4box" }')) "av_mux dispatch: MP4Box inline + fallback co-locat (mp4/mov, v93)"
Assert-Match $muxPs ([regex]::Escape('Invoke-AvMuxDvSignal -Raw $rxRaw -Built $finalOut -Target $Target')) "av_mux Remux: DV-aware post-process (#1)"

# ── 3b. passthrough stream-copy: dispatch+resignal partajat in av_encode.ps1 + 3 situri ──
Assert-Match $enc 'function Invoke-DvContainerSignal' "av_encode: Invoke-DvContainerSignal definit (dispatch partajat)"
Assert-Match $enc 'function Invoke-DvResignalCopy' "av_encode: Invoke-DvResignalCopy definit (re-signal stream-copy)"
Assert-Match $enc ([regex]::Escape('Invoke-DvResignalCopy -Source $fileInfo.FullName -Output $outFile -Target $container')) "Invoke-StreamCopy: re-signal dvcC"
Assert-Match $enc ([regex]::Escape('Invoke-DvResignalCopy -Source $f.FullName -Output $outFile -Target $eaContainer')) "audio-only: re-signal dvcC"
Assert-Match $enc ([regex]::Escape('Invoke-DvResignalCopy -Source $src.FullName -Output $outPath')) "trim: re-signal dvcC"

# ── 4. installerele exista ────────────────────────────────────────────────
Assert-Eq $true (Test-Path (Join-Path $SRC "tools\mp4box_installer.ps1")) "installer PS1 exista"
Assert-Eq $true (Test-Path (Join-Path $SRC "tools\mp4box_installer.sh")) "installer bash exista"

# ── 5. FUNCTIONAL — hibrid HEVC multi-track → dvcC via Invoke-DvMp4Mux ─────
$mp4box = if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } else { "mp4box" }
$gpacLocal = Join-Path $PSScriptRoot "..\..\src\GPAC\mp4box.exe"  # copia co-locata (v93) — fara cai absolute
if (-not (Get-Command $mp4box -ErrorAction SilentlyContinue) -and (Test-Path $gpacLocal)) { $mp4box = (Resolve-Path $gpacLocal).Path }
$dovi = if ($env:AV_TOOL_DOVI) { $env:AV_TOOL_DOVI } else { "dovi_tool" }
$haveAll = (Get-Command ffmpeg -ErrorAction SilentlyContinue) -and (Get-Command ffprobe -ErrorAction SilentlyContinue) `
           -and (Get-Command $dovi -ErrorAction SilentlyContinue) -and (Get-Command $mp4box -ErrorAction SilentlyContinue)
if ($haveAll) {
    Import-AvEncodeFunctions -Names @('Invoke-DvMp4Mux') | Out-Null
    $td = Join-Path $env:TEMP ("v71_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $td | Out-Null
    "1`n00:00:00,000 --> 00:00:01,000`nhi`n" | Set-Content "$td\s.srt" -Encoding ascii
    # meta cu 2 capitole — calea MP4Box NU le copiaza din -add → dump-chap+chap le cara
    ";FFMETADATA1`n[CHAPTER]`nTIMEBASE=1/1000`nSTART=0`nEND=500`ntitle=Intro`n[CHAPTER]`nTIMEBASE=1/1000`nSTART=500`nEND=1000`ntitle=Scene 2`n" | Set-Content "$td\meta.txt" -Encoding ascii
    & ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=320x240:rate=12:duration=1" -f lavfi -i "sine=frequency=440:duration=1" -f lavfi -i "sine=frequency=880:duration=1" -i "$td\s.srt" -i "$td\meta.txt" -map 0:v -map 1:a -map 2:a -map 3:s -map_metadata 4 -map_chapters 4 -c:v libx265 -pix_fmt yuv420p10le -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" -c:a aac -c:s mov_text -metadata:s:a:0 language=fre -metadata:s:a:1 language=ger -metadata:s:s:0 language=spa -t 1 "$td\multi.mp4" 2>$null
    & ffmpeg -y -loglevel error -i "$td\multi.mp4" -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb "$td\v.hevc" 2>$null
    Set-Content "$td\cfg.json" '{ "cm_version": "V40", "length": 12, "level6": { "max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 1, "max_content_light_level": 1000, "max_frame_average_light_level": 400 } }' -Encoding ascii
    & $dovi generate -j "$td\cfg.json" -o "$td\rpu.bin" 2>$null | Out-Null
    & $dovi inject-rpu -i "$td\v.hevc" --rpu-in "$td\rpu.bin" -o "$td\vh.hevc" 2>$null | Out-Null
    # Prerechizita robusta (anti-flaky sub incarcarea suitei): encode-ul greu (multi.mp4 =
    # libx265 10-bit + 3 input-uri lavfi + 2 audio + 1 sub + 2 capitole) SI injectul DV
    # (vh.hevc) trebuie sa fi reusit. Daca un subproces esueaza tranzitoriu sub presiune
    # de fork (rar), prerechizita iese malformata → SKIP (codul e validat izolat + de
    # restul matricei), in loc de cascada de FAIL-uri pe un setup incomplet.
    $preA = @(& ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$td\multi.mp4" 2>$null).Count
    $preS = @(& ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$td\multi.mp4" 2>$null).Count
    $preC = @(& ffprobe -v error -show_chapters -of csv=p=0 "$td\multi.mp4" 2>$null).Count
    $preOk = ((Test-Path "$td\vh.hevc") -and (Get-Item "$td\vh.hevc").Length -gt 0 -and $preA -eq 2 -and $preS -eq 1 -and $preC -eq 2)
    if ($preOk) {
        # un retry pe transient rar de unealta (MP4Box/ffmpeg pot rata o pista sub presiune
        # de fork — non-determinist, ~1/15 sub incarcarea suitei; 14/14 curat la repro izolat).
        # Un bug DETERMINIST ar esua AMBELE incercari → tot prins de aserțiunile de mai jos.
        $r = $false
        for ($att = 1; $att -le 2; $att++) {
            Remove-Item "$td\out.mp4" -ErrorAction SilentlyContinue
            $r = Invoke-DvMp4Mux -RawHevc "$td\vh.hevc" -Original "$td\multi.mp4" -Output "$td\out.mp4"
            $tsc = @(& ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$td\out.mp4" 2>$null).Count
            $tac = @(& ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$td\out.mp4" 2>$null).Count
            if ($r -and $tsc -eq 1 -and $tac -eq 2) { break }
        }
        Assert-Eq $true $r "functional: Invoke-DvMp4Mux reuseste pe hibrid HEVC"
        $probe = ((& ffprobe -v error -select_streams v:0 -show_streams -show_entries stream_side_data=side_data_type "$td\out.mp4" 2>$null) -join "`n")
        Assert-Match $probe "DOVI configuration record" "functional: dvcC scris in MP4"
        $nv = @(& ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$td\out.mp4" 2>$null).Count
        Assert-Eq 1 $nv "functional: un singur track video (fara duplicat)"
        $a0 = (& ffprobe -v error -select_streams a:0 -show_entries stream_tags=language -of default=noprint_wrappers=1:nokey=1 "$td\out.mp4" 2>$null | Select-Object -First 1)
        if ($a0) { $a0 = $a0.Trim() }
        Assert-Eq "fre" $a0 "functional: limba audio 1 (fre) pastrata"
        $na = @(& ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$td\out.mp4" 2>$null).Count
        Assert-Eq 2 $na "functional: ambele piste audio pastrate"
        $ns = @(& ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$td\out.mp4" 2>$null).Count
        Assert-Eq 1 $ns "functional: subtitrarea pastrata"
        $nc = @(& ffprobe -v error -show_chapters -of csv=p=0 "$td\out.mp4" 2>$null).Count
        Assert-Eq 2 $nc "functional: capitolele pastrate (dump-chap + chap; MP4Box -add nu le copiaza)"
        # gating: sursa MKV → $false (fallback)
        & ffmpeg -y -loglevel error -i "$td\multi.mp4" -c copy "$td\src.mkv" 2>$null
        $gk = Invoke-DvMp4Mux -RawHevc "$td\vh.hevc" -Original "$td\src.mkv" -Output "$td\frommkv.mp4"
        Assert-Eq $false $gk "functional: gating non-ISO (MKV) -> false"
        Assert-Eq $false (Test-Path "$td\frommkv.mp4") "functional: gating nu lasa output"
    } else {
        Write-Host "  (functional sarit: prerechizita build esuata tranzitoriu sub incarcare — cod validat izolat)" -ForegroundColor DarkGray
    }
    Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "  (functional sarit: ffmpeg/ffprobe/dovi_tool/MP4Box lipsesc)" -ForegroundColor DarkGray
}

Invoke-TestSummary
