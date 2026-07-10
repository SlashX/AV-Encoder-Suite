# v87 — Spatial audio passthrough awareness (mirror test_v87_spatial_audio.sh):
# detectie Dolby Atmos (E-AC-3 JOC / TrueHD) + DTS:X (stream=profile) + garda la
# re-encode (oferta copy) + etichete av_check. Source-level (ambele platforme) +
# functional pe sample-uri reale (gated pe ffmpeg + sample).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$src = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "src"
$psText  = Get-Content (Join-Path $src "av_encode.ps1") -Raw
$chkPs   = Get-Content (Join-Path $src "av_check.ps1") -Raw
$avcText = Get-Content (Join-Path $src "av_common.sh") -Raw
$aeaText = Get-Content (Join-Path $src "av_encoder_audio.sh") -Raw
$chkText = Get-Content (Join-Path $src "av_check.sh") -Raw

# ── source-level PS1 ──────────────────────────────────────────────────
Assert-Eq 2 ([regex]::Matches($psText + $chkPs, '(?m)^function Get-AudioSpatialKind').Count) `
    "Get-AudioSpatialKind exista in av_encode.ps1 + copia standalone av_check.ps1"
Assert-Eq 1 ([regex]::Matches($psText, '(?m)^function Read-SpatialGuardChoice').Count) `
    "Read-SpatialGuardChoice exista in av_encode.ps1"
Assert-Match $psText 'function Get-AudioSpatialKind[\s\S]*?analyzeduration 25M[\s\S]*?\n\}' `
    "detectia PS1 are retry cu probe marit (edge-case TrueHD 9.1.6)"
Assert-Eq 6 ([regex]::Matches($psText, 'Read-SpatialGuardChoice -Tracks').Count) `
    "garda cablata pe toate 6 caile (3 flux principal + 3 audio-only)"
Assert-Match $psText '← ATMOS' "pistele Atmos sunt marcate in dialoguri"
Assert-Match $psText '← DTS:X' "pistele DTS:X sunt marcate in dialoguri"
Assert-Match $psText 'AV_ATMOS_POLICY' "garda respecta env bypass AV_ATMOS_POLICY"
Assert-Match $psText 'AV_DTSX_POLICY' "garda respecta env bypass AV_DTSX_POLICY (per tip)"
Assert-Eq 2 ([regex]::Matches($chkPs, '\(Atmos\)"').Count) `
    "av_check.ps1 eticheteaza Atmos (pista principala + per-track)"
Assert-Eq 2 ([regex]::Matches($chkPs, '\(DTS:X\)"').Count) `
    "av_check.ps1 eticheteaza DTS:X (pista principala + per-track)"
# v87 FIX pre-existent v68: coliziunea `$eaSkip` (contor fisiere vs lista piste skip)
Assert-Eq 0 ([regex]::Matches($psText, '\$eaSkip = @\(\)').Count) `
    "FIX: lista pistelor sarite nu mai foloseste `$eaSkip (coliziune cu contorul)"
Assert-Match $psText '\$eaSkipIn = @\(\)' `
    "FIX: lista redenumita `$eaSkipIn"

# ── paritate bash (source-level) ──────────────────────────────────────
Assert-Eq 1 ([regex]::Matches($avcText, '(?m)^_audio_spatial_kind\(\)').Count) `
    "bash: _audio_spatial_kind exista (paritate)"
Assert-Eq 4 ([regex]::Matches($avcText, '_ask_spatial_guard ').Count) `
    "bash: garda cablata pe toate 4 caile din handle_multi_audio_dialog"
Assert-Eq 2 ([regex]::Matches($chkText, '\(Atmos\)').Count) `
    "bash: av_check.sh eticheteaza Atmos (paritate)"
Assert-Eq 2 ([regex]::Matches($chkText, '\(DTS:X\)').Count) `
    "bash: av_check.sh eticheteaza DTS:X (paritate)"
Assert-Eq 0 ([regex]::Matches($aeaText, 'Metadata Dolby Atmos \(obiecte spatiale\) se va pierde').Count) `
    "bash: afirmatia oarba pe orice TrueHD scoasa din av_encoder_audio"

# ── source-level: semnalizare Atmos de container + warn-uri TC + mux tools ──
$muxPs  = Get-Content (Join-Path $src "av_mux.ps1") -Raw
$muxSh  = Get-Content (Join-Path $src "av_mux.sh") -Raw
$tcText = Get-Content (Join-Path $src "av_trimconcat.sh") -Raw
Assert-Eq 1 ([regex]::Matches($psText, '(?m)^function Invoke-AtmosMp4Signal').Count) `
    "Invoke-AtmosMp4Signal exista in av_encode.ps1"
