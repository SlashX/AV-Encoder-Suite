#!/usr/bin/env bash
# v88 — Eclipsa Audio / IAMF (AOMedia): detectie (stream_group=type), authoring nativ
# ffmpeg (stereo/5.1/7.1 + 7.1.4 din v89, substream-uri Opus izolate cu `pan`, raw .iamf → MP4Box
# package) + passthrough (ffmpeg APLATIZEAZA grupul la Opus simplu la ORICE mux/copy
# → gate copy-ca-UN-grup in dialogul audio + re-graft `_iamf_preserve` din sursa pe
# caile 1:1; analog dvcC v70-72 / Atmos v87). IAMF = DOAR MP4/MOV (Matroska/WebM fara
# mapare). Source-level (mereu) + functional hermetic (gated ffmpeg-cu-muxer-iamf +
# MP4Box; fixture-urile se genereaza local — sine → author → flatten → preserve).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"
AVC="$SRC/av_common.sh"
AEA="$SRC/av_encoder_audio.sh"
AMX="$SRC/av_mux.sh"
ATC="$SRC/av_trimconcat.sh"
CHK="$SRC/av_check.sh"
PS="$SRC/av_encode.ps1"
MXPS="$SRC/av_mux.ps1"
CHKPS="$SRC/av_check.ps1"

# ── source-level bash: helperi in av_common.sh ────────────────────────
assert_eq "1" "$(grep -c '^_iamf_probe()' "$AVC")" \
    "helperul _iamf_probe exista in av_common.sh"
assert_match "$(sed -n '/^_iamf_probe()/,/^}/p' "$AVC")" "IAMF Audio Element" \
    "detectia e AUTORITARA pe stream_group=type (nu codec_name — substream-urile sunt opus simplu)"
assert_match "$(sed -n '/^_iamf_probe()/,/^}/p' "$AVC")" "hide_banner" \
    "layout-ul se citeste din banner (NU -v error — ar suprima liniile Layer N:)"
assert_eq "1" "$(grep -c '^_iamf_author()' "$AVC")" \
    "helperul _iamf_author exista in av_common.sh"
assert_match "$(sed -n '/^_iamf_author()/,/^}/p' "$AVC")" "pan=stereo" \
    "substream-urile se izoleaza cu pan (layout GENERIC — channelsplit pastreaza etichete surround → libopus refuza)"
assert_match "$(sed -n '/^_iamf_author()/,/^}/p' "$AVC")" "stg=0,annotations" \
    "mix_presentation foloseste stg=0,annotations (VIRGULA — cu colon stereo esueaza la header)"
assert_match "$(sed -n '/^_iamf_author()/,/^}/p' "$AVC")" 'st=0:st=1:st=2:st=3' \
    "referintele de substream folosesc COLON intre st= (pipe da Invalid stream index)"
assert_match "$(sed -n '/^_iamf_author()/,/^}/p' "$AVC")" 'AV_TOOL_MP4BOX' \
    "authoring-ul impacheteaza prin \$AV_TOOL_MP4BOX (nu nume hardcodat)"
assert_eq "1" "$(grep -c '^_iamf_preserve()' "$AVC")" \
    "helperul _iamf_preserve exista in av_common.sh"
assert_match "$(sed -n '/^_iamf_preserve()/,/^}/p' "$AVC")" 'Media Type: soun:iamf' \
    "preserve gaseste track ID-ul din perechea Track-Info + Media Type (ID real, nu pozitie)"
assert_match "$(sed -n '/^_iamf_preserve()/,/^}/p' "$AVC")" '2>&1' \
    "preserve citeste MP4Box -info cu 2>&1 (GPAC scrie pe STDERR)"
assert_match "$(sed -n '/^_iamf_preserve()/,/^}/p' "$AVC")" 'allow_no_audio' \
    "preserve are arg 3 allow_no_audio (Remux: audio cerut dar dropat de compat → graft din sursa)"
assert_match "$(sed -n '/^_iamf_preserve()/,/^}/p' "$AVC")" 'mp4|mov|m4v' \
    "preserve e gateat pe MP4/MOV (Matroska/WebM fara mapare IAMF)"

