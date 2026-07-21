# v88 — Eclipsa Audio / IAMF (mirror test_v88_iamf.sh): detectie (stream_group=type),
# authoring nativ ffmpeg (stereo/5.1/7.1 + 7.1.4 din v89, substream-uri Opus izolate cu `pan`, raw
# .iamf -> MP4Box package) + passthrough (ffmpeg APLATIZEAZA grupul la Opus simplu la
# ORICE mux/copy -> gate copy-ca-UN-grup + re-graft Invoke-IamfPreserve pe caile 1:1;
# analog dvcC v70-72 / Atmos v87). IAMF = DOAR MP4/MOV. Source-level (ambele platforme)
# + functional REAL pe Windows (gated ffmpeg-cu-muxer-iamf + MP4Box; fixtures locale).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$src = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "src"
$psText  = Get-Content (Join-Path $src "av_encode.ps1") -Raw
$muxPs   = Get-Content (Join-Path $src "av_mux.ps1") -Raw
$chkPs   = Get-Content (Join-Path $src "av_check.ps1") -Raw
$avcText = Get-Content (Join-Path $src "av_common.sh") -Raw
$aeaText = Get-Content (Join-Path $src "av_encoder_audio.sh") -Raw
$muxSh   = Get-Content (Join-Path $src "av_mux.sh") -Raw
$tcText  = Get-Content (Join-Path $src "av_trimconcat.sh") -Raw
$chkText = Get-Content (Join-Path $src "av_check.sh") -Raw

# ── source-level PS1: helperi in av_encode.ps1 ────────────────────────
Assert-Eq 1 ([regex]::Matches($psText, '(?m)^function Get-IamfLayout \{').Count) `
    "Get-IamfLayout exista in av_encode.ps1"
Assert-Match $psText 'function Get-IamfLayout \{[\s\S]*?IAMF Audio Element[\s\S]*?\n\}' `
    "detectia e AUTORITARA pe stream_group=type (nu codec_name — substream-urile sunt opus simplu)"
Assert-Match $psText 'function Get-IamfLayout \{[\s\S]*?-hide_banner[\s\S]*?\n\}' `
    "layout-ul se citeste din banner (NU -v error — ar suprima liniile Layer N:)"
Assert-Eq 1 ([regex]::Matches($psText, '(?m)^function Invoke-IamfAuthor \{').Count) `
    "Invoke-IamfAuthor exista in av_encode.ps1"
Assert-Match $psText 'function Invoke-IamfAuthor \{[\s\S]*?pan=stereo[\s\S]*?\n\}' `
    "substream-urile se izoleaza cu pan (layout GENERIC — channelsplit pastreaza etichete surround)"
Assert-Match $psText 'function Invoke-IamfAuthor \{[\s\S]*?stg=0,annotations[\s\S]*?\n\}' `
    "mix_presentation foloseste stg=0,annotations (VIRGULA — cu colon stereo esueaza la header)"
Assert-Match $psText 'function Invoke-IamfAuthor \{[\s\S]*?st=0:st=1:st=2:st=3[\s\S]*?\n\}' `
    "referintele de substream folosesc COLON intre st="
Assert-Match $psText 'function Invoke-IamfAuthor \{[\s\S]*?AV_TOOL_MP4BOX[\s\S]*?\n\}' `
    "authoring-ul impacheteaza prin env AV_TOOL_MP4BOX (nu nume hardcodat)"
Assert-Eq 1 ([regex]::Matches($psText, '(?m)^function Invoke-IamfPreserve \{').Count) `
    "Invoke-IamfPreserve exista in av_encode.ps1"
Assert-Match $psText 'function Invoke-IamfPreserve \{[\s\S]*?Media Type: soun:iamf[\s\S]*?\n\}' `
    "preserve gaseste track ID-ul din perechea Track-Info + Media Type (ID real, nu pozitie)"
Assert-Match $psText 'function Invoke-IamfPreserve \{[\s\S]*?2>&1[\s\S]*?\n\}' `
    "preserve citeste MP4Box -info cu 2>&1 (GPAC scrie pe STDERR)"
Assert-Match $psText 'function Invoke-IamfPreserve \{[\s\S]*?AllowNoAudio[\s\S]*?\n\}' `
    "preserve are switch -AllowNoAudio (Remux: audio cerut dar dropat de compat)"
