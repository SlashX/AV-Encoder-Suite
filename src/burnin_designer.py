#!/usr/bin/env python3
"""
burnin_designer.py — Designer vizual de layout HUD pentru burn-in (browser local).

Server HTTP local (127.0.0.1, stdlib http.server) + UI single-page
(burnin_designer.html, servit de pe disc). Randarea overlay-ului foloseste
EXACT engine-ul de productie (burnin_render.render_frame) → preview 100% fidel
cu encode-ul final (WYSIWYG onest).

Fluxul: wrapper-ul (av_burnin.sh / av_burnin.ps1) alege video [+ CSV norm] →
lanseaza serverul → deschide browserul → userul trage elementele HUD cu mouse-ul,
ajusteaza stil/culori/campuri → salveaza preset .conf in UserProfiles/burnin/ →
preset-ul apare in meniul HUD la urmatorul burn-in.

Fara CSV → date DEMO sintetice (traseu circular + valori plauzibile) ca layoutul
sa poata fi proiectat inainte de extragerea telemetriei.

API:
  GET  /                    → UI (burnin_designer.html)
  GET  /api/state           → info video/telemetrie/preseturi + cfg initial
  GET  /frame?t=<sec>       → cadrul video la t (PNG; tonemap pe HDR, ca still-preview v82)
  GET  /api/preset?name=<n> → cfg-ul unui preset (user dir are prioritate)
  POST /api/overlay         → {cfg,t,grid} → PNG overlay (base64) + hitbox-uri drag
  POST /api/save            → {name,cfg} → scrie <user-presets-dir>/<name>.conf
  POST /api/shutdown        → opreste serverul

Doar stdlib + matplotlib (deja cerut de fluxul HUD). Ruleaza pe Windows, Linux,
macOS si Termux (browser → localhost).
"""

import sys, os, json, math, base64, argparse, subprocess, threading
import re, time, shutil, tempfile, webbrowser
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# stdout redirectat pe Windows = cp1252 strict → un path cu diacritice sau un
# caracter non-cp1252 in print ar crapa serverul. UTF-8 + replace = imun.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import burnin_render as br   # engine partajat — render REAL (matplotlib validat acolo)

HTML_FILE = os.path.join(SCRIPT_DIR, "burnin_designer.html")

# ── Inventarul cheilor gestionate (whitelist la save) ─────────────────
# Ordinea = ordinea de scriere in .conf (grupat ca preseturile built-in).
CONF_KEYS = [
    # HUD components
    "HUD_TIMESTAMP", "HUD_SPEED", "HUD_ALTITUDE", "HUD_HEADING",
    "HUD_TEMPERATURE", "HUD_GFORCE", "HUD_HR", "HUD_MAP", "HUD_DATA_STRIP",
    # Corner positions
    "POS_TIMESTAMP", "POS_SPEED", "POS_ALTITUDE", "POS_HEADING",
    "POS_TEMPERATURE", "POS_GFORCE", "POS_HR",
    # Strip
    "STRIP_HEIGHT", "STRIP_BG_COLOR", "STRIP_BG_ALPHA", "STRIP_POSITION", "STRIP_FIELDS",
    # Map M2
    "MAP_SIZE", "MAP_POSITION", "MAP_OFFSET_X", "MAP_OFFSET_Y",
    "MAP_BG_COLOR", "MAP_BG_ALPHA", "MAP_ROUTE_COLOR", "MAP_ROUTE_WIDTH",
    "MAP_DOT_COLOR", "MAP_DOT_SIZE",
    # Style
    "FONT_SIZE_LARGE", "FONT_SIZE_MEDIUM", "FONT_SIZE_LABEL",
    "FONT_COLOR", "LABEL_COLOR", "SHADOW_COLOR", "SHADOW_OFFSET", "FONT_FAMILY",
    "SPEED_UNIT",
]

