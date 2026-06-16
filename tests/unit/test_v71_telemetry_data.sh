#!/usr/bin/env bash
# v71 — telemetrie embed/strip: ffmpeg NU poate re-muxa pistele de date proprietare
# (djmd/dbgi/tmcd/gpmd) — le vede ca codec=none → `-c copy` esueaza ("tag for codec
# none" pe MP4; "Only audio/video/subtitles" pe MKV). Inainte: embed mapa data cu
# `-map 0:d?` + strip-ul modurilor 1/2 PASTRA date → ambele picau pe surse reale (DJI).
# Fix: `-dn` (drop data ne-muxabil); telemetria ramane ca SRT/CSV/GPX/KML.
#   Source-level (mereu) + functional (cand exista un sample DJI cu data stream + ffmpeg).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SRC:$PATH"
TEL="$(cat "$SRC/av_telemetry.sh")"
TELP="$(cat "$SRC/av_telemetry.ps1")"

# ── 1. embed: -dn, FARA -map 0:d? (bash + PS1) ────────────────────────────
assert_contains "$TEL" 'ff_args+=("${ff_maps[@]}" -dn -c:v copy -c:a copy)' "embed bash: -dn (drop data ne-muxabil)"
assert_not_contains "$TEL" '-map "0:d?"' "embed bash: nu mai mapeaza data (codec none)"
assert_contains "$TELP" '"-dn","-c:v","copy","-c:a","copy"' "embed PS1: -dn"
assert_not_contains "$TELP" '"-map","0:d?"' "embed PS1: nu mai mapeaza data"

# ── 2. strip: -dn in toate cele 3 cai bash + PS1 ──────────────────────────
assert_contains "$TEL" 'local maps="-map 0 -dn"' "strip bash: -dn prezent"
n=$(grep -c 'maps="-map 0 -dn"' "$SRC/av_telemetry.sh" || true)
assert_eq "3" "$n" "strip bash: -dn in toate 3 caile (dji/gopro/telem)"
np=$(grep -c '@("-map","0","-dn")' "$SRC/av_telemetry.ps1" || true)
assert_eq "3" "$np" "strip PS1: -dn in toate 3 caile"

# ── 3. meniul DJI nu mai promite fals 'keep GPS' (imposibil la re-mux) ─────
assert_not_contains "$TEL" 'Doar debug (dbgi ~295 MB)' "meniu bash: optiunea inselatoare scoasa"
assert_contains "$TEL" 'GPS-ul djmd NU poate ramane la re-mux' "meniu bash: nota onesta DJI"
assert_contains "$TELP" 'GPS-ul djmd NU poate ramane la re-mux' "meniu PS1: nota onesta DJI"

# ── 4. FUNCTIONAL — sample DJI cu data stream (codec none) → embed/strip reusesc ──
DJI_SAMPLE="$(ls "$SRC"/DJI_*.MP4 "$SRC"/DJI_*.mp4 2>/dev/null | head -1 || true)"
if [ -n "$DJI_SAMPLE" ] && command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    has_data=$(ffprobe -v error -select_streams d -show_entries stream=index -of csv=p=0 "$DJI_SAMPLE" 2>/dev/null | grep -c . || true)
    if [ "${has_data:-0}" -gt 0 ]; then
        TD="$(mktemp -d)"
        printf '1\n00:00:00,000 --> 00:00:01,000\nt\n' > "$TD/t.srt"
        # embed pattern (ca embed_telemetry_lossless, -dn) → MKV reuseste pe data codec none
        ok=0
        if ffmpeg -v error -y -t 1 -i "$DJI_SAMPLE" -i "$TD/t.srt" -map 0:v -map 0:a? -map 1:s \
              -dn -c:v copy -c:a copy -c:s srt "$TD/embed.mkv" </dev/null 2>/dev/null && [ -s "$TD/embed.mkv" ]; then ok=1; fi
        assert_eq "1" "$ok" "functional: embed -dn → MKV reuseste pe DJI (data codec none)"
        ns=$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$TD/embed.mkv" 2>/dev/null | grep -c . || true)
        assert_eq "1" "$ns" "functional: SRT-ul de telemetrie pastrat"
        nd=$(ffprobe -v error -select_streams d -show_entries stream=index -of csv=p=0 "$TD/embed.mkv" 2>/dev/null | grep -c . || true)
        assert_eq "0" "$nd" "functional: data ne-muxabil dropat (matroska)"
        # strip mode 1 pattern (-map 0 -dn) → reuseste (inainte: "Remux esuat")
        ok2=0
        if ffmpeg -v error -y -t 1 -i "$DJI_SAMPLE" -map 0 -dn -c copy -map_metadata 0 "$TD/strip.mp4" </dev/null 2>/dev/null && [ -s "$TD/strip.mp4" ]; then ok2=1; fi
        assert_eq "1" "$ok2" "functional: strip -map 0 -dn reuseste pe DJI"
        rm -rf "$TD"
    else
        echo "  (functional sarit: sample DJI fara data stream)" >&2
    fi
else
    echo "  (functional sarit: niciun sample DJI_*.MP4 in src/ sau ffmpeg/ffprobe lipsesc)" >&2
fi
