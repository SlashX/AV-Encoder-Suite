# AV Encoder Suite

**Cross-platform video encoding suite (bash/PS1) for Termux (Android) and Windows**

> FFmpeg Smart Adaptive Encoder with HDR/DV detection, DJI GPS extraction, batch processing and profile system — v33

---

## Features

- **6 video encoders**: H.265/HEVC, H.264/AVC, AV1 (SVT-AV1/libaom), DNxHR, ProRes, APV
- **Automatic HDR detection**: HDR10, HDR10+, Dolby Vision, LOG (Apple Log, D-Log M, Samsung Log)
- **DJI support**: GPS/telemetry extraction (GPX, KML, CSV, SRT), DJI track preservation
- **Audio encoding**: AAC, AC3, E-AC3 (Dolby Digital Plus), DTS, TrueHD, FLAC, PCM, Opus
- **Video filters**: 4K upscale (Lanczos), vidstab 2-pass stabilization, denoise, deinterlace, crop, resize, FPS conversion
- **Audio normalization**: EBU R128 loudnorm (2-pass, -24 LUFS)
- **Profile system**: save/load full encode config as `.conf` files (cross-platform KEY=VALUE)
- **Batch processing**: resume interrupted batch, skip existing, dry-run preview, detailed summary
- **Media analysis**: `av_check` with 50-field CSV export, I/O comparison
- **GPS import**: external GPX/FIT/KML → CSV, SRT, GPX, KML conversion

---

## Platforms

| Platform | Scripts | Requirements |
|----------|---------|--------------|
| **Termux (Android)** | `.sh` (bash) | FFmpeg 8.1+, ffprobe, Termux:API |
| **Windows** | `.ps1` (PowerShell) | FFmpeg in PATH, PowerShell 5.1+ |

---

## Project Structure

```
AV-Encoder-Suite/
├── src/
│   ├── av_launcher.sh          # Interactive main menu (Termux)
│   ├── av_common.sh            # Shared functions (HDR, DJI, audio, progress)
│   ├── av_encoder_x265.sh      # H.265/HEVC encoder
│   ├── av_encoder_x264.sh      # H.264/AVC encoder
│   ├── av_encoder_av1.sh       # AV1 encoder (SVT-AV1 / libaom)
│   ├── av_encoder_dnxhr.sh     # DNxHR encoder (Avid mezzanine)
│   ├── av_encoder_prores.sh    # ProRes encoder (Apple professional)
│   ├── av_encoder_apv.sh       # APV encoder (Samsung, ffmpeg 8.1+)
│   ├── av_encoder_audio.sh     # Audio-only re-encode (video stream copy)
│   ├── av_check.sh             # Media analysis + CSV export (Termux)
│   ├── av_check.ps1            # Media analysis + CSV export (Windows)
│   ├── av_encode.ps1           # All-in-one PowerShell script (Windows)
│   ├── av_extractor_dji.sh     # DJI GPS/telemetry extractor (Termux)
│   ├── av_extractor_gps.sh     # External GPS import GPX/FIT/KML (Termux)
│   ├── hdr10plus_parser.sh     # hdr10plus_tool installer (Termux, Rust)
│   ├── hdr10plus_parser.ps1    # hdr10plus_tool installer (Windows)
│   ├── dovi_parser.sh          # dovi_tool installer (Termux, Rust)
│   ├── dovi_parser.ps1         # dovi_tool installer (Windows)
│   └── example_profile.conf    # Documented profile example (all fields)
├── docs/
│   ├── av_info.txt             # Full setup & usage documentation
│   └── av_changelog.txt        # Version history
├── .gitignore
├── LICENSE
└── README.md
```

---

## Requirements

### Termux (Android)