# ── source-level bash: gate in handle_multi_audio_dialog ─────────────
_hmad=$(sed -n '/^handle_multi_audio_dialog()/,/^}/p' "$AVC")
assert_match "$_hmad" "_iamf_probe" \
    "handle_multi_audio_dialog are gate IAMF (substream-urile = UN grup → copy)"
assert_match "$_hmad" 'AUDIO_LOUDNORM_TRACK=-1' \
    "gate-ul IAMF dezactiveaza loudnorm (-1; filtru pe stream copiat ar esua)"

# ── source-level bash: situri _iamf_preserve pe caile 1:1 ────────────
assert_eq "2" "$(grep -c '_iamf_preserve "\$file" "\$output"' "$AVC")" \
    "av_common.sh: 2 situri graft (run_encode_loop post-encode + do_stream_copy)"
assert_eq "2" "$(grep -c '_iamf_preserve "\$file" "\$output"' "$AEA")" \
    "av_encoder_audio.sh: 2 situri graft (flux deja-IAMF copy+regraft + graft general audio-only)"
assert_eq "1" "$(grep -c '_iamf_preserve "\$file" "\$final_out"' "$AMX")" \
    "av_mux.sh: sit graft pe Remux (Mux nu poate primi IAMF — doar extensii audio externe)"
assert_match "$(grep '_iamf_preserve "\$file" "\$final_out"' "$AMX")" 'REMUX_IAMF_WANT_AUDIO' \
    "Remux paseaza REMUX_IAMF_WANT_AUDIO (graft si cand compat-ul a dropat opus→MOV)"

# ── source-level bash: meniu authoring (av_encoder_audio opt 10) ─────
assert_eq "1" "$(grep -c '10) Eclipsa Audio' "$AEA")" \
    "meniul audio-only are optiunea 10 Eclipsa Audio (IAMF)"
assert_match "$(cat "$AEA")" 'AUDIO_CODEC="iamf"' \
    "optiunea 10 seteaza AUDIO_CODEC=iamf"
assert_match "$(cat "$AEA")" 'Sursa are DEJA grup Eclipsa/IAMF' \
    "edge anti-downgrade: sursa deja-IAMF → copy 1:1 + re-graft (NU authoring din substream stereo)"
assert_match "$(cat "$AEA")" 'IAMF suporta surse 2/6/8/12 canale' \
    "layout-urile nesuportate → skip onest (gate extins 12ch in v89)"

# ── source-level v89: authoring 7.1.4 (12ch, 7 substream-uri) ────────
assert_match "$(sed -n '/^_iamf_author()/,/^}/p' "$AVC")" 'st=0:st=1:st=2:st=3:st=4:st=5:st=6' \
    "v89: cazul 7.1.4 refera 7 substream-uri (5 perechi stereo + C + LFE)"
assert_match "$(sed -n '/^_iamf_author()/,/^}/p' "$AVC")" 'layer=ch_layout=7\.1\.4' \
    "v89: layer scalabil 7.1.4 (baza stereo + tinta 7.1.4)"
assert_match "$(sed -n '/^_iamf_author()/,/^}/p' "$AVC")" 'sound_system=7\.1\.4' \
    "v89: mix_presentation are layout sound_system=7.1.4"
assert_match "$(sed -n '/^_iamf_probe()/,/^}/p' "$AVC")" '12 channels' \
    "v89: probe mapeaza bannerul '12 channels' → 7.1.4 (12ch e UNIC printre layouturile scalabile)"
assert_eq "1" "$(grep -c '12) IAMF_LAYOUT="7.1.4"' "$AEA")" \
    "v89: gate-ul de canale accepta 12 → layout 7.1.4"
assert_match "$(cat "$AEA")" 'obiectele NU se transfera in IAMF' \
    "sursa Atmos/DTS:X → warn onest (doar bed-ul intra in IAMF)"

# ── source-level bash: TC warns + Remux inline note + av_check ───────
assert_eq "2" "$(grep -c 'Sursele au grup Eclipsa/IAMF' "$ATC")" \
    "av_trimconcat: ambele warn-uri spatiale (sources + filter) au linia IAMF"
