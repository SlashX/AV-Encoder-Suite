#!/usr/bin/env bash
# v82 — Burn-in: (A) still-preview HDR tonemap (_burnin_still_display_filter) +
#   (B) subtitle `shaping` (libass HarfBuzz) la SRT/ASS +
#   (C) fix ASS scale rupt din v48: filtrul `ass` NU are force_style, deci optiunile
#       ScaleX/Y 1.25x/1.5x nu redau nimic -> SCOASE. ASS = filtru nativ `ass`
#       (respecta styling-ul embedded) + shaping optional (filtrul `ass` il suporta).
#   A = filtru aplicat DOAR pe PNG-ul de preview (output real NEatins).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

BSH="$(cat "$SCRIPT_DIR/av_burnin.sh")"
BPS="$(cat "$SCRIPT_DIR/av_burnin.ps1")"

# ── 1. A: still display filter (tonemap) — bash ─────────────────────
assert_contains "$BSH" '_burnin_still_display_filter()'             "bash: helper still display filter"
assert_contains "$BSH" 'tonemap=tonemap=hable'                      "bash: lant tonemap pt still"
assert_contains "$BSH" 'BURNIN_STILL_NO_TONEMAP'                    "bash: env bypass tonemap"
assert_contains "$BSH" '_st_disp="$(_burnin_still_display_filter)"' "bash: ramura still foloseste helper"
assert_contains "$BSH" 'still tonemapped pentru preview'           "bash: nota onesta HDR-preserve"

# ── 2. B: shaping SRT/ASS — bash ────────────────────────────────────
assert_contains "$BSH" '_burnin_subtitles_has_shaping()'           "bash: capability shaping"
assert_contains "$BSH" 'ask_burnin_shaping()'                      "bash: prompt shaping"
assert_contains "$BSH" 'SUB_SHAPING='                              "bash: state SUB_SHAPING"
assert_contains "$BSH" ':shaping=${SUB_SHAPING}'                   "bash: append shaping in vf"
assert_contains "$BSH" '-h filter=subtitles'                       "bash: gate capabilitate ffmpeg"
n_ask=$(printf '%s\n' "$BSH" | grep -c 'ask_burnin_shaping$')
ask_ok=1; [[ "$n_ask" -ge 2 ]] && ask_ok=0
assert_zero "$ask_ok" "bash: ask_burnin_shaping chemat in srt+ass ($n_ask)"

# ── 2b. C: ASS = filtru nativ ass, meniul scale rupt SCOS — bash ────
assert_contains     "$BSH" "vf=\"ass='"           "bash: ASS filtru nativ ass"
assert_contains     "$BSH" 'styling embedded pastrat' "bash: nota styling embedded ASS"
assert_not_contains "$BSH" 'ASS FONT SCALE'       "bash: meniul ASS scale SCOS (rupt din v48)"
assert_not_contains "$BSH" 'ScaleX=125'           "bash: optiune scale 1.25x SCOASA"
assert_not_contains "$BSH" 'ScaleX=150'           "bash: optiune scale 1.5x SCOASA"

# ── 3. PS1 mirror (source-level) ────────────────────────────────────
assert_contains     "$BPS" 'function Get-BurninStillDisplayFilter'  "PS1: helper still display filter"
assert_contains     "$BPS" 'tonemap=tonemap=hable'                 "PS1: lant tonemap"
assert_contains     "$BPS" 'BURNIN_STILL_NO_TONEMAP'               "PS1: env bypass"
assert_contains     "$BPS" '$stDisp = Get-BurninStillDisplayFilter' "PS1: ramura still foloseste helper"
assert_contains     "$BPS" 'function Test-BurninSubtitleShaping'   "PS1: capability shaping"
assert_contains     "$BPS" 'function Get-BurninShaping'            "PS1: prompt shaping"
assert_contains     "$BPS" ':shaping=$subShaping'                  "PS1: append shaping in vf"
assert_contains     "$BPS" "ass='"'$'"assEsc'"                     "PS1: ASS filtru nativ ass"
assert_contains     "$BPS" 'styling embedded pastrat'             "PS1: nota styling embedded ASS"
assert_not_contains "$BPS" 'ASS FONT SCALE'                       "PS1: meniul ASS scale SCOS"
assert_not_contains "$BPS" 'ScaleX=125'                           "PS1: optiune scale 1.25x SCOASA"

