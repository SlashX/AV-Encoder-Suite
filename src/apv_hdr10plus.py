#!/usr/bin/env python3
# ══════════════════════════════════════════════════════════════════════
# apv_hdr10plus.py — inject / extract HDR10+ (SMPTE ST 2094-40) pe APV.
#
# APV (RFC 9924) suporta nativ metadata ITU-T T.35 (payload type 4 in
# PBU-ul de metadata, type 66) — acelasi vehicul ca SEI-ul HEVC / OBU-ul
# AV1 — dar ffmpeg (encoderul liboapv) nu scrie metadata in bitstream si
# decoderul nativ ignora T.35. Acest engine face puntea:
#
#   inject  — JSON HDR10+ (format quietvoid/Samsung, acelasi consumat de
#             x265 dhdr10-info si svtav1 hdr10plus-json) -> serializare
#             ST 2094-40 App1 -> un metadata PBU per access unit, dupa
#             frame-ul primar, cu group_id-ul frame-ului. Optional scrie
#             si MDCV (type 5, ordinea R,G,B!) + CLL (type 6).
#   extract — invers: T.35 din PBU-uri -> JSON quietvoid, gata de
#             dhdr10-info / hdr10plus-json.
#   probe   — detectie rapida (av_check): numara AU-urile cu HDR10+.
#
# Opereaza pe bitstream APV BRUT (extras cu `ffmpeg -c copy -f apv`):
#   [au_size u32 BE | 'aPv1' | (pbu_size u32 | pbu_header | payload)*]*
# Fara start codes / emulation prevention -> chirurgie byte directa.
# Layout validat pe output-ul oapv_app_enc oficial + ffmpeg CBS
# (apv_metadata / trace_headers) + oapv_app_dec.
#
# ATENTIE consumatori raw: output-ul inject are metadata PBU INAINTEA
# frame-ului (altfel decoderul ffmpeg, secvential, nu ataseaza side data),
# dar PROBE-ul demuxerului ffmpeg cere primul PBU = frame/au_info -> la
# citirea raw-ului injectat cu ffmpeg forteaza formatul: `-f apv -i ...`.
# (Containerele mp4/mov/mkv nu au problema; decoderul oficial oapv foloseste
# group_id si accepta ambele ordini. AU_INFO sintetic ar rezolva probe-ul,
# dar cbs_apv din ffmpeg citeste gresit group_id pe 8 biti in au_info —
# bug fata de RFC 9924 §5.3.9 care cere u(16) -> ar pica apv_metadata BSF.)
#
# Suportat: ST 2094-40 Application 1 (tot ecosistemul HDR10+), 1 fereastra.
# Variantele exotice (ferestre multiple, matrice actual_peak_luminance)
# sunt refuzate onest la conversia JSON (parserul intern le citeste corect
# ca sa nu deraieze, iar campurile non-standard ne-nule sunt pastrate in
# chei extra ca round-trip-ul nostru sa fie fara pierderi).
#
# Engine partajat bash <-> PowerShell (ca av1_dv_t35_repair.py); doar stdlib.
#   usage: apv_hdr10plus.py inject  -i in.apv -j meta.json -o out.apv
#                                   [--master-display STR] [--max-cll STR]
#          apv_hdr10plus.py extract -i in.apv -o meta.json
#          apv_hdr10plus.py probe   -i in.apv
#   exit: 0 = OK, 1 = eroare, 2 = usage
# ══════════════════════════════════════════════════════════════════════
import argparse
import json
import re
import struct
import sys

APV_SIG = b"aPv1"
PBU_METADATA = 66
META_ITU_T_T35 = 4
META_MDCV = 5
META_CLL = 6
HDR10P_PREFIX = bytes.fromhex("b5003c0001")  # country B5 | provider 003C | code 0001


def err(msg):
    sys.stderr.write(f"apv_hdr10plus: {msg}\n")


# ── bit I/O (MSB-first) ──────────────────────────────────────────────

class BitReader:
    def __init__(self, data, byte_off=0):
        self.d = data; self.p = byte_off * 8

    def u(self, n):
        v = 0
        for _ in range(n):
            byte = self.d[self.p >> 3]
            v = (v << 1) | ((byte >> (7 - (self.p & 7))) & 1)
            self.p += 1
        return v

    def bits_left(self):
        return len(self.d) * 8 - self.p


