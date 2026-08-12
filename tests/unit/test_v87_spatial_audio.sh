#!/usr/bin/env bash
# v87 — Spatial audio passthrough awareness: detectie Dolby Atmos (E-AC-3 JOC / TrueHD)
# + DTS:X (peste DTS-HD MA) din stream=profile + garda la re-encode (pistele cu obiecte
# → oferta copy; obiectele NU pot fi regenerate — encoderele exista doar in uneltele
# licentiate Dolby/DTS) + etichete av_check. Creare Atmos/DTS:X = IMPOSIBILA in ffmpeg
# → suita PASTREAZA (copy), nu creeaza. Auro-3D = steganografic LSB → nedetectabil (doc).
# Source-level (mereu) + functional pe sample-uri reale (gated pe ffmpeg + sample).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"
AVC="$SRC/av_common.sh"
AEA="$SRC/av_encoder_audio.sh"
CHK="$SRC/av_check.sh"
PS="$SRC/av_encode.ps1"
CHKPS="$SRC/av_check.ps1"

# ── source-level bash: helperi ────────────────────────────────────────
assert_eq "1" "$(grep -c '^_audio_spatial_kind()' "$AVC")" \
    "helperul _audio_spatial_kind exista in av_common.sh"
assert_match "$(sed -n '/^_audio_spatial_kind()/,/^}/p' "$AVC")" "analyzeduration 25M" \
    "detectia are retry cu probe marit (edge-case TrueHD 9.1.6)"
assert_match "$(sed -n '/^_audio_spatial_kind()/,/^}/p' "$AVC")" "eac3\|truehd\|dts" \
    "detectia e gateata pe codecurile Dolby/DTS — ieftina pe rest"
assert_eq "1" "$(grep -c '^_ask_spatial_guard()' "$AVC")" \
    "garda _ask_spatial_guard exista in av_common.sh"
assert_match "$(sed -n '/^_ask_spatial_guard()/,/^}/p' "$AVC")" "AV_ATMOS_POLICY" \
    "garda respecta env bypass AV_ATMOS_POLICY"
assert_match "$(sed -n '/^_ask_spatial_guard()/,/^}/p' "$AVC")" "AV_DTSX_POLICY" \
    "garda respecta env bypass AV_DTSX_POLICY (policy per tip)"

# ── source-level bash: cablare in handle_multi_audio_dialog ──────────
hmad="$(sed -n '/^handle_multi_audio_dialog()/,/^}/p' "$AVC")"
assert_eq "4" "$(echo "$hmad" | grep -c '_ask_spatial_guard ')" \
    "garda cablata pe TOATE 4 caile (single / non-interactiv / default / selectie)"
assert_match "$hmad" "_audio_spatial_kind" \
    "dialogul detecteaza spatial per-pista"
assert_match "$hmad" "← ATMOS" \
    "pistele Atmos sunt marcate in lista dialogului"
assert_match "$hmad" "← DTS:X" \
    "pistele DTS:X sunt marcate in lista dialogului"
assert_match "$hmad" 'AUDIO_LOUDNORM_TRACK=-1' \
    "flip-ul pe copy dezactiveaza loudnorm (nu se filtreaza stream copiat)"
assert_match "$hmad" 'for _k in atmos dtsx' \
    "garda pe selectia finala grupeaza per TIP (dialog + policy separate)"

# ── source-level bash: av_encoder_audio + av_check ───────────────────
assert_match "$(cat "$AEA")" "_warn_audio_metadata" \
    "av_encoder_audio delega avertismentele la helperul comun (DRY v87)"
assert_eq "0" "$(grep -c 'Metadata Dolby Atmos (obiecte spatiale) se va pierde' "$AEA")" \
    "afirmatia oarba 'Atmos se pierde' pe ORICE TrueHD a fost scoasa (audio-only)"
assert_eq "0" "$(grep -c 'Metadata Dolby Atmos (obiecte spatiale JOC) se va pierde' "$AVC")" \
    "afirmatia oarba scoasa si din _warn_audio_metadata (av_common)"
assert_match "$(sed -n '/^_warn_audio_metadata()/,/^}/p' "$AVC")" 'DTS-HD MA \(lossless\)' \
    "warn-ul DTS-HD MA ramane (lossless→lossy), separat de garda DTS:X"