# Default-urile EFECTIVE din render_frame (UI are nevoie de valori concrete
# pentru toate controalele; un preset le suprascrie).
CONF_DEFAULTS = {
    "HUD_TIMESTAMP": "0", "HUD_SPEED": "0", "HUD_ALTITUDE": "0", "HUD_HEADING": "0",
    "HUD_TEMPERATURE": "0", "HUD_GFORCE": "0", "HUD_HR": "0", "HUD_MAP": "0",
    "HUD_DATA_STRIP": "0",
    "POS_TIMESTAMP": "tl:24,24", "POS_SPEED": "tr:24,24",
    "POS_ALTITUDE": "tl:24,80", "POS_HEADING": "tl:24,116", "POS_TEMPERATURE": "tl:24,152",
    "POS_GFORCE": "tl:24,24", "POS_HR": "tl:24,80",
    "STRIP_HEIGHT": "80", "STRIP_BG_COLOR": "#000000", "STRIP_BG_ALPHA": "0.55",
    "STRIP_POSITION": "bottom",
    "STRIP_FIELDS": "timestamp,speed,altitude,heading,temperature",
    "MAP_SIZE": "220", "MAP_POSITION": "tr", "MAP_OFFSET_X": "24", "MAP_OFFSET_Y": "24",
    "MAP_BG_COLOR": "#000000", "MAP_BG_ALPHA": "0.45",
    "MAP_ROUTE_COLOR": "#00aaff", "MAP_ROUTE_WIDTH": "2",
    "MAP_DOT_COLOR": "#ff3333", "MAP_DOT_SIZE": "8",
    "FONT_SIZE_LARGE": "24", "FONT_SIZE_MEDIUM": "18", "FONT_SIZE_LABEL": "14",
    "FONT_COLOR": "white", "LABEL_COLOR": "#aaaaaa",
    "SHADOW_COLOR": "black", "SHADOW_OFFSET": "2", "FONT_FAMILY": "",
    "SPEED_UNIT": "kmh",
}

BUILTIN_PRESETS = ["minimal", "data-strip", "full"]

RENDER_LOCK = threading.Lock()   # matplotlib Agg + cache-ul de cadre, serializate


# ── Probe video (ffprobe JSON — imun la trailing-comma/CRLF) ──────────
def probe_video(path):
    # NB: UN singur -show_entries cu sectiuni separate prin ':' — doua optiuni
    # -show_entries se suprascriu (ultima castiga → width/height ar fi pierdute).
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height,color_transfer:format=duration",
         "-of", "json", path],
        capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"ffprobe a esuat pe {path}: {out.stderr.strip()[:200]}")
    data = json.loads(out.stdout or "{}")
    streams = data.get("streams") or [{}]
    st = streams[0]
    w = int(st.get("width") or 1920)
    h = int(st.get("height") or 1080)
    trc = (st.get("color_transfer") or "").strip()
    try:
        dur = float((data.get("format") or {}).get("duration") or 0)
    except (TypeError, ValueError):
        dur = 0.0
    return w, h, dur, trc


# ── Date DEMO sintetice (mod fara CSV) ────────────────────────────────
def synth_points(duration):
    """Traseu circular + valori plauzibile — schema identica cu load_csv_points."""
    dur = max(duration, 10.0)
    n = max(60, int(dur))          # ~1 Hz, minim 60 puncte
    pts = []
    for i in range(n + 1):
        frac = i / n
        t = frac * dur
        ang = frac * 2 * math.pi
        pts.append({
            "t": t,
            "lat": 44.4300 + 0.0040 * math.sin(ang),
            "lon": 26.1000 + 0.0060 * math.cos(ang),
            "alt_m": 96.0 + 28.0 * math.sin(ang * 1.5),
            "speed_mps": (38.0 + 21.0 * math.sin(ang * 2)) / 3.6,
            "speed_kmh": 38.0 + 21.0 * math.sin(ang * 2),
            "heading_deg": (frac * 360.0) % 360.0,
            "gforce_x": 0.10 * math.sin(ang * 3),
            "gforce_y": 0.15 * math.cos(ang * 2),
            "gforce_z": 1.0 + 0.20 * math.sin(ang * 5),
            "gyro_x": 0.0, "gyro_y": 0.0, "gyro_z": 0.0,
            "temp_c": 22.0 + 2.5 * math.sin(ang),
            "hr_bpm": 122.0 + 18.0 * math.sin(ang * 1.2),
            "cadence_rpm": 84.0, "power_w": 210.0,
            "pitch_deg": 2.0 * math.sin(ang), "roll_deg": 4.0 * math.sin(ang * 2),
            "yaw_deg": (frac * 360.0) % 360.0,
            "num_sats": 12.0, "hdop": 0.8,
            "fix_quality": "3d", "brand": "demo",
        })
    return pts


# ── Estimare hitbox-uri pentru drag (aceleasi stringuri ca render_frame) ──
def _text_box(x, y, txt, size, ha, va):
    est_w = max(12, int(len(txt) * size * 0.62))
    est_h = int(size * 1.55)
    bx = x - est_w if ha == "right" else x
    by = y - est_h if va == "bottom" else y
    return bx, by, est_w, est_h


