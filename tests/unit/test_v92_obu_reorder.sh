#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# v92 — reorder OBU metadata T.35 la pozitia conforma (bash).
#   av1dovi_tool / av1hdr10plus_tool inject scriu OBU-ul de metadata la
#   INCEPUTUL temporal unit-ului; spec-ul Dolby Vision AV1 il cere DUPA
#   toate cadrele non-shown (GPAC avertizeaza "must appear after all
#   non-shown frames"), iar continutul real + encoderele native il pun
#   imediat INAINTEA cadrului shown (DV inaintea HDR10+). v92 muta
#   OBU-urile in engine-ul av1_dv_t35_repair.py (aceeasi trecere cu
#   repair-ul 0x80, moduri dv/hdr10plus/both 1:1, zero situri noi).
#   Source-level + functional hermetic pe IVF sintetic craftat (doar
#   python, fara ffmpeg) + sectiune reala sample-gated.
# ══════════════════════════════════════════════════════════════════════
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SRC:$PATH"
ENGINE="$SRC/av1_dv_t35_repair.py"

# ── 1. Source-level: engine + calleri ─────────────────────────────────
ENG="$(cat "$ENGINE")"
assert_contains "$ENG" 'def reorder_tu'      "engine are faza de reorder (reorder_tu)"
assert_contains "$ENG" 'moved='              "engine raporteaza moved= in sumar"
assert_contains "$ENG" 'skipped='            "engine raporteaza skipped= in sumar (TU-uri anomale neatinse)"
assert_contains "$ENG" "not in providers"    "insert-point sare T.35-urile NEmutate lipite de shown (svtav1-inline)"
CMN="$(cat "$SRC/av_common.sh")"
assert_contains "$CMN" 'reordonat conform'   "mesajul _repair_av1_dv_t35 mentioneaza reorder-ul"
ENC="$(cat "$SRC/av_encode.ps1")"
assert_contains "$ENC" 'reordonat conform'   "paritate PS1: mesajul Repair-Av1DvT35 mentioneaza reorder-ul"

# ── 2. Functional hermetic (IVF sintetic — doar python) ───────────────
PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"
if [ -n "$PY" ]; then
    TMP="$(mktemp -d)"
    HELPER="$TMP/v92_craft.py"
    cat > "$HELPER" <<'PYEOF'
import sys

def leb(v):
    out = bytearray()
    while True:
        b = v & 0x7f; v >>= 7
        if v: out.append(b | 0x80)
        else: out.append(b); break
    return bytes(out)

def obu(t, payload):
    return bytes([(t << 3) | 0x02]) + leb(len(payload)) + payload

def t35(prov, aligned=False):
    pl = leb(4) + b'\xb5' + bytes([prov >> 8, prov & 0xff]) + b'\x01\x02\x03'
    if aligned:
        pl += b'\x80'
    return obu(5, pl)

TD   = obu(2, b'')
SEQ  = obu(1, b'\x00\x00\x00\x00')      # reduced_still=0
KEYS = obu(6, b'\x10' + b'\xaa' * 8)    # shown key (ft=0, show=1)
NSH  = obu(6, b'\x20' + b'\xbb' * 8)    # non-shown inter (ft=1, show=0)
SHOW = obu(6, b'\x30' + b'\xcc' * 8)    # shown inter
SEF  = obu(3, b'\x80')                  # frame header show_existing=1

def ivf(tus):
    h = b'DKIF' + (0).to_bytes(2, 'little') + (32).to_bytes(2, 'little') + b'AV01'
    h += (64).to_bytes(2, 'little') + (64).to_bytes(2, 'little')
    h += (25).to_bytes(4, 'little') + (1).to_bytes(4, 'little')
    h += len(tus).to_bytes(4, 'little') + (0).to_bytes(4, 'little')
    out = bytearray(h)
    for i, tu in enumerate(tus):
        out += len(tu).to_bytes(4, 'little') + i.to_bytes(8, 'little') + tu
    return bytes(out)

