#!/usr/bin/env python3
# ══════════════════════════════════════════════════════════════════════
# av1_dv_t35_repair.py — repara OBU_METADATA ITU-T T.35 Dolby Vision din
# fluxuri AV1 produse de av1dovi_tool inject-rpu.
#
# Problema: crate-ul dolby_vision (3.3.0+, folosit de av1dovi_tool) arunca
# trailing byte-ul de aliniere 0x80 din payload-ul T.35 al stratului DV.
# Decoderul dav1d il cere si, fara el, respinge metadata ("Malformed ITU-T
# T.35 metadata message format") -> stratul Dolby Vision e pierdut silentios
# la decodare / re-mux. Acest script re-adauga byte-ul 0x80 lipsa.
#
# Surgical: repara DOAR OBU-urile DV (terminal_provider_code 0x00 0x3B,
# Dolby). HDR10+ foloseste acelasi metadata_type=4 cu provider 0x00 0x3C si
# NU este atins (in fluxuri hibride DV+HDR10+ ramane intact).
#
# Opereaza pe IVF (low-overhead bitstream, obu_has_size_field=1).
# A se aplica EXACT O DATA, pe output-ul av1dovi_tool inject-rpu.
#
# Engine partajat bash <-> PowerShell (ca burnin_render.py); doar stdlib.
#   usage: av1_dv_t35_repair.py <in.ivf> <out.ivf>
#   exit: 0 = OK (chiar daca 0 OBU-uri reparate), 1 = eroare (input invalid)
# ══════════════════════════════════════════════════════════════════════
import sys

DV_PROVIDER = 0x003B  # terminal_provider_code Dolby (ITU-T T.35, country 0xB5)


def leb_dec(buf, p):
    """Decodeaza leb128 din buf la offset p. Return (valoare, lungime_bytes)."""
    val = 0; sh = 0; n = 0
    while True:
        b = buf[p + n]; val |= (b & 0x7f) << sh; n += 1; sh += 7
        if not (b & 0x80):
            break
        if n > 8:
            break
    return val, n


def leb_enc(v):
    """Codeaza v ca leb128 minimal."""
    out = bytearray()
    while True:
        b = v & 0x7f; v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b); break
    return bytes(out)


def fix_tu(tu):
    """Parcurge OBU-urile dintr-un temporal unit; re-adauga 0x80 pe OBU-urile
    metadata ITU-T T.35 cu provider Dolby. Return (bytes_noi, nr_reparate)."""
    out = bytearray(); p = 0; n = len(tu); fixed = 0
    while p < n:
        start = p
        hdr = tu[p]
        obu_type = (hdr >> 3) & 0x0f
        ext = (hdr >> 2) & 1
        has_size = (hdr >> 1) & 1
        hdr_len = 1 + (1 if ext else 0)
        q = p + hdr_len
        if has_size:
            size, ln = leb_dec(tu, q); pstart = q + ln
        else:
            size = n - q; pstart = q
        payload = tu[pstart:pstart + size]

        is_dv_t35 = False
        if obu_type == 5 and len(payload):  # OBU_METADATA
            mtype, mln = leb_dec(payload, 0)
            if mtype == 4:  # METADATA_TYPE_ITUT_T35
                cc_off = mln
                cc = payload[cc_off] if cc_off < len(payload) else None
                prov_off = cc_off + (2 if cc == 0xff else 1)
                if prov_off + 1 < len(payload):
                    prov = (payload[prov_off] << 8) | payload[prov_off + 1]
                    if prov == DV_PROVIDER:
                        is_dv_t35 = True

        if is_dv_t35:
            new_payload = bytes(payload) + b"\x80"
            out += tu[start:start + hdr_len]
            if has_size:
                out += leb_enc(len(new_payload))
            out += new_payload
            fixed += 1
        else:
            out += tu[start:pstart + size]  # copy verbatim (HDR10+, non-T.35, ...)
        p = pstart + size
    return bytes(out), fixed


def repair(src, dst):
    data = open(src, "rb").read()
    if data[:4] != b"DKIF":
        sys.stderr.write("av1_dv_t35_repair: input nu este IVF (lipseste DKIF)\n")
        return 1
    hdrlen = int.from_bytes(data[6:8], "little")
    out = bytearray(data[:hdrlen])
    p = hdrlen; total = 0; nframes = 0
    while p + 12 <= len(data):
        fsz = int.from_bytes(data[p:p + 4], "little")
        ts = data[p + 4:p + 12]
        fr = data[p + 12:p + 12 + fsz]; p += 12 + fsz
        new_fr, fx = fix_tu(fr); total += fx; nframes += 1
        out += len(new_fr).to_bytes(4, "little") + ts + new_fr
    open(dst, "wb").write(out)
    sys.stderr.write(
        f"av1_dv_t35_repair: frames={nframes} dv_t35_fixed={total}\n")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.stderr.write("usage: av1_dv_t35_repair.py <in.ivf> <out.ivf>\n")
        sys.exit(2)
    sys.exit(repair(sys.argv[1], sys.argv[2]))