Assert-Match $psText "function Invoke-IamfPreserve \{[\s\S]*?'mp4','mov','m4v'[\s\S]*?\n\}" `
    "preserve e gateat pe MP4/MOV (Matroska/WebM fara mapare IAMF)"

# ── source-level PS1: situri graft + gate-uri dialog ──────────────────
Assert-Eq 4 ([regex]::Matches($psText, 'Invoke-IamfPreserve -Source').Count) `
    "4 situri graft in av_encode.ps1 (post-encode + stream-copy + audio-only regraft + audio-only general)"
Assert-Match $psText '\$iamfSrcGate' "gate IAMF in dialogul fluxului principal"
Assert-Match $psText '\$eaIamfSrc'   "gate IAMF in dialogul audio-only"
Assert-Contains $psText "10-Eclipsa (IAMF)" "meniul audio-only are optiunea 10 Eclipsa (IAMF)"
Assert-Contains $psText 'Alege 1-10' "promptul audio-only extins la 1-10"
Assert-Contains $psText 'Sursa are DEJA grup Eclipsa/IAMF' `
    "edge anti-downgrade: sursa deja-IAMF -> copy 1:1 + re-graft (NU authoring din substream stereo)"
Assert-Contains $psText 'Eclipsa/IAMF exista doar in MP4/MOV' `
    "gate container: IAMF cere MP4/MOV (oferta switch sau Opus)"

# ── source-level PS1: TC warns + av_mux + av_check ────────────────────
Assert-Eq 2 ([regex]::Matches($psText, 'Sursele au grup Eclipsa/IAMF').Count) `
    "ambele warn-uri spatiale TC (sources + filter) au linia IAMF"
Assert-Eq 1 ([regex]::Matches($muxPs, '(?m)^function Get-IamfLayout \{').Count) `
    "av_mux.ps1 are copia standalone Get-IamfLayout"
Assert-Eq 1 ([regex]::Matches($muxPs, '(?m)^function Invoke-IamfPreserve \{').Count) `
    "av_mux.ps1 are copia standalone Invoke-IamfPreserve"
Assert-Match $muxPs 'IamfWantAudio' `
    "Remux cara IamfWantAudio (audio cerut pre-filtrare compat -> graft si pe drop de compat)"
Assert-Match $muxPs 'seenIdx' `
    "Get-RemuxStreams are dedupe (ffprobe listeaza dublu pe IAMF-in-MP4 + linii doar-CR)"
Assert-Contains $muxPs 'UN grup Eclipsa/IAMF (atomic)' `
    "Remux: nota inline la selectia audio pe surse IAMF (tinta ISO)"
Assert-Contains $muxPs 'nu are mapare IAMF' `
    "Remux: warn inline pe tinta non-ISO (MKV/WebM)"
Assert-Eq 1 ([regex]::Matches($chkPs, '(?m)^function Get-IamfLayout \{').Count) `
    "av_check.ps1 are copia standalone Get-IamfLayout"
Assert-Contains $chkPs '(Eclipsa)' "av_check.ps1 eticheteaza audio-ul Eclipsa"

# ── source-level: audit v88 — consistenta fluxurilor IAMF cu fluxul normal ──
$burnPs  = Get-Content (Join-Path $src "av_burnin.ps1") -Raw
$burnSh  = Get-Content (Join-Path $src "av_burnin.sh") -Raw
Assert-Eq 2 ([regex]::Matches($psText, [regex]::Escape('Invoke-DvResignalCopy -Source $f.FullName -Output $outFile -Target $eaContainer')).Count) `
    "PS1: dvcC re-scris pe ambele cai audio-only (normal + copy-IAMF)"
Assert-Eq 1 ([regex]::Matches($psText, 'sursa nu are pista audio').Count) `
    "PS1: skip onest pe sursa fara audio la authoring"
Assert-Match $psText 'function Invoke-IamfAuthor \{[\s\S]*?sbtl\|subt[\s\S]*?\n\}' `
    "PS1: authoring importa subtitrarile ISO cu #trackID (NU text: = capitole QT)"
Assert-Match $psText 'function Invoke-IamfAuthor \{[\s\S]*?dump-chap[\s\S]*?\n\}' `
    "PS1: authoring cara capitolele (MP4Box -add nu le copiaza — regula v71)"