CASES = {
    # forma av1dovi: DV la inceput de TU (TU1 = neconform, TU0/TU2 deja lipite de shown)
    'dv_start':     [TD + SEQ + t35(0x3b) + KEYS,
                     TD + t35(0x3b) + NSH + NSH + SHOW,
                     TD + t35(0x3b) + SEF],
    # svtav1-inline: HDR10+ nativ linga shown + DV injectat la inceput (mode=dv)
    'dv_native_hp': [TD + SEQ + t35(0x3b) + NSH + t35(0x3c, aligned=True) + SHOW],
    # izolare mod: mode=hdr10plus muta DOAR 003C, DV aligned ramane pe loc
    'hp_isolation': [TD + t35(0x3b, aligned=True) + t35(0x3c) + NSH + SHOW],
    # deja conform -> moved=0 (idempotenta reorder-ului)
    'compliant':    [TD + SEQ + NSH + t35(0x3b) + SHOW],
    # anomalie: TU fara cadru shown -> neatins (skipped=1)
    'no_shown':     [TD + t35(0x3b) + NSH],
}

def layout(path):
    data = open(path, 'rb').read()
    hl = int.from_bytes(data[6:8], 'little'); p = hl
    rs = 0; outs = []
    while p + 12 <= len(data):
        fsz = int.from_bytes(data[p:p + 4], 'little')
        tu = data[p + 12:p + 12 + fsz]; p += 12 + fsz
        q = 0; names = []
        while q < len(tu):
            hdr = tu[q]; ot = (hdr >> 3) & 0xf
            ext = (hdr >> 2) & 1; hs = (hdr >> 1) & 1
            r = q + 1 + (1 if ext else 0)
            if hs:
                sz = 0; sh = 0; ln = 0
                while True:
                    b = tu[r + ln]; sz |= (b & 0x7f) << sh; ln += 1; sh += 7
                    if not (b & 0x80):
                        break
                ps = r + ln
            else:
                sz = len(tu) - r; ps = r
            pl = tu[ps:ps + sz]
            if ot == 2:
                nm = 'TD'
            elif ot == 1:
                nm = 'SEQ'; rs = (pl[0] >> 3) & 1
            elif ot == 5:
                pv = (pl[2] << 8) | pl[3]
                nm = 'DV' if pv == 0x3b else ('HP' if pv == 0x3c else 'MT')
                if pl[-1:] == b'\x80':
                    nm += '+80'
            elif ot in (3, 6):
                if rs or (pl[0] >> 7) & 1 or (pl[0] >> 4) & 1:
                    nm = 'SHOWN'
                else:
                    nm = 'NSH'
            else:
                nm = str(ot)
            names.append('%s(%d)' % (nm, sz))
            q = ps + sz
        outs.append('|'.join(names))
    print(';'.join(outs))

def verify(path, prov_hex):
    want = int(prov_hex, 16)
    data = open(path, 'rb').read()
    hl = int.from_bytes(data[6:8], 'little'); p = hl
    rs = 0; target_tus = 0; bad = 0
    while p + 12 <= len(data):
        fsz = int.from_bytes(data[p:p + 4], 'little')
        tu = data[p + 12:p + 12 + fsz]; p += 12 + fsz
        q = 0; idx = 0; tgt = []; nsh = []
        while q < len(tu):
            hdr = tu[q]; ot = (hdr >> 3) & 0xf
            ext = (hdr >> 2) & 1; hs = (hdr >> 1) & 1
            r = q + 1 + (1 if ext else 0)
            if hs:
                sz = 0; sh = 0; ln = 0
                while True:
                    b = tu[r + ln]; sz |= (b & 0x7f) << sh; ln += 1; sh += 7
                    if not (b & 0x80):
                        break
                ps = r + ln
            else:
                sz = len(tu) - r; ps = r
            pl = tu[ps:ps + sz]
            if ot == 1 and sz:
                rs = (pl[0] >> 3) & 1
            elif ot == 5 and sz > 3 and pl[1] == 0xb5 and ((pl[2] << 8) | pl[3]) == want:
                tgt.append(idx)
            elif ot in (3, 6) and sz:
                if not (rs or (pl[0] >> 7) & 1 or (pl[0] >> 4) & 1):
                    nsh.append(idx)
            idx += 1
            q = ps + sz
        if tgt:
            target_tus += 1
            if nsh and min(tgt) < max(nsh):
                bad += 1
    print('target_tus=%d bad=%d' % (target_tus, bad))