assert_eq "1" "$(grep -cF 'UN grup Eclipsa/IAMF (atomic)' "$AMX")" \
    "Remux: nota inline la selectia audio pe surse IAMF (tinta ISO)"
assert_match "$(cat "$AMX")" 'nu are mapare IAMF' \
    "Remux: warn inline pe tinta non-ISO (MKV/WebM)"
assert_match "$(grep -cF '(Eclipsa)' "$CHK")" '^[1-9]' \
    "av_check.sh eticheteaza audio-ul Eclipsa"
# dedupe enumerare (ffprobe listeaza dublu pe IAMF-in-MP4 + linii doar-CR)
assert_eq "4" "$(grep -c 'v88 dedupe' "$AVC")" \
    "remux_enumerate_streams: dedupe pe toate 4 buclele (v/a/s/t)"

# ── source-level: audit v88 — consistenta fluxurilor IAMF cu fluxul normal ──
BURN="$SRC/av_burnin.sh"
BURNPS="$SRC/av_burnin.ps1"
assert_eq "1" "$(grep -c '_dv_resignal_copy "\$file" "\$output" "\$CONTAINER"' "$AEA")" \
    "fluxul deja-IAMF copy re-scrie dvcC DV (paritate cu fluxul normal al meniului)"
assert_eq "3" "$(grep -c '_dji_preserve_meta_postencode "\$file" "\$output"' "$AEA")" \
    "GPS-ul nativ DJI se re-grefeaza pe toate 3 caile audio-only (normal + copy-IAMF + authoring)"
assert_eq "2" "$(grep -c -- '-map 0:s? -map 0:t?' "$AEA")" \
    "fluxul deja-IAMF copy pastreaza subs+attachments (paritate cu MAP_FLAGS normal)"
assert_eq "1" "$(grep -c 'sursa nu are pista audio' "$AEA")" \
    "authoring pe sursa fara audio → skip onest (nu eroare ffmpeg criptica)"
assert_match "$(sed -n '/^_iamf_author()/,/^}/p' "$AVC")" 'sbtl.subt' \
    "authoring importa subtitrarile ISO cu #trackID (tx3g nativ MP4Box; NU text: = capitole QT)"
assert_match "$(sed -n '/^_iamf_author()/,/^}/p' "$AVC")" 'dump-chap' \
    "authoring cara capitolele (MP4Box -add nu le copiaza — regula v71)"
assert_match "$(sed -n '/^_iamf_preserve()/,/^}/p' "$AVC")" 'dump-chap' \
    "preserve cara capitolele DETERMINIST (rebuild-ul MP4Box trunchia etichetele track-ului QT)"
assert_match "$(sed -n '/^warn_incompat_audio_copies()/,/^}/p' "$AVC")" 'stream=index,codec_name' \
    "warn-ul compat are index in query → dedupe (IAMF dublu-listat dadea warn-uri fantoma a:4-a:7)"
assert_match "$(grep -c 'sort -u' "$CHK")" '^[1-9]' \
    "av_check numara pistele audio cu dedupe (count dublu pe IAMF)"
assert_eq "1" "$(grep -c 'stream=index,codec_name,bit_rate' "$CHK")" \
    "av_check per-track are index in query (dedupe piste fantoma pe IAMF)"
assert_eq "1" "$(grep -c 'la burn-in audio-ul se copiaza' "$BURN")" \
    "burn-in are nota onesta pe surse IAMF (v90: graftul e cablat pe output-ul complet)"

# ── source-level v90: graftul IAMF pe burn-in (inchide TO-DO-ul gated v88) ──
assert_eq "4" "$(grep -c '_iamf_preserve "\$vid" "\$out" || true' "$BURN")" \
    "v90: 4 situri graft in av_burnin.sh (HUD/SRT/ASS/img), gardat || true (set -e)"
assert_eq "4" "$(grep -c 'out_suffix" != "preview" \]\]' "$BURN")" \
    "v90: graftul e gardat pe output-ul COMPLET (NU pe preview — clip taiat nu se regrupeaza)"
assert_match "$(cat "$BURN")" 'pe MP4/MOV grupul se RE-SCRIE automat' \
    "v90: nota onesta actualizata (graft automat pe ISO, aplatizat pe rest/preview)"