Assert-Eq 7 ([regex]::Matches($psText, 'Invoke-AtmosMp4Signal -File').Count) `
    "cablat pe toate 7 caile av_encode (encode/stream-copy/audio-only/trim/batch/concat/pipeline)"
Assert-Eq 1 ([regex]::Matches($muxPs, '(?m)^function Invoke-AtmosMp4Signal').Count) `
    "av_mux.ps1: copie standalone Invoke-AtmosMp4Signal"
Assert-Eq 2 ([regex]::Matches($muxPs, 'Invoke-AtmosMp4Signal -File').Count) `
    "av_mux.ps1: cablat in Remux + Mux"
Assert-Eq 1 ([regex]::Matches($avcText, '(?m)^_atmos_mp4_signal\(\)').Count) `
    "bash: _atmos_mp4_signal exista (paritate)"
Assert-Eq 9 ([regex]::Matches($avcText + $aeaText + $tcText + $muxSh, '_atmos_mp4_signal "\$').Count) `
    "bash: cablat pe toate 9 caile (2 common + 1 audio-only + 4 trimconcat + 2 mux)"
Assert-Eq 1 ([regex]::Matches($psText, '(?m)^function Show-TcSpatialWarning').Count) `
    "Show-TcSpatialWarning exista in av_encode.ps1"
Assert-Eq 3 ([regex]::Matches($psText, 'Show-TcSpatialWarning -Files').Count) `
    "warn cu oferta copy pe caile unde copy E posibil (trim/batch/pipeline-menu)"
Assert-Eq 2 ([regex]::Matches($psText, 'Show-TcSpatialFilterLoss -Files').Count) `
    "mesajul dedicat filter pe concat-filter + pipeline-fallback"
Assert-Eq 3 ([regex]::Matches($tcText, '_tc_warn_spatial_sources ').Count) `
    "bash: warn cu oferta copy pe 3 cai (paritate)"
Assert-Eq 2 ([regex]::Matches($tcText, '_tc_warn_spatial_filter_loss ').Count) `
    "bash: mesajul filter pe 2 cai (paritate)"
# v87 FIX pre-existent (v36/v60): concat FILTER cu audio copy esua complet → fallback aac
Assert-Eq 2 ([regex]::Matches($tcText, 'Audio copy nu functioneaza cu concat filter').Count) `
    "FIX v36/v60 bash: fallback aac pe ambele cai filter"
Assert-Eq 2 ([regex]::Matches($psText, 'Audio copy nu functioneaza cu concat filter').Count) `
    "FIX v36/v60 PS1: fallback aac pe ambele cai filter"
# audit v87: :delay= pastreaza offset-ul + check idempotent la nivel de fisier (multi-Atmos)
Assert-Match $psText 'function Invoke-AtmosMp4Signal[\s\S]*?:delay=[\s\S]*?\n\}' `
    "semnalizarea PS1 pastreaza offset-ul prin :delay="
Assert-Match $psText 'Check O DATA' `
    "check-ul idempotent PS1 e la nivel de fisier, inainte de bucla (multi-Atmos)"
Assert-Eq 2 ([regex]::Matches($muxPs, 'Pista contine \$spl').Count) `
    "av_mux.ps1: nota spatiala in preflight (MP4 + MOV)"
Assert-Eq 2 ([regex]::Matches($muxSh, 'foloseste MKV ca s-o pastrezi').Count) `
    "av_mux.sh: drop-warn inline imbogatit (Atmos + DTS:X)"
