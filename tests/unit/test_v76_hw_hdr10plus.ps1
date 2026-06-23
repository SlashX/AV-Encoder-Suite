# v76 — HDR10+ (si hibrid DV+HDR10+) preserve pe encodere HW via post-encode inject (PS1).
#   Source-level pe av_encode.ps1 (paritate cu bash) + hermetic pe engine av1_dv_t35_repair.py
#   (mod dv|hdr10plus|both, fara HW/tool extern). Functional QSV/AV1 = validat manual (vezi memorie).
. "$PSScriptRoot\..\framework.ps1"
$proj   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$enc    = Get-Content "$proj\src\av_encode.ps1" -Raw
$engine = "$proj\src\av1_dv_t35_repair.py"
$engSrc = Get-Content $engine -Raw

# ── 1. Helper Inject-Hdr10PlusMetadata (oglinda Inject-DvRpu) ──
Assert-Match $enc 'function Inject-Hdr10PlusMetadata'         "helper Inject-Hdr10PlusMetadata definit"
Assert-Match $enc 'Get-ToolForInject.*-Kind "hdr10plus"'     "Inject-Hdr10PlusMetadata foloseste tool codec-aware"
Assert-Match $enc 'Repair-Av1DvT35 -File \$OutputFile -Mode "hdr10plus"' "Inject-Hdr10Plus repara T.35 mod hdr10plus pe AV1"

# ── 2. Repair-Av1DvT35 are param Mode (default dv, back-compat) ──
Assert-Match $enc '\[string\]\$Mode = "dv"'   "Repair-Av1DvT35 ia -Mode (default dv)"

# ── 3. Ramura DV preserve HW extinsa pt hibrid (extrage SI JSON HDR10+) ──
Assert-Match $enc '\$si\.isHDRPlus -and \(Test-Hdr10PlusToolFor -Codec \$hwTargetCodec\)' "DV preserve detecteaza HDR10+ co-existent (gateat tool)"
Assert-Match $enc 'HW hibrid DV\+HDR10\+: JSON HDR10\+ extras' "DV preserve extrage JSON HDR10+ pt hibrid"

# ── 4. Bloc post-encode: HDR10+ injectat INAINTE de DV RPU in lantul hibrid ──
Assert-Match $enc '\$dvSrc = \$rawTemp; \$hybHp = ""'  "lant hibrid: dvSrc = raw sau raw+HDR10+"
Assert-Match $enc 'Inject-Hdr10PlusMetadata -StreamFile \$rawTemp -JsonFile \$hdr10PlusJson -OutputFile \$hybHp' "HDR10+ injectat in raw inaintea DV"
Assert-Match $enc 'Inject-DvRpu \$dvSrc \$doviRpuFile'  "DV RPU injectat pe sursa cu HDR10+ (hibrid) sau raw"

# ── 5. Blocul standalone HDR10+ NU ruleaza dublu in hibrid (gardat pe tripleLayerMode) ──
Assert-Match $enc '\$hwHdr10PlusInject -and \$hdr10PlusJson -and \(Test-Path \$hdr10PlusJson\) -and -not \$tripleLayerMode' "standalone HDR10+ sare cand triple-layer (hibrid) l-a tratat"

# ── 6. State init + reset defensiv ──
Assert-Match $enc '\$hwHdr10PlusInject = \$false; \$hwHdr10PlusCodec = ""'  "state HW HDR10+ initializat/resetat"

# ── 7. Engine (shared): provider HDR10+ + mod ──
Assert-Match $engSrc 'HDR10PLUS_PROVIDER = 0x003C'  "engine cunoaste provider HDR10+ 0x003C"
Assert-Match $engSrc 'DV_PROVIDER = 0x003B'         "engine cunoaste provider DV 0x003B"
Assert-Match $engSrc 'def providers_for_mode\(mode\)' "engine are providers_for_mode"