def compute_boxes(cfg, sample, route_xy, w, h):
    """Hitbox-uri aproximative pt elementele DESENATE (drag handles in UI)."""
    if sample is None:
        sample = {}
    boxes = []
    strip_on = br.cfg_bool(cfg, "HUD_DATA_STRIP")
    speed_unit = cfg.get("SPEED_UNIT", "kmh").lower()
    f_l = br.cfg_int(cfg, "FONT_SIZE_LARGE", 24)
    f_m = br.cfg_int(cfg, "FONT_SIZE_MEDIUM", 18)

    def corner_text(el_id, pos_key, pos_def, txt, size):
        a, ox, oy = br.parse_pos(cfg.get(pos_key, pos_def))
        x, y = br.anchor_to_xy(a, w, h, ox, oy)
        ha = "right" if a in ("tr", "br") else "left"
        va = "bottom" if a in ("bl", "br") else "top"
        bx, by, bw, bh = _text_box(x, y, txt, size, ha, va)
        boxes.append({"id": el_id, "kind": "pos", "key": pos_key,
                      "anchor": a, "x": bx, "y": by, "w": bw, "h": bh})

    if strip_on:
        strip_h = br.cfg_int(cfg, "STRIP_HEIGHT", 80)
        strip_pos = cfg.get("STRIP_POSITION", "bottom").lower()
        sy = h - strip_h if strip_pos == "bottom" else 0
        boxes.append({"id": "strip", "kind": "strip", "key": "STRIP_POSITION",
                      "anchor": strip_pos, "x": 0, "y": sy, "w": w, "h": strip_h})
    else:
        if br.cfg_bool(cfg, "HUD_TIMESTAMP"):
            corner_text("timestamp", "POS_TIMESTAMP", "tl:24,24",
                        br.fmt_time(sample.get("t")), f_m)
        if br.cfg_bool(cfg, "HUD_SPEED"):
            corner_text("speed", "POS_SPEED", "tr:24,24",
                        br.fmt_speed(sample.get("speed_mps"), sample.get("speed_kmh"), speed_unit), f_l)
        if br.cfg_bool(cfg, "HUD_ALTITUDE"):
            corner_text("altitude", "POS_ALTITUDE", "tl:24,80",
                        "ALT " + br.fmt_value(sample.get("alt_m"), "{:.1f}", " m"), f_m)
        if br.cfg_bool(cfg, "HUD_HEADING"):
            corner_text("heading", "POS_HEADING", "tl:24,116",
                        "HDG " + br.fmt_value(sample.get("heading_deg"), "{:.0f}", "°"), f_m)
        if br.cfg_bool(cfg, "HUD_TEMPERATURE"):
            corner_text("temperature", "POS_TEMPERATURE", "tl:24,152",
                        "TEMP " + br.fmt_value(sample.get("temp_c"), "{:.1f}", "°C"), f_m)

    # G-force / HR — gateate DOAR pe existenta datelor (ca render_frame)
    if br.cfg_bool(cfg, "HUD_GFORCE") and sample.get("gforce_x") is not None:
        gx = sample.get("gforce_x") or 0; gy = sample.get("gforce_y") or 0
        gz = sample.get("gforce_z") or 0
        gmag = math.sqrt(gx * gx + gy * gy + gz * gz)
        corner_text("gforce", "POS_GFORCE", "tl:24,24", f"G {gmag:.2f}", f_m)
    if br.cfg_bool(cfg, "HUD_HR") and sample.get("hr_bpm") is not None:
        corner_text("hr", "POS_HR", "tl:24,80",
                    f"HR {int(sample.get('hr_bpm'))} bpm", f_m)

    # Map M2 — box exact (aceeasi geometrie ca render_frame)
    if br.cfg_bool(cfg, "HUD_MAP") and route_xy is not None:
        ms = br.cfg_int(cfg, "MAP_SIZE", 220)
        a = cfg.get("MAP_POSITION", "tr").strip().lower()
        ox = br.cfg_int(cfg, "MAP_OFFSET_X", 24)
        oy = br.cfg_int(cfg, "MAP_OFFSET_Y", 24)
        if a == "tr":   bx, by = w - ox - ms, oy
        elif a == "tl": bx, by = ox, oy
        elif a == "br": bx, by = w - ox - ms, h - oy - ms
        else:           bx, by = ox, h - oy - ms
        boxes.append({"id": "map", "kind": "map", "key": "MAP_POSITION",
                      "anchor": a, "x": bx, "y": by, "w": ms, "h": ms})
    return boxes


