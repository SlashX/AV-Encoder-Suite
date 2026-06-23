#!/usr/bin/env bash
# v76 — HDR10+ (si hibrid DV+HDR10+) preserve pe encodere HW via post-encode inject (bash).
#   Source-level: wiring hw_preserve / hw_preserve_hdr10plus + bloc post-encode + reset state.
#   Hermetic: engine av1_dv_t35_repair.py mod dv|hdr10plus|both (functie pura, fara HW/tool extern).
#   Functional QSV/AV1 = validat manual la implementare (netestabil aici fara HW/tool; vezi memorie).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
ENGINE="$SCRIPT_DIR/av1_dv_t35_repair.py"

# ── 1. Helper inject_hdr10plus_metadata (oglinda inject_dv_rpu) ──
assert_contains "$COMMON" 'inject_hdr10plus_metadata()'           "helper inject_hdr10plus_metadata definit"
assert_contains "$COMMON" 'tool_for_inject "$target_codec" hdr10plus' "inject_hdr10plus foloseste tool codec-aware"
assert_contains "$COMMON" '_repair_av1_dv_t35 "$output_file" hdr10plus' "inject_hdr10plus repara T.35 mod hdr10plus pe AV1"

# ── 2. _repair_av1_dv_t35 are param mod (default dv, back-compat) ──
assert_contains "$COMMON" 'mode="${2:-dv}"'  "_repair_av1_dv_t35 ia mod (default dv)"

# ── 3. hw_preserve extins pt hibrid DV+HDR10+ (extrage SI JSON cand HDR_PLUS) ──
assert_contains "$COMMON" '== *"HDR10+"* ]] && _check_hdr10plus_tool_for "$enc_codec"' "hw_preserve detecteaza HDR10+ co-existent (gateat tool)"
assert_contains "$COMMON" 'HW hibrid DV+HDR10+ preserve: JSON HDR10+ extras' "hw_preserve extrage JSON HDR10+ pt hibrid"

# ── 4. case hw_preserve_hdr10plus (HDR10+-only pe HW) ──
assert_contains "$COMMON" 'hw_preserve_hdr10plus)'  "case hw_preserve_hdr10plus in hw_dispatch_sdr"
assert_contains "$COMMON" 'HW_HDR10PLUS_INJECT=1'   "hw_preserve_hdr10plus seteaza flag inject"

# ── 5. Bloc post-encode: HDR10+ injectat INAINTE de DV RPU in lantul hibrid ──
assert_contains "$COMMON" 'local _dv_src="$raw_temp" _hyb_hp=""'   "lant hibrid: _dv_src = raw sau raw+HDR10+"
assert_contains "$COMMON" 'inject_hdr10plus_metadata "$raw_temp" "$HDR10PLUS_JSON" "$_hyb_hp" "$_tl_codec"' "HDR10+ injectat in raw inaintea DV"
assert_contains "$COMMON" 'inject_dv_rpu "$_dv_src"'  "DV RPU injectat pe sursa cu HDR10+ (hibrid) sau raw"

# ── 6. Blocul standalone HDR10+ NU ruleaza dublu in hibrid (gardat pe TRIPLE_LAYER_MODE) ──
assert_contains "$COMMON" '[[ "${TRIPLE_LAYER_MODE:-0}" != "1" ]]' "standalone HDR10+ sare cand triple-layer (hibrid) l-a tratat"

# ── 7. State reset defensiv per-fisier ──
assert_contains "$COMMON" 'HW_HDR10PLUS_INJECT=0; HW_HDR10PLUS_CODEC=""' "state HW HDR10+ resetat per-fisier"

# ── 8. Engine: provider HDR10+ + mod ──
ENG="$(cat "$ENGINE")"
assert_contains "$ENG" 'HDR10PLUS_PROVIDER = 0x003C' "engine cunoaste provider HDR10+ 0x003C"
assert_contains "$ENG" 'DV_PROVIDER = 0x003B'        "engine cunoaste provider DV 0x003B"
assert_contains "$ENG" 'def providers_for_mode(mode)' "engine are providers_for_mode"
assert_contains "$ENG" 'def fix_tu(tu, providers)'    "fix_tu ia set de provideri"

# ── 9. Hermetic: engine repara DOAR provider-ul cerut prin mod (fara HW/tool) ──
if command -v python3 >/dev/null 2>&1; then
    TMP="$(mktemp -d)"
    PYOUT="$(python3 - "$ENGINE" "$TMP" <<'PYEOF'