Assert-Match $psText 'function Invoke-IamfPreserve \{[\s\S]*?dump-chap[\s\S]*?\n\}' `
    "PS1: preserve cara capitolele determinist (av_encode)"
Assert-Match $muxPs 'function Invoke-IamfPreserve \{[\s\S]*?dump-chap[\s\S]*?\n\}' `
    "PS1: preserve cara capitolele determinist (copia av_mux)"
Assert-Match $psText 'function Show-IncompatAudioCopyWarnings \{[\s\S]*?stream=index,codec_name[\s\S]*?\n\}' `
    "PS1: warn-ul compat dedupe pe index (IAMF dublu-listat dadea warn-uri fantoma)"
Assert-Match $chkPs 'Sort-Object -Unique' "PS1: av_check numara pistele audio cu dedupe"
Assert-Eq 1 ([regex]::Matches($chkPs, 'stream=index,codec_name,bit_rate').Count) `
    "PS1: av_check per-track are index in query (dedupe piste fantoma)"
Assert-Eq 1 ([regex]::Matches($burnPs, '(?m)^function Get-IamfLayout \{').Count) `
    "PS1: av_burnin.ps1 are copia standalone Get-IamfLayout (pt warn)"
Assert-Eq 1 ([regex]::Matches($burnPs, 'la burn-in audio-ul se copiaza').Count) `
    "PS1: burn-in avertizeaza onest pe surse IAMF"

# ── source-level v90: graftul IAMF pe burn-in (inchide TO-DO-ul gated v88) ──
Assert-Eq 1 ([regex]::Matches($burnPs, '(?m)^function Invoke-IamfPreserve \{').Count) `
    "v90: av_burnin.ps1 are copia standalone Invoke-IamfPreserve"
Assert-Eq 4 ([regex]::Matches($burnPs, [regex]::Escape('Invoke-IamfPreserve -Source $p.Video -Output $out')).Count) `
    "v90: 4 situri graft PS1 (HUD/SRT/ASS/img)"
Assert-Eq 4 ([regex]::Matches($burnPs, 'outSuffix -ne "preview"').Count) `
    "v90: graftul PS1 gardat pe output-ul complet (NU pe preview)"
Assert-Contains $burnPs 'pe MP4/MOV grupul se RE-SCRIE automat' `
    "v90: nota onesta actualizata PS1"
# paritate bash v90
Assert-Eq 4 ([regex]::Matches($burnSh, [regex]::Escape('_iamf_preserve "$vid" "$out" || true')).Count) `
    "v90: 4 situri graft bash, gardate || true (set -e)"
Assert-Eq 4 ([regex]::Matches($burnSh, 'out_suffix" != "preview"').Count) `
    "v90: gate preview bash pe toate 4 fluxurile"
Assert-Contains $burnSh 'pe MP4/MOV grupul se RE-SCRIE automat' `
    "v90: nota onesta actualizata bash (paritate mesaj)"

# ── source-level v89: authoring 7.1.4 (12ch, 7 substream-uri) ─────────
Assert-Match $psText 'function Invoke-IamfAuthor \{[\s\S]*?st=0:st=1:st=2:st=3:st=4:st=5:st=6[\s\S]*?\n\}' `
    "PS1 v89: Invoke-IamfAuthor are cazul 7.1.4 (7 substream-uri: 5 perechi stereo + C + LFE)"
Assert-Match $psText 'function Invoke-IamfAuthor \{[\s\S]*?sound_system=7\.1\.4[\s\S]*?\n\}' `
    "PS1 v89: mix_presentation are layout sound_system=7.1.4"
Assert-Contains $psText 'IAMF suporta surse 2/6/8/12 canale' `
    "PS1 v89: gate-ul de canale extins la 12 (mesaj skip)"