Assert-Eq 4 ([regex]::Matches($muxPs, 'foloseste MKV ca s-o pastrezi').Count) `
    "av_mux.ps1: drop-warn inline (2: Atmos+DTS:X) + note preflight (2: MP4+MOV)"
Assert-Match $muxPs '← ATMOS' "av_mux.ps1: demux marcheaza pistele Atmos"
Assert-Match $muxSh '← ATMOS' "av_mux.sh: demux marcheaza pistele Atmos (paritate)"
# FIX pre-existent v49: drop-ul audio la remux se aplica EFECTIV
Assert-Match $muxPs 'audioCompatList' "FIX v49 PS1: pistele audio incompat se dropeaza efectiv"
Assert-Match $muxSh '_audio_kept'     "FIX v49 bash: pistele audio incompat se dropeaza efectiv"

# ── functional: sample-uri reale (gated) ──────────────────────────────
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$src;" + $env:PATH }
$sample = Join-Path $src "Dolby_Tone714_Atmos_20s.mkv"
$dtsx   = Join-Path $src "DTS_SoundCheck_DTSX_8s.mkv"
$haveTools = (Get-Command ffmpeg -ErrorAction SilentlyContinue) -and (Get-Command ffprobe -ErrorAction SilentlyContinue)
if ($haveTools -and (Test-Path $sample) -and (Test-Path $dtsx)) {
    Import-AvEncodeFunctions -Names @('Get-AudioSpatialKind','Read-SpatialGuardChoice','Get-SpatialLabel')
    $tmpd = Join-Path $env:TEMP ("v87sa_" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Force $tmpd | Out-Null
    $oldAtmos = $env:AV_ATMOS_POLICY; $oldDtsx = $env:AV_DTSX_POLICY
    try {
        Assert-Eq "atmos" (Get-AudioSpatialKind -File $sample -AIdx 0) "functional: a:0 TrueHD Atmos → atmos"
        Assert-Eq ""      (Get-AudioSpatialKind -File $sample -AIdx 1) "functional: a:1 AC-3 → gol (zero fals-pozitive)"
        Assert-Eq "atmos" (Get-AudioSpatialKind -File $sample -AIdx 2) "functional: a:2 E-AC-3 JOC → atmos"
        Assert-Eq "dtsx"  (Get-AudioSpatialKind -File $dtsx -AIdx 0)   "functional: DTS Sound Check → dtsx"
        $plain = Join-Path $tmpd "plain_eac3.mkv"
        & ffmpeg -v error -f lavfi -i "sine=frequency=440:duration=2" -ac 6 -c:a eac3 -b:a 640k $plain -y 2>$null
        Assert-Eq "" (Get-AudioSpatialKind -File $plain -AIdx 0) "functional: eac3 simplu generat → gol"
        $env:AV_ATMOS_POLICY = "copy"
        Assert-Eq $true  (Read-SpatialGuardChoice -Tracks "a:0" -Kind atmos) "functional: AV_ATMOS_POLICY=copy → pastreaza"
        $env:AV_ATMOS_POLICY = "reencode"
        Assert-Eq $false (Read-SpatialGuardChoice -Tracks "a:0" -Kind atmos) "functional: AV_ATMOS_POLICY=reencode → re-encodeaza"
        $env:AV_ATMOS_POLICY = ""
        $env:AV_DTSX_POLICY = "copy"
        Assert-Eq $true  (Read-SpatialGuardChoice -Tracks "a:0" -Kind dtsx) "functional: AV_DTSX_POLICY=copy → pastreaza"
        $env:AV_DTSX_POLICY = "reencode"
        Assert-Eq $false (Read-SpatialGuardChoice -Tracks "a:0" -Kind dtsx) "functional: AV_DTSX_POLICY=reencode → re-encodeaza"
        $env:AV_DTSX_POLICY = ""
        # CANAR: capcana pierderii tacute + mecanismul pastrarii (Atmos si DTS:X)
        $reenc = Join-Path $tmpd "reenc.mkv"; $copied = Join-Path $tmpd "copied.mkv"; $dxCopy = Join-Path $tmpd "dtsx_copy.mkv"
        & ffmpeg -v error -i $sample -map 0:a:2 -c:a eac3 -b:a 1024k -t 5 $reenc -y 2>$null
        & ffmpeg -v error -i $sample -map 0:a:2 -c copy -t 5 $copied -y 2>$null
        & ffmpeg -v error -i $dtsx -map 0:a:0 -c copy -t 5 $dxCopy -y 2>$null
        $profRe = @(& ffprobe -v error -select_streams a:0 -show_entries stream=profile -of default=noprint_wrappers=1:nokey=1 $reenc 2>$null)[0]
        $profCp = @(& ffprobe -v error -select_streams a:0 -show_entries stream=profile -of default=noprint_wrappers=1:nokey=1 $copied 2>$null)[0]
        $profDx = @(& ffprobe -v error -select_streams a:0 -show_entries stream=profile -of default=noprint_wrappers=1:nokey=1 $dxCopy 2>$null)[0]
        Assert-Eq "unknown" "$profRe" "CANAR: re-encode eac3→eac3 PIERDE Atmos (de-aia exista garda)"
        Assert-Match "$profCp" "Dolby Atmos" "functional: -c copy PASTREAZA Atmos"
        Assert-Match "$profDx" "DTS:X" "functional: -c copy PASTREAZA DTS:X"
        # functional semnalizare dec3 JOC (gated pe MP4Box; pe Windows ruleaza REAL)
        $oldMp4boxEnv = $env:AV_TOOL_MP4BOX
        $mp4box = if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } else { "mp4box" }
        if (-not (Get-Command $mp4box -ErrorAction SilentlyContinue) -and (Test-Path "D:\Pers\APPS\APPPortable\GPAC\MP4Box.exe")) {
            $mp4box = "D:\Pers\APPS\APPPortable\GPAC\MP4Box.exe"; $env:AV_TOOL_MP4BOX = $mp4box
        }
        if (Get-Command $mp4box -ErrorAction SilentlyContinue) {
            Import-AvEncodeFunctions -Names @('Invoke-AtmosMp4Signal')
            $sig = Join-Path $tmpd "sig.mp4"
            & ffmpeg -v error -i $sample -map 0:v:0 -map 0:a:2 -c copy -t 5 $sig -y 2>$null
            $pre = (& $mp4box -info $sig 2>&1) -join "`n"
            Assert-Eq $false ($pre -match 'ATMOS complexity') "premisa: ffmpeg NU scrie JOC in dec3 (gap-ul reparat)"
            Invoke-AtmosMp4Signal -File $sig | Out-Null
            $post = (& $mp4box -info $sig 2>&1) -join "`n"
            Assert-Match $post 'ATMOS complexity' "functional: Invoke-AtmosMp4Signal scrie extensia JOC in dec3"
            $bitp = @(& ffprobe -v error -select_streams a:0 -show_entries stream=profile -of default=noprint_wrappers=1:nokey=1 $sig 2>$null)[0]
            Assert-Match "$bitp" "Dolby Atmos" "functional: bitstream-ul ramane intact dupa semnalizare"
            # multi-Atmos (2 piste, limbi diferite): AMBELE semnalizate, limbile pastrate
            $multi = Join-Path $tmpd "multi.mp4"
            & ffmpeg -v error -t 5 -i $sample -map 0:v:0 -map 0:a:2 -map 0:a:2 -c copy `
                -metadata:s:a:0 language=eng -metadata:s:a:1 language=ron $multi -y 2>$null
            Invoke-AtmosMp4Signal -File $multi | Out-Null
            $mCnt = (((& $mp4box -info $multi 2>&1) -join "`n") | Select-String "ATMOS complexity" -AllMatches).Matches.Count
            Assert-Eq 2 $mCnt "functional multi-Atmos: AMBELE piste semnalizate (fix audit v87)"
            $mLangs = ((& ffprobe -v error -select_streams a -show_entries stream_tags=language -of csv=p=0 $multi 2>$null) | Out-String)
            Assert-Match $mLangs "eng" "functional multi-Atmos: limba pistei 1 pastrata"
            Assert-Match $mLangs "ron" "functional multi-Atmos: limba pistei 2 pastrata"
        } else {
            Assert-Eq 1 1 "skip-equivalent: MP4Box lipseste (semnalizare doar source-level)"
        }
    } finally {
        $env:AV_ATMOS_POLICY = $oldAtmos; $env:AV_DTSX_POLICY = $oldDtsx
        if ($null -ne (Get-Variable oldMp4boxEnv -ErrorAction SilentlyContinue)) { $env:AV_TOOL_MP4BOX = $oldMp4boxEnv }
        Remove-Item -Recurse -Force $tmpd -ErrorAction SilentlyContinue
    }
} else {
    Assert-Eq 1 1 "skip-equivalent: ffmpeg/ffprobe/sample-uri lipsesc (source-level a rulat)"
}

Invoke-TestSummary
