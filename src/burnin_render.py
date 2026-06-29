#!/usr/bin/env python3
"""
burnin_render.py — Render HUD PNG sequence pentru burn-in overlay.

Citeste norm CSV (schema 18 col), preset .conf, si genereaza PNG-uri
frame_NNNNNN.png cu HUD render (gauges text + map M2 optional).
Frame index 1..N unde N = ceil(duration * fps).

Telemetry timestamps presupuse ISO 8601; interpolare liniara intre
sample-uri consecutive. Daca CSV are 1 punct (QuickTime), HUD afiseaza
acel punct static pe toata durata.

Sync offset (sec, +/-): adaugat la timpul HUD inainte de lookup CSV.
"""

import sys, os, csv, argparse, math, logging
from datetime import datetime, timezone

try:
    import matplotlib
    matplotlib.use("Agg")
    # FONT_FAMILY invalid (nume de familie negasit) → matplotlib cade pe default,
    # dar logheaza "findfont: Font family X not found" la fiecare apel. Mut warning-ul
    # ca fallback-ul sa fie TACUT (cale .ttf inexistenta e deja tacuta via os.path.isfile).
    logging.getLogger("matplotlib.font_manager").setLevel(logging.ERROR)
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle, Circle
    from matplotlib.font_manager import FontProperties
    import numpy as np
except ImportError as e:
    print(f"EROARE: dependenta lipsa ({e}). Instaleaza matplotlib + numpy + pillow.", file=sys.stderr)
    sys.exit(1)


# ── Preset loader (KEY=VALUE) ────────────────────────────────────────
def load_preset(path):
    cfg = {}
    # utf-8-sig: defensiv pe Windows cu locale non-UTF-8 default + tolerant la BOM
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg


def cfg_int(cfg, key, default):
    try:
        return int(cfg.get(key, default))
    except (ValueError, TypeError):
        return default


def cfg_float(cfg, key, default):
    try:
        return float(cfg.get(key, default))
    except (ValueError, TypeError):
        return default


def cfg_bool(cfg, key, default=False):
    v = cfg.get(key, "1" if default else "0")
    return str(v).strip() in ("1", "true", "True", "yes", "on")


# ── CSV loader cu interpolare liniara ────────────────────────────────
def parse_ts(s):
    if not s:
        return None
    s = s.strip().replace("Z", "+00:00")
    # Acceptat: "2024-03-15 12:30:45" sau "2024-03-15T12:30:45.123Z" sau epoch float
    try:
        return datetime.fromisoformat(s).timestamp()
    except ValueError:
        pass
    # exiftool format: "2024:03:15 12:30:45"
    try:
        return datetime.strptime(s[:19], "%Y:%m:%d %H:%M:%S").timestamp()
    except ValueError:
        pass
    try:
        return float(s)
    except ValueError:
        return None


def load_csv_points(csv_path):
    """
    Returneaza lista de dict-uri ordonate dupa timestamp.
    Campuri normalizate: t (float sec), lat, lon, alt_m, speed_mps, speed_kmh,
    heading_deg, gforce_x/y/z, gyro_x/y/z, temp_c, hr_bpm, cadence_rpm, power_w, brand
    """
    points = []
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            t = parse_ts(row.get("timestamp", ""))
            if t is None:
                continue
            def fnum(k):
                v = (row.get(k) or "").strip()
                try: return float(v) if v else None
                except ValueError: return None
            points.append({
                "t": t,
                "lat": fnum("lat"),
                "lon": fnum("lon"),
                "alt_m": fnum("alt_m"),
                "speed_mps": fnum("speed_mps"),
                "speed_kmh": fnum("speed_kmh"),
                "heading_deg": fnum("heading_deg"),
                "gforce_x": fnum("gforce_x"),
                "gforce_y": fnum("gforce_y"),
                "gforce_z": fnum("gforce_z"),
                "gyro_x": fnum("gyro_x"),
                "gyro_y": fnum("gyro_y"),
                "gyro_z": fnum("gyro_z"),
                "temp_c": fnum("temp_c"),
                "hr_bpm": fnum("hr_bpm"),
                "cadence_rpm": fnum("cadence_rpm"),
                "power_w": fnum("power_w"),
                "pitch_deg": fnum("pitch_deg"),
                "roll_deg": fnum("roll_deg"),
                "yaw_deg": fnum("yaw_deg"),
                "num_sats": fnum("num_sats"),
                "hdop": fnum("hdop"),
                "fix_quality": (row.get("fix_quality") or "").strip(),
                "brand": (row.get("source_brand") or "").strip(),
            })
    points.sort(key=lambda p: p["t"])
    return points