class BitWriter:
    def __init__(self):
        self.buf = bytearray(); self.acc = 0; self.n = 0

    def u(self, v, n):
        for i in range(n - 1, -1, -1):
            self.acc = (self.acc << 1) | ((v >> i) & 1); self.n += 1
            if self.n == 8:
                self.buf.append(self.acc); self.acc = 0; self.n = 0

    def align_zero(self):
        """Aliniere la byte cu ZEROURI — conventia serializatorului de REFERINTA
        (quietvoid hdr10plus_tool inject == graderul oficial FF Pictures, validat
        byte-exact pe ambele). NB: encoderul Samsung (telefoane) scrie SEI-style
        `bit 1 + zerouri` (0x40 in loc de 0x00 pe ultimul byte) — parserul accepta
        ambele (padding-ul e non-semantic, dincolo de ultimul camp citit)."""
        while self.n:
            self.u(0, 1)

    def bytes(self):
        assert self.n == 0
        return bytes(self.buf)


# ── ST 2094-40 Application 1: parse / build ──────────────────────────

def parse_t35(payload):
    """T.35 HDR10+ -> dict intern (toate campurile)."""
    if payload[:5] != HDR10P_PREFIX:
        raise ValueError("payload nu e HDR10+ (prefix b5 00 3c 00 01 lipsa)")
    app_id, app_ver = payload[5], payload[6]
    if app_id != 4 or app_ver != 1:
        raise ValueError(f"doar ST 2094-40 App1 suportat (id={app_id} ver={app_ver})")
    br = BitReader(payload, 7)
    m = {"num_windows": br.u(2)}
    if not 1 <= m["num_windows"] <= 3:
        raise ValueError(f"num_windows invalid: {m['num_windows']}")
    wins = []
    for _ in range(m["num_windows"] - 1):
        w = {k: br.u(16) for k in ("ulx", "uly", "lrx", "lry", "cex", "cey")}
        w["rot"] = br.u(8)
        w["smi"] = br.u(16); w["sme"] = br.u(16); w["smn"] = br.u(16)
        w["overlap"] = br.u(1)
        wins.append(w)
    m["extra_windows"] = wins
    m["tsdml"] = br.u(27)
    m["tsdapl_flag"] = br.u(1)
    if m["tsdapl_flag"]:
        r, c = br.u(5), br.u(5)
        m["tsdapl"] = (r, c, [br.u(4) for _ in range(r * c)])
    m["win"] = []
    for _ in range(m["num_windows"]):
        w = {"maxscl": [br.u(17) for _ in range(3)], "avg_maxrgb": br.u(17)}
        n = br.u(4)
        w["dist"] = [(br.u(7), br.u(17)) for _ in range(n)]
        w["fraction_bright"] = br.u(10)
        m["win"].append(w)
    m["mdapl_flag"] = br.u(1)
    if m["mdapl_flag"]:
        r, c = br.u(5), br.u(5)
        m["mdapl"] = (r, c, [br.u(4) for _ in range(r * c)])
    for w in m["win"]:
        w["tm_flag"] = br.u(1)
        if w["tm_flag"]:
            w["knee_x"] = br.u(12); w["knee_y"] = br.u(12)
            n = br.u(4)
            w["anchors"] = [br.u(10) for _ in range(n)]
        w["cs_flag"] = br.u(1)
        if w["cs_flag"]:
            w["cs_weight"] = br.u(6)
    return m


def build_t35(m):
    """dict intern -> payload T.35 HDR10+ (cu prefix + zero-padding la byte)."""
    bw = BitWriter()
    for b in HDR10P_PREFIX + b"\x04\x01":   # prefix + app_id=4 + app_ver=1
        bw.u(b, 8)
    bw.u(m["num_windows"], 2)
    for w in m.get("extra_windows", []):
        for k in ("ulx", "uly", "lrx", "lry", "cex", "cey"):
            bw.u(w[k], 16)
        bw.u(w["rot"], 8)
        bw.u(w["smi"], 16); bw.u(w["sme"], 16); bw.u(w["smn"], 16)
        bw.u(w["overlap"], 1)
    bw.u(m["tsdml"], 27)
    bw.u(m["tsdapl_flag"], 1)
    if m["tsdapl_flag"]:
        r, c, vals = m["tsdapl"]
        bw.u(r, 5); bw.u(c, 5)
        for v in vals: bw.u(v, 4)
    for w in m["win"]:
        for v in w["maxscl"]: bw.u(v, 17)
        bw.u(w["avg_maxrgb"], 17)
        bw.u(len(w["dist"]), 4)
        for pct, val in w["dist"]:
            bw.u(pct, 7); bw.u(val, 17)
        bw.u(w["fraction_bright"], 10)
    bw.u(m["mdapl_flag"], 1)
    if m["mdapl_flag"]:
        r, c, vals = m["mdapl"]
        bw.u(r, 5); bw.u(c, 5)
        for v in vals: bw.u(v, 4)
    for w in m["win"]:
        bw.u(w["tm_flag"], 1)
        if w["tm_flag"]:
            bw.u(w["knee_x"], 12); bw.u(w["knee_y"], 12)
            bw.u(len(w["anchors"]), 4)
            for a in w["anchors"]: bw.u(a, 10)
        bw.u(w["cs_flag"], 1)
        if w["cs_flag"]:
            bw.u(w["cs_weight"], 6)
    bw.align_zero()
    return bw.bytes()