# ── 4. Functional A: starile helper-ului (source izolat in subshell) ─
_sdf() { export AV_BURNIN_TEST_MODE=1; source "$SCRIPT_DIR/av_burnin.sh" >/dev/null 2>&1; BURNIN_PRE_FILTER="$1"; BURNIN_SOURCE_TYPE="$2"; BURNIN_STILL_NO_TONEMAP="${3:-0}"; _burnin_still_display_filter; }
assert_contains "$(_sdf '' hdr10 0)"   "tonemap"            "A funct: HDR-preserve -> tonemap"
assert_eq ""             "$(_sdf '' sdr 0)"                 "A funct: SDR -> gol"
assert_eq ""             "$(_sdf '' hdr10 1)"               "A funct: NO_TONEMAP=1 -> gol (raw)"
assert_eq "lut3d=x.cube" "$(_sdf 'lut3d=x.cube' log 0)"     "A funct: pre-filter -> verbatim"

# ── 5. Functional B: capability parity + render-uri reale ───────────
if command -v ffmpeg >/dev/null 2>&1; then
    direct=1; ffmpeg -hide_banner -h filter=subtitles 2>/dev/null | grep -q shaping && direct=0
    helper=1; ( export AV_BURNIN_TEST_MODE=1; source "$SCRIPT_DIR/av_burnin.sh" >/dev/null 2>&1; _burnin_subtitles_has_shaping ) && helper=0
    assert_eq "$direct" "$helper" "B funct: capability helper == check direct ffmpeg"

    tmpd="$(mktemp -d)"
    printf '1\n00:00:00,000 --> 00:00:01,000\nHello shaping test\n' > "$tmpd/s.srt"
    ffmpeg -v error -y -f lavfi -i "color=c=navy:s=320x240:d=1" -pix_fmt yuv420p "$tmpd/v.mp4" >/dev/null 2>&1
    ffmpeg -v error -y -i "$tmpd/s.srt" "$tmpd/s.ass" >/dev/null 2>&1
    # v96: rularile cu shaping se fac DOAR daca build-ul chiar il are ($direct==0 = suportat).
    # Testul masura capabilitatea mai sus, apoi o folosea neconditionat — pe un ffmpeg fara
    # libharfbuzz (ex. pachetul din Ubuntu) ffmpeg raspunde "Option not found" si testul pica,
    # desi codul de PRODUCTIE e corect: `ask_burnin_shaping` sare promptul cand poarta zice nu.
    # Adica testul presupunea exact ce tocmai masurase.
    if [ "$direct" -eq 0 ]; then
        # SRT + force_style + shaping=complex (forma reala a suitei; filtrul `subtitles`)
        ( cd "$tmpd" && ffmpeg -v error -i v.mp4 -vf "subtitles=s.srt:force_style='FontSize=24':shaping=complex" -frames:v 1 -y o1.png ) >/dev/null 2>&1 && r1=0 || r1=1
        assert_zero "$r1" "B funct: SRT force_style+shaping=complex -> rc=0"
        # ASS prin filtrul NATIV `ass` + shaping (forma reala a suitei v82)
        if [[ -f "$tmpd/s.ass" ]]; then
            ( cd "$tmpd" && ffmpeg -v error -i v.mp4 -vf "ass=s.ass:shaping=complex" -frames:v 1 -y o2.png ) >/dev/null 2>&1 && r2=0 || r2=1
            assert_zero "$r2" "B funct: ASS(filtru nativ ass)+shaping -> rc=0"
        fi
    else
        # Fara shaping, formele de baza trebuie sa mearga la fel — asta ramane verificabil.
        ( cd "$tmpd" && ffmpeg -v error -i v.mp4 -vf "subtitles=s.srt:force_style='FontSize=24'" -frames:v 1 -y o1.png ) >/dev/null 2>&1 && r1=0 || r1=1
        assert_zero "$r1" "B funct: SRT force_style (build fara shaping) -> rc=0"
    fi
    # lant tonemap valid pe frame PQ (setparams taguieste frame-ul, ca sursele HDR reale)
    chain="format=yuv420p10le,setparams=color_trc=smpte2084:color_primaries=bt2020:colorspace=bt2020nc,zscale=t=linear:npl=100,tonemap=tonemap=hable,zscale=t=bt709:m=bt709:p=bt709:r=tv,format=yuv420p"
    ffmpeg -v error -y -f lavfi -i "color=c=gray:s=320x240:d=1" -vf "$chain" -frames:v 1 "$tmpd/o3.png" >/dev/null 2>&1 && r3=0 || r3=1
    assert_zero "$r3" "A funct: lant tonemap valid pe frame PQ -> rc=0"
    rm -rf "$tmpd"
else
    echo "  (functional B skip — ffmpeg lipseste)" >&2
fi
