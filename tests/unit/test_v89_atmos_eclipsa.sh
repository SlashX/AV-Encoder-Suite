#!/usr/bin/env bash
# v89 — Atmos → Eclipsa/IAMF 7.1.4 prin Cavern: render POZITIONAL al obiectelor
# (E-AC-3 JOC nativ; TrueHD via truehdd auto-descarcat) → WAV 12ch → authoring IAMF
# cu canale de inaltime REALE. Helper `_atmos_render_714`/`Invoke-AtmosRender714`
# (timeout defensiv — CavernizeGUI NU se inchide singur pe eroare; validare
# AUTORITARA pe WAV 12ch, nu pe exit code) + arg nou `audio_src` in `_iamf_author`/
# `-AudioSource` (audio din WAV-ul randat, video/subs/capitole raman din sursa) +
# dialog in meniul 2 opt 10 pe sursa Atmos (render/bed/skip; env
# AV_ATMOS_ECLIPSA_POLICY; non-interactiv → bed do-no-harm) + installere.
# Source-level (mereu) + functional gated (Cavernize + ffmpeg + sample Atmos local).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"
AVC="$SRC/av_common.sh"
AEA="$SRC/av_encoder_audio.sh"
PS="$SRC/av_encode.ps1"

# ── source-level bash: config + helper in av_common.sh ────────────────
assert_eq "1" "$(grep -c '^AV_TOOL_CAVERNIZE="\${AV_TOOL_CAVERNIZE:-' "$AVC")" \
    "AV_TOOL_CAVERNIZE e in blocul config (forma canonica — santinela no_hardcoded_tools o deriva)"
assert_eq "1" "$(grep -c '^_atmos_render_714()' "$AVC")" \
    "helperul _atmos_render_714 exista in av_common.sh"
_arh=$(sed -n '/^_atmos_render_714()/,/^}/p' "$AVC")
assert_match "$_arh" 'timeout 7200' \
    "render-ul are timeout defensiv (CavernizeGUI NU se inchide singur pe eroare)"
assert_match "$_arh" 'DOTNET_ROLL_FORWARD=LatestMajor' \
    "roll-forward .NET setat (Cavernize tinteste Desktop 8, ruleaza pe 9/10)"
assert_match "$_arh" '"\$_ch" = "12"' \
    "validare AUTORITARA pe WAV: 12 canale (nu exit code-ul GUI-ului)"
assert_match "$_arh" 'atmos714_' \
    "extractul pistei merge intr-un temp CO-LOCAT (Cavernize scrie temp-uri LANGA input)"
assert_match "$_arh" '\-track 0 -target 7.1.4 -format PCM_LE' \
    "Cavernize e chemat cu -track 0 pe copia mono-pista (neambiguu) + tinta 7.1.4 PCM"
assert_match "$_arh" 'AV_TOOL_CAVERNIZE' \
    "tool-ul se apeleaza prin \$AV_TOOL_CAVERNIZE (nu nume hardcodat)"

# ── source-level bash: arg 5 audio_src in _iamf_author ────────────────
_ia=$(sed -n '/^_iamf_author()/,/^}/p' "$AVC")
assert_match "$_ia" 'audio_src="\$\{5:-\$1\}"' \
    "v89: _iamf_author are arg 5 optional audio_src (gol → \$1, back-compat v88)"
assert_match "$_ia" '\-i "\$audio_src"' \
    "authoring-ul ffmpeg citeste audio-ul din \$audio_src (video/subs/capitole raman din \$input)"

# ── source-level bash: dialog render in av_encoder_audio.sh ───────────
assert_match "$(cat "$AEA")" 'AV_ATMOS_ECLIPSA_POLICY' \
    "policy env AV_ATMOS_ECLIPSA_POLICY citita in dialog (render|bed|skip)"
assert_match "$(cat "$AEA")" 'Render 7.1.4 → Eclipsa cu canale de inaltime' \
    "dialogul ofera render 7.1.4 ca optiunea 1 (implicit cu tool prezent)"
assert_match "$(cat "$AEA")" '_iamf_rmode="bed"' \
    "non-interactiv fara env → bed (do-no-harm, comportamentul v88)"
assert_match "$(cat "$AEA")" '_atmos_render_714 "\$file" "\$_iamf_wav"' \
    "render-ul e chemat prin helperul comun"
assert_match "$(cat "$AEA")" 'Render esuat → fallback pe bed-ul de canale' \
    "render esuat → fallback onest pe bed (output-ul tot iese)"
assert_match "$(cat "$AEA")" '_iamf_author "\$file" "\$output" "\$IAMF_LAYOUT" "" "\$IAMF_RENDER_WAV"' \
    "authoring-ul primeste WAV-ul randat ca arg 5 (gol pe caile clasice = back-compat)"
assert_match "$(cat "$AEA")" 'rm -f "\$IAMF_RENDER_WAV"' \
    "WAV-ul de render se curata dupa authoring (ambele ramuri)"
assert_match "$(cat "$AEA")" 'tools/cavernize_installer' \
    "sursa Atmos fara tool → hint onest la installer"
assert_match "$(cat "$AEA")" 'obiectele NU se transfera in IAMF' \
    "mesajul v87 ramane pe calea bed (obiectele intra doar prin render)"

# ── source-level PS1: paritate ────────────────────────────────────────
assert_eq "1" "$(grep -c '^function Invoke-AtmosRender714 {' "$PS")" \
    "PS1: Invoke-AtmosRender714 exista in av_encode.ps1"
_arps=$(sed -n '/^function Invoke-AtmosRender714 {/,/^}/p' "$PS")
assert_match "$_arps" 'WaitForExit' \
    "PS1: WPF nu se asteapta cu & → Start-Process + WaitForExit cu timeout"
assert_match "$_arps" '\.Kill\(\)' \
    "PS1: Kill defensiv pe timeout (procesul nu se inchide singur pe eroare)"
assert_match "$_arps" 'DOTNET_ROLL_FORWARD' \
    "PS1: roll-forward .NET setat"
assert_match "$_arps" '\-eq "12"' \
    "PS1: validare autoritara pe WAV 12 canale"
assert_match "$_arps" 'AV_TOOL_CAVERNIZE' \
    "PS1: tool prin env AV_TOOL_CAVERNIZE"
_iaps=$(sed -n '/^function Invoke-IamfAuthor {/,/^}/p' "$PS")
assert_match "$_iaps" 'AudioSource' \
    "PS1: Invoke-IamfAuthor are -AudioSource (mirror arg 5 bash)"
assert_match "$_iaps" '\$audioIn' \
    "PS1: linia ffmpeg citeste audio-ul din \$audioIn"
assert_match "$(cat "$PS")" 'AV_ATMOS_ECLIPSA_POLICY' \
    "PS1: policy env in dialogul audio-only"
assert_match "$(cat "$PS")" '\-AudioSource \$iamfRenderWav' \
    "PS1: authoring-ul primeste WAV-ul randat prin -AudioSource"
assert_match "$(cat "$PS")" 'Remove-Item \$iamfRenderWav' \
    "PS1: WAV-ul de render se curata dupa authoring"

# paritate mesaje-cheie bash ↔ PS1 (regex → parantezele/punctele escapate;
# mesajele de dialog stau in AEA, cele de helper in AVC → verific pe concatenare)
for _msg in \
    "Render 7\.1\.4 → Eclipsa cu canale de inaltime" \
    "Render esuat → fallback pe bed-ul de canale" \
    "render Cavern 12ch" \
    "sarit de user \(sursa Atmos\)" \
    "Cavern nu a produs un WAV 7\.1\.4 valid"; do
    assert_match "$(cat "$AVC" "$AEA")" "$_msg" "paritate mesaj bash: '$_msg'"
    assert_match "$(cat "$PS")" "$_msg" "paritate mesaj PS1: '$_msg'"
done

# ── installere ────────────────────────────────────────────────────────
assert_file_exists "$SRC/tools/cavernize_installer.sh"  "installer bash exista"
assert_file_exists "$SRC/tools/cavernize_installer.ps1" "installer PS1 exista"
assert_match "$(cat "$SRC/tools/cavernize_installer.sh")" 'Linux/Termux' \
    "installer bash: mesaj onest pe platformele fara Cavernize"
assert_match "$(cat "$SRC/tools/cavernize_installer.ps1")" 'cavern\.sbence\.hu' \
    "installer PS1: descarca de pe site-ul oficial (GitHub are doar demo-ul Unity pe Windows)"
assert_match "$(cat "$SRC/tools/cavernize_installer.ps1")" 'WindowsDesktop' \
    "installer PS1: verifica .NET Desktop Runtime 8+"

# ── functional (gated: Cavernize + ffmpeg + sample Atmos local) ───────
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SRC:$PATH"
_CAV="${AV_TOOL_CAVERNIZE:-CavernizeGUI}"
_MP4BOX="${AV_TOOL_MP4BOX:-MP4Box}"
SAMPLE="$SRC/Dolby_Tone714_Atmos_20s.mkv"
if ! command -v "$_CAV" >/dev/null 2>&1; then
    echo "  (functional sarit — Cavernize lipseste; seteaza AV_TOOL_CAVERNIZE)"
elif [ ! -f "$SAMPLE" ]; then
    echo "  (functional sarit — sample-ul Atmos local lipseste)"
elif ! command -v ffmpeg >/dev/null 2>&1 || ! ffmpeg -hide_banner -muxers 2>/dev/null | grep -q ' iamf '; then
    echo "  (functional sarit — ffmpeg fara muxer iamf)"
elif ! command -v "$_MP4BOX" >/dev/null 2>&1; then
    echo "  (functional sarit — MP4Box lipseste; seteaza AV_TOOL_MP4BOX)"
else
    export AV_TOOL_MP4BOX="$_MP4BOX"
    # shellcheck disable=SC1090
    source "$AVC" 2>/dev/null || true
    TD=$(mktemp -d "${TMPDIR:-/tmp}/v89atmos.XXXXXX")
    trap 'rm -rf "$TD"; _test_summary' EXIT

    # fara tool → rc=1 curat, fara WAV partial
    if AV_TOOL_CAVERNIZE="/nonexistent_cavern_$$" _atmos_render_714 "$SAMPLE" "$TD/no.wav" >/dev/null 2>&1; then
        assert_eq "rc1" "rc0" "render fara tool: trebuia rc=1"
    else
        assert_eq "ok" "ok" "render fara tool: rc=1 curat"
    fi
    assert_eq "0" "$(ls "$TD"/no.wav 2>/dev/null | grep -c . || true)" "render fara tool: zero WAV partial"

    # render REAL pe sample-ul Atmos 20s (TrueHD cu obiecte; truehdd auto-descarcat de Cavernize)
    # NB: sample-ul de 20s lumineaza DOAR FL (Tone-ul oficial e secvential) — validarea
    # tuturor celor 12 canale s-a facut pe Tone-ul COMPLET; aici validam contractul
    # helperului: WAV 12ch layout 7.1.4 + lantul author cu audio_src.
    _iamf_render_test_wav="$TD/r714.wav"
    _atmos_render_714 "$SAMPLE" "$_iamf_render_test_wav" >/dev/null 2>&1
    assert_zero $? "render 20s: rc=0"
    _rch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$_iamf_render_test_wav" 2>/dev/null | head -1 | tr -d '\r')
    assert_eq "12" "$_rch" "render 20s: WAV are 12 canale"
    _rlay=$(ffprobe -v error -select_streams a:0 -show_entries stream=channel_layout -of default=noprint_wrappers=1:nokey=1 "$_iamf_render_test_wav" 2>/dev/null | head -1 | tr -d '\r')
    assert_eq "7.1.4" "$_rlay" "render 20s: layout nativ ffmpeg 7.1.4 (zero remapare)"

    # authoring cu audio_src (arg 5): audio din WAV, video din sursa
    _iamf_author "$SAMPLE" "$TD/out714.mp4" "7.1.4" "" "$_iamf_render_test_wav" >/dev/null 2>&1
    assert_zero $? "author cu audio_src: rc=0"
    assert_eq "7.1.4" "$(_iamf_probe "$TD/out714.mp4")" "author cu audio_src: probe → 7.1.4"
    _v=$(ffprobe -hide_banner "$TD/out714.mp4" 2>&1 | grep -ac 'Stream #.*Video:')
    assert_eq "1" "$_v" "author cu audio_src: video-ul din SURSA e pastrat (copy)"

    # zero temp-uri orfane atmos714_ (extractul MKV se curata)
    assert_eq "0" "$(find "$TD" -name "*.atmos714_*.mkv" 2>/dev/null | grep -c . || true)" \
        "zero temp-uri orfane atmos714_ (extract MKV curatat)"
fi
# NB: fara _test_summary explicit — framework-ul are trap implicit; ramura functionala
# il pastreaza in trap-ul propriu de cleanup (regula v43: 'rm; _test_summary').