# ── source-level PS1: paritate ────────────────────────────────────────
assert_eq "1" "$(grep -c '^function Get-IamfLayout {' "$PS")" \
    "PS1: Get-IamfLayout exista in av_encode.ps1"
assert_eq "1" "$(grep -c '^function Invoke-IamfAuthor {' "$PS")" \
    "PS1: Invoke-IamfAuthor exista in av_encode.ps1"
assert_eq "1" "$(grep -c '^function Invoke-IamfPreserve {' "$PS")" \
    "PS1: Invoke-IamfPreserve exista in av_encode.ps1"
assert_match "$(cat "$PS")" '10-Eclipsa \(IAMF\)' \
    "PS1: meniul audio-only are optiunea 10"
assert_eq "4" "$(grep -c 'Invoke-IamfPreserve -Source' "$PS")" \
    "PS1: 4 situri graft in av_encode.ps1 (post-encode + stream-copy + audio-only regraft + audio-only general)"
assert_eq "2" "$(grep -o 'iamfSrcGate\|eaIamfSrc' "$PS" | sort -u | wc -l | tr -d ' ')" \
    "PS1: gate IAMF in AMBELE dialoguri (flux principal + audio-only)"
assert_eq "1" "$(grep -c '^function Get-IamfLayout {' "$MXPS")" \
    "PS1: av_mux.ps1 are copia standalone Get-IamfLayout"
assert_eq "1" "$(grep -c '^function Invoke-IamfPreserve {' "$MXPS")" \
    "PS1: av_mux.ps1 are copia standalone Invoke-IamfPreserve"
assert_match "$(cat "$MXPS")" 'IamfWantAudio' \
    "PS1: Remux cara IamfWantAudio (audio cerut pre-filtrare compat)"
assert_match "$(cat "$MXPS")" 'seenIdx' \
    "PS1: Get-RemuxStreams are dedupe (listare dubla pe IAMF-in-MP4)"
assert_eq "1" "$(grep -c '^function Get-IamfLayout {' "$CHKPS")" \
    "PS1: av_check.ps1 are copia standalone Get-IamfLayout"
assert_match "$(grep -cF '(Eclipsa)' "$CHKPS")" '^[1-9]' \
    "PS1: av_check.ps1 eticheteaza audio-ul Eclipsa"
# ── source-level PS1: paritate audit v88 ─────────────────────────────
assert_eq "2" "$(grep -c 'Invoke-DvResignalCopy -Source \$f.FullName -Output \$outFile -Target \$eaContainer' "$PS")" \
    "PS1: dvcC re-scris pe ambele cai audio-only (normal + copy-IAMF)"
assert_eq "1" "$(grep -c 'sursa nu are pista audio' "$PS")" \
    "PS1: skip onest pe sursa fara audio la authoring"
assert_match "$(sed -n '/^function Invoke-IamfAuthor {/,/^}/p' "$PS")" 'sbtl.subt' \
    "PS1: authoring importa subtitrarile ISO cu #trackID"
assert_match "$(sed -n '/^function Invoke-IamfAuthor {/,/^}/p' "$PS")" 'dump-chap' \
    "PS1: authoring cara capitolele"
assert_match "$(sed -n '/^function Invoke-IamfPreserve {/,/^}/p' "$PS")" 'dump-chap' \
    "PS1: preserve cara capitolele determinist (av_encode)"
assert_match "$(sed -n '/^function Invoke-IamfPreserve {/,/^}/p' "$MXPS")" 'dump-chap' \
    "PS1: preserve cara capitolele determinist (copia av_mux)"
assert_match "$(sed -n '/^function Show-IncompatAudioCopyWarnings {/,/^}/p' "$PS")" 'stream=index,codec_name' \
    "PS1: warn-ul compat dedupe pe index"
assert_match "$(grep -c 'Sort-Object -Unique' "$CHKPS")" '^[1-9]' \
    "PS1: av_check numara pistele audio cu dedupe"
assert_eq "1" "$(grep -c 'stream=index,codec_name,bit_rate' "$CHKPS")" \
    "PS1: av_check per-track are index in query"
