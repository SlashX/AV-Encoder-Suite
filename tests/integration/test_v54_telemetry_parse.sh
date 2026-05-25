#!/usr/bin/env bash
# v54 integration: ruleaza parser-ele Python embedate (GPMF + FIT) din av_telemetry.sh
# pe binare sintetice → valideaza GPS5/ACCL/GYRO, GPS9 (Hero11+), FIT temp+enhanced.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"

command -v python3 >/dev/null 2>&1 || skip_test "python3 lipseste"
[[ -f "$SRC/av_telemetry.sh" ]] || skip_test "av_telemetry.sh lipseste"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
OUT=$(python3 - "$SRC/av_telemetry.sh" "$TMP" <<'PYEOF'
import re, struct, os, sys, subprocess, csv, datetime
tele_sh, tmp = sys.argv[1], sys.argv[2]

# 1. extrage parser-ul GPMF_PY (contine si parse_fit) din heredoc
src = open(tele_sh, encoding='utf-8').read()
code = re.search(r"<< 'PYEOF'\n(.*?)\nPYEOF", src, re.S).group(1)
pyfile = os.path.join(tmp, 'parser.py'); open(pyfile,'w',encoding='utf-8').write(code)

def klv(fc,tc,ss,sc,pl):
    h=fc.encode()+bytes([ord(tc) if tc!='\x00' else 0,ss])+struct.pack('>H',sc)
    return h+pl+b'\x00'*((-len(pl))%4)

def run(binf,name,fmt='gpmf'):
    subprocess.run([sys.executable,pyfile,fmt,binf,name,tmp,'4','test'],
                   capture_output=True,text=True)
    with open(os.path.join(tmp,name+'_norm.csv')) as f: rows=list(csv.reader(f))
    return rows[0], rows[1:]

ok=[]
def chk(cond,label):
    ok.append(("OK" if cond else "FAIL")+" "+label)

# ── GPS5 + ACCL + GYRO ────────────────────────────────────────────────
scal_gps=klv('SCAL','l',4,5,struct.pack('>5i',10000000,10000000,1000,1000,100))
gpsf=klv('GPSF','L',4,1,struct.pack('>I',3))
gps5=klv('GPS5','l',20,2,struct.pack('>5i',450000000,250000000,100000,5000,5000)+struct.pack('>5i',450001000,250001000,101000,6000,6000))
strm_gps=klv('STRM','\x00',1,len(scal_gps+gpsf+gps5),scal_gps+gpsf+gps5)
scal_a=klv('SCAL','s',2,1,struct.pack('>h',418))
accl=klv('ACCL','s',6,2,struct.pack('>6h',4100,100,200,4150,120,210))
strm_a=klv('STRM','\x00',1,len(scal_a+accl),scal_a+accl)
scal_g=klv('SCAL','s',2,1,struct.pack('>h',1000))
gyro=klv('GYRO','s',6,2,struct.pack('>6h',50,10,20,60,15,25))
strm_g=klv('STRM','\x00',1,len(scal_g+gyro),scal_g+gyro)
devc_pl=klv('DVNM','c',1,6,b'HERO11')+strm_gps+strm_a+strm_g
binf=os.path.join(tmp,'gp.bin'); open(binf,'wb').write(klv('DEVC','\x00',1,len(devc_pl),devc_pl))
hdr,data=run(binf,'gp')
idx={c:i for i,c in enumerate(hdr)}
chk(len(hdr)==24,'gpmf_norm_24cols')
chk(hdr[-1]=='source_brand','gpmf_source_brand_last')
chk(len(data)==2,'gpmf_2_points')
chk(data[0][idx['gforce_z']]!='','gpmf_gforce_populated')
chk(data[0][idx['gyro_z']]!='','gpmf_gyro_populated')
chk(data[0][idx['fix_quality']]=='3','gpmf_fix_quality')
chk(abs(float(data[0][idx['gforce_z']])-1.006)<0.01,'gpmf_gforce_gravity')

# ── GPS9 (Hero11+) ────────────────────────────────────────────────────
scal9=klv('SCAL','l',4,9,struct.pack('>9i',10000000,10000000,1000,1000,1000,1,1000,100,1))
d=(datetime.datetime(2024,3,15)-datetime.datetime(2000,1,1)).days
secs=12*3600+30*60+45
samp=struct.pack('>7i',450000000,250000000,100000,5000,5000,d,secs*1000)+struct.pack('>2H',150,3)
gps9=klv('GPS9','l',32,1,samp)
strm9=klv('STRM','\x00',1,len(scal9+gps9),scal9+gps9)
devc9=klv('DVNM','c',1,6,b'HERO12')+strm9
binf9=os.path.join(tmp,'g9.bin'); open(binf9,'wb').write(klv('DEVC','\x00',1,len(devc9),devc9))
hdr9,data9=run(binf9,'g9'); i9={c:i for i,c in enumerate(hdr9)}
chk(len(data9)==1,'gps9_1_point')
chk(data9[0][i9['timestamp']].startswith('2024-03-15T12:30:45'),'gps9_embedded_time')
chk(data9[0][i9['hdop']]=='1.50','gps9_dop')
chk(data9[0][i9['lat']].startswith('45.0'),'gps9_lat')

# ── FIT: temp field 13 (NU 23) + enhanced speed/alt (73/78) ───────────
def fit_build():
    # header 12 bytes + .FIT, little-endian
    body=b''
    # definition msg, local 0, mesg_num=20 (record)
    fields=[(0,4,0x85),(1,4,0x85),(253,4,0x86),(73,4,0x86),(78,4,0x84),(13,1,0x01),(23,4,0x86)]
    dfn=bytes([0x40,0,0])+struct.pack('<H',20)+bytes([len(fields)])
    for fn,fs,bt in fields: dfn+=bytes([fn,fs,bt])
    body+=dfn
    lat=int(45.0/(180.0/2**31)); lon=int(25.0/(180.0/2**31))
    ts=1000
    espeed=8500   # 8.5 m/s
    ealt=int((123.4+500)*5)  # enhanced alt
    temp=256-7    # -7 C as sint8 (0xF9)
    accpow=999999 # field 23 = accumulated_power (trebuie IGNORAT pt temp)
    rec=bytes([0])+struct.pack('<i',lat)+struct.pack('<i',lon)+struct.pack('<I',ts)+struct.pack('<I',espeed)+struct.pack('<I',ealt)+bytes([temp])+struct.pack('<I',accpow)
    body+=rec
    hs=12
    hdr=bytes([hs,0x10])+struct.pack('<H',0)+struct.pack('<I',len(body))+b'.FIT'
    return hdr+body+struct.pack('<H',0)
binff=os.path.join(tmp,'g.fit'); open(binff,'wb').write(fit_build())
hdrf,dataf=run(binff,'gf','fit'); iF={c:i for i,c in enumerate(hdrf)}
chk(len(dataf)>=1,'fit_1_point')
if dataf:
    chk(dataf[0][iF['temp_c']]=='-7','fit_temp_field13_signed')
    chk(abs(float(dataf[0][iF['speed_mps']])-8.5)<0.01,'fit_enhanced_speed')
    chk(abs(float(dataf[0][iF['alt_m']])-123.4)<0.5,'fit_enhanced_alt')

print("\n".join(ok))
PYEOF
)
rc=$?
echo "$OUT"
assert_zero $rc "builder python exit 0"

# Fiecare marker trebuie sa fie OK
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    label="${line#* }"
    assert_match "$line" "^OK " "$label"
done <<< "$OUT"