# v97: numaratoarea se face pe COD, nu pe comentarii (regula v95) — o nota care explica
# de ce eticheta se pune dupa liniuta ("codecul poate purta deja (Atmos)/(DTS:X)/(Eclipsa)")
# contine ea insasi sirul cautat si ar umfla numarul.
_chk_code="$(grep -v '^[[:space:]]*#' "$CHK")"
assert_eq "2" "$(printf '%s\n' "$_chk_code" | grep -c '(Atmos)')" \
    "av_check.sh eticheteaza Atmos (pista principala + per-track)"
assert_eq "2" "$(printf '%s\n' "$_chk_code" | grep -c '(DTS:X)')" \
    "av_check.sh eticheteaza DTS:X (pista principala + per-track)"

# ── source-level PS1 (paritate) ───────────────────────────────────────
assert_eq "1" "$(grep -c '^function Get-AudioSpatialKind' "$PS")" \
    "PS1: Get-AudioSpatialKind exista in av_encode.ps1"
assert_eq "1" "$(grep -c '^function Read-SpatialGuardChoice' "$PS")" \
    "PS1: Read-SpatialGuardChoice exista"
assert_match "$(sed -n '/^function Get-AudioSpatialKind/,/^}/p' "$PS")" "analyzeduration 25M" \
    "PS1: retry probe marit prezent (paritate)"
assert_eq "6" "$(grep -c 'Read-SpatialGuardChoice -Tracks' "$PS")" \
    "PS1: garda cablata pe toate 6 caile (3 flux principal + 3 audio-only)"
assert_match "$(cat "$PS")" "← ATMOS" \
    "PS1: pistele Atmos marcate in dialoguri"
assert_match "$(cat "$PS")" "← DTS:X" \
    "PS1: pistele DTS:X marcate in dialoguri"
assert_eq "1" "$(grep -c '^function Get-AudioSpatialKind' "$CHKPS")" \
    "av_check.ps1: copie standalone Get-AudioSpatialKind (nu importa av_encode)"
_chkps_code="$(grep -v '^[[:space:]]*#' "$CHKPS")"
assert_eq "2" "$(printf '%s\n' "$_chkps_code" | grep -c '(Atmos)"')" \
    "av_check.ps1 eticheteaza Atmos (pista principala + per-track)"
assert_eq "2" "$(printf '%s\n' "$_chkps_code" | grep -c '(DTS:X)"')" \
    "av_check.ps1 eticheteaza DTS:X (pista principala + per-track)"
# v87 FIX pre-existent v68: coliziunea $eaSkip (contor fisiere vs lista piste)
assert_eq "0" "$(grep -c 'eaSkip = @()' "$PS")" \
    "PS1 FIX: lista pistelor sarite nu mai foloseste \$eaSkip (coliziune cu contorul)"
assert_match "$(cat "$PS")" 'eaSkipIn = @\(\)' \
    "PS1 FIX: lista redenumita \$eaSkipIn"

# ── source-level: semnalizare Atmos de container (dec3 JOC, analog dvcC) ──
MUX="$SRC/av_mux.sh"
MUXPS="$SRC/av_mux.ps1"
TC="$SRC/av_trimconcat.sh"
assert_eq "1" "$(grep -c '^_atmos_mp4_signal()' "$AVC")" \
    "helperul _atmos_mp4_signal exista in av_common.sh"
assert_match "$(sed -n '/^_atmos_mp4_signal()/,/^}/p' "$AVC")" "ATMOS complexity" \
    "helperul verifica idempotent semnalizarea existenta (MP4Box -info pe stderr)"
assert_eq "2" "$(grep -c '_atmos_mp4_signal "\$output"' "$AVC")" \
    "cablat in run_encode_loop + do_stream_copy (av_common)"
assert_eq "1" "$(grep -c '_atmos_mp4_signal "\$output"' "$AEA")" \
    "cablat in av_encoder_audio (audio-only)"
assert_eq "4" "$(grep -c '_atmos_mp4_signal "\$out_path"' "$TC")" \
    "cablat pe toate 4 caile de copy din av_trimconcat (trim/batch/concat/pipeline)"
assert_eq "2" "$(grep -c '_atmos_mp4_signal "\$final_out"' "$MUX")" \
    "cablat in av_mux (Remux + Mux)"
