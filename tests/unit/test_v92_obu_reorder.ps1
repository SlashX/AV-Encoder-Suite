# ══════════════════════════════════════════════════════════════════════
# v92 — reorder OBU metadata T.35 la pozitia conforma (PS1). Mirror bash.
#   Source-level (engine + mesaje calleri, paritate) + functional hermetic
#   pe IVF sintetic craftat (doar python) + sectiune reala sample-gated cu
#   oracolul MP4Box (ruleaza REAL pe Windows — pe MSYS bash se sare).
# ══════════════════════════════════════════════════════════════════════
. "$PSScriptRoot\..\framework.ps1"

$proj = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$src  = Join-Path $proj 'src'
$engine = Join-Path $src 'av1_dv_t35_repair.py'

# ── 1. Source-level: engine + calleri (paritate) ──────────────────────
$eng = Get-Content $engine -Raw
Assert-Match $eng 'def reorder_tu'      "engine are faza de reorder (reorder_tu)"
Assert-Match $eng 'moved='              "engine raporteaza moved= in sumar"
Assert-Match $eng 'skipped='            "engine raporteaza skipped= in sumar (TU-uri anomale neatinse)"
Assert-Match $eng 'not in providers'    "insert-point sare T.35-urile NEmutate lipite de shown (svtav1-inline)"
$cmn = Get-Content (Join-Path $src 'av_common.sh') -Raw
Assert-Match $cmn 'reordonat conform'   "mesajul _repair_av1_dv_t35 mentioneaza reorder-ul"
$enc = Get-Content (Join-Path $src 'av_encode.ps1') -Raw
Assert-Match $enc 'reordonat conform'   "paritate PS1: mesajul Repair-Av1DvT35 mentioneaza reorder-ul"