def interp(p0, p1, alpha, key):
    v0 = p0.get(key); v1 = p1.get(key)
    if v0 is None and v1 is None:
        return None
    if v0 is None:
        return v1
    if v1 is None:
        return v0
    return v0 + (v1 - v0) * alpha


def sample_at(points, t):
    """Interpolare liniara la momentul t. Returneaza dict (poate avea None-uri)."""
    if not points:
        return None
    if len(points) == 1 or t <= points[0]["t"]:
        return points[0]
    if t >= points[-1]["t"]:
        return points[-1]
    # binary search
    lo, hi = 0, len(points) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if points[mid]["t"] <= t:
            lo = mid
        else:
            hi = mid
    p0, p1 = points[lo], points[hi]
    span = p1["t"] - p0["t"]
    alpha = 0 if span <= 0 else (t - p0["t"]) / span
    out = {"t": t, "brand": p0.get("brand", ""),
           "fix_quality": (p1 if alpha >= 0.5 else p0).get("fix_quality", "")}
    for k in ("lat","lon","alt_m","speed_mps","speed_kmh","heading_deg",
              "gforce_x","gforce_y","gforce_z","gyro_x","gyro_y","gyro_z",
              "temp_c","hr_bpm","cadence_rpm","power_w",
              "pitch_deg","roll_deg","yaw_deg","num_sats","hdop"):
        out[k] = interp(p0, p1, alpha, k)
    return out


# ── Map M2 helpers ───────────────────────────────────────────────────
def project_xy(lat, lon, lat0, lon0):
    """Equirectangular projection — fine pentru zone mici (sub 100km)."""
    R = 6378137.0
    x = math.radians(lon - lon0) * R * math.cos(math.radians(lat0))
    y = math.radians(lat - lat0) * R
    return x, y


def build_route_xy(points):
    pts = [(p["lat"], p["lon"]) for p in points if p["lat"] is not None and p["lon"] is not None]
    if not pts:
        return None, None, None
    lat0 = sum(p[0] for p in pts) / len(pts)
    lon0 = sum(p[1] for p in pts) / len(pts)
    xs, ys = [], []
    for lat, lon in pts:
        x, y = project_xy(lat, lon, lat0, lon0)
        xs.append(x); ys.append(y)
    return xs, ys, (lat0, lon0)


# ── Rendering ────────────────────────────────────────────────────────
def fmt_speed(mps, kmh, unit):
    if unit == "mps":
        return f"{mps:.1f} m/s" if mps is not None else "—"
    if unit == "mph":
        return f"{(kmh or 0)*0.621371:.1f} mph" if kmh is not None else "—"
    return f"{kmh:.1f} km/h" if kmh is not None else "—"


def fmt_value(v, fmt, suffix=""):
    if v is None:
        return "—"
    try:
        return fmt.format(v) + suffix
    except Exception:
        return f"{v}{suffix}"


def fmt_time(t):
    if t is None:
        return "—"
    try:
        return datetime.fromtimestamp(t, tz=timezone.utc).strftime("%H:%M:%S")
    except Exception:
        return "—"


def anchor_to_xy(anchor, w, h, ox, oy, dx=0, dy=0):
    """Returneaza (x, y) in pixel space (origin top-left) pentru anchor tl/tr/bl/br."""
    if anchor == "tl": return ox + dx, oy + dy
    if anchor == "tr": return w - ox - dx, oy + dy
    if anchor == "bl": return ox + dx, h - oy - dy
    if anchor == "br": return w - ox - dx, h - oy - dy
    return ox + dx, oy + dy


