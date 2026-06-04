#!/usr/bin/env python3
# ══════════════════════════════════════════════════════════════════════
# dji_djmd_dlogm.py — detecteaza profilul D-Log M din track-ul de metadata
# djmd al camerelor DJI Osmo Action 6 (model AC006).
#
# Problema: pe Action 6, D-Log M e INVIZIBIL in metadata containerului — atat
# Normal cat si D-Log M raporteaza identic pix_fmt=yuv420p10le,
# color_primaries=bt709, color_transfer=bt709. Curba LOG sta in pixeli, iar
# discriminatorul sta in protobuf-ul djmd (schema dvtm_ac206.proto), la
# path-ul .2.4.1 (field 1 din sub-mesajul .2.4, varint):
#     .2.4.1 == 19   -> D-Log M
#     .2.4.1 absent  -> Normal
# Validat empiric pe 4 clipuri reale Action 6 (2 D-Log + 2 Normal). exiftool
# NU expune acest camp (decodeaza doar un subset din djmd).
#
# Model-gate: ne increm DOAR pe Action 6 — verificam ca string-ul
# "dvtm_ac206.proto" apare in dump. Orice alt model / sursa cu layout djmd
# neverificat -> raportam "unknown" (conservator: fara fals-pozitive pe ce nu
# am validat). Caller-ul decide ce face cu "unknown" (implicit: SDR onest).
#
# Engine partajat bash <-> PowerShell (ca av1_dv_t35_repair.py); doar stdlib.
# Input = dump-ul brut al track-ului djmd (caller-ul il extrage cu
# `ffmpeg -i in -map 0:<djmd_idx> -c copy -f data out.djmd`).
#   usage: dji_djmd_dlogm.py <djmd_dump>
#   stdout: "dlog_m" | "normal" | "unknown"
#   exit:   0 mereu (soft — caller decide ce face cu "unknown")
# ══════════════════════════════════════════════════════════════════════
import sys

MODEL_GATE  = b"dvtm_ac206.proto"  # schema protobuf Action 6 (AC006)
DLOGM_VALUE = 19                   # .2.4.1 == 19 -> D-Log M


def _rv(buf, p, end):
    """Decodeaza un varint din buf la offset p (< end). Return (val, p_nou)."""
    val = 0; sh = 0
    while True:
        if p >= end:
            raise ValueError("eof in varint")
        b = buf[p]; val |= (b & 0x7f) << sh; p += 1; sh += 7
        if not (b & 0x80):
            break
        if sh > 70:
            raise ValueError("varint prea lung")
    return val, p


def _fields(buf, s, e):
    """Iterator peste campurile protobuf din [s, e). Yield (field_num, wire_type,
    info, p_dupa). info = (start,end) pt wt2 / valoarea varint pt wt0 / None."""
    p = s
    while p < e:
        tag, p = _rv(buf, p, e); fn = tag >> 3; wt = tag & 7
        if wt == 0:
            v, p = _rv(buf, p, e); yield fn, 0, v, p
        elif wt == 2:
            ln, p = _rv(buf, p, e); a = p; p += ln
            if p > e:
                raise ValueError("len-delimited depaseste mesajul")
            yield fn, 2, (a, p), p
        elif wt == 1:
            p += 8; yield fn, 1, None, p
        elif wt == 5:
            p += 4; yield fn, 5, None, p
        else:
            raise ValueError("wire-type %d invalid" % wt)


def _has_dlogm(buf):
    """True daca exista path 2 -> 4 -> 1 == DLOGM_VALUE oriunde in blob.
    Dump-ul djmd e o concatenare de inregistrari protobuf per-sample (muxerul
    `data` pierde framing-ul) -> parcurgem campurile top-level secvential, cu
    resync tolerant (p+=1) pe erori de aliniere. Early-exit la prima potrivire."""
    n = len(buf); p = 0
    while p < n:
        try:
            fn, wt, info, np = next(_fields(buf, p, n))
        except (StopIteration, ValueError, IndexError):
            p += 1; continue
        if fn == 2 and wt == 2:
            a, b = info
            try:
                for f2, w2, i2, _ in _fields(buf, a, b):
                    if f2 == 4 and w2 == 2:
                        c, d = i2
                        for f3, w3, i3, _ in _fields(buf, c, d):
                            if f3 == 1 and w3 == 0 and i3 == DLOGM_VALUE:
                                return True
            except (ValueError, IndexError):
                pass
        p = np
    return False


def detect(path):
    try:
        with open(path, "rb") as fh:
            buf = fh.read()
    except OSError:
        return "unknown"
    if not buf or MODEL_GATE not in buf:
        return "unknown"   # nu e Action 6 (sau dump gol) -> nu garantam path-ul
    return "dlog_m" if _has_dlogm(buf) else "normal"


def main(argv):
    if len(argv) < 2:
        print("unknown"); return 0
    print(detect(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