- [Termux](https://f-droid.org/en/packages/com.termux/) from **F-Droid** (not Play Store)
- [Termux:API](https://f-droid.org/en/packages/com.termux.api/) — for wake-lock and notifications
- **FFmpeg 8.1+** recommended (APV decode, ProRes Vulkan, HDR10+ metadata)
- **ffprobe** (included with FFmpeg)
- ExifTool *(optional — required only for DJI GPS extraction)*
- Python3 *(optional — required only for external GPS import)*

```bash
pkg update && pkg upgrade -y
pkg install ffmpeg termux-api -y
pkg install exiftool -y   # optional
pkg install python -y     # optional
```

### Windows

- **FFmpeg** installed and in PATH — download from [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) (full build)
- **PowerShell 5.1+** (included in Windows 10/11)
- ExifTool *(optional — download from [exiftool.org](https://exiftool.org/))*
- Python3 *(optional — download from [python.org](https://www.python.org/downloads/))*

---

## Quick Start

### Termux

```bash
# Set execute permissions
chmod +x src/*.sh

# Launch interactive menu
cd src
./av_launcher.sh
```

### Windows (PowerShell)

```powershell
# Allow script execution (run once as Administrator)
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

# Launch
cd src
.\av_encode.ps1
```

---

## Menu Options

### Termux — `av_launcher.sh` (7 options)
1. Encode video + audio
2. Encode audio only (video stream copy)
3. Analyze media files (analysis + CSV export)
4. Export DJI GPS/telemetry data
5. Import external GPS — GPX/FIT
6. Check video *(standalone av_check.sh)*
7. Exit

### Windows — `av_encode.ps1` (6 options)
1. Encode video + audio
2. Encode audio only (video stream copy)
3. Analyze media files (analysis + CSV 30 fields)
4. Export DJI GPS data *(requires ExifTool)*
5. Import external GPS — GPX/FIT/KML *(requires Python3)*
6. Exit

---

## Key Features — Details

### HDR / Color Science
- **HDR10** — 10-bit encode with static metadata
- **HDR10+** — dynamic metadata preserved via `hdr10plus_tool`
- **Dolby Vision** — stream copy or HDR10 fallback on re-encode
- **LOG formats** — Apple Log, D-Log M (DJI), Samsung Log with LUT support (`.cube`) or best-effort tonemap
- **SDR tonemap** — zscale linearization + Hable tonemap → Rec.709

### Audio Codecs
| Codec | Channels | Auto Bitrate |
|-------|----------|--------------|
| E-AC3 (Dolby Digital Plus) | stereo / 5.1 / 7.1 | 224k / 640k / 1024k |
| AC3 (Dolby Digital) | stereo / 5.1 | 192k / 448k |
| AAC | all | adaptive |
| DTS, TrueHD, FLAC, PCM, Opus | all | — |

### Batch Processing
- **Dry-run mode** — preview full batch without encoding (seconds, not hours)
- **Resume interrupted batch** — `batch_progress.log` tracks completed files; restart skips already-done
- **Skip existing** — files >1MB in output are skipped automatically
- **Batch summary** — per-file compression %, encode time, fastest/slowest report

### Profile System
- Save full configuration to `.conf` file (encoder, CRF, preset, audio, filters, loudnorm, etc.)
- Profiles stored in `Profiles/` folder — auto-detected at next launch
- Cross-platform format: `KEY=VALUE` (bash `source` / PS1 `Get-Content`)

### Video Filters
- **4K Upscale** — Lanczos algorithm (`scale=3840:-2:flags=lanczos`)
- **Vidstab 2-pass** — `vidstabdetect` (shakiness=5, accuracy=15) + `vidstabtransform` (smoothing=10)
- Denoise, deinterlace, crop, resize, FPS conversion, HDR→SDR tonemap

---

## Output Locations

| Platform | Video output | CSV report | DJI export |
|----------|-------------|------------|------------|
| Termux | `/storage/emulated/0/Media/OutputVideos/` | `av_check_report.csv` | `.gpx / .csv / .srt` |
| Windows | `output\` subfolder next to script | `av_check_report.csv` | `.gpx / .csv / .srt` |

---

## Optional Tools Installation

### hdr10plus_tool (HDR10+ metadata)
```bash
# Termux (compiles from Rust source)
./hdr10plus_parser.sh

# Windows (downloads release binary)
.\hdr10plus_parser.ps1
```

### dovi_tool (Dolby Vision)
```bash
# Termux
./dovi_parser.sh

# Windows
.\dovi_parser.ps1
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Permission denied` on `.sh` | `chmod +x src/*.sh` |
| `command not found: ffmpeg` | `pkg install ffmpeg -y` (Termux) or add to PATH (Windows) |
| PS1 script blocked | `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned` |
| `termux-wake-lock` not working | Install Termux:API app from F-Droid |
| DJI files lose GPS metadata | Choose MKV container — DJI tracks incompatible with MP4/MOV |
| PGS/DVDSUB subtitles lost | Normal — incompatible with MP4/MOV. Use MKV to preserve |
| GPS export generates empty files | DJI Action 6 has no internal GPS — requires DJI RC with GPS or DJI Mimo app during recording |

---

## License

[MIT License](LICENSE) — free to use, modify and distribute.

---

## Changelog

See [docs/av_changelog.txt](docs/av_changelog.txt) for full version history.

Current: **v33** — 46 bugs fixed | 95+ features | ~9400 lines of code