# ── 8. Hermetic: engine repara DOAR provider-ul cerut prin mod (fara HW/tool) ──
$py = $null
foreach ($c in @('python','python3')) { $g = Get-Command $c -EA SilentlyContinue; if ($g) { $py = $g.Source; break } }
if ($py) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v76eng_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $harness = Join-Path $tmp "h.py"
    @'
import sys, subprocess, struct
engine, tmp = sys.argv[1], sys.argv[2]
def leb(v):
    o=bytearray()
    while True:
        b=v&0x7f; v>>=7; o.append(b|0x80 if v else b)
        if not v: break
    return bytes(o)
def obu_t35(provider, data):
    payload=b"\x04\xB5"+struct.pack(">H",provider)+data
    return bytes([0x2A])+leb(len(payload))+payload
def build_ivf(tu):
    hdr=b"DKIF"+struct.pack("<H",0)+struct.pack("<H",32)+b"AV01"
    hdr+=struct.pack("<HH",320,240)+struct.pack("<II",30,1)+struct.pack("<II",1,0)
    return hdr+struct.pack("<I",len(tu))+b"\x00"*8+tu
tu=obu_t35(0x003C,b"\x11\x22")+obu_t35(0x003B,b"\x33\x44")
def run(mode):
    src=tmp+f"/in_{mode}.ivf"; dst=tmp+f"/out_{mode}.ivf"
    open(src,"wb").write(build_ivf(tu))
    subprocess.run([sys.executable,engine,src,dst,mode],capture_output=True)
    body=open(dst,"rb").read()[32+12:]; p=0; res={}
    while p<len(body):
        q=p+1; n=0; sh=0; size=0
        while True:
            b=body[q+n]; size|=(b&0x7f)<<sh; n+=1; sh+=7
            if not (b&0x80): break
        s=q+n; pl=body[s:s+size]; res[(pl[2]<<8)|pl[3]]=(len(pl),pl[-1]); p=s+size
    return res
def chk(res,prov,fixed):
    l,last=res[prov]
    return (l==7 and last==0x80) if fixed else (l==6 and last!=0x80)
rh=run("hdr10plus"); rd=run("dv"); rb=run("both")
print("HP_hp_fixed="+("1" if chk(rh,0x003C,True) else "0"))
print("HP_dv_untouched="+("1" if chk(rh,0x003B,False) else "0"))
print("DV_dv_fixed="+("1" if chk(rd,0x003B,True) else "0"))
print("DV_hp_untouched="+("1" if chk(rd,0x003C,False) else "0"))
print("BOTH_hp_fixed="+("1" if chk(rb,0x003C,True) else "0"))
print("BOTH_dv_fixed="+("1" if chk(rb,0x003B,True) else "0"))
'@ | Set-Content -Path $harness -Encoding ASCII
    $out = & $py $harness $engine $tmp 2>$null
    $map = @{}
    foreach ($line in $out) { if ($line -match '^(\w+)=(\d)$') { $map[$Matches[1]] = $Matches[2] } }
    Remove-Item -Recurse -Force $tmp -EA SilentlyContinue
    Assert-Eq "1" $map['HP_hp_fixed']     "mod hdr10plus: OBU 0x003C reparat (+0x80)"
    Assert-Eq "1" $map['HP_dv_untouched'] "mod hdr10plus: OBU DV 0x003B NEatins"
    Assert-Eq "1" $map['DV_dv_fixed']     "mod dv: OBU 0x003B reparat (+0x80)"
    Assert-Eq "1" $map['DV_hp_untouched'] "mod dv: OBU HDR10+ 0x003C NEatins (hibrid SW safe)"
    Assert-Eq "1" $map['BOTH_hp_fixed']   "mod both: OBU 0x003C reparat"
    Assert-Eq "1" $map['BOTH_dv_fixed']   "mod both: OBU 0x003B reparat"
} else {
    Skip-Test "python lipseste — hermetic engine sarit"
}

Invoke-TestSummary