import sys, subprocess, struct
engine, tmp = sys.argv[1], sys.argv[2]

def leb(v):
    o=bytearray()
    while True:
        b=v&0x7f; v>>=7
        o.append(b|0x80 if v else b)
        if not v: break
    return bytes(o)

def obu_t35(provider, data):
    # OBU_METADATA (type 5), has_size=1; payload: metadata_type=4, country=0xB5, provider(2B), data; FARA 0x80
    payload = b"\x04\xB5" + struct.pack(">H", provider) + data
    return bytes([0x2A]) + leb(len(payload)) + payload, len(payload)

def build_ivf(tu):
    hdr = b"DKIF" + struct.pack("<H", 0) + struct.pack("<H", 32) + b"AV01"
    hdr += struct.pack("<HH", 320, 240) + struct.pack("<II", 30, 1) + struct.pack("<II", 1, 0)
    frame = struct.pack("<I", len(tu)) + b"\x00"*8 + tu
    return hdr + frame

HP, hp_len = obu_t35(0x003C, b"\x11\x22")   # HDR10+
DV, dv_len = obu_t35(0x003B, b"\x33\x44")   # DV
tu = HP + DV

def run(mode):
    src = tmp + f"/in_{mode}.ivf"; dst = tmp + f"/out_{mode}.ivf"
    open(src,"wb").write(build_ivf(tu))
    subprocess.run([sys.executable, engine, src, dst, mode], capture_output=True)
    data = open(dst,"rb").read()
    # re-parseaza: gaseste fiecare OBU si lungimea payload-ului per provider
    body = data[32+12:]  # sari IVF hdr (32) + frame hdr (4 size + 8 ts)
    p=0; res={}
    while p < len(body):
        h=body[p]; has_size=(h>>1)&1; q=p+1
        from_leb=0; sh=0; size=0
        while True:
            b=body[q+from_leb]; size|=(b&0x7f)<<sh; from_leb+=1; sh+=7
            if not (b&0x80): break
        pl_start=q+from_leb; pl=body[pl_start:pl_start+size]
        prov=(pl[2]<<8)|pl[3]
        res[prov]=(len(pl), pl[-1])  # (payload_len, last_byte)
        p=pl_start+size
    return res

r_hp = run("hdr10plus")
r_dv = run("dv")
r_both = run("both")
# baseline payload lens: HP=4 (04 B5 00 3C) +2 data =6; DV=6
# dupa repair: +1 (0x80) -> 7
def chk(res, prov, expect_fixed):
    pl_len, last = res[prov]
    if expect_fixed:
        return pl_len == 7 and last == 0x80
    return pl_len == 6 and last != 0x80
print("HP_mode_hp_fixed=" + ("1" if chk(r_hp, 0x003C, True) else "0"))
print("HP_mode_hp_dv_untouched=" + ("1" if chk(r_hp, 0x003B, False) else "0"))
print("DV_mode_dv_fixed=" + ("1" if chk(r_dv, 0x003B, True) else "0"))
print("DV_mode_hp_untouched=" + ("1" if chk(r_dv, 0x003C, False) else "0"))
print("BOTH_hp_fixed=" + ("1" if chk(r_both, 0x003C, True) else "0"))
print("BOTH_dv_fixed=" + ("1" if chk(r_both, 0x003B, True) else "0"))
PYEOF
)"
    rm -rf "$TMP"
    _pv() { echo "$PYOUT" | grep "^$1=" | cut -d= -f2; }
    assert_eq "1" "$(_pv HP_mode_hp_fixed)"        "mod hdr10plus: OBU 0x003C reparat (+0x80)"
    assert_eq "1" "$(_pv HP_mode_hp_dv_untouched)" "mod hdr10plus: OBU DV 0x003B NEatins"
    assert_eq "1" "$(_pv DV_mode_dv_fixed)"        "mod dv: OBU 0x003B reparat (+0x80)"
    assert_eq "1" "$(_pv DV_mode_hp_untouched)"    "mod dv: OBU HDR10+ 0x003C NEatins (hibrid SW safe)"
    assert_eq "1" "$(_pv BOTH_hp_fixed)"           "mod both: OBU 0x003C reparat"
    assert_eq "1" "$(_pv BOTH_dv_fixed)"           "mod both: OBU 0x003B reparat"
else
    skip_test "python3 lipseste — hermetic engine sarit"
fi

_test_summary