# ── mapare JSON quietvoid/Samsung <-> dict intern ────────────────────

def meta_to_json_entry(m):
    if m["num_windows"] != 1 or m["tsdapl_flag"] or m["mdapl_flag"]:
        raise ValueError("doar num_windows=1 fara matrice actual_peak_luminance "
                         "e reprezentabil in JSON-ul HDR10+ standard")
    w = m["win"][0]
    e = {}
    if w["tm_flag"]:
        e["BezierCurveData"] = {"Anchors": list(w["anchors"]),
                                "KneePointX": w["knee_x"], "KneePointY": w["knee_y"]}
    e["LuminanceParameters"] = {
        "AverageRGB": w["avg_maxrgb"],
        "LuminanceDistributions": {
            "DistributionIndex": [p for p, _ in w["dist"]],
            "DistributionValues": [v for _, v in w["dist"]],
        },
        "MaxScl": list(w["maxscl"]),
    }
    e["NumberOfWindows"] = 1
    e["TargetedSystemDisplayMaximumLuminance"] = m["tsdml"]
    # campuri non-standard pastrate doar daca poarta informatie (round-trip lossless)
    if w["fraction_bright"]:
        e["FractionBrightPixels"] = w["fraction_bright"]
    if w["cs_flag"]:
        e["ColorSaturationWeight"] = w["cs_weight"]
    return e


def json_entry_to_meta(e, idx):
    try:
        if e.get("NumberOfWindows", 1) != 1:
            raise ValueError("doar NumberOfWindows=1 suportat")
        lp = e["LuminanceParameters"]
        ld = lp["LuminanceDistributions"]
        idx_l, val_l = ld["DistributionIndex"], ld["DistributionValues"]
        if len(idx_l) != len(val_l):
            raise ValueError("DistributionIndex/Values au lungimi diferite")
        w = {"maxscl": list(lp["MaxScl"]), "avg_maxrgb": lp["AverageRGB"],
             "dist": list(zip(idx_l, val_l)),
             "fraction_bright": e.get("FractionBrightPixels", 0)}
        bc = e.get("BezierCurveData")
        if bc:
            w["tm_flag"] = 1
            w["knee_x"] = bc["KneePointX"]; w["knee_y"] = bc["KneePointY"]
            w["anchors"] = list(bc["Anchors"])
        else:
            w["tm_flag"] = 0
        if "ColorSaturationWeight" in e:
            w["cs_flag"] = 1; w["cs_weight"] = e["ColorSaturationWeight"]
        else:
            w["cs_flag"] = 0
        return {"num_windows": 1, "extra_windows": [],
                "tsdml": e["TargetedSystemDisplayMaximumLuminance"],
                "tsdapl_flag": 0, "mdapl_flag": 0, "win": [w]}
    except (KeyError, TypeError) as exc:
        raise ValueError(f"SceneInfo[{idx}] invalid/incomplet: {exc}") from exc


# ── MDCV / CLL (statice, bonus) ──────────────────────────────────────

def parse_master_display(s):
    """String x265 'G(x,y)B(..)R(..)WP(..)L(max,min)' -> payload MDCV 24B.
    ATENTIE: APV scrie primarele in ordinea R,G,B (validat pe oapv_app_enc)."""
    vals = {}
    for tag, x, y in re.findall(r"(G|B|R|WP|L)\((\d+),(\d+)\)", s):
        vals[tag] = (int(x), int(y))
    if set(vals) != {"G", "B", "R", "WP", "L"}:
        raise ValueError(f"master-display invalid: {s}")
    out = bytearray()
    for tag in ("R", "G", "B", "WP"):
        out += struct.pack(">HH", *vals[tag])
    out += struct.pack(">II", *vals["L"])
    return bytes(out)