assert_eq "1" "$(grep -c '^function Get-IamfLayout {' "$BURNPS")" \
    "PS1: av_burnin.ps1 are copia standalone Get-IamfLayout (pt warn)"
assert_eq "1" "$(grep -c 'la burn-in audio-ul se copiaza' "$BURNPS")" \
    "PS1: burn-in avertizeaza onest pe surse IAMF"
# ── source-level PS1: paritate v90 (graft burn-in) ───────────────────
assert_eq "1" "$(grep -c '^function Invoke-IamfPreserve {' "$BURNPS")" \
    "PS1 v90: av_burnin.ps1 are copia standalone Invoke-IamfPreserve"
assert_eq "4" "$(grep -c 'Invoke-IamfPreserve -Source \$p.Video -Output \$out' "$BURNPS")" \
    "PS1 v90: 4 situri graft (HUD/SRT/ASS/img)"
assert_eq "4" "$(grep -c 'outSuffix -ne "preview"' "$BURNPS")" \
    "PS1 v90: graftul gardat pe output-ul complet (NU pe preview)"
assert_match "$(cat "$BURNPS")" 'pe MP4/MOV grupul se RE-SCRIE automat' \
    "PS1 v90: nota onesta actualizata (paritate mesaj)"
# ── source-level PS1: paritate v89 (7.1.4) ───────────────────────────
assert_match "$(sed -n '/^function Invoke-IamfAuthor {/,/^}/p' "$PS")" 'st=0:st=1:st=2:st=3:st=4:st=5:st=6' \
    "PS1 v89: Invoke-IamfAuthor are cazul 7.1.4 (7 substream-uri)"
assert_match "$(sed -n '/^function Invoke-IamfAuthor {/,/^}/p' "$PS")" 'sound_system=7\.1\.4' \
    "PS1 v89: mix_presentation are sound_system=7.1.4"
assert_match "$(cat "$PS")" 'IAMF suporta surse 2/6/8/12 canale' \
    "PS1 v89: gate-ul de canale extins la 12 (mesaj skip paritate)"
for _f in "$PS" "$MXPS" "$CHKPS" "$BURNPS"; do
    assert_match "$(sed -n '/^function Get-IamfLayout {/,/^}/p' "$_f")" '12 channels' \
        "PS1 v89: Get-IamfLayout mapeaza 12ch → 7.1.4 in $(basename "$_f")"
done

# paritate mesaje-cheie bash ↔ PS1
for _msg in \
    "substream-urile raman copy ca UN grup" \
    "Grup Eclipsa/IAMF re-scris in container" \
    "Sursa are DEJA grup Eclipsa/IAMF" \
    "obiectele NU se transfera in IAMF" \
    "sursa nu are pista audio" \
    "nu se transfera la authoring"; do
    _inb=$(grep -l "$_msg" "$AVC" "$AEA" "$AMX" 2>/dev/null | head -1)
    assert_match "$(cat "$PS")" "$_msg" "paritate mesaj: '$_msg' exista si in PS1 (bash: $(basename "${_inb:-lipsa}"))"
done
assert_eq "1" "$(grep -cF 'la burn-in audio-ul se copiaza prin ffmpeg' "$BURN")" \
    "paritate mesaj burn-in: bash"
assert_eq "1" "$(grep -cF 'la burn-in audio-ul se copiaza prin ffmpeg' "$BURNPS")" \
    "paritate mesaj burn-in: PS1"

# ── functional (gated: ffmpeg cu muxer iamf + MP4Box) ────────────────
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SRC:$PATH"
_MP4BOX="${AV_TOOL_MP4BOX:-MP4Box}"
# v93: fallback co-locat (ca productia) — pachetul GPAC portabil din src/GPAC/, fara PATH/env
# v96: DOAR pe Windows/MSYS, ca in productie. Pe un arbore partajat (WSL /mnt/..., share)
# fisierul .exe exista si e marcat executabil pe Linux, deci testul ar fi folosit binarul
# Windows in locul celui nativ. Se incearca si numele POSIX (`MP4Box`, case-sensitive).
_t_is_win=0; case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) _t_is_win=1 ;; esac
if ! command -v "$_MP4BOX" >/dev/null 2>&1 && command -v MP4Box >/dev/null 2>&1; then _MP4BOX="MP4Box"; fi
if [ "$_t_is_win" = "1" ] && ! command -v "$_MP4BOX" >/dev/null 2>&1 && [ -f "$SRC/GPAC/mp4box.exe" ]; then _MP4BOX="$SRC/GPAC/mp4box.exe"; fi
if ! command -v ffmpeg >/dev/null 2>&1 || ! ffmpeg -hide_banner -muxers 2>/dev/null | grep -q ' iamf '; then
    echo "  (functional sarit — ffmpeg fara muxer iamf)"