def parse_pos(s):
    # "tl:24,24" -> ("tl", 24, 24)
    try:
        anchor, rest = s.split(":", 1)
        x, y = rest.split(",", 1)
        return anchor.strip(), int(x), int(y)
    except Exception:
        return "tl", 24, 24


def render_frame(cfg, sample, route_xy, w, h, out_path, grid=False):
    """Render un frame HUD ca PNG (transparenta). grid=True → grila de pozitionare (design-aid still preview)."""
    dpi = 100
    fig = plt.figure(figsize=(w / dpi, h / dpi), dpi=dpi)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, w); ax.set_ylim(h, 0)  # origin top-left
    ax.axis("off")
    fig.patch.set_alpha(0)

    speed_unit = cfg.get("SPEED_UNIT", "kmh").lower()
    font_large = cfg_int(cfg, "FONT_SIZE_LARGE", 24)
    font_medium = cfg_int(cfg, "FONT_SIZE_MEDIUM", 18)
    font_label = cfg_int(cfg, "FONT_SIZE_LABEL", 14)
    font_color = cfg.get("FONT_COLOR", "white")
    label_color = cfg.get("LABEL_COLOR", "#aaaaaa")
    shadow = cfg.get("SHADOW_COLOR", "black")
    shadow_off = cfg_int(cfg, "SHADOW_OFFSET", 2)

    # FONT_FAMILY optional: nume de familie matplotlib (ex. "DejaVu Sans", "monospace")
    # SAU cale catre un fisier .ttf/.otf/.ttc. Gol → default matplotlib. Fallback tacut
    # (cale inexistenta / familie negasita → matplotlib cade pe default, fara crash).
    _font_family = cfg.get("FONT_FAMILY", "").strip()
    _font_path = ""
    _font_name = ""
    if _font_family:
        if _font_family.lower().endswith((".ttf", ".otf", ".ttc")):
            if os.path.isfile(_font_family):
                _font_path = _font_family   # cale validata → FontProperties(fname=)
        else:
            _font_name = _font_family       # nume de familie → fontfamily=

    def draw_text(x, y, txt, size, color=font_color, ha="left", va="top"):
        if _font_path:
            fp = FontProperties(fname=_font_path); fp.set_size(size)
            fkw = {"fontproperties": fp}     # NU pune fontsize alaturi (conflict)
        else:
            fkw = {"fontsize": size}
            if _font_name:
                fkw["fontfamily"] = _font_name
        # Soft shadow
        ax.text(x + shadow_off, y + shadow_off, txt, color=shadow,
                ha=ha, va=va, alpha=0.7, **fkw)
        ax.text(x, y, txt, color=color, ha=ha, va=va, **fkw)

    if sample is None:
        sample = {}

    # ── Data-strip ──────────────────────────────────────────────────
    if cfg_bool(cfg, "HUD_DATA_STRIP"):
        strip_h = cfg_int(cfg, "STRIP_HEIGHT", 80)
        strip_alpha = cfg_float(cfg, "STRIP_BG_ALPHA", 0.55)
        strip_color = cfg.get("STRIP_BG_COLOR", "#000000")
        strip_pos = cfg.get("STRIP_POSITION", "bottom").lower()
        strip_y = h - strip_h if strip_pos == "bottom" else 0
        ax.add_patch(Rectangle((0, strip_y), w, strip_h, color=strip_color, alpha=strip_alpha))

        fields = [s.strip() for s in cfg.get("STRIP_FIELDS", "timestamp,speed,altitude,heading,temperature").split(",") if s.strip()]
        if fields:
            cell_w = w / len(fields)
            for i, fld in enumerate(fields):
                cx = i * cell_w + cell_w / 2
                label_y = strip_y + 16
                value_y = strip_y + strip_h - 16
                if fld == "timestamp":
                    label, value = "TIME", fmt_time(sample.get("t"))
                elif fld == "speed":
                    label, value = "SPEED", fmt_speed(sample.get("speed_mps"), sample.get("speed_kmh"), speed_unit)
                elif fld == "altitude":
                    label, value = "ALT", fmt_value(sample.get("alt_m"), "{:.1f}", " m")
                elif fld == "heading":
                    label, value = "HDG", fmt_value(sample.get("heading_deg"), "{:.0f}", "°")
                elif fld == "temperature":
                    label, value = "TEMP", fmt_value(sample.get("temp_c"), "{:.1f}", "°C")
                elif fld == "gforce":
                    gx = sample.get("gforce_x"); gy = sample.get("gforce_y"); gz = sample.get("gforce_z")
                    if gx is None and gy is None and gz is None:
                        label, value = "G", "—"
                    else:
                        gmag = math.sqrt((gx or 0)**2 + (gy or 0)**2 + (gz or 0)**2)
                        label, value = "G", f"{gmag:.2f}"
                elif fld == "satellites":
                    label, value = "SATS", fmt_value(sample.get("num_sats"), "{:.0f}", "")
                elif fld == "hdop":
                    label, value = "HDOP", fmt_value(sample.get("hdop"), "{:.1f}", "")
                elif fld == "attitude":
                    label = "P/R"
                    pit = sample.get("pitch_deg"); rol = sample.get("roll_deg")
                    if pit is None and rol is None:
                        value = "—"
                    else:
                        value = f"{(pit or 0):.0f}°/{(rol or 0):.0f}°"
                else:
                    continue
                draw_text(cx, label_y, label, font_label, color=label_color, ha="center", va="top")
                draw_text(cx, value_y, value, font_large, ha="center", va="bottom")

    # ── Corner text overlays (no strip) ─────────────────────────────
    if cfg_bool(cfg, "HUD_TIMESTAMP") and not cfg_bool(cfg, "HUD_DATA_STRIP"):
        a, ox, oy = parse_pos(cfg.get("POS_TIMESTAMP", "tl:24,24"))
        x, y = anchor_to_xy(a, w, h, ox, oy)
        ha = "right" if a in ("tr","br") else "left"
        va = "bottom" if a in ("bl","br") else "top"
        draw_text(x, y, fmt_time(sample.get("t")), font_medium, ha=ha, va=va)

    if cfg_bool(cfg, "HUD_SPEED") and not cfg_bool(cfg, "HUD_DATA_STRIP"):
        a, ox, oy = parse_pos(cfg.get("POS_SPEED", "tr:24,24"))
        x, y = anchor_to_xy(a, w, h, ox, oy)
        ha = "right" if a in ("tr","br") else "left"
        va = "bottom" if a in ("bl","br") else "top"
        draw_text(x, y, fmt_speed(sample.get("speed_mps"), sample.get("speed_kmh"), speed_unit), font_large, ha=ha, va=va)

    # Altitude / Heading / Temperature in colt — alternativa la data-strip
    # (gateate pe NOT HUD_DATA_STRIP ca timestamp/speed: aceste 3 campuri exista
    # si in STRIP_FIELDS → cu strip pornit ar fi redundante).
    if cfg_bool(cfg, "HUD_ALTITUDE") and not cfg_bool(cfg, "HUD_DATA_STRIP"):
        a, ox, oy = parse_pos(cfg.get("POS_ALTITUDE", "tl:24,80"))
        x, y = anchor_to_xy(a, w, h, ox, oy)
        ha = "right" if a in ("tr","br") else "left"
        va = "bottom" if a in ("bl","br") else "top"
        draw_text(x, y, "ALT " + fmt_value(sample.get("alt_m"), "{:.1f}", " m"), font_medium, ha=ha, va=va)

    if cfg_bool(cfg, "HUD_HEADING") and not cfg_bool(cfg, "HUD_DATA_STRIP"):
        a, ox, oy = parse_pos(cfg.get("POS_HEADING", "tl:24,116"))
        x, y = anchor_to_xy(a, w, h, ox, oy)
        ha = "right" if a in ("tr","br") else "left"
        va = "bottom" if a in ("bl","br") else "top"
        draw_text(x, y, "HDG " + fmt_value(sample.get("heading_deg"), "{:.0f}", "°"), font_medium, ha=ha, va=va)

    if cfg_bool(cfg, "HUD_TEMPERATURE") and not cfg_bool(cfg, "HUD_DATA_STRIP"):
        a, ox, oy = parse_pos(cfg.get("POS_TEMPERATURE", "tl:24,152"))
        x, y = anchor_to_xy(a, w, h, ox, oy)
        ha = "right" if a in ("tr","br") else "left"
        va = "bottom" if a in ("bl","br") else "top"
        draw_text(x, y, "TEMP " + fmt_value(sample.get("temp_c"), "{:.1f}", "°C"), font_medium, ha=ha, va=va)

    # ── Extra gauges (G-force, HR) — afisate doar daca data exista ─
    if cfg_bool(cfg, "HUD_GFORCE") and sample.get("gforce_x") is not None:
        a, ox, oy = parse_pos(cfg.get("POS_GFORCE", "tl:24,24"))
        x, y = anchor_to_xy(a, w, h, ox, oy)
        gx = sample.get("gforce_x") or 0
        gy = sample.get("gforce_y") or 0
        gz = sample.get("gforce_z") or 0
        gmag = math.sqrt(gx*gx + gy*gy + gz*gz)
        draw_text(x, y, f"G {gmag:.2f}", font_medium)

    if cfg_bool(cfg, "HUD_HR") and sample.get("hr_bpm") is not None:
        a, ox, oy = parse_pos(cfg.get("POS_HR", "tl:24,80"))
        x, y = anchor_to_xy(a, w, h, ox, oy)
        draw_text(x, y, f"HR {int(sample.get('hr_bpm'))} bpm", font_medium)

    # ── Map M2 (route + dot) ────────────────────────────────────────
    if cfg_bool(cfg, "HUD_MAP") and route_xy is not None:
        xs, ys, (lat0, lon0) = route_xy
        if xs and ys:
            map_size = cfg_int(cfg, "MAP_SIZE", 220)
            a, ox, oy = parse_pos(cfg.get("MAP_POSITION", "tr") + ":" +
                                   str(cfg_int(cfg, "MAP_OFFSET_X", 24)) + "," +
                                   str(cfg_int(cfg, "MAP_OFFSET_Y", 24)))
            # Plasament corner: calculam top-left col al box-ului
            if a == "tr":
                bx = w - ox - map_size; by = oy
            elif a == "tl":
                bx = ox; by = oy
            elif a == "br":
                bx = w - ox - map_size; by = h - oy - map_size
            else:  # bl
                bx = ox; by = h - oy - map_size

            ax.add_patch(Rectangle((bx, by), map_size, map_size,
                                   color=cfg.get("MAP_BG_COLOR", "#000000"),
                                   alpha=cfg_float(cfg, "MAP_BG_ALPHA", 0.45)))

            # Scale route into map box (padding 10px)
            pad = 10
            min_x, max_x = min(xs), max(xs)
            min_y, max_y = min(ys), max(ys)
            range_x = max(max_x - min_x, 1e-6)
            range_y = max(max_y - min_y, 1e-6)
            scale = (map_size - 2*pad) / max(range_x, range_y)
            cx = bx + map_size / 2
            cy = by + map_size / 2
            mid_x = (min_x + max_x) / 2
            mid_y = (min_y + max_y) / 2
            def map_to_px(x, y):
                px = cx + (x - mid_x) * scale
                py = cy - (y - mid_y) * scale  # y flipped (screen origin top)
                return px, py
            route_px = [map_to_px(x, y) for x, y in zip(xs, ys)]
            rx = [p[0] for p in route_px]
            ry = [p[1] for p in route_px]
            ax.plot(rx, ry,
                    color=cfg.get("MAP_ROUTE_COLOR", "#00aaff"),
                    linewidth=cfg_float(cfg, "MAP_ROUTE_WIDTH", 2))

            # Dot la pozitia curenta
            if sample.get("lat") is not None and sample.get("lon") is not None:
                px, py = project_xy(sample["lat"], sample["lon"], lat0, lon0)
                dx, dy = map_to_px(px, py)
                ax.add_patch(Circle((dx, dy),
                                    cfg_float(cfg, "MAP_DOT_SIZE", 8),
                                    color=cfg.get("MAP_DOT_COLOR", "#ff3333")))

    # ── Positioning grid (design-aid pt still preview; --grid) ──────
    if grid:
        gc = "#00ff88"
        for fx in (0.25, 0.5, 0.75):
            ax.plot([w * fx, w * fx], [0, h], color=gc, linewidth=1, alpha=0.35)
            ax.plot([0, w], [h * fx, h * fx], color=gc, linewidth=1, alpha=0.35)
            ax.text(w * fx + 4, 16, str(int(w * fx)), color=gc, fontsize=font_label, alpha=0.85, ha="left", va="top")
            ax.text(4, h * fx + 4, str(int(h * fx)), color=gc, fontsize=font_label, alpha=0.85, ha="left", va="top")
        for lbl, lx, ly, lha, lva in (("tl", 8, 8, "left", "top"), ("tr", w - 8, 8, "right", "top"),
                                      ("bl", 8, h - 8, "left", "bottom"), ("br", w - 8, h - 8, "right", "bottom")):
            ax.text(lx, ly, lbl, color=gc, fontsize=font_label, alpha=0.9, ha=lha, va=lva)

    fig.savefig(out_path, dpi=dpi, transparent=True)
    plt.close(fig)


