#!/usr/bin/env bash
# v84 — Burn-in Designer (Tier 2): server HTTP local (burnin_designer.py, stdlib)
#   + UI browser (burnin_designer.html) + integrare av_burnin (flow 5 „Designer
#   vizual" + optiunea „custom" in meniul LAYOUT PRESET, preseturi in
#   UserProfiles/burnin/). Randare cu engine-ul REAL (burnin_render) → WYSIWYG.
#   Source-level (engine/UI/wrappere + paritate bash↔PS1) + functional headless
#   (server pornit pe video testsrc → state/frame/overlay/save/shutdown).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

# self-resolve ffmpeg din src/ standalone (ca v55/v62)
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

tmpd="$(mktemp -d)"
SRV_PID=""
trap '[ -n "$SRV_PID" ] && kill -9 "$SRV_PID" 2>/dev/null; rm -rf "$tmpd"; _test_summary' EXIT

ENGINE="$SCRIPT_DIR/burnin_designer.py"
UIHTML="$SCRIPT_DIR/burnin_designer.html"
[ -f "$ENGINE" ] && _pass || _fail "engine burnin_designer.py exista"
[ -f "$UIHTML" ] && _pass || _fail "UI burnin_designer.html exista"

ENG_TXT="$(cat "$ENGINE")"
UI_TXT="$(cat "$UIHTML")"
BSH="$(cat "$SCRIPT_DIR/av_burnin.sh")"
BPS="$(cat "$SCRIPT_DIR/av_burnin.ps1")"

# ── Engine: rute API + principii ─────────────────────────────────────
assert_contains "$ENG_TXT" "/api/overlay"          "engine: ruta /api/overlay"
assert_contains "$ENG_TXT" "/api/save"             "engine: ruta /api/save"
assert_contains "$ENG_TXT" "/api/shutdown"         "engine: ruta /api/shutdown"
assert_contains "$ENG_TXT" "/frame"                "engine: ruta /frame"
assert_contains "$ENG_TXT" "import burnin_render"  "engine: reuse burnin_render (render REAL = WYSIWYG)"
assert_contains "$ENG_TXT" "127.0.0.1"             "engine: bind localhost-only"
assert_contains "$ENG_TXT" "synth_points"          "engine: mod DEMO fara CSV"
assert_contains "$ENG_TXT" "tonemap=tonemap=hable" "engine: tonemap display pe HDR (ca still v82)"
assert_contains "$ENG_TXT" "BURNIN_STILL_NO_TONEMAP" "engine: onoreaza env-ul v82 de bypass tonemap"
assert_contains "$ENG_TXT" 'PRESET_NAME='          "engine: scrie PRESET_NAME in conf"

# ── Engine render (burnin_render) — fix-uri v84 expuse de designer ──
# G-force/HR ignorau ancora (ha/va fixe left/top → text iesit din cadru pe
# tr/br) + map crapa pe route_xy=(None,None,None) (CSV fara GPS).
RND_TXT="$(cat "$SCRIPT_DIR/burnin_render.py")"
assert_contains "$RND_TXT" 'f"G {gmag:.2f}", font_medium, ha=ha, va=va' "render: G-force aliniat dupa ancora (ha/va)"
assert_contains "$RND_TXT" 'bpm", font_medium, ha=ha, va=va'            "render: HR aliniat dupa ancora (ha/va)"
assert_contains "$RND_TXT" 'route_xy is not None and route_xy[0]'       "render: guard map pe route_xy[0] (CSV fara GPS)"

# ── UI: markere esentiale ────────────────────────────────────────────
assert_contains "$UI_TXT" "api/overlay"            "UI: cere overlay de la server"
assert_contains "$UI_TXT" "applyDrop"              "UI: drag→anchor:x,y (applyDrop)"
assert_contains "$UI_TXT" "dragLayer"              "UI: strat de drag peste cadru"
assert_contains "$UI_TXT" "STRIP_FIELDS"           "UI: editor campuri strip"

# ── av_burnin.sh: flow 5 + preset custom ─────────────────────────────
assert_contains "$BSH" 'DESIGNER_PY='                        "bash: DESIGNER_PY definit"
assert_contains "$BSH" 'designer_flow()'                     "bash: designer_flow exista"
assert_contains "$BSH" '5) Designer vizual layout HUD'       "bash: optiunea 5 in meniul principal"
grep -qE '^\s+5\)\s+designer_flow' "$SCRIPT_DIR/av_burnin.sh" \
    && _pass || _fail "bash: dispatcher 5 → designer_flow"
assert_contains "$BSH" '6) Anulare'                          "bash: Anulare renumerotata 6"
assert_contains "$BSH" 'custom      — preset salvat (Designer)' "bash: LAYOUT PRESET opt 4 = custom"
assert_contains "$BSH" 'USER_PROFILES_DIR/burnin'            "bash: preseturi custom in UserProfiles/burnin"

# ── Paritate PS1 ─────────────────────────────────────────────────────
assert_contains "$BPS" 'Invoke-DesignerFlow'                 "PS1: Invoke-DesignerFlow exista"
assert_contains "$BPS" '$DesignerPy'                         "PS1: \$DesignerPy definit"
assert_contains "$BPS" '5) Designer vizual layout HUD'       "PS1: optiunea 5 in meniul principal"
assert_contains "$BPS" '6) Anulare'                          "PS1: Anulare renumerotata 6"
assert_contains "$BPS" 'custom      — preset salvat (Designer)' "PS1: LAYOUT PRESET opt 4 = custom"
assert_contains "$BPS" 'UserProfiles'                        "PS1: preseturi custom in UserProfiles"