def parse_max_cll(s):
    a, b = (int(x) for x in s.split(","))
    return struct.pack(">HH", a, b)


# ── strat APV: AU / PBU ──────────────────────────────────────────────

def walk_aus(data):
    """Generator: (au_offset, au_size, au_bytes) — valideaza semnatura."""
    pos = 0
    while pos + 4 <= len(data):
        au_size = struct.unpack_from(">I", data, pos)[0]
        au = data[pos + 4: pos + 4 + au_size]
        if au[:4] != APV_SIG:
            raise ValueError(f"semnatura aPv1 lipsa la offset 0x{pos:x} — nu e APV brut")
        yield pos, au_size, au
        pos += 4 + au_size


def walk_pbus(au):
    """Generator: (off_in_au, pbu_size, pbu_bytes) pentru fiecare PBU din AU."""
    p = 4
    while p + 4 <= len(au):
        pbu_size = struct.unpack_from(">I", au, p)[0]
        yield p, pbu_size, au[p + 4: p + 4 + pbu_size]
        p += 4 + pbu_size


def ff_code(val):
    out = bytearray()
    while val >= 255:
        out.append(0xFF); val -= 255
    out.append(val)
    return bytes(out)


def parse_payload_list(pbu):
    """Metadata PBU -> lista (type, bytes). pbu = header(4) + msize(4) + lista."""
    msize = struct.unpack_from(">I", pbu, 4)[0]
    plist, q, end = [], 8, min(8 + msize, len(pbu))
    while q < end:
        ptype = 0
        while pbu[q] == 0xFF: ptype += 255; q += 1
        ptype += pbu[q]; q += 1
        psize = 0
        while pbu[q] == 0xFF: psize += 255; q += 1
        psize += pbu[q]; q += 1
        plist.append((ptype, bytes(pbu[q:q + psize])))
        q += psize
    return plist


def build_metadata_pbu(group_id, payloads):
    """[(type, bytes)] -> PBU complet cu prefixul pbu_size."""
    plist = b"".join(ff_code(t) + ff_code(len(p)) + p for t, p in payloads)
    pbu = (bytes([PBU_METADATA]) + struct.pack(">H", group_id) + b"\x00"
           + struct.pack(">I", len(plist)) + plist)
    return struct.pack(">I", len(pbu)) + pbu


def is_hdr10plus(ptype, payload):
    return ptype == META_ITU_T_T35 and payload[:5] == HDR10P_PREFIX


def au_frame_group_id(au):
    for _, _, pbu in walk_pbus(au):
        if pbu[0] in (1, 2):  # PRIMARY / NON_PRIMARY frame
            return struct.unpack_from(">H", pbu, 1)[0]
    return 1


# ── comenzi ──────────────────────────────────────────────────────────

def cmd_inject(args):
    data = open(args.input, "rb").read()
    with open(args.json, "r", encoding="utf-8-sig") as f:
        scenes = json.load(f).get("SceneInfo")
    if not scenes:
        err("JSON fara SceneInfo"); return 1
    aus = list(walk_aus(data))
    if len(aus) != len(scenes):
        err(f"numar AU-uri ({len(aus)}) != frames in JSON ({len(scenes)}) — "
            "extrage JSON-ul din ACEEASI sursa din care ai encodat APV-ul")
        return 1
    static = []
    if args.max_cll:
        static.append((META_CLL, parse_max_cll(args.max_cll)))
    if args.master_display:
        static.append((META_MDCV, parse_master_display(args.master_display)))
    out = bytearray()
    for i, (_, _, au) in enumerate(aus):
        t35 = build_t35(json_entry_to_meta(scenes[i], i))
        gid = au_frame_group_id(au)
        # PBU-ul nostru de metadata trebuie INAINTEA frame-ului: decoderul ffmpeg
        # e secvential si ataseaza side data doar din metadata vazuta inainte de
        # frame (validat empiric; decoderul oficial oapvm foloseste group_id si
        # accepta ambele ordini). Analog SEI prefix la HEVC.
        pre, post, seen_frame = bytearray(), bytearray(), False
        for _, _, pbu in walk_pbus(au):
            if pbu[0] in (1, 2, 25, 26, 27):
                seen_frame = True
            if pbu[0] == PBU_METADATA:
                # curata HDR10+ vechi (idempotent) + staticele pe care le inlocuim
                kept = [(t, p) for t, p in parse_payload_list(pbu)
                        if not is_hdr10plus(t, p)
                        and not (static and t in (META_MDCV, META_CLL))]
                if kept:
                    rebuilt = build_metadata_pbu(struct.unpack_from(">H", pbu, 1)[0], kept)
                    (post if seen_frame else pre).extend(rebuilt)
            else:
                (post if seen_frame else pre).extend(struct.pack(">I", len(pbu)) + pbu)
        meta = build_metadata_pbu(gid, [(META_ITU_T_T35, t35)] + static)
        full = APV_SIG + bytes(pre) + meta + bytes(post)
        out += struct.pack(">I", len(full)) + full
    open(args.output, "wb").write(bytes(out))
    err(f"inject OK: {len(aus)} AU-uri, HDR10+ per frame"
        + (", + MDCV/CLL static" if static else ""))
    return 0