# ── Starea designerului ───────────────────────────────────────────────
class Designer:
    def __init__(self, args):
        self.video = os.path.abspath(args.video)
        self.presets_dir = args.presets_dir
        self.user_dir = args.user_presets_dir
        self.w, self.h, self.duration, trc = probe_video(self.video)
        # Tonemap de DISPLAY pe HDR (doar preview — ca still-ul v82); env-ul
        # BURNIN_STILL_NO_TONEMAP e onorat pentru consistenta cu still-preview.
        self.is_hdr = trc in ("smpte2084", "arib-std-b67")
        self.tonemap = self.is_hdr and os.environ.get("BURNIN_STILL_NO_TONEMAP", "0") != "1"
        if args.csv:
            self.points = br.load_csv_points(args.csv)
            if not self.points:
                raise RuntimeError(f"CSV fara puncte cu timestamp valid: {args.csv}")
            t0 = self.points[0]["t"]
            for p in self.points:
                p["t"] = p["t"] - t0
            self.telem_mode = "real"
        else:
            self.points = synth_points(self.duration)
            self.telem_mode = "demo"
        self.brand = self.points[0].get("brand", "")
        rx = br.build_route_xy(self.points)
        # build_route_xy → (None,None,None) pe CSV fara GPS; render_frame face
        # unpack nested pe al 3-lea element → normalizam la None (map se sare curat).
        self.route_xy = rx if rx and rx[0] else None
        base = args.temp_dir if (args.temp_dir and os.path.isdir(args.temp_dir)) else None
        self.tmpdir = tempfile.mkdtemp(prefix="burnin_designer_", dir=base)
        self.frame_cache = {}        # bytes PNG per t; FIFO cap (vezi mai jos)
        self.frame_cache_order = []  # ordinea cheilor pt evictie

    # cadru video la t (PNG, cache; tonemap pe HDR — DOAR pentru display).
    # PNG (RGB), NU JPEG: lantul tonemap iese limited-range (r=tv, ca v82) iar
    # encoderul mjpeg REFUZA non-full-range pe ffmpeg-ul curent ("Non full-range
    # YUV is non-standard") — prins REAL pe HDR10+ la E2E; PNG e imun la range.
    FRAME_CACHE_MAX = 24   # ~24 cadre in RAM (scrub lung pe 4K altfel creste nelimitat)

    def get_frame(self, t):
        t = max(0.0, min(t, max(self.duration - 0.05, 0.0)))
        key = round(t, 1)
        with RENDER_LOCK:
            if key in self.frame_cache:
                return self.frame_cache[key]
            # UN singur fisier temp reutilizat (suntem sub lock) — fara
            # acumulare pe disc la scrub; cache-ul de bytes are FIFO cap.
            out = os.path.join(self.tmpdir, "frame_cur.png")
            # Scara de retry: pe VFR durata de CONTAINER poate depasi ultimul
            # cadru real (ex. 403 cadre @ ~59.76 = 6.74s, container 6.89s) →
            # seek in zona moarta = 0 cadre, rc=0. Cadem gratios inapoi.
            last_err = ""
            for att in (t, max(0.0, t - 0.5), 0.0):
                cmd = ["ffmpeg", "-v", "error", "-ss", f"{att:.3f}", "-i", self.video,
                       "-frames:v", "1"]
                if self.tonemap:
                    cmd += ["-vf", "zscale=t=linear:npl=100,tonemap=tonemap=hable,"
                                   "zscale=t=bt709:m=bt709:p=bt709:r=tv,format=yuv420p"]
                cmd += ["-f", "image2", out, "-y"]
                r = subprocess.run(cmd, capture_output=True, text=True)
                if r.returncode == 0 and os.path.isfile(out) and os.path.getsize(out) > 0:
                    with open(out, "rb") as f:
                        data = f.read()
                    self.frame_cache[key] = data
                    self.frame_cache_order.append(key)
                    while len(self.frame_cache_order) > self.FRAME_CACHE_MAX:
                        old = self.frame_cache_order.pop(0)
                        self.frame_cache.pop(old, None)
                    return data
                last_err = r.stderr.strip()[:200]
                if att == 0.0:
                    break
            raise RuntimeError(f"extragere cadru esuata la t={t:.2f}s: {last_err}")

    # overlay HUD REAL la t (engine de productie) + hitbox-uri
    def render_overlay(self, cfg, t, grid):
        cfg = {str(k): str(v) for k, v in cfg.items()}
        sample = br.sample_at(self.points, t)
        with RENDER_LOCK:
            out = os.path.join(self.tmpdir, "overlay.png")
            br.render_frame(cfg, sample, self.route_xy, self.w, self.h, out, grid=grid)
            with open(out, "rb") as f:
                png = f.read()
        boxes = compute_boxes(cfg, sample, self.route_xy, self.w, self.h)
        return png, boxes

    def preset_path(self, name):
        """user dir are prioritate (override), apoi built-in."""
        for d in (self.user_dir, self.presets_dir):
            p = os.path.join(d, name + ".conf")
            if os.path.isfile(p):
                return p
        return None

    def list_user_presets(self):
        if not os.path.isdir(self.user_dir):
            return []
        return sorted(os.path.splitext(f)[0] for f in os.listdir(self.user_dir)
                      if f.endswith(".conf"))

    def load_preset_cfg(self, name):
        p = self.preset_path(name)
        if not p:
            return None
        cfg = dict(CONF_DEFAULTS)
        cfg.update({k: v for k, v in br.load_preset(p).items() if k in CONF_KEYS})
        return cfg

    def save_preset(self, name, cfg):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", name):
            raise ValueError("nume invalid (permis: litere/cifre/._- , max 64)")
        os.makedirs(self.user_dir, exist_ok=True)
        path = os.path.join(self.user_dir, name + ".conf")
        cfg = {str(k): str(v) for k, v in cfg.items()}
        lines = [f"# Burn-in HUD layout preset: {name}",
                 "# Generat cu Burn-in Designer (browser)",
                 "", f"PRESET_NAME={name}", ""]
        for k in CONF_KEYS:
            if k in cfg:
                # sanitizare: fara newline (ar injecta linii straine in .conf)
                v = cfg[k].replace("\r", " ").replace("\n", " ").strip()[:200]
                if k == "FONT_FAMILY" and not v:
                    continue          # gol = default; nu-l scriem
                lines.append(f"{k}={v}")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        return path

    def state_json(self):
        return {
            "video": {"name": os.path.basename(self.video), "width": self.w,
                      "height": self.h, "duration": round(self.duration, 3),
                      "hdr": self.is_hdr, "tonemap": self.tonemap},
            "telemetry": {"mode": self.telem_mode, "points": len(self.points),
                          "brand": self.brand, "has_route": self.route_xy is not None},
            "presets": {"builtin": [n for n in BUILTIN_PRESETS if self.preset_path(n)],
                        "user": self.list_user_presets()},
            "user_dir": self.user_dir,
            "cfg": self.load_preset_cfg("full") or dict(CONF_DEFAULTS),
        }

    def cleanup(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)