foreach ($pair in @(@($psText,'av_encode.ps1'), @($muxPs,'av_mux.ps1'), @($chkPs,'av_check.ps1'), @($burnPs,'av_burnin.ps1'))) {
    Assert-Match $pair[0] 'function Get-IamfLayout \{[\s\S]*?12 channels[\s\S]*?\n\}' `
        ("PS1 v89: Get-IamfLayout mapeaza 12ch -> 7.1.4 in " + $pair[1])
}
# paritate bash v89
Assert-Match $avcText 'st=0:st=1:st=2:st=3:st=4:st=5:st=6' "bash v89: _iamf_author are cazul 7.1.4 (paritate)"
Assert-Match $avcText '12 channels' "bash v89: _iamf_probe mapeaza 12ch (paritate)"
Assert-Contains $aeaText 'IAMF suporta surse 2/6/8/12 canale' "bash v89: gate 12ch (paritate mesaj)"
# paritate bash pe audit
Assert-Eq 1 ([regex]::Matches($aeaText, [regex]::Escape('_dv_resignal_copy "$file" "$output" "$CONTAINER"')).Count) `
    "bash: fluxul deja-IAMF copy re-scrie dvcC (paritate)"
Assert-Eq 3 ([regex]::Matches($aeaText, [regex]::Escape('_dji_preserve_meta_postencode "$file" "$output"')).Count) `
    "bash: GPS DJI re-grefat pe toate 3 caile audio-only (paritate)"
Assert-Eq 1 ([regex]::Matches($burnSh, 'la burn-in audio-ul se copiaza').Count) `
    "bash: burn-in avertizeaza onest pe surse IAMF (paritate)"
Assert-Match $avcText '(?s)_iamf_author\(\).*?dump-chap.*?\n\}' `
    "bash: authoring cara capitolele (paritate)"
Assert-Match $avcText '(?s)_iamf_preserve\(\).*?dump-chap.*?\n\}' `
    "bash: preserve cara capitolele (paritate)"

# ── paritate bash (source-level) ──────────────────────────────────────
Assert-Eq 1 ([regex]::Matches($avcText, '(?m)^_iamf_probe\(\)').Count)    "bash: _iamf_probe exista (paritate)"
Assert-Eq 1 ([regex]::Matches($avcText, '(?m)^_iamf_author\(\)').Count)   "bash: _iamf_author exista (paritate)"
Assert-Eq 1 ([regex]::Matches($avcText, '(?m)^_iamf_preserve\(\)').Count) "bash: _iamf_preserve exista (paritate)"
Assert-Eq 2 ([regex]::Matches($avcText, [regex]::Escape('_iamf_preserve "$file" "$output"')).Count) `
    "bash: 2 situri graft in av_common.sh (run_encode_loop + do_stream_copy)"
Assert-Eq 2 ([regex]::Matches($aeaText, [regex]::Escape('_iamf_preserve "$file" "$output"')).Count) `
    "bash: 2 situri graft in av_encoder_audio.sh (flux deja-IAMF + graft general)"
Assert-Eq 1 ([regex]::Matches($muxSh, [regex]::Escape('_iamf_preserve "$file" "$final_out"')).Count) `
    "bash: sit graft pe Remux (av_mux.sh)"
Assert-Match $muxSh 'REMUX_IAMF_WANT_AUDIO' `
    "bash: Remux paseaza REMUX_IAMF_WANT_AUDIO (paritate IamfWantAudio)"
Assert-Contains $aeaText '10) Eclipsa Audio' "bash: meniul audio-only are optiunea 10 (paritate)"
Assert-Match $avcText '(?s)handle_multi_audio_dialog\(\).*?_iamf_probe.*?AUDIO_LOUDNORM_TRACK=-1' `
    "bash: gate IAMF in handle_multi_audio_dialog (copy ca UN grup + loudnorm off)"
Assert-Eq 4 ([regex]::Matches($avcText, 'v88 dedupe').Count) `
    "bash: remux_enumerate_streams dedupe pe toate 4 buclele (paritate seenIdx)"
Assert-Eq 2 ([regex]::Matches($tcText, 'Sursele au grup Eclipsa/IAMF').Count) `
    "bash: ambele warn-uri spatiale TC au linia IAMF (paritate)"
Assert-Contains $chkText '(Eclipsa)' "bash: av_check.sh eticheteaza Eclipsa (paritate)"
# paritate mesaje-cheie bash <-> PS1
foreach ($msg in @(
    'substream-urile raman copy ca UN grup',
    'Grup Eclipsa/IAMF re-scris in container',
    'Sursa are DEJA grup Eclipsa/IAMF',
    'obiectele NU se transfera in IAMF')) {
    Assert-Contains $psText $msg "paritate mesaj PS1: '$msg'"
    Assert-Eq $true (($avcText + $aeaText + $muxSh) -clike "*$msg*") "paritate mesaj bash: '$msg'"
}

# ── functional REAL pe Windows (gated: ffmpeg cu muxer iamf + MP4Box) ─
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$src;" + $env:PATH }
$hasIamfMux = ((& ffmpeg -hide_banner -muxers 2>$null) | Out-String) -match ' iamf '
$oldMp4boxEnv = $env:AV_TOOL_MP4BOX
$mp4box = if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } else { "mp4box" }
$gpacLocal = Join-Path $PSScriptRoot "..\..\src\GPAC\mp4box.exe"  # copia co-locata (v93) — fara cai absolute
if (-not (Get-Command $mp4box -ErrorAction SilentlyContinue) -and (Test-Path $gpacLocal)) {
    $mp4box = (Resolve-Path $gpacLocal).Path; $env:AV_TOOL_MP4BOX = $mp4box
}
if ($hasIamfMux -and (Get-Command $mp4box -ErrorAction SilentlyContinue)) {
    # Invoke-IamfAuthor/Preserve depind tranzitiv de Get-IamfLayout (regula v63)
    Import-AvEncodeFunctions -Names @('Get-IamfLayout','Invoke-IamfAuthor','Invoke-IamfPreserve')
    $tmpd = Join-Path $env:TEMP ("v88iamf_" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Force $tmpd | Out-Null
    try {
        # fixtures locale: video+5.1+subs+capitole (audit v88) si stereo (sine)
        $src51 = Join-Path $tmpd "src51.mp4"; $srcst = Join-Path $tmpd "srcst.wav"
        $chapMeta = Join-Path $tmpd "chap.txt"; $srtF = Join-Path $tmpd "s.srt"
        Set-Content -Path $chapMeta -Value ";FFMETADATA1`n[CHAPTER]`nTIMEBASE=1/1000`nSTART=0`nEND=1000`ntitle=Intro`n[CHAPTER]`nTIMEBASE=1/1000`nSTART=1000`nEND=2000`ntitle=Final" -Encoding ascii
        Set-Content -Path $srtF -Value "1`n00:00:00,000 --> 00:00:02,000`nSub test" -Encoding ascii
        & ffmpeg -y -v error -f lavfi -i "testsrc=duration=2:size=192x108:rate=30" `
            -f lavfi -i "sine=frequency=440:duration=2" -i $chapMeta -i $srtF -filter_complex `
            "[1:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a]" -map 0:v -map "[a]" `
            -map 3:s -map_metadata 2 -map_chapters 2 `
            -c:v libx264 -preset ultrafast -c:a aac -c:s mov_text $src51 2>$null
        & ffmpeg -y -v error -f lavfi -i "sine=frequency=440:duration=2" -ac 2 $srcst 2>$null
        Assert-Zero $LASTEXITCODE "fixtures generate (video+5.1+subs+capitole mp4 + stereo wav)"

        # authoring 5.1 cu video (+ subs #trackID + capitole dump-chap — audit v88)
        $out51 = Join-Path $tmpd "out51.mp4"
        Assert-Eq $true (Invoke-IamfAuthor -Source $src51 -Output $out51 -Layout "5.1") "authoring 5.1: true"
        Assert-Eq "5.1" (Get-IamfLayout -File $out51) "authoring 5.1: probe -> layout 5.1"
        $vCnt = @(@(& ffprobe -hide_banner $out51 2>&1) | Select-String 'Stream #.*Video:').Count
        Assert-Eq 1 $vCnt "authoring 5.1: video pastrat (copy)"
        $sCodec = @(& ffprobe -v error -select_streams s -show_entries stream=codec_name -of default=nw=1:nk=1 $out51 2>$null)[0]
        Assert-Eq "mov_text" "$sCodec".Trim() "authoring 5.1: subtitrarile ISO importate (#trackID)"
        $chCnt = (@(& ffprobe -v error -show_chapters $out51 2>$null) | Where-Object { $_ -match '^\[CHAPTER\]' }).Count
        Assert-Eq 2 $chCnt "authoring 5.1: capitolele carate (dump-chap)"

        # authoring stereo (fara video)
        $outst = Join-Path $tmpd "outst.mp4"
        Assert-Eq $true (Invoke-IamfAuthor -Source $srcst -Output $outst -Layout "stereo") "authoring stereo: true"
        Assert-Eq "stereo" (Get-IamfLayout -File $outst) "authoring stereo: probe -> layout stereo"

        # authoring 7.1.4 (v89 — 12ch, 7 substream-uri, layere stereo + 7.1.4)
        $src714 = Join-Path $tmpd "src714.wav"; $out714 = Join-Path $tmpd "out714.mp4"
        & ffmpeg -y -v error -f lavfi -i "sine=frequency=440:duration=2" -filter_complex `
            "[0:a]pan=7.1.4|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0|c6=c0|c7=c0|c8=c0|c9=c0|c10=c0|c11=c0[a]" `
            -map "[a]" $src714 2>$null
        Assert-Zero $LASTEXITCODE "fixture 12ch 7.1.4 generat (WAVE_FORMAT_EXTENSIBLE)"
        Assert-Eq $true (Invoke-IamfAuthor -Source $src714 -Output $out714 -Layout "7.1.4") "authoring 7.1.4: true"
        Assert-Eq "7.1.4" (Get-IamfLayout -File $out714) "authoring 7.1.4: probe -> layout 7.1.4"
        $b714 = (@(& ffprobe -hide_banner $out714 2>&1) | Out-String)
        Assert-Match $b714 'Layer 0: stereo' "authoring 7.1.4: layer de baza stereo prezent (scalabil)"
        Assert-Match $b714 'TFL.TFR.TBL.TBR' "authoring 7.1.4: canalele de inaltime prezente in layerul 12ch"

        # layout invalid -> refuz curat
        Assert-Eq $false (Invoke-IamfAuthor -Source $srcst -Output (Join-Path $tmpd "bad.mp4") -Layout "9.1.6") `
            "authoring layout invalid: refuz curat (false)"

        # probe pe fisier normal -> gol
        Assert-Eq "" (Get-IamfLayout -File $src51) "probe pe sursa normala -> gol"

        # CANAR clasa v88: ffmpeg -c copy APLATIZEAZA grupul (rc=0, pierdere tacuta).
        # Daca un ffmpeg viitor invata sa pastreze IAMF-in-MP4 -> re-evalueaza graft-urile.
        $flat = Join-Path $tmpd "flat.mp4"
        & ffmpeg -y -v error -i $out51 -map 0 -c copy $flat 2>$null
        Assert-Zero $LASTEXITCODE "flatten: ffmpeg -c copy rc=0 (pierderea e TACUTA)"
        Assert-Eq "" (Get-IamfLayout -File $flat) "CANAR: grupul e PIERDUT dupa -c copy (de-aia exista graft-ul)"

        # preserve: re-graft grupul din sursa pe output-ul aplatizat
        Assert-Eq $true (Invoke-IamfPreserve -Source $out51 -Output $flat) "preserve: true"
        Assert-Eq "5.1" (Get-IamfLayout -File $flat) "preserve: grupul e RESTAURAT (layout 5.1)"
        $pchCnt = (@(& ffprobe -v error -show_chapters $flat 2>$null) | Where-Object { $_ -match '^\[CHAPTER\]' }).Count
        Assert-Eq 2 $pchCnt "preserve: capitolele supravietuiesc rebuild-ului (dump-chap determinist — audit v88)"
        $psCodec = @(& ffprobe -v error -select_streams s -show_entries stream=codec_name -of default=nw=1:nk=1 $flat 2>$null)[0]
        Assert-Eq "mov_text" "$psCodec".Trim() "preserve: subtitrarile supravietuiesc rebuild-ului"

        # idempotent: al 2-lea preserve -> no-op true
        Assert-Eq $true (Invoke-IamfPreserve -Source $out51 -Output $flat) "preserve idempotent: true pe output deja-IAMF"

        # non-ISO -> warn + false, output neatins
        $flatMkv = Join-Path $tmpd "flat.mkv"
        & ffmpeg -y -v error -i $out51 -map 0 -c copy $flatMkv 2>$null
        Assert-Eq $false (Invoke-IamfPreserve -Source $out51 -Output $flatMkv) `
            "preserve pe .mkv: false onest (fara mapare IAMF, output neatins)"

        # zero temp-uri orfane (co-locate cu output-ul)
        $orph = @(Get-ChildItem $tmpd -File | Where-Object { $_.Name -match 'iamf(auth|pre)_' }).Count
        Assert-Eq 0 $orph "zero temp-uri orfane iamfauth_/iamfpre_"
    } finally {
        if ($null -ne $oldMp4boxEnv) { $env:AV_TOOL_MP4BOX = $oldMp4boxEnv }
        Remove-Item -Recurse -Force $tmpd -ErrorAction SilentlyContinue
    }
} else {
    Assert-Eq 1 1 "skip-equivalent: ffmpeg fara muxer iamf sau MP4Box lipseste (source-level a rulat)"
}

Invoke-TestSummary