def cmd_extract(args):
    data = open(args.input, "rb").read()
    entries, n_au = [], 0
    for _, _, au in walk_aus(data):
        n_au += 1
        found = None
        for _, _, pbu in walk_pbus(au):
            if pbu[0] != PBU_METADATA:
                continue
            for t, p in parse_payload_list(pbu):
                if is_hdr10plus(t, p):
                    if found is not None:
                        err(f"AU#{n_au - 1}: mai multe payload-uri HDR10+ — il folosesc pe primul")
                    else:
                        found = p
        if found is None:
            err(f"AU#{n_au - 1} fara HDR10+ — flux incomplet, extract abandonat")
            return 1
        entries.append(meta_to_json_entry(parse_t35(found)))
    if not entries:
        err("niciun AU in fisier"); return 1
    # grupare pe scene (quietvoid-style: scena noua cand metadata difera de frame-ul anterior)
    first_idx, frame_nums = [], []
    prev = None
    for i, e in enumerate(entries):
        key = json.dumps(e, sort_keys=True)
        if key != prev:
            first_idx.append(i); frame_nums.append(0)
            prev = key
        frame_nums[-1] += 1
        e["SceneFrameIndex"] = i - first_idx[-1]
        e["SceneId"] = len(first_idx) - 1
        e["SequenceFrameIndex"] = i
    profile = "B" if any("BezierCurveData" in e for e in entries) else "A"
    doc = {"JSONInfo": {"HDR10plusProfile": profile, "Version": "1.0"},
           "SceneInfo": entries,
           "SceneInfoSummary": {"SceneFirstFrameIndex": first_idx,
                                "SceneFrameNumbers": frame_nums},
           "ToolInfo": {"Tool": "apv_hdr10plus", "Version": "1.0"}}
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(doc, f, separators=(",", ":"))
    err(f"extract OK: {len(entries)} frames, {len(first_idx)} scene -> {args.output}")
    return 0


def cmd_probe(args):
    data = open(args.input, "rb").read()
    n_au = n_hdr = n_mdcv = n_cll = 0
    for _, _, au in walk_aus(data):
        n_au += 1
        for _, _, pbu in walk_pbus(au):
            if pbu[0] != PBU_METADATA:
                continue
            for t, p in parse_payload_list(pbu):
                if is_hdr10plus(t, p):
                    n_hdr += 1
                elif t == META_MDCV:
                    n_mdcv += 1
                elif t == META_CLL:
                    n_cll += 1
    status = "hdr10plus" if n_hdr else "none"
    print(f"{status} frames={n_au} hdr10plus={n_hdr} mdcv={n_mdcv} cll={n_cll}")
    return 0


def main():
    ap = argparse.ArgumentParser(prog="apv_hdr10plus.py",
                                 description="HDR10+ (ST 2094-40) inject/extract pe APV brut")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("inject")
    p.add_argument("-i", "--input", required=True)
    p.add_argument("-j", "--json", required=True)
    p.add_argument("-o", "--output", required=True)
    p.add_argument("--master-display", help="string x265 G(..)B(..)R(..)WP(..)L(..)")
    p.add_argument("--max-cll", help="'MaxCLL,MaxFALL' ex. 1000,400")
    p = sub.add_parser("extract")
    p.add_argument("-i", "--input", required=True)
    p.add_argument("-o", "--output", required=True)
    p = sub.add_parser("probe")
    p.add_argument("-i", "--input", required=True)
    args = ap.parse_args()
    try:
        return {"inject": cmd_inject, "extract": cmd_extract, "probe": cmd_probe}[args.cmd](args)
    except (ValueError, OSError) as exc:
        err(str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