# ── HTTP handler ──────────────────────────────────────────────────────
def make_handler(designer, server_ref):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *a):   # linistit — terminalul ramane curat
            pass

        def _send(self, code, ctype, body):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()

        def _json(self, obj, code=200):
            self._send(code, "application/json; charset=utf-8",
                       json.dumps(obj).encode("utf-8"))

        def _read_body(self):
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n > 0 else b"{}"
            return json.loads(raw.decode("utf-8"))

        def do_GET(self):
            try:
                u = urlparse(self.path)
                if u.path == "/":
                    if not os.path.isfile(HTML_FILE):
                        self._send(500, "text/plain; charset=utf-8",
                                   "burnin_designer.html lipseste langa engine".encode("utf-8"))
                        return
                    with open(HTML_FILE, "rb") as f:
                        self._send(200, "text/html; charset=utf-8", f.read())
                elif u.path == "/api/state":
                    self._json(designer.state_json())
                elif u.path == "/frame":
                    q = parse_qs(u.query)
                    t = float((q.get("t") or ["0"])[0])
                    self._send(200, "image/png", designer.get_frame(t))
                elif u.path == "/api/preset":
                    q = parse_qs(u.query)
                    name = (q.get("name") or [""])[0]
                    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", name):
                        self._json({"error": "nume invalid"}, 400); return
                    cfg = designer.load_preset_cfg(name)
                    if cfg is None:
                        self._json({"error": f"preset inexistent: {name}"}, 404)
                    else:
                        self._json({"name": name, "cfg": cfg})
                else:
                    self._send(404, "text/plain; charset=utf-8", b"404")
            except Exception as e:
                try:
                    self._json({"error": str(e)}, 500)
                except Exception:
                    pass

        def do_POST(self):
            try:
                u = urlparse(self.path)
                if u.path == "/api/overlay":
                    body = self._read_body()
                    t = float(body.get("t") or 0)
                    grid = bool(body.get("grid"))
                    png, boxes = designer.render_overlay(body.get("cfg") or {}, t, grid)
                    self._json({"png": base64.b64encode(png).decode("ascii"),
                                "boxes": boxes, "t": t})
                elif u.path == "/api/save":
                    body = self._read_body()
                    path = designer.save_preset(str(body.get("name") or ""),
                                                body.get("cfg") or {})
                    print(f"[designer] Preset salvat: {path}", flush=True)
                    self._json({"ok": True, "path": path,
                                "name": os.path.splitext(os.path.basename(path))[0]})
                elif u.path == "/api/shutdown":
                    # 1) DRENEAZA body-ul cererii — close cu date inbound
                    #    necitite trimite TCP RST → clientul pierde si
                    #    raspunsul (prins REAL la teste: ConnectionReset).
                    # 2) flush in _send + close explicit + shutdown INTARZIAT
                    #    (handler daemon → fara delay, exit-ul procesului
                    #    poate ucide write-ul mid-flight).
                    self._read_body()
                    self._json({"ok": True})
                    self.close_connection = True
                    def _delayed_shutdown():
                        time.sleep(0.3)
                        server_ref["srv"].shutdown()
                    threading.Thread(target=_delayed_shutdown, daemon=True).start()
                else:
                    self._send(404, "text/plain; charset=utf-8", b"404")
            except ValueError as e:
                self._json({"error": str(e)}, 400)
            except Exception as e:
                try:
                    self._json({"error": str(e)}, 500)
                except Exception:
                    pass
    return Handler