assert_eq "1" "$(grep -c '^function Invoke-AtmosMp4Signal' "$PS")" \
    "PS1: Invoke-AtmosMp4Signal exista in av_encode.ps1"
assert_eq "7" "$(grep -c 'Invoke-AtmosMp4Signal -File' "$PS")" \
    "PS1: cablat pe toate 7 caile av_encode (encode/stream-copy/audio-only/trim/batch/concat/pipeline)"
assert_eq "1" "$(grep -c '^function Invoke-AtmosMp4Signal' "$MUXPS")" \
    "av_mux.ps1: copie standalone Invoke-AtmosMp4Signal"
assert_eq "2" "$(grep -c 'Invoke-AtmosMp4Signal -File' "$MUXPS")" \
    "av_mux.ps1: cablat in Remux + Mux"

# ── source-level: warn-uri Trim & Concat (re-encode audio pierde spatial) ──
assert_eq "1" "$(grep -c '^_tc_warn_spatial_sources()' "$TC")" \
    "helperul _tc_warn_spatial_sources exista in av_trimconcat.sh"
assert_eq "3" "$(grep -c '_tc_warn_spatial_sources ' "$TC")" \
    "warn cu oferta copy cablat pe caile unde copy E posibil (trim/batch/pipeline-menu)"
assert_eq "1" "$(grep -c '^_tc_warn_spatial_filter_loss()' "$TC")" \
    "helperul _tc_warn_spatial_filter_loss exista (mesaj dedicat concat-filter)"
assert_eq "2" "$(grep -c '_tc_warn_spatial_filter_loss ' "$TC")" \
    "mesajul filter cablat pe concat-filter + pipeline-fallback (copy imposibil acolo)"
assert_eq "1" "$(grep -c '^function Show-TcSpatialWarning' "$PS")" \
    "PS1: Show-TcSpatialWarning exista"
assert_eq "3" "$(grep -c 'Show-TcSpatialWarning -Files' "$PS")" \
    "PS1: warn cu oferta copy pe caile unde copy E posibil (paritate)"
assert_eq "1" "$(grep -c '^function Show-TcSpatialFilterLoss' "$PS")" \
    "PS1: Show-TcSpatialFilterLoss exista"
assert_eq "2" "$(grep -c 'Show-TcSpatialFilterLoss -Files' "$PS")" \
    "PS1: mesajul filter pe concat-filter + pipeline-fallback (paritate)"
assert_eq "1" "$(grep -c '^_file_spatial_label()' "$AVC")" \
    "helperul comun _file_spatial_label exista (DRY: preflight + warn TC)"
# v87 FIX pre-existent (v36/v60): concat FILTER cu audio 3-copy esua COMPLET
# ("Filtering and streamcopy cannot be used together") — fallback aac ca la Pipeline
assert_eq "2" "$(grep -c 'Audio copy nu functioneaza cu concat filter' "$TC")" \
    "FIX v36/v60: fallback-ul aac exista pe AMBELE cai filter (concat + pipeline)"
assert_eq "2" "$(grep -c 'Audio copy nu functioneaza cu concat filter' "$PS")" \
    "FIX v36/v60 PS1: fallback-ul aac pe ambele cai filter (paritate)"
# audit v87: semnalizarea pastreaza offset-ul audio prin optiunea MP4Box :delay=
assert_match "$(sed -n '/^_atmos_mp4_signal()/,/^}/p' "$AVC")" ':delay=' \
    "semnalizarea PASTREAZA offset-ul de start prin :delay= (nu mai sare pista)"
assert_match "$(sed -n '/^_atmos_mp4_signal()/,/^}/p' "$AVC")" 'Check O DATA' \
    "check-ul idempotent e la nivel de FISIER, inainte de bucla (multi-Atmos corect)"

# ── source-level: preflight remux + inline drop-warn + demux (mux tools) ──
assert_eq "2" "$(grep -c 'Pista contine \$_spl' "$AVC")" \
    "preflight remux: nota spatiala pe MP4 si MOV (av_common)"
assert_eq "2" "$(grep -c 'Pista contine \$spl' "$MUXPS")" \
    "av_mux.ps1: nota spatiala in Get-RemuxPreflight (MP4 + MOV)"
assert_eq "2" "$(grep -c 'foloseste MKV ca s-o pastrezi' "$MUX")" \
    "av_mux.sh: drop-warn inline imbogatit (Atmos/DTS:X) la selectia remux"