cmd = sys.argv[1]
if cmd == 'craft':
    open(sys.argv[3], 'wb').write(ivf(CASES[sys.argv[2]]))
elif cmd == 'layout':
    layout(sys.argv[2])
elif cmd == 'verify':
    verify(sys.argv[2], sys.argv[3])
PYEOF

    _run_case() {   # nume mod -> layout string + stderr engine in $TMP
        "$PY" "$HELPER" craft "$1" "$TMP/$1.ivf"
        "$PY" "$ENGINE" "$TMP/$1.ivf" "$TMP/$1.out.ivf" "$2" 2>"$TMP/$1.err" >/dev/null
        "$PY" "$HELPER" layout "$TMP/$1.out.ivf"
    }

    # forma av1dovi (mode=dv): TU1 mutat, TU0/TU2 deja conforme
    L1="$(_run_case dv_start dv)"
    assert_eq "TD(0)|SEQ(4)|DV+80(8)|SHOWN(9);TD(0)|NSH(9)|NSH(9)|DV+80(8)|SHOWN(9);TD(0)|DV+80(8)|SHOWN(1)" \
        "$L1" "dv_start: DV mutat dupa non-shown, imediat inaintea shown (incl. show_existing)"
    assert_contains "$(cat "$TMP/dv_start.err")" 't35_fixed=3 moved=1 skipped=0' \
        "dv_start: sumar corect (3 reparate, 1 mutat, 0 sarite)"

    # svtav1-inline (mode=dv): DV intra INAINTEA HDR10+-ului nativ nemiscat
    L2="$(_run_case dv_native_hp dv)"
    assert_eq "TD(0)|SEQ(4)|NSH(9)|DV+80(8)|HP+80(8)|SHOWN(9)" \
        "$L2" "dv_native_hp: DV mutat inaintea HDR10+-ului nativ (ordinea din continutul real)"

    # izolare mod: hdr10plus NU atinge DV (nici 0x80, nici pozitia)
    L3="$(_run_case hp_isolation hdr10plus)"
    assert_eq "TD(0)|DV+80(8)|NSH(9)|HP+80(8)|SHOWN(9)" \
        "$L3" "hp_isolation: mode=hdr10plus muta doar 003C, DV ramane pe loc fara al 2-lea 0x80"

    # deja conform -> moved=0 (reorder idempotent)
    L4="$(_run_case compliant dv)"
    assert_eq "TD(0)|SEQ(4)|NSH(9)|DV+80(8)|SHOWN(9)" \
        "$L4" "compliant: pozitia conforma ramane neatinsa"
    assert_contains "$(cat "$TMP/compliant.err")" 'moved=0 skipped=0' \
        "compliant: moved=0 (no-op pe plasare deja conforma)"

    # anomalie: TU fara cadru shown -> plasarea veche pastrata, skipped=1
    L5="$(_run_case no_shown dv)"
    assert_eq "TD(0)|DV+80(8)|NSH(9)" \
        "$L5" "no_shown: TU anomal neatins (repair da, mutare nu)"
    assert_contains "$(cat "$TMP/no_shown.err")" 'moved=0 skipped=1' \
        "no_shown: skipped=1 raportat onest"

    # ── 3. Functional REAL (sample-gated): lantul inject prin engine ──
    SAMPLE="$SRC/Upload_S02E01_DV_40s_AV1.mkv"
    if [ -f "$SAMPLE" ] && command -v ffmpeg >/dev/null 2>&1 && command -v av1dovi_tool >/dev/null 2>&1; then
        ffmpeg -v error -y -i "$SAMPLE" -c:v copy -t 5 -an -f ivf "$TMP/real.ivf" </dev/null 2>/dev/null
        av1dovi_tool extract-rpu -i "$TMP/real.ivf" -o "$TMP/real.rpu" >/dev/null 2>&1
        av1dovi_tool remove -i "$TMP/real.ivf" -o "$TMP/real_clean.ivf" >/dev/null 2>&1
        av1dovi_tool inject-rpu -i "$TMP/real_clean.ivf" --rpu-in "$TMP/real.rpu" -o "$TMP/real_inj.ivf" >/dev/null 2>&1
        if [ -s "$TMP/real_inj.ivf" ]; then
            "$PY" "$ENGINE" "$TMP/real_inj.ivf" "$TMP/real_fix.ivf" dv 2>"$TMP/real.err" >/dev/null
            V="$("$PY" "$HELPER" verify "$TMP/real_fix.ivf" 3b)"
            assert_match "$V" 'bad=0' "real: ZERO OBU DV inaintea cadrelor non-shown (conform pe tot stream-ul)"
            assert_match "$V" 'target_tus=[1-9]' "real: DV prezent in TU-uri (mutarea nu l-a pierdut)"
            # integritate: extract pre-engine == extract post-engine (byte-identic)
            av1dovi_tool extract-rpu -i "$TMP/real_inj.ivf" -o "$TMP/r_pre.rpu" >/dev/null 2>&1
            av1dovi_tool extract-rpu -i "$TMP/real_fix.ivf" -o "$TMP/r_post.rpu" >/dev/null 2>&1
            if cmp -s "$TMP/r_pre.rpu" "$TMP/r_post.rpu"; then
                assert_eq "ok" "ok" "real: RPU byte-identic pre/post engine (repair+reorder lossless)"
            else
                assert_eq "identic" "diferit" "real: RPU byte-identic pre/post engine (repair+reorder lossless)"
            fi
            # decode strict: zero Malformed T.35 la dav1d
            ERRS="$(ffmpeg -v warning -i "$TMP/real_fix.ivf" -f null - </dev/null 2>&1 | grep -ci 'malformed' || true)"
            assert_eq "0" "$ERRS" "real: decode dav1d fara Malformed T.35"
            # oracol GPAC (non-MSYS: MP4Box nu rezolva caile POSIX git-bash — clasa v71)
            case "$(uname -s 2>/dev/null)" in
                MINGW*|MSYS*|CYGWIN*) echo "  (oracol MP4Box sarit pe MSYS — acoperit de test_v92 PS1)" ;;
                *)
                    MP4BOX="${AV_TOOL_MP4BOX:-MP4Box}"
                    if command -v "$MP4BOX" >/dev/null 2>&1; then
                        W="$("$MP4BOX" -add "$TMP/real_fix.ivf:dvp=10.1" -new "$TMP/real_fix.mp4" 2>&1 | grep -c 'Dolby' || true)"
                        assert_eq "0" "$W" "real: MP4Box import fara warning de plasare Dolby"
                    else
                        echo "  (oracol MP4Box sarit — binar indisponibil)"
                    fi
                    ;;
            esac
        else
            echo "  (lant real sarit — inject esuat)"
        fi
    else
        echo "  (functional real sarit — sample/av1dovi_tool/ffmpeg indisponibile)"
    fi

    rm -rf "$TMP"
else
    echo "  (functional sarit — python indisponibil)"
fi

# sumarul vine din trap-ul EXIT al framework-ului