# ── 2. Functional hermetic (IVF sintetic — doar python) ───────────────
$py = Get-Command python -ErrorAction SilentlyContinue
if ($py) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v92obu_" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $helper = Join-Path $tmp 'v92_craft.py'
    Set-Content -Path $helper -Encoding UTF8 -Value @'
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
SEQ  = obu(1, b'\x00\x00\x00\x00')
KEYS = obu(6, b'\x10' + b'\xaa' * 8)
NSH  = obu(6, b'\x20' + b'\xbb' * 8)
SHOW = obu(6, b'\x30' + b'\xcc' * 8)
SEF  = obu(3, b'\x80')

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
    'dv_start':     [TD + SEQ + t35(0x3b) + KEYS,
                     TD + t35(0x3b) + NSH + NSH + SHOW,
                     TD + t35(0x3b) + SEF],
    'dv_native_hp': [TD + SEQ + t35(0x3b) + NSH + t35(0x3c, aligned=True) + SHOW],
    'hp_isolation': [TD + t35(0x3b, aligned=True) + t35(0x3c) + NSH + SHOW],
    'compliant':    [TD + SEQ + NSH + t35(0x3b) + SHOW],
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
'@

    function _RunCase([string]$name, [string]$mode) {
        & python $helper craft $name (Join-Path $tmp "$name.ivf") 2>$null
        $script:caseErr = (& python $engine (Join-Path $tmp "$name.ivf") (Join-Path $tmp "$name.out.ivf") $mode 2>&1 | Out-String)
        return ((& python $helper layout (Join-Path $tmp "$name.out.ivf") 2>$null) | Out-String).Trim()
    }

    $L1 = _RunCase 'dv_start' 'dv'
    Assert-Eq "TD(0)|SEQ(4)|DV+80(8)|SHOWN(9);TD(0)|NSH(9)|NSH(9)|DV+80(8)|SHOWN(9);TD(0)|DV+80(8)|SHOWN(1)" `
        $L1 "dv_start: DV mutat dupa non-shown, imediat inaintea shown (incl. show_existing)"
    Assert-Match $caseErr 't35_fixed=3 moved=1 skipped=0' "dv_start: sumar corect (3 reparate, 1 mutat, 0 sarite)"

    $L2 = _RunCase 'dv_native_hp' 'dv'
    Assert-Eq "TD(0)|SEQ(4)|NSH(9)|DV+80(8)|HP+80(8)|SHOWN(9)" `
        $L2 "dv_native_hp: DV mutat inaintea HDR10+-ului nativ (ordinea din continutul real)"

    $L3 = _RunCase 'hp_isolation' 'hdr10plus'
    Assert-Eq "TD(0)|DV+80(8)|NSH(9)|HP+80(8)|SHOWN(9)" `
        $L3 "hp_isolation: mode=hdr10plus muta doar 003C, DV ramane pe loc fara al 2-lea 0x80"

    $L4 = _RunCase 'compliant' 'dv'
    Assert-Eq "TD(0)|SEQ(4)|NSH(9)|DV+80(8)|SHOWN(9)" `
        $L4 "compliant: pozitia conforma ramane neatinsa"
    Assert-Match $caseErr 'moved=0 skipped=0' "compliant: moved=0 (no-op pe plasare deja conforma)"

    $L5 = _RunCase 'no_shown' 'dv'
    Assert-Eq "TD(0)|DV+80(8)|NSH(9)" `
        $L5 "no_shown: TU anomal neatins (repair da, mutare nu)"
    Assert-Match $caseErr 'moved=0 skipped=1' "no_shown: skipped=1 raportat onest"

    # ── 3. Functional REAL (sample-gated) + oracolul MP4Box pe Windows ─
    $env:PATH = "$src;$env:PATH"
    $sample = Join-Path $src 'Upload_S02E01_DV_40s_AV1.mkv'
    $haveTools = (Get-Command ffmpeg -EA SilentlyContinue) -and (Get-Command av1dovi_tool -EA SilentlyContinue)
    if ((Test-Path $sample) -and $haveTools) {
        & ffmpeg -v error -y -i $sample -c:v copy -t 5 -an -f ivf (Join-Path $tmp 'real.ivf') 2>$null
        & av1dovi_tool extract-rpu -i (Join-Path $tmp 'real.ivf') -o (Join-Path $tmp 'real.rpu') *> $null
        & av1dovi_tool remove -i (Join-Path $tmp 'real.ivf') -o (Join-Path $tmp 'real_clean.ivf') *> $null
        & av1dovi_tool inject-rpu -i (Join-Path $tmp 'real_clean.ivf') --rpu-in (Join-Path $tmp 'real.rpu') -o (Join-Path $tmp 'real_inj.ivf') *> $null
        if ((Test-Path (Join-Path $tmp 'real_inj.ivf')) -and (Get-Item (Join-Path $tmp 'real_inj.ivf')).Length -gt 0) {
            & python $engine (Join-Path $tmp 'real_inj.ivf') (Join-Path $tmp 'real_fix.ivf') dv 2>$null | Out-Null
            $v = ((& python $helper verify (Join-Path $tmp 'real_fix.ivf') '3b' 2>$null) | Out-String).Trim()
            Assert-Match $v 'bad=0' "real: ZERO OBU DV inaintea cadrelor non-shown (conform pe tot stream-ul)"
            Assert-Match $v 'target_tus=[1-9]' "real: DV prezent in TU-uri (mutarea nu l-a pierdut)"
            & av1dovi_tool extract-rpu -i (Join-Path $tmp 'real_inj.ivf') -o (Join-Path $tmp 'r_pre.rpu') *> $null
            & av1dovi_tool extract-rpu -i (Join-Path $tmp 'real_fix.ivf') -o (Join-Path $tmp 'r_post.rpu') *> $null
            $same = (Get-FileHash (Join-Path $tmp 'r_pre.rpu')).Hash -eq (Get-FileHash (Join-Path $tmp 'r_post.rpu')).Hash
            Assert-Eq "True" "$same" "real: RPU byte-identic pre/post engine (repair+reorder lossless)"
            $dec = & ffmpeg -v warning -i (Join-Path $tmp 'real_fix.ivf') -f null NUL 2>&1
            $mal = ($dec | Select-String -Pattern 'malformed' | Measure-Object).Count
            Assert-Eq "0" "$mal" "real: decode dav1d fara Malformed T.35"
            $mp4boxName = if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } else { 'MP4Box' }
            if (Get-Command $mp4boxName -EA SilentlyContinue) {
                $w = (& $mp4boxName -add "$(Join-Path $tmp 'real_fix.ivf'):dvp=10.1" -new (Join-Path $tmp 'real_fix.mp4') 2>&1 |
                    Select-String 'Dolby' | Measure-Object).Count
                Assert-Eq "0" "$w" "real: MP4Box import fara warning de plasare Dolby (oracol GPAC)"
            } else {
                Write-Host "  (oracol MP4Box sarit — binar indisponibil)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  (lant real sarit — inject esuat)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  (functional real sarit — sample/av1dovi_tool/ffmpeg indisponibile)" -ForegroundColor DarkGray
    }

    Remove-Item -Recurse -Force $tmp -EA SilentlyContinue
} else {
    Write-Host "  (functional sarit — python indisponibil)" -ForegroundColor DarkGray
}

Invoke-TestSummary