# ── Main ──────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", required=True)
    ap.add_argument("--csv", default="")
    ap.add_argument("--presets-dir", default=os.path.join(SCRIPT_DIR, "burnin_presets"))
    ap.add_argument("--user-presets-dir", required=True)
    ap.add_argument("--temp-dir", default="")
    ap.add_argument("--port", type=int, default=0,
                    help="0 = port efemer (implicit)")
    ap.add_argument("--open-cmd", default="",
                    help="comanda de deschis URL-ul (ex. termux-open-url); gol = webbrowser")
    ap.add_argument("--no-open", action="store_true",
                    help="nu deschide browserul (doar afiseaza URL-ul)")
    args = ap.parse_args()

    if not os.path.isfile(args.video):
        print(f"EROARE: video inexistent: {args.video}", file=sys.stderr); return 2
    if args.csv and not os.path.isfile(args.csv):
        print(f"EROARE: CSV inexistent: {args.csv}", file=sys.stderr); return 2
    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            print(f"EROARE: {tool} nu este in PATH.", file=sys.stderr); return 2

    try:
        d = Designer(args)
    except Exception as e:
        print(f"EROARE: {e}", file=sys.stderr); return 2

    server_ref = {}
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(d, server_ref))
    except OSError as e:
        print(f"EROARE: nu pot porni serverul pe portul {args.port} ({e}). "
              f"Incearca alt --port sau lasa 0 (efemer).", file=sys.stderr)
        d.cleanup()
        return 2
    server_ref["srv"] = srv
    srv.daemon_threads = True
    url = f"http://127.0.0.1:{srv.server_address[1]}/"

    hdr_note = "  [HDR -> tonemap doar pe preview]" if d.tonemap else \
               ("  [HDR raw - BURNIN_STILL_NO_TONEMAP=1]" if d.is_hdr else "")
    telem_note = (f"reala ({len(d.points)} puncte, brand {d.brand})"
                  if d.telem_mode == "real" else "DEMO (sintetica, doar pentru layout)")
    print(f"[designer] Video: {os.path.basename(d.video)} "
          f"({d.w}x{d.h}, {d.duration:.1f}s){hdr_note}")
    print(f"[designer] Telemetrie: {telem_note}")
    print(f"[designer] Preseturi user: {d.user_dir}")
    print(f"[designer] URL: {url}")
    print("[designer] Inchide din browser (Salveaza & Inchide) sau Ctrl+C aici.", flush=True)

    if not args.no_open:
        try:
            if args.open_cmd:
                subprocess.Popen([args.open_cmd, url],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            else:
                webbrowser.open(url)
        except Exception:
            pass   # URL-ul e afisat — userul il deschide manual

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
        d.cleanup()
    print("[designer] Server oprit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