elif ! command -v "$_MP4BOX" >/dev/null 2>&1; then
    echo "  (functional sarit — MP4Box lipseste; seteaza AV_TOOL_MP4BOX)"
else
    export AV_TOOL_MP4BOX="$_MP4BOX"
    # shellcheck disable=SC1090
    source "$AVC" 2>/dev/null || true
    TD=$(mktemp -d "${TMPDIR:-/tmp}/v88iamf.XXXXXX")
    trap 'rm -rf "$TD"; _test_summary' EXIT

    # fixtures locale: video+5.1+subs+capitole (audit v88) si stereo (sine)
    printf ';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Intro\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Final\n' > "$TD/chap.txt"
    printf '1\n00:00:00,000 --> 00:00:02,000\nSub test\n' > "$TD/s.srt"
    ffmpeg -y -v error -f lavfi -i "testsrc=duration=2:size=192x108:rate=30" \
        -f lavfi -i "sine=frequency=440:duration=2" -i "$TD/chap.txt" -i "$TD/s.srt" \
        -filter_complex "[1:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a]" \
        -map 0:v -map "[a]" -map 3:s -map_metadata 2 -map_chapters 2 \
        -c:v libx264 -preset ultrafast -c:a aac -c:s mov_text "$TD/src51.mp4" 2>/dev/null
    ffmpeg -y -v error -f lavfi -i "sine=frequency=440:duration=2" -ac 2 "$TD/srcst.wav" 2>/dev/null
    assert_zero $? "fixtures generate (video+5.1+subs+capitole mp4 + stereo wav)"

    # authoring 5.1 cu video (+ subs #trackID + capitole dump-chap — audit v88)
    _iamf_author "$TD/src51.mp4" "$TD/out51.mp4" "5.1" >/dev/null 2>&1
    assert_zero $? "authoring 5.1: rc=0"
    assert_eq "5.1" "$(_iamf_probe "$TD/out51.mp4")" "authoring 5.1: probe → layout 5.1"
    _v=$(ffprobe -hide_banner "$TD/out51.mp4" 2>&1 | grep -ac 'Stream #.*Video:')
    assert_eq "1" "$_v" "authoring 5.1: video pastrat (copy)"
    assert_eq "mov_text" "$(ffprobe -v error -select_streams s -show_entries stream=codec_name -of default=nw=1:nk=1 "$TD/out51.mp4" 2>/dev/null | head -1 | tr -d '\r')" \
        "authoring 5.1: subtitrarile ISO importate (#trackID)"
    assert_eq "2" "$(ffprobe -v error -show_chapters "$TD/out51.mp4" 2>/dev/null | grep -c '^\[CHAPTER\]')" \
        "authoring 5.1: capitolele carate (dump-chap)"

    # authoring stereo (fara video)
    _iamf_author "$TD/srcst.wav" "$TD/outst.mp4" "stereo" >/dev/null 2>&1
    assert_zero $? "authoring stereo: rc=0"
    assert_eq "stereo" "$(_iamf_probe "$TD/outst.mp4")" "authoring stereo: probe → layout stereo"

    # authoring 7.1.4 (v89 — 12ch, 7 substream-uri, layere stereo + 7.1.4)
    ffmpeg -y -v error -f lavfi -i "sine=frequency=440:duration=2" -filter_complex \
        "[0:a]pan=7.1.4|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0|c6=c0|c7=c0|c8=c0|c9=c0|c10=c0|c11=c0[a]" \
        -map "[a]" "$TD/src714.wav" 2>/dev/null
    assert_zero $? "fixture 12ch 7.1.4 generat (WAVE_FORMAT_EXTENSIBLE)"
    _iamf_author "$TD/src714.wav" "$TD/out714.mp4" "7.1.4" >/dev/null 2>&1
    assert_zero $? "authoring 7.1.4: rc=0"
    assert_eq "7.1.4" "$(_iamf_probe "$TD/out714.mp4")" "authoring 7.1.4: probe → layout 7.1.4"
    _b714=$(ffprobe -hide_banner "$TD/out714.mp4" 2>&1)
    assert_match "$_b714" 'Layer 0: stereo' "authoring 7.1.4: layer de baza stereo prezent (scalabil)"
    assert_match "$_b714" 'TFL.TFR.TBL.TBR' "authoring 7.1.4: canalele de inaltime prezente in layerul 12ch"

    # layout invalid → refuz curat
    if _iamf_author "$TD/srcst.wav" "$TD/outbad.mp4" "9.1.6" >/dev/null 2>&1; then
        assert_eq "rc1" "rc0" "authoring layout invalid: trebuia rc=1"
    else
        assert_eq "ok" "ok" "authoring layout invalid: refuz curat rc=1"
    fi

    # probe pe fisier normal → gol
    assert_eq "" "$(_iamf_probe "$TD/src51.mp4" || true)" "probe pe sursa normala → gol"

    # CANAR clasa v88: ffmpeg -c copy APLATIZEAZA grupul (rc=0, pierdere tacuta).
    # Daca un ffmpeg viitor invata sa pastreze IAMF-in-MP4 → re-evalueaza graft-urile.
    ffmpeg -y -v error -i "$TD/out51.mp4" -map 0 -c copy "$TD/flat.mp4" 2>/dev/null
    assert_zero $? "flatten: ffmpeg -c copy rc=0 (pierderea e TACUTA)"
    assert_eq "" "$(_iamf_probe "$TD/flat.mp4" || true)" "CANAR: grupul e PIERDUT dupa -c copy (de-aia exista graft-ul)"

    # preserve: re-graft grupul din sursa pe output-ul aplatizat
    _iamf_preserve "$TD/out51.mp4" "$TD/flat.mp4" >/dev/null 2>&1
    assert_zero $? "preserve: rc=0"
    assert_eq "5.1" "$(_iamf_probe "$TD/flat.mp4")" "preserve: grupul e RESTAURAT (layout 5.1)"
    assert_eq "2" "$(ffprobe -v error -show_chapters "$TD/flat.mp4" 2>/dev/null | grep -c '^\[CHAPTER\]')" \
        "preserve: capitolele supravietuiesc rebuild-ului (dump-chap determinist — audit v88)"
    assert_eq "mov_text" "$(ffprobe -v error -select_streams s -show_entries stream=codec_name -of default=nw=1:nk=1 "$TD/flat.mp4" 2>/dev/null | head -1 | tr -d '\r')" \
        "preserve: subtitrarile supravietuiesc rebuild-ului"

    # idempotent: al 2-lea preserve → no-op rc=0
    _iamf_preserve "$TD/out51.mp4" "$TD/flat.mp4" >/dev/null 2>&1
    assert_zero $? "preserve idempotent: rc=0 pe output deja-IAMF"

    # non-ISO → warn + rc=1
    ffmpeg -y -v error -i "$TD/out51.mp4" -map 0 -c copy "$TD/flat.mkv" 2>/dev/null
    if _iamf_preserve "$TD/out51.mp4" "$TD/flat.mkv" >/dev/null 2>&1; then
        assert_eq "rc1" "rc0" "preserve pe .mkv: trebuia rc=1 (fara mapare IAMF)"
    else
        assert_eq "ok" "ok" "preserve pe .mkv: rc=1 onest (warn, output neatins)"
    fi

    # zero temp-uri orfane (co-locate cu output-ul)
    assert_eq "0" "$(find "$TD" -name "*.iamfauth_*" -o -name "*.iamfpre_*" 2>/dev/null | grep -c . || true)" \
        "zero temp-uri orfane iamfauth_/iamfpre_"
fi
# NB: fara _test_summary explicit — framework-ul are trap implicit; ramura functionala
# il pastreaza in trap-ul propriu de cleanup (regula v43: 'rm; _test_summary').
