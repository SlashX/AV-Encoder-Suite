#!/usr/bin/env bash
# v94 — AV1 VBR / 2-pass pe SVT-AV1. Doua defecte gasite la reluarea matricei:
#
#   B12 (fatal): suita calculeaza mereu maxrate = target x 1.5 si il trimitea si la
#     libsvtav1, care il REFUZA in VBR — „Svt[error]: Max Bitrate only supported with CRF
#     mode" → encoderul nici nu porneste (exit 127, 0 octeti). Adica AV1 VBR (1-pass SI
#     2-pass) nu a functionat niciodata pe SVT. maxrate/bufsize raman pentru libaom-av1.
#
#   B13 (tacut): sintaxa inline `pass=N:stats=` NU e implementata pe toate build-urile.
#     Acolo esecul e perfid — mesajul „Error parsing option stats" e pe nivel info (deci
#     invizibil cu `-v error`), exit code-ul ramane 0, dar fisierul de statistici nu se
#     scrie → pass 2 moare cu „RC stats buffer not available". Detectia veche ghicea din
#     `ffmpeg -version`, care pe multe build-uri (gyan.dev 2026) scrie doar „libsvtav1"
#     fara versiune → fallback „optimist" pe sintaxa gresita. Acum se probeaza REZULTATUL.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

AV1_SRC="$(cat "$SCRIPT_DIR/av_encoder_av1.sh")"

# ── B12 source-level: maxrate NU se trimite la libsvtav1 ──
assert_contains "$AV1_SRC" 'if [[ "$AV1_ENCODER" == "libsvtav1" ]]; then' \
    "B12: rate control-ul e ramificat pe encoder"
assert_contains "$AV1_SRC" '_av1_vbv=" -maxrate $VBR_MAXRATE -bufsize $VBR_BUFSIZE"' \
    "B12: maxrate/bufsize doar pe ramura non-SVT (libaom)"
assert_contains "$AV1_SRC" 'rate_flag="-b:v ${VBR_TARGET}${_av1_vbv}"' \
    "B12: rate_flag compus (fara maxrate hardcodat)"
# nicio linie nu mai trimite neconditionat maxrate pe AV1
bad=$(echo "$AV1_SRC" | grep -n 'rate_flag="-b:v \$VBR_TARGET -maxrate' || true)
assert_eq "" "$bad" "B12: zero rate_flag cu -maxrate neconditionat"

# ── B13 source-level: proba se uita la FISIER, nu la exit code/mesaj ──
CMN="$(cat "$SCRIPT_DIR/av_common.sh")"
assert_contains "$CMN" 'if [ -s "$_probe_stats" ]; then' \
    "B13: decizia se ia dupa fisierul de statistici"
assert_contains "$CMN" 'stats=svtprobe.passlog' \
    "B13: proba foloseste nume gol + CWD (ca in productie)"
notv=$(echo "$CMN" | grep -c "assumed-modern" || true)
assert_eq "0" "$notv" "B13: fallback-ul 'assumed-modern' (ghicit din versiune) a disparut"

# ── Functional ──
if command -v ffmpeg >/dev/null 2>&1; then
    export SCRIPT_DIR
    source "$SCRIPT_DIR/av_common.sh" 2>/dev/null
    tmpd="$(mktemp -d)"
    trap 'rm -rf "$tmpd"; _test_summary' EXIT

    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'libsvtav1'; then
        # CANAR B12: daca un SVT viitor accepta maxrate in VBR, testul asta pica si
        # regula (si mesajul „fara plafon") pot fi re-evaluate.
        out=$(ffmpeg -v error -y -f lavfi -i "testsrc2=s=256x256:r=30:d=1" \
              -c:v libsvtav1 -b:v 2000k -maxrate 3000k -bufsize 4000k \
              -svtav1-params "preset=12:rc=1" -f null - 2>&1) || true
        if echo "$out" | grep -qi 'Max Bitrate only supported with CRF'; then
            assert_eq "1" "1" "CANAR B12: SVT-AV1 inca refuza maxrate in VBR"
        else
            assert_eq "1" "0" "CANAR B12: SVT-AV1 accepta acum maxrate in VBR — re-evalueaza B12"
        fi
        # VBR fara maxrate = forma pe care o trimite suita acum
        ffmpeg -v error -y -f lavfi -i "testsrc2=s=256x256:r=30:d=1" \
            -c:v libsvtav1 -b:v 2000k -svtav1-params "preset=12:rc=1" \
            "$tmpd/vbr.mkv" 2>/dev/null
        assert_file_exists "$tmpd/vbr.mkv" "B12: VBR fara plafon produce output"

        # B13: proba reala + coerenta cu mecanismul care chiar scrie statisticile
        _check_svtav1_2pass_caps
        assert_match "$SVTAV1_DETECT_SOURCE" '^proba=' "B13: sursa deciziei e proba, nu versiunea"
        ( cd "$tmpd" && ffmpeg -v error -y -f lavfi -i "testsrc2=s=256x256:r=30:d=1" \
            -c:v libsvtav1 -b:v 2000k -svtav1-params "preset=12:pass=1:stats=chk.passlog" \
            -f null - ) >/dev/null 2>&1 || true
        inline_ok=0; [ -s "$tmpd/chk.passlog" ] && inline_ok=1
        assert_eq "$inline_ok" "$SVTAV1_2PASS_SUPPORTED" \
            "B13: verdictul probei corespunde realitatii (inline scrie stats? $inline_ok)"
        # mecanismul generic trebuie sa scrie statisticile pe build-urile fara inline
        if [ "$inline_ok" -eq 0 ]; then
            ( cd "$tmpd" && ffmpeg -v error -y -f lavfi -i "testsrc2=s=256x256:r=30:d=1" \
                -c:v libsvtav1 -b:v 2000k -svtav1-params "preset=12" \
                -pass 1 -passlogfile gen -f null - ) >/dev/null 2>&1 || true
            gen_ok=0; ls "$tmpd"/gen*.log >/dev/null 2>&1 && gen_ok=1
            assert_eq "1" "$gen_ok" "B13: sintaxa generica -pass/-passlogfile scrie statisticile"
        fi
    else
        echo "  (functional sarit — libsvtav1 lipseste)"
    fi
fi
