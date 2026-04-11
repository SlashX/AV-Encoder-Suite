#!/data/data/com.termux/files/usr/bin/bash
# ══════════════════════════════════════════════════════════════════════
# av_extractor_dji.sh — Extractor date GPS/telemetrie din fisiere video DJI
# Necesita: exiftool (pkg install exiftool sau cpan App::ExifTool)
# ══════════════════════════════════════════════════════════════════════

INPUT_DIR="/storage/emulated/0/Media/InputVideos"
OUTPUT_DIR="/storage/emulated/0/Media/OutputVideos"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

# ── Scanare fisiere ──────────────────────────────────────────────────
shopt -s nullglob nocaseglob
FILES=("$INPUT_DIR"/*.{mp4,mov,mkv,m2ts,mts,vob,mxf,apv})
shopt -u nocaseglob nullglob
TOTAL=${#FILES[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo "Nu am gasit fisiere video in $INPUT_DIR"
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  DJI GPS/TELEMETRIE EXTRACTOR                ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  Fisiere gasite : $TOTAL"
echo "║  Input  : $INPUT_DIR"
echo "║  Output : $OUTPUT_DIR"
echo "╠══════════════════════════════════════════════╣"
echo "║  Ce doresti sa extragi?                       ║"
echo "║  1) Standard (GPX + KML + CSV esential)        ║"
echo "║  2) Full Data (GPX + KML + CSV TOATE metadate) ║"
echo "║  3) Subtitrare (fisier .SRT pentru VLC)        ║"
echo "║  4) Totul (GPX + KML + CSV + SRT)              ║"
echo "║  5) Raw streams (djmd, dbgi, tmcd, cover)      ║"
echo "║  6) Elimina metadata DJI (remux rapid)         ║"
echo "║  7) Anulare                                    ║"
echo "╚══════════════════════════════════════════════╝"
read -p "Alege 1-7 [implicit: 1]: " choice
choice="${choice:-1}"

if [ "$choice" == "7" ]; then
    echo "Anulat."; exit 0
fi

# ── Verificare dependente ────────────────────────────────────────────
# Optiunile 1-4 necesita exiftool, optiunile 5-6 necesita ffmpeg
if [ "$choice" == "5" ] || [ "$choice" == "6" ]; then
    if ! command -v ffmpeg &>/dev/null; then
        echo "EROARE: ffmpeg nu este instalat (necesar pentru aceasta optiune)."
        exit 1
    fi
else
    if ! command -v exiftool &>/dev/null; then
        echo "EROARE: exiftool nu este instalat."
        echo "Instaleaza cu: pkg install exiftool"
        echo "          sau: cpan App::ExifTool"
        exit 1
    fi
fi

# ── Generare template GPX ────────────────────────────────────────────
GPX_FMT=$(mktemp)
cat <<'GPXEOF' > "$GPX_FMT"
#[HEAD]<?xml version="1.0" encoding="utf-8"?>
#[HEAD]<gpx version="1.0" creator="ExifTool $[ExifToolVersion]" xmlns="http://www.topografix.com/GPX/1/0">
#[HEAD]<trk><name>$filename</name><trkseg>
#[BODY]<trkpt lat="$gpslatitude#" lon="$gpslongitude#"><ele>$gpsaltitude#</ele><time>$gpsdatetime</time></trkpt>
#[TAIL]</trkseg></trk></gpx>
GPXEOF

# ── Generare template SRT ────────────────────────────────────────────
SRT_FMT=$(mktemp)
cat <<'SRTEOF' > "$SRT_FMT"
#[BODY]${self:SampleIndex}
#[BODY]${gpsdatetime} --> ${gpsdatetime}
#[BODY]Viteza: ${gpsspeed#} m/s | Alt: ${gpsaltitude#}m
#[BODY]Coord: ${gpslatitude#}, ${gpslongitude#}
#[BODY]
SRTEOF

# ── Generare template KML ────────────────────────────────────────────
KML_FMT=$(mktemp)
cat <<'KMLEOF' > "$KML_FMT"
#[HEAD]<?xml version="1.0" encoding="UTF-8"?>
#[HEAD]<kml xmlns="http://www.opengis.net/kml/2.2">
#[HEAD]<Document><name>$filename</name>
#[HEAD]<Style id="track"><LineStyle><color>ff0000ff</color><width>3</width></LineStyle></Style>
#[HEAD]<Placemark><name>Track</name><styleUrl>#track</styleUrl>
#[HEAD]<LineString><altitudeMode>absolute</altitudeMode><coordinates>
#[BODY]$gpslongitude#,$gpslatitude#,$gpsaltitude#
#[TAIL]</coordinates></LineString></Placemark></Document></kml>
KMLEOF

# ── Sub-dialog strip metadata (optiunea 6) ──────────────────────────
STRIP_MODE=""
if [ "$choice" == "6" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ELIMINA METADATA DJI (REMUX FARA RE-ENCODE) ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  1) Elimina doar debug (dbgi ~295 MB) [impl]  ║"
    echo "║  2) Elimina GPS + debug (djmd + dbgi)         ║"
    echo "║  3) Elimina tot (djmd + dbgi + tmcd + cover)  ║"
    echo "║  4) Anulare                                   ║"
    echo "╚══════════════════════════════════════════════╝"
    read -p "Alege 1-4 [implicit: 1]: " STRIP_MODE
    STRIP_MODE="${STRIP_MODE:-1}"
    if [ "$STRIP_MODE" == "4" ]; then echo "Anulat."; exit 0; fi
fi

# ── Procesare ────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════"
echo "Incep extractia..."
echo "═══════════════════════════════════════"

COUNT=0; ERRORS=0; DONE=0
for file in "${FILES[@]}"; do
    [ -f "$file" ] || continue
    COUNT=$((COUNT + 1))
    filename=$(basename "$file")
    name="${filename%.*}"

    echo ""
    echo "── Fisier $COUNT/$TOTAL: $filename"

    # GPX — optiunile 1, 2, 4
    if [ "$choice" == "1" ] || [ "$choice" == "2" ] || [ "$choice" == "4" ]; then
        exiftool -p "$GPX_FMT" -ee3 -api LargeFileSupport=1 "$file" > "$OUTPUT_DIR/${name}.gpx" 2>/dev/null
        if [ $? -eq 0 ] && [ -s "$OUTPUT_DIR/${name}.gpx" ]; then
            echo "  [OK] GPX: ${name}.gpx"
        else
            echo "  [SKIP] GPX: nu s-au gasit date GPS"
            rm -f "$OUTPUT_DIR/${name}.gpx"
        fi
    fi

    # KML — optiunile 1, 2, 4
    if [ "$choice" == "1" ] || [ "$choice" == "2" ] || [ "$choice" == "4" ]; then
        exiftool -p "$KML_FMT" -ee3 -api LargeFileSupport=1 "$file" > "$OUTPUT_DIR/${name}.kml" 2>/dev/null
        if [ $? -eq 0 ] && [ -s "$OUTPUT_DIR/${name}.kml" ]; then
            echo "  [OK] KML: ${name}.kml"
        else
            echo "  [SKIP] KML: nu s-au gasit date GPS"
            rm -f "$OUTPUT_DIR/${name}.kml"
        fi
    fi

    # CSV Basic — optiunile 1, 4
    if [ "$choice" == "1" ] || [ "$choice" == "4" ]; then
        exiftool -ee3 -api LargeFileSupport=1 -csv -n \
            -GPSLatitude -GPSLongitude -GPSAltitude \
            -GPSSpeed -GPSTrack -GPSDateTime \
            "$file" > "$OUTPUT_DIR/${name}_basic.csv" 2>/dev/null
        if [ $? -eq 0 ] && [ -s "$OUTPUT_DIR/${name}_basic.csv" ]; then
            echo "  [OK] CSV Basic: ${name}_basic.csv"
        else
            echo "  [SKIP] CSV: nu s-au gasit date GPS"
            rm -f "$OUTPUT_DIR/${name}_basic.csv"
        fi
    fi

    # CSV Full — optiunile 2, 4
    if [ "$choice" == "2" ] || [ "$choice" == "4" ]; then
        exiftool -ee3 -api LargeFileSupport=1 -csv -G -n \
            "$file" > "$OUTPUT_DIR/${name}_FULL.csv" 2>/dev/null
        if [ $? -eq 0 ] && [ -s "$OUTPUT_DIR/${name}_FULL.csv" ]; then
            echo "  [OK] CSV Full: ${name}_FULL.csv"
        else
            echo "  [SKIP] CSV Full: nu s-au gasit date"
            rm -f "$OUTPUT_DIR/${name}_FULL.csv"
        fi
    fi

    # SRT — optiunile 3, 4
    if [ "$choice" == "3" ] || [ "$choice" == "4" ]; then
        exiftool -p "$SRT_FMT" -ee3 -api LargeFileSupport=1 "$file" > "$OUTPUT_DIR/${name}.srt" 2>/dev/null
        if [ $? -eq 0 ] && [ -s "$OUTPUT_DIR/${name}.srt" ]; then
            echo "  [OK] SRT: ${name}.srt"
        else
            echo "  [SKIP] SRT: nu s-au gasit date GPS"
            rm -f "$OUTPUT_DIR/${name}.srt"
        fi
    fi

    # RAW STREAMS — optiunea 5: extrage djmd, dbgi, tmcd, cover ca fisiere separate
    if [ "$choice" == "5" ]; then
        local_idx=0
        while IFS= read -r tag; do
            if echo "$tag" | grep -qi "djmd"; then
                ffmpeg -v error -i "$file" -map 0:$local_idx -c copy -f data "$OUTPUT_DIR/${name}_djmd.bin" -y </dev/null 2>/dev/null
                if [ -s "$OUTPUT_DIR/${name}_djmd.bin" ]; then
                    echo "  [OK] djmd: ${name}_djmd.bin ($(du -h "$OUTPUT_DIR/${name}_djmd.bin" | cut -f1))"
                else
                    rm -f "$OUTPUT_DIR/${name}_djmd.bin"
                    echo "  [SKIP] djmd: stream gol"
                fi
            elif echo "$tag" | grep -qi "dbgi"; then
                ffmpeg -v error -i "$file" -map 0:$local_idx -c copy -f data "$OUTPUT_DIR/${name}_dbgi.bin" -y </dev/null 2>/dev/null
                if [ -s "$OUTPUT_DIR/${name}_dbgi.bin" ]; then
                    echo "  [OK] dbgi: ${name}_dbgi.bin ($(du -h "$OUTPUT_DIR/${name}_dbgi.bin" | cut -f1))"
                else
                    rm -f "$OUTPUT_DIR/${name}_dbgi.bin"
                    echo "  [SKIP] dbgi: stream gol"
                fi
            elif echo "$tag" | grep -qi "tmcd"; then
                ffmpeg -v error -i "$file" -map 0:$local_idx -c copy -f data "$OUTPUT_DIR/${name}_tmcd.bin" -y </dev/null 2>/dev/null
                if [ -s "$OUTPUT_DIR/${name}_tmcd.bin" ]; then
                    echo "  [OK] tmcd: ${name}_tmcd.bin ($(du -h "$OUTPUT_DIR/${name}_tmcd.bin" | cut -f1))"
                else
                    rm -f "$OUTPUT_DIR/${name}_tmcd.bin"
                    echo "  [SKIP] tmcd: stream gol"
                fi
            elif echo "$tag" | grep -qi "mjpeg\|jpeg"; then
                ffmpeg -v error -i "$file" -map 0:$local_idx -c copy -f mjpeg "$OUTPUT_DIR/${name}_cover.jpg" -y </dev/null 2>/dev/null
                if [ -s "$OUTPUT_DIR/${name}_cover.jpg" ]; then
                    echo "  [OK] cover: ${name}_cover.jpg ($(du -h "$OUTPUT_DIR/${name}_cover.jpg" | cut -f1))"
                else
                    rm -f "$OUTPUT_DIR/${name}_cover.jpg"
                    echo "  [SKIP] cover: nu s-a gasit"
                fi
            fi
            local_idx=$((local_idx + 1))
        done < <(ffprobe -v error \
            -show_entries stream=codec_tag_string,codec_name \
            -of csv=p=0 "$file" 2>/dev/null)
        
        # Daca nu s-a extras nimic, nu e fisier DJI
        if [ ! -f "$OUTPUT_DIR/${name}_djmd.bin" ] && [ ! -f "$OUTPUT_DIR/${name}_dbgi.bin" ]; then
            echo "  [SKIP] Nu e fisier DJI (nu s-au gasit stream-uri djmd/dbgi)"
        fi
    fi

    # STRIP METADATA — optiunea 6: remux fara re-encode, exclude track-uri selectate
    if [ "$choice" == "6" ]; then
        ext="${filename##*.}"
        # Detecteaza track-uri DJI
        has_djmd=0; has_dbgi=0; has_tc=0
        tracks_raw=$(ffprobe -v error \
            -show_entries stream=codec_tag_string,codec_name \
            -of csv=p=0 "$file" 2>/dev/null)
        echo "$tracks_raw" | grep -qi "djmd" && has_djmd=1
        echo "$tracks_raw" | grep -qi "dbgi" && has_dbgi=1
        echo "$tracks_raw" | grep -qi "tmcd" && has_tc=1

        if [ "$has_djmd" -eq 0 ] && [ "$has_dbgi" -eq 0 ]; then
            echo "  [SKIP] Nu e fisier DJI (nu s-au gasit track-uri djmd/dbgi)"
        else
            # Construieste map flags cu negative mapping
            maps="-map 0"
            local_idx=0
            while IFS= read -r tag; do
                case "$STRIP_MODE" in
                    1) echo "$tag" | grep -qi "dbgi" && maps="$maps -map -0:$local_idx" ;;
                    2) echo "$tag" | grep -qi "djmd\|dbgi" && maps="$maps -map -0:$local_idx" ;;
                    3) echo "$tag" | grep -qi "djmd\|dbgi\|tmcd\|mjpeg\|jpeg" && maps="$maps -map -0:$local_idx" ;;
                esac
                local_idx=$((local_idx + 1))
            done < <(ffprobe -v error -show_entries stream=codec_tag_string \
                -of csv=p=0 "$file" 2>/dev/null)

            out_clean="$OUTPUT_DIR/${name}_clean.${ext}"
            ffmpeg -v error -i "$file" $maps -c copy -map_metadata 0 "$out_clean" -y </dev/null 2>/dev/null
            strip_rc=$?
            if [ $strip_rc -eq 0 ] && [ -s "$out_clean" ]; then
                src_size=$(du -h "$file" | cut -f1)
                out_size=$(du -h "$out_clean" | cut -f1)
                echo "  [OK] ${name}_clean.${ext} ($src_size → $out_size)"
            else
                echo "  [EROARE] Remux esuat pentru $filename"
                rm -f "$out_clean"
            fi
        fi
    fi

    DONE=$((DONE + 1))
done

# ── Curatenie ────────────────────────────────────────────────────────
rm -f "$GPX_FMT" "$SRT_FMT" "$KML_FMT"

echo ""
echo "═══════════════════════════════════════"
echo "FINALIZAT — $DONE fisiere procesate"
echo "Output: $OUTPUT_DIR"
echo "═══════════════════════════════════════"