# ── Main ─────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--preset", required=True)
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--fps", type=float, default=10)
    ap.add_argument("--duration", type=float, required=True)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--offset", type=float, default=0)
    ap.add_argument("--brand", default="")
    ap.add_argument("--single", type=float, default=None,
                    help="Randeaza UN singur cadru la timpul video t (sec) — still layout preview")
    ap.add_argument("--grid", action="store_true",
                    help="Grila de pozitionare peste HUD (design-aid pt still preview)")
    args = ap.parse_args()

    if not os.path.isfile(args.csv):
        print(f"EROARE: CSV inexistent: {args.csv}", file=sys.stderr); sys.exit(2)
    if not os.path.isfile(args.preset):
        print(f"EROARE: preset inexistent: {args.preset}", file=sys.stderr); sys.exit(2)
    if args.duration <= 0:
        print("EROARE: durata invalida (<=0)", file=sys.stderr); sys.exit(2)
    os.makedirs(args.output_dir, exist_ok=True)

    cfg = load_preset(args.preset)
    points = load_csv_points(args.csv)
    if not points:
        print("EROARE: CSV nu contine puncte cu timestamp valid", file=sys.stderr); sys.exit(3)

    # Reset timpi la 0 = primul sample (pt CSV cu epoch absolut)
    t0_csv = points[0]["t"]
    for p in points:
        p["t"] = p["t"] - t0_csv

    route_xy = build_route_xy(points) if cfg_bool(cfg, "HUD_MAP") else None

    # Still layout preview: UN singur cadru la timpul video --single (fara secventa)
    if args.single is not None:
        t_csv = args.single + args.offset
        s = sample_at(points, t_csv)
        out = os.path.join(args.output_dir, "frame_000001.png")
        render_frame(cfg, s, route_xy, args.width, args.height, out, grid=args.grid)
        print(f"[render] still frame @ t={args.single}s -> {out}")
        return 0

    total_frames = max(1, int(math.ceil(args.duration * args.fps)))
    print(f"[render] {total_frames} frames @ {args.fps} fps, {args.width}x{args.height}, preset={cfg.get('PRESET_NAME','?')}, offset={args.offset}s")

    for i in range(total_frames):
        t_video = i / args.fps
        t_csv = t_video + args.offset  # offset >0 = avansam in CSV
        s = sample_at(points, t_csv)
        out = os.path.join(args.output_dir, f"frame_{i+1:06d}.png")
        render_frame(cfg, s, route_xy, args.width, args.height, out)
        if (i + 1) % max(1, total_frames // 20) == 0:
            pct = (i + 1) * 100 / total_frames
            print(f"  [{i+1}/{total_frames}] {pct:.0f}%", flush=True)

    print(f"[render] done — {total_frames} frames in {args.output_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
