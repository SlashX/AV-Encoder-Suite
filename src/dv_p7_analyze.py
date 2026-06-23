#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v76 — Clasificator strat de imbunatatire (EL) pentru Dolby Vision Profile 7.
Engine partajat bash<->PS1, stdlib-only (ca av1_dv_t35_repair.py / apv_hdr10plus.py /
dji_djmd_dlogm.py / burnin_render.py).

Decide daca aruncarea EL-ului la o conversie P7->8.1 (dovi_tool -m 2 convert --discard)
este SIGURA sau pierde informatie vizibila (highlight-uri din FEL).

Input:
  argv[1] = JSON-ul produs de `dovi_tool export -i <rpu> -d all=<json>`
  argv[2] = peak-ul base-layer in niti (MaxCLL real al BL, citit din container de apelant;
            optional, default 1000)

Verdicte (stdout, exit 0 — soft-fail):
  MEL          -> Minimal Enhancement Layer: EL gol functional -> discard LOSSLESS.
  FEL_SAFE     -> Full EL dar fara expansiune de luminozitate peste BL (+marja) -> discard sigur.
  FEL_COMPLEX  -> Full EL CU expansiune de luminozitate: discard-ul pierde highlight-uri
                  -> tone-mapping gresit. Apelantul refuza by default (escape: force).
  UNKNOWN      -> analiza imposibila (JSON lipsa/corupt / fara L1) -> apelantul trateaza
                  conservator (ca FEL_COMPLEX).

Linia de output: "<VERDICT> l1_nits=<n> bl_peak=<n> thr=<n>" (campurile numerice = transparenta).

Euristica e portata conceptual din proiectul community `cryptochrome/dovi_convert`
(comparatie L1 max reconstruit vs peak-ul base-layer), nu codul lui.
"""
import sys
import json

MARGIN_NITS = 50.0          # marja peste BL peak sub care FEL e considerat sigur de aruncat
DEFAULT_BL_PEAK = 1000.0    # fallback cand apelantul nu trimite MaxCLL


def pq_to_nits(code12):
    """SMPTE ST.2084 EOTF. code12 = valoare PQ pe 12 biti (0..4095) -> niti (cd/m^2)."""
    e = code12 / 4095.0
    m1 = 2610.0 / 16384.0
    m2 = 2523.0 / 32.0
    c1 = 3424.0 / 4096.0
    c2 = 2413.0 / 128.0
    c3 = 2392.0 / 128.0
    p = e ** (1.0 / m2)
    num = p - c1
    if num < 0.0:
        num = 0.0
    den = c2 - c3 * p
    if den <= 0.0:
        return 0.0
    return 10000.0 * (num / den) ** (1.0 / m1)


def collect_l1_max(obj, out):
    """Cauta recursiv toate blocurile Level1 si aduna campul max_pq (toleranta la nesting)."""
    if isinstance(obj, dict):
        l1 = obj.get("Level1")
        if isinstance(l1, dict):
            for key in ("max_pq", "max", "Max"):
                val = l1.get(key)
                if isinstance(val, (int, float)):
                    out.append(int(val))
                    break
        for v in obj.values():
            collect_l1_max(v, out)
    elif isinstance(obj, list):
        for v in obj:
            collect_l1_max(v, out)


def classify(json_path, bl_peak):
    try:
        with open(json_path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
        data = json.loads(raw)
    except Exception:
        return ("UNKNOWN", 0.0, bl_peak)

    # MEL: substring brut pe JSON-ul compact (robust la nivelul de nesting al RPU header-ului).
    # Identic ca abordare cu dovi_convert; el_type apare in fiecare frame.
    if '"el_type":"MEL"' in raw.replace(" ", ""):
        return ("MEL", 0.0, bl_peak)

    maxs = []
    collect_l1_max(data, maxs)
    if not maxs:
        return ("UNKNOWN", 0.0, bl_peak)

    l1_nits = pq_to_nits(max(maxs))
    threshold = bl_peak + MARGIN_NITS
    verdict = "FEL_COMPLEX" if l1_nits > threshold else "FEL_SAFE"
    return (verdict, l1_nits, bl_peak)


def main(argv):
    if len(argv) < 2:
        print("UNKNOWN l1_nits=0 bl_peak=0 thr=0")
        return 0
    json_path = argv[1]
    bl_peak = DEFAULT_BL_PEAK
    if len(argv) > 2 and argv[2]:
        try:
            bl_peak = float(argv[2])
        except ValueError:
            bl_peak = DEFAULT_BL_PEAK
    if bl_peak <= 0.0:
        bl_peak = DEFAULT_BL_PEAK

    verdict, l1_nits, bl = classify(json_path, bl_peak)
    print("%s l1_nits=%d bl_peak=%d thr=%d" % (
        verdict, int(round(l1_nits)), int(round(bl)), int(round(bl + MARGIN_NITS))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