# ── Functional headless (python3 + matplotlib + ffmpeg; skip gratios) ──
PY=""
if command -v python3 >/dev/null 2>&1; then PY="python3"
elif command -v python >/dev/null 2>&1 && python --version 2>&1 | grep -q "^Python 3"; then PY="python"
fi
DEPS_OK=0
if [ -n "$PY" ] && "$PY" -c "import matplotlib" >/dev/null 2>&1 && command -v ffmpeg >/dev/null 2>&1; then
    DEPS_OK=1
fi

if [ "$DEPS_OK" -eq 1 ]; then
    # functional: render_frame supravietuieste route_xy=(None,None,None)
    # (contract build_route_xy pe CSV fara GPS; fix v84 — inainte: TypeError)
    cat > "$tmpd/nogps.py" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import burnin_render as br
br.render_frame({"HUD_MAP": "1", "HUD_TIMESTAMP": "1"}, {}, (None, None, None), 320, 180, sys.argv[2])
print("NOGPS ok")
PYEOF
    nogps_out="$("$PY" "$tmpd/nogps.py" "$SCRIPT_DIR" "$tmpd/nogps.png" 2>&1 || true)"
    assert_contains "$nogps_out" "NOGPS ok" "functional: render cu route_xy=(None,None,None) nu crapa (fix v84)"

    ffmpeg -v error -f lavfi -i "testsrc=duration=2:size=320x180:rate=25" \
        -c:v libx264 -pix_fmt yuv420p "$tmpd/dsg.mp4" -y </dev/null >/dev/null 2>&1 || true
    if [ -s "$tmpd/dsg.mp4" ]; then
        mkdir -p "$tmpd/user"
        "$PY" "$ENGINE" --video "$tmpd/dsg.mp4" \
            --user-presets-dir "$tmpd/user" --temp-dir "$tmpd" \
            --port 0 --no-open >"$tmpd/out.log" 2>&1 &
        SRV_PID=$!
        port=""
        for _i in $(seq 1 60); do
            port="$(grep -oE 'URL: http://127\.0\.0\.1:[0-9]+' "$tmpd/out.log" 2>/dev/null | grep -oE '[0-9]+$' || true)"
            [ -n "$port" ] && break
            kill -0 "$SRV_PID" 2>/dev/null || break
            sleep 0.25
        done
        if [ -n "$port" ]; then
            _pass "functional: server pornit (port $port)"
            cat > "$tmpd/client.py" <<'PYEOF'
import json, sys, base64, urllib.request
base = sys.argv[1]
st = json.load(urllib.request.urlopen(base + "/api/state", timeout=15))
print("WIDTH", st["video"]["width"])
print("TELEM", st["telemetry"]["mode"])
fr = urllib.request.urlopen(base + "/frame?t=1.0", timeout=30).read()
print("FRAMEMAGIC", fr[1:4] == b"PNG")
body = json.dumps({"cfg": st["cfg"], "t": 1.0, "grid": False}).encode()
req = urllib.request.Request(base + "/api/overlay", data=body,
                             headers={"Content-Type": "application/json"})
ov = json.load(urllib.request.urlopen(req, timeout=60))
png = base64.b64decode(ov["png"])
print("PNGMAGIC", png[1:4] == b"PNG")
print("BOXES", len(ov["boxes"]) > 0)
body = json.dumps({"name": "v84_smoke", "cfg": st["cfg"]}).encode()
req = urllib.request.Request(base + "/api/save", data=body,
                             headers={"Content-Type": "application/json"})
sv = json.load(urllib.request.urlopen(req, timeout=15))
print("SAVED", sv["ok"])
req = urllib.request.Request(base + "/api/shutdown", data=b"{}",
                             headers={"Content-Type": "application/json"})
json.load(urllib.request.urlopen(req, timeout=15))
print("SHUTDOWN ok")
PYEOF
            client_out="$("$PY" "$tmpd/client.py" "http://127.0.0.1:$port" 2>&1 || true)"
            assert_contains "$client_out" "WIDTH 320"     "functional: state → width 320 (probe JSON)"
            assert_contains "$client_out" "TELEM demo"    "functional: fara CSV → mod demo"
            assert_contains "$client_out" "FRAMEMAGIC True" "functional: /frame → PNG valid (imun la range pe HDR)"
            assert_contains "$client_out" "PNGMAGIC True" "functional: /api/overlay → PNG valid"
            assert_contains "$client_out" "BOXES True"    "functional: hitbox-uri de drag prezente"
            assert_contains "$client_out" "SAVED True"    "functional: /api/save ok"
            assert_contains "$client_out" "SHUTDOWN ok"   "functional: /api/shutdown raspunde"
            [ -s "$tmpd/user/v84_smoke.conf" ] && _pass || _fail "functional: conf scris in user dir"
            grep -q '^PRESET_NAME=v84_smoke' "$tmpd/user/v84_smoke.conf" 2>/dev/null \
                && _pass || _fail "functional: conf contine PRESET_NAME"
            srv_down=0
            for _i in $(seq 1 20); do
                kill -0 "$SRV_PID" 2>/dev/null || { srv_down=1; break; }
                sleep 0.25
            done
            if [ "$srv_down" -eq 1 ]; then
                _pass "functional: serverul s-a oprit dupa shutdown"
            else
                kill -9 "$SRV_PID" 2>/dev/null
                _fail "functional: serverul NU s-a oprit dupa shutdown"
            fi
            SRV_PID=""
        else
            _fail "functional: serverul designer nu a pornit (log: $(tail -3 "$tmpd/out.log" 2>/dev/null | tr '\n' ' '))"
        fi
    else
        _pass  # skip-equivalent: ffmpeg nu a putut genera testsrc
    fi
else
    _pass  # skip-equivalent: python3/matplotlib/ffmpeg lipsesc
fi
