#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  generate_samples.sh — synthesize tiny test media files via ffmpeg
#  Idempotent: skips files that already exist (override with --force)
#  Outputs to ./samples/
# ═══════════════════════════════════════════════════════════════

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLES_DIR="$SCRIPT_DIR/samples"
mkdir -p "$SAMPLES_DIR"

FORCE=0
for arg in "$@"; do
    case "$arg" in
        -f|--force) FORCE=1 ;;
        -h|--help) echo "Usage: $0 [--force]"; exit 0 ;;
    esac
done

HAVE_FFMPEG=1
if ! command -v ffmpeg &>/dev/null; then
    echo "  ⚠ ffmpeg not found — voi genera doar sample-urile non-video (GPX/KML)" >&2
    HAVE_FFMPEG=0
fi

_skip_if_exists() {
    [[ $FORCE -eq 1 ]] && return 1
    [[ -f "$1" ]] && { echo "  ~ exists: $(basename "$1")"; return 0; }
    return 1
}

# Suppress ffmpeg banner/noise; capture stderr only on error
_ff() {
    local out_file="$1"; shift
    if ! ffmpeg -y -hide_banner -loglevel error "$@" "$out_file" 2>&1; then
        echo "    FAIL: $out_file" >&2
        return 1
    fi
    echo "  + $(basename "$out_file") ($(du -k "$out_file" | cut -f1) KB)"
}

echo "Generating synthetic samples in: $SAMPLES_DIR"

if [[ $HAVE_FFMPEG -eq 1 ]]; then

# 1) SDR — 320x240, 2s, libx264 yuv420p, MP4
out="$SAMPLES_DIR/sdr_320p.mp4"
if ! _skip_if_exists "$out"; then
    _ff "$out" \
        -f lavfi -i "testsrc2=duration=2:size=320x240:rate=30" \
        -f lavfi -i "sine=frequency=440:duration=2" \
        -c:v libx264 -pix_fmt yuv420p -preset ultrafast \
        -c:a aac -b:a 64k -shortest
fi

# 2) HDR10 — 320x240, 2s, libx265 yuv420p10le, BT.2020 PQ
# v52 fix: NU folosim ffmpeg -color_primaries/-color_trc/-colorspace (scriu
# Matroska "Colour" element care override VUI stream → sample produs cu
# color_transfer=unknown si testele HDR detect cad). Doar x265-params.
out="$SAMPLES_DIR/hdr10_320p.mkv"
if ! _skip_if_exists "$out"; then
    _ff "$out" \
        -f lavfi -i "testsrc2=duration=2:size=320x240:rate=30" \
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast \
        -x265-params "hdr10=1:hdr10-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
        -an
fi

# 3) HLG — 320x240, 2s, libx265 yuv420p10le, BT.2020 HLG (arib-std-b67)
# v52 fix: same as above — doar x265-params, fara ffmpeg color flags
out="$SAMPLES_DIR/hlg_320p.mkv"
if ! _skip_if_exists "$out"; then
    _ff "$out" \
        -f lavfi -i "testsrc2=duration=2:size=320x240:rate=30" \
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast \
        -x265-params "transfer=arib-std-b67:colormatrix=bt2020nc:colorprim=bt2020:repeat-headers=1" \
        -an
fi

# 4) Audio-only WAV — 1s sine 440Hz mono 16-bit
out="$SAMPLES_DIR/audio_440hz.wav"
if ! _skip_if_exists "$out"; then
    _ff "$out" \
        -f lavfi -i "sine=frequency=440:duration=1:sample_rate=48000" \
        -c:a pcm_s16le -ac 1
fi

# 5) Multi-segment SDR for trim/concat (2 inputs → concat) — actually a single 4s file with scene change at 2s via fade
out="$SAMPLES_DIR/sdr_4s.mp4"
if ! _skip_if_exists "$out"; then
    _ff "$out" \
        -f lavfi -i "testsrc2=duration=4:size=320x240:rate=30" \
        -f lavfi -i "sine=frequency=440:duration=4" \
        -c:v libx264 -pix_fmt yuv420p -preset ultrafast \
        -c:a aac -b:a 64k -shortest
fi

fi  # HAVE_FFMPEG

# 6) GPX sample — manual XML, 3 trackpoints
out="$SAMPLES_DIR/sample.gpx"
if ! _skip_if_exists "$out"; then
    cat > "$out" <<'GPX_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="av-encoder-suite-test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>test-track</name>
    <trkseg>
      <trkpt lat="44.4268" lon="26.1025"><ele>85.0</ele><time>2025-01-01T10:00:00Z</time></trkpt>
      <trkpt lat="44.4270" lon="26.1027"><ele>86.0</ele><time>2025-01-01T10:00:01Z</time></trkpt>
      <trkpt lat="44.4272" lon="26.1029"><ele>87.0</ele><time>2025-01-01T10:00:02Z</time></trkpt>
    </trkseg>
  </trk>
</gpx>
GPX_EOF
    echo "  + sample.gpx ($(du -k "$out" | cut -f1) KB)"
fi

# 7) KML sample — minimal LineString
out="$SAMPLES_DIR/sample.kml"
if ! _skip_if_exists "$out"; then
    cat > "$out" <<'KML_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>test-track</name>
    <Placemark>
      <LineString>
        <coordinates>26.1025,44.4268,85 26.1027,44.4270,86 26.1029,44.4272,87</coordinates>
      </LineString>
    </Placemark>
  </Document>
</kml>
KML_EOF
    echo "  + sample.kml ($(du -k "$out" | cut -f1) KB)"
fi

echo ""
echo "Done. Samples directory: $SAMPLES_DIR"
ls -la "$SAMPLES_DIR" | tail -n +2