assert_match "$(cat "$MUX")" '← ATMOS' \
    "av_mux.sh: demux marcheaza pistele Atmos"
assert_match "$(cat "$MUXPS")" '← ATMOS' \
    "av_mux.ps1: demux marcheaza pistele Atmos"

# ── source-level: FIX pre-existent remux (drop-ul audio nu se aplica) ──
assert_match "$(cat "$MUX")" '_audio_kept' \
    "FIX v49: pistele audio incompat selectate se dropeaza EFECTIV (bash)"
assert_match "$(cat "$MUXPS")" 'audioCompatList' \
    "FIX v49: pistele audio incompat selectate se dropeaza EFECTIV (PS1)"

# ── functional: sample-uri reale (gated) ──────────────────────────────
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SRC:$PATH"
SAMPLE="$SRC/Dolby_Tone714_Atmos_20s.mkv"
DTSX="$SRC/DTS_SoundCheck_DTSX_8s.mkv"
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 \
   && [ -f "$SAMPLE" ] && [ -f "$DTSX" ]; then
    tmpd="$(mktemp -d)"
    trap 'rm -rf "$tmpd"; _test_summary' EXIT
    # negativ generat: eac3 SIMPLU (fara JOC)
    ffmpeg -v error -f lavfi -i "sine=frequency=440:duration=2" -ac 6 \
        -c:a eac3 -b:a 640k "$tmpd/plain_eac3.mkv" -y </dev/null 2>/dev/null
    out=$(bash -c '
        source "'"$AVC"'" >/dev/null 2>&1
        S="'"$SAMPLE"'"; X="'"$DTSX"'"
        echo "A0=[$(_audio_spatial_kind "$S" 0 || true)]"
        echo "A1=[$(_audio_spatial_kind "$S" 1 || true)]"
        echo "A2=[$(_audio_spatial_kind "$S" 2 || true)]"
        echo "DX=[$(_audio_spatial_kind "$X" 0 || true)]"
        echo "PLAIN=[$(_audio_spatial_kind "'"$tmpd"'/plain_eac3.mkv" 0 || true)]"
        # garda non-interactiva: toate 3 pe E → pistele Atmos mutate pe copy
        export AV_AUDIO_TRACKS=all AV_NONINTERACTIVE=1
        AUDIO_CODEC_ARG="eac3:224k"; MAP_FLAGS=""; LOG_FILE=/dev/null
        AUDIO_PARAMS="-c:a copy -c:a:0 eac3 -b:a:0 1024k"
        handle_multi_audio_dialog "$S" >/dev/null 2>&1
        echo "GUARD_PARAMS=$AUDIO_PARAMS"
        echo "GUARD_LN=$AUDIO_LOUDNORM_TRACK"
        # override: policy reencode → toate raman pe E
        export AV_ATMOS_POLICY=reencode
        AUDIO_PARAMS="-c:a copy -c:a:0 eac3 -b:a:0 1024k"; MAP_FLAGS=""
        handle_multi_audio_dialog "$S" >/dev/null 2>&1
        echo "OVERRIDE_PARAMS=$AUDIO_PARAMS"
        unset AV_ATMOS_POLICY AV_AUDIO_TRACKS
        # garda DTS:X single-track (non-interactiv → do-no-harm copy)
        AUDIO_PARAMS="-c:a copy -c:a:0 eac3 -b:a:0 1024k"; MAP_FLAGS=""
        handle_multi_audio_dialog "$X" >/dev/null 2>&1
        echo "DTSX_GUARD_PARAMS=[$AUDIO_PARAMS]"
        export AV_DTSX_POLICY=reencode
        AUDIO_PARAMS="-c:a copy -c:a:0 eac3 -b:a:0 1024k"; MAP_FLAGS=""
        handle_multi_audio_dialog "$X" >/dev/null 2>&1
        echo "DTSX_OVERRIDE_PARAMS=[$AUDIO_PARAMS]"
    ' 2>/dev/null)
    assert_match "$out" 'A0=\[atmos\]'  "functional: a:0 TrueHD Atmos → atmos"
    assert_match "$out" 'A1=\[\]'       "functional: a:1 AC-3 → gol (zero fals-pozitive)"
    assert_match "$out" 'A2=\[atmos\]'  "functional: a:2 E-AC-3 JOC → atmos"
    assert_match "$out" 'DX=\[dtsx\]'   "functional: DTS Sound Check → dtsx"
    assert_match "$out" 'PLAIN=\[\]'    "functional: eac3 simplu generat → gol"
    assert_match "$out" "GUARD_PARAMS=-c:a copy -c:a:1 eac3" \
        "functional: garda muta pistele Atmos (a:0,a:2) pe copy; doar a:1 re-encodata"
    assert_match "$out" "GUARD_LN=1" \
        "functional: loudnorm urmareste prima pista re-encodata ramasa (a:1)"
    assert_match "$out" "OVERRIDE_PARAMS=.*-c:a:0 eac3.*-c:a:2 eac3" \
        "functional: AV_ATMOS_POLICY=reencode pastreaza selectia userului"
    assert_match "$out" 'DTSX_GUARD_PARAMS=\[-c:a copy\]' \
        "functional: garda DTS:X single-track → copy total"
    assert_match "$out" 'DTSX_OVERRIDE_PARAMS=\[-c:a copy -c:a:0 eac3' \
        "functional: AV_DTSX_POLICY=reencode pastreaza re-encodarea"
    # CANAR: capcana pierderii tacute — re-encode pierde profilul spatial; copy il tine
    ffmpeg -v error -i "$SAMPLE" -map 0:a:2 -c:a eac3 -b:a 1024k -t 5 "$tmpd/reenc.mkv" -y </dev/null 2>/dev/null
    ffmpeg -v error -i "$SAMPLE" -map 0:a:2 -c copy -t 5 "$tmpd/copied.mkv" -y </dev/null 2>/dev/null
    ffmpeg -v error -i "$DTSX" -map 0:a:0 -c copy -t 5 "$tmpd/dtsx_copy.mkv" -y </dev/null 2>/dev/null
    prof_re=$(ffprobe -v error -select_streams a:0 -show_entries stream=profile \
        -of default=noprint_wrappers=1:nokey=1 "$tmpd/reenc.mkv" 2>/dev/null | head -1 | tr -d '\r')
    prof_cp=$(ffprobe -v error -select_streams a:0 -show_entries stream=profile \
        -of default=noprint_wrappers=1:nokey=1 "$tmpd/copied.mkv" 2>/dev/null | head -1 | tr -d '\r')
    prof_dx=$(ffprobe -v error -select_streams a:0 -show_entries stream=profile \
        -of default=noprint_wrappers=1:nokey=1 "$tmpd/dtsx_copy.mkv" 2>/dev/null | head -1 | tr -d '\r')
    assert_eq "unknown" "$prof_re" \
        "CANAR: re-encode eac3→eac3 PIERDE Atmos (fisierul arata tot eac3 — de-aia exista garda)"
    assert_match "$prof_cp" "Dolby Atmos" \
        "functional: -c copy PASTREAZA Atmos (mecanismul gardat de v87)"
    assert_match "$prof_dx" "DTS:X" \
        "functional: -c copy PASTREAZA DTS:X"
    # functional semnalizare dec3 JOC (gated pe MP4Box; skip pe MSYS — MP4Box.exe nu
    # rezolva caile /tmp git-bash, pattern v71/v72; validat REAL prin PS1 pe Windows)
    _mp4box="${AV_TOOL_MP4BOX:-mp4box}"
    if command -v "$_mp4box" >/dev/null 2>&1 && [[ "$(uname -s)" != MINGW* ]]; then
        ffmpeg -v error -i "$SAMPLE" -map 0:v:0 -map 0:a:2 -c copy -t 5 "$tmpd/sig.mp4" -y </dev/null 2>/dev/null
        bash -c 'source "'"$AVC"'" >/dev/null 2>&1; LOG_FILE=/dev/null; _atmos_mp4_signal "'"$tmpd"'/sig.mp4"' >/dev/null 2>&1
        sig_info=$("$_mp4box" -info "$tmpd/sig.mp4" 2>&1)
        assert_match "$sig_info" "ATMOS complexity" \
            "functional: _atmos_mp4_signal scrie extensia JOC in dec3 (container)"
    else
        _pass "skip-equivalent: MP4Box lipseste / MSYS (semnalizarea validata prin PS1)"
    fi
else
    _pass "skip-equivalent: ffmpeg/ffprobe/sample-uri lipsesc (source-level a rulat)"
fi
