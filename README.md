# AV Encoder Suite

**Cross-platform video encoding suite (bash/PS1) for Termux (Android), Linux, macOS and Windows**

> FFmpeg Smart Adaptive Encoder with HDR/DV/HLG detection, unified telemetry extraction (DJI/GoPro/Sony/Garmin/QuickTime), batch processing, profile system, and unified HW encoding across NVENC/VAAPI/QSV/VideoToolbox/AMF/MediaCodec — v42.1

---

## Features

- **6 video encoders**: H.265/HEVC, H.264/AVC, AV1 (SVT-AV1/libaom), DNxHR, ProRes, APV
- **Hardware encoding (Windows)**: NVENC, QSV, AMF for H.264/H.265/AV1 with GPU capability detection (RTX 40+, Intel Arc, AMD RDNA3+)
- **Hardware encoding (Termux/Android, v38)**: MediaCodec for H.264/H.265/AV1 with SoC whitelist (Snapdragon 8xx 8 Gen 1+, Exynos 21xx-24xx, Tensor G2+, Dimensity 9xxx); HDR10 supported via signaling repair (mastering display + max_cll injected post-encode); unified HDR dialog (DV/HDR10+/HDR10) with SW fallback options per file; HDR10+ dynamic and DV native preservation are SW-only
- **Trim & Concat pipeline** (v36/v37): cut single files, concatenate multiple files (auto demuxer/filter), full trim→concat→encode pipeline + **batch trim** (v37: same cuts on N files), **smart stream copy**, **audio-only mode**, **chapter markers**, **preview thumbnails**, **HDR-aware** (v37: HDR10 auto + HDR10+ opt-in)
- **Automatic HDR detection**: HDR10, HDR10+, Dolby Vision, **HLG (BT.2100 HLG, v39)**, LOG (Apple Log, D-Log M, Samsung Log)
- **HLG end-to-end (v39)**: native HLG signaling preserved across SW (libx265/x264/AV1), HW Windows (NVENC/QSV/AMF), and MediaCodec (Termux); dialog with HLG nativ / HLG→HDR10 / HLG→SDR / Stream copy / Skip; LOG → HLG via dedicated LUT category (`Luts/hlg_<brand>_*.cube`)
- **Telemetry Unified (v40)**: multi-brand telemetry extraction (DJI / GoPro GPMF / Sony NMEA / Garmin VIRB FIT / QuickTime ISO 6709) with auto brand detection and **normalized cross-brand CSV** (18-column schema: timestamp, lat/lon, alt_m, speed_mps/kmh, heading, gforce/gyro, temp, hr, cadence, power, source_brand)
- **Audio encoding**: AAC, AC3, E-AC3 (Dolby Digital Plus), DTS, TrueHD, FLAC, PCM, Opus
- **Video filters**: 4K upscale (Lanczos), vidstab 2-pass stabilization, denoise, deinterlace, crop, resize, FPS conversion
- **Audio normalization**: EBU R128 loudnorm (2-pass, -24 LUFS)
- **Profile system**: save/load full encode config as `.conf` files (cross-platform KEY=VALUE)
- **Batch processing**: resume interrupted batch, skip existing, dry-run preview, detailed summary
- **Smart stream copy** (v38): auto-detect when source codec matches target → opt-in skip re-encode (instant, lossless, prevents quality loss)
- **Unified progress bar** (v38): all encode flows show codec-labeled progress (HEVC/H264/AV1/DNxHR/etc.) with FPS, ETA, percent; stderr tail on error for instant diagnosis
- **Media analysis**: `av_check` with 50-field CSV export, I/O comparison
- **GPS import**: external GPX/FIT/KML → CSV, SRT, GPX, KML conversion

---

## Platforms

| Platform | Scripts | Requirements |
|----------|---------|--------------|
| **Termux (Android)** | `.sh` (bash) | FFmpeg 8.1+, ffprobe, Termux:API |
| **Linux** (v41) | `.sh` (bash 4+) | FFmpeg 8.1+, python3, exiftool; optional: `notify-send` (libnotify), `xdg-open` |
| **macOS** (v41) | `.sh` (bash 4+) | `brew install bash ffmpeg python3 exiftool` (default macOS bash 3.2 NOT supported); optional: `coreutils`, `hdr10plus_tool`, `dovi_tool` |
| **Windows** | `.ps1` (PowerShell) | FFmpeg in PATH, PowerShell 5.1+ |

**v41 cross-platform bash**: paths are auto-detected — Termux keeps `/storage/emulated/0/Media/...`; Linux/macOS create folders next to scripts (`$SCRIPT_DIR/InputVideos`, etc.). Wrappers in `av_common.sh` abstract GNU vs BSD coreutils differences (stat, sed, nproc, readlink, grep -P, date), wake-lock (caffeinate on macOS), and notifications (notify-send / osascript).

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
│   ├── av_trimconcat.sh        # Trim & Concat pipeline (v36: trim / concat / full pipeline)
│   ├── av_check.sh             # Media analysis + CSV export (Termux)
│   ├── av_check.ps1            # Media analysis + CSV export (Windows)
│   ├── av_encode.ps1           # All-in-one PowerShell script (Windows; encode + Trim/Concat)
│   ├── av_telemetry.sh         # Unified telemetry extractor (DJI/GoPro/Sony/Garmin/QuickTime)
│   ├── av_telemetry.ps1        # PS1 mirror standalone (v40)
│   ├── av_extractor_gps.sh     # External GPS import GPX/FIT/KML
│   ├── av_extractor_gps.ps1    # PS1 mirror standalone (v40)
│   ├── profiles/
│   │   ├── example_profile.conf    # Documented profile example (all fields)
│   │   └── dji_action6/        # DJI Osmo Action 6 preset profiles
│   │       ├── DJI_Action6_Airsoft_Indoor.conf
│   │       ├── DJI_Action6_Airsoft_Outdoor.conf
│   │       ├── DJI_Action6_Moto_Outdoor.conf
│   │       ├── DJI_Action6_Moto_Cinematic.conf   # D-Log M + LUT
│   │       └── DJI_Action6_DLogM_Outdoor.conf    # D-Log M + LUT
│   └── tools/
│       ├── hdr10plus_parser.sh     # hdr10plus_tool installer (Termux, Rust)
│       ├── hdr10plus_parser.ps1    # hdr10plus_tool installer (Windows)
│       ├── dovi_parser.sh          # dovi_tool installer (Termux, Rust)
│       ├── dovi_parser.ps1         # dovi_tool installer (Windows)
│       ├── exiftool_update.sh      # ExifTool smart updater (Termux)
│       └── exiftool_update.ps1     # ExifTool smart updater (Windows)
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
- ExifTool *(required for DJI + QuickTime telemetry; optional otherwise)*
- Python3 *(required for GoPro/Sony/Garmin telemetry and external GPS import)*

```bash
pkg update && pkg upgrade -y
pkg install ffmpeg termux-api -y
pkg install exiftool -y   # for DJI/QuickTime telemetry
pkg install python -y     # for GoPro/Sony/Garmin/external GPS
```

### Windows

- **FFmpeg** installed and in PATH — download from [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) (full build)
- **PowerShell 5.1+** (included in Windows 10/11)
- ExifTool *(required for DJI + QuickTime telemetry — download from [exiftool.org](https://exiftool.org/))*
- Python3 *(required for GoPro/Sony/Garmin telemetry and external GPS — download from [python.org](https://www.python.org/downloads/))*

---

## Quick Start

### Termux

```bash
# Set execute permissions
chmod +x src/*.sh src/tools/*.sh

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
4. Telemetry video *(v40 — DJI / GoPro / Sony / Garmin / QuickTime)*
5. Import external GPS — GPX/FIT/KML
6. Trim & Concat *(v36/v37 — trim / concat / pipeline / batch trim)*
7. Exit

### Windows — `av_encode.ps1` (7 options)
1. Encode video + audio
2. Encode audio only (video stream copy)
3. Analyze media files (analysis + CSV 30 fields)
4. Telemetry video *(v40 — DJI / GoPro / Sony / Garmin / QuickTime)*
5. Import external GPS — GPX/FIT/KML *(requires Python3)*
6. Trim & Concat *(v36/v37 — trim / concat / pipeline / batch trim)*
7. Exit

---

## Key Features — Details

### HDR / Color Science
- **HDR10** — 10-bit encode with static metadata
- **HDR10+** — dynamic metadata preserved via `hdr10plus_tool`
- **Dolby Vision** — stream copy or HDR10 fallback on re-encode
- **HLG (v39)** — native BT.2100 HLG (transfer=arib-std-b67) across SW + HW + MediaCodec; per-file dialog (HLG nativ / HLG→HDR10 / HLG→SDR / Stream copy / Skip)
- **LOG formats** — Apple Log, D-Log M (DJI), Samsung Log with LUT support (`.cube`) or best-effort tonemap; v39 adds Log → HLG conversion via `Luts/hlg_<brand>_*.cube` category
- **SDR tonemap** — zscale linearization + Hable tonemap → Rec.709

### Audio Codecs
| Codec | Channels | Auto Bitrate |
|-------|----------|--------------|
| E-AC3 (Dolby Digital Plus) | stereo / 5.1 / 7.1 | 224k / 640k / 1024k |
| AC3 (Dolby Digital) | stereo / 5.1 | 192k / 448k |
| AAC | all | adaptive |
| DTS, TrueHD, FLAC, PCM, Opus | all | — |

### Batch Processing
- **Preserve folder structure** — recursive scan with subfolder recreation in output
- **Dry-run mode** — preview full batch without encoding (seconds, not hours)
- **Resume interrupted batch** — `batch_progress.log` tracks completed files; restart skips already-done
- **Skip existing** — files >1MB in output are skipped automatically
- **Batch summary** — per-file compression %, encode time, fastest/slowest report, folder count

### Profile System
- Save full configuration to `.conf` file (encoder, CRF, preset, audio, filters, loudnorm, etc.)
- User profiles stored in `UserProfiles/` folder — auto-detected at next launch
- **Built-in profiles** for DJI Osmo Action 6 (airsoft, moto, cinematic, D-Log M)
- D-Log M profiles include automatic LUT validation — warns if `.cube` file missing
- Cross-platform format: `KEY=VALUE` (bash `source` / PS1 `Get-Content`)

### Video Filters
- **4K Upscale** — Lanczos algorithm (`scale=3840:-2:flags=lanczos`)
- **Vidstab 2-pass** — `vidstabdetect` (shakiness=5, accuracy=15) + `vidstabtransform` (smoothing=10)
- Denoise, deinterlace, crop, resize, FPS conversion, HDR→SDR tonemap

### Telemetry Unified (v40)
- **Auto brand detection** per file (codec_tag scan + ISO 6709 fallback): DJI, GoPro, Sony, Garmin VIRB, QuickTime (Apple/Samsung/Pixel/OnePlus/Xiaomi)
- **GPMF parser** (GoPro) — KLV binary, DEVC→STRM nested, GPS5 5×int32 with SCAL factors, GPSU/GPSF/GPSP/TMPC; filters no-fix points
- **NMEA 0183 parser** (Sony) — `$GPRMC` + `$GPGGA` (+ `$GNRMC`/`$GNGGA`), ddmm.mmmm → decimal, knots → m/s
- **FIT parser** (Garmin VIRB) — semicircles → degrees, altitude (raw/5)−500, speed raw/1000, plus HR/cadence/power/temp
- **QuickTime ISO 6709** — single-point GPS via ExifTool atom (`com.apple.quicktime.location.ISO6709`)
- **Normalized cross-brand CSV** (`<name>_norm.csv`, 18 columns): timestamp, lat, lon, alt_m, speed_mps, speed_kmh, heading_deg, gforce_x/y/z, gyro_x/y/z, temp_c, hr_bpm, cadence_rpm, power_w, source_brand
- **6 menu options**: Standard / Full / SRT / All / Raw streams / Strip metadata (DJI sub-dialog: dbgi-only / djmd+dbgi / total)
- **Excluded v40**: Insta360, Yi/Akaso/SJCAM. **Burn-in HUD** and **Embed lossless telemetry** planned for later versions.

### Cross-platform bash (v41)

- Single `av_launcher.sh` runs on Termux, Linux and macOS — `detect_platform()` in `av_common.sh` auto-detects platform via `uname -s` + Termux markers (`/data/data/com.termux`, `$TERMUX_VERSION`).
- **Path resolution**: Termux keeps `/storage/emulated/0/Media/...` (zero changes); Linux/macOS use `$SCRIPT_DIR/InputVideos`, `$SCRIPT_DIR/OutputVideos`, etc. (folders next to scripts, mirroring the PS1 layout).
- **Wrappers** abstract GNU vs BSD coreutils: `av_nproc`, `av_stat_mtime`, `av_stat_size`, `av_sed_inplace`, `av_readlink_f`, `av_grep_perl`, `av_date_to_epoch`.
- **Wake-lock cross-platform**: `av_wake_lock` / `av_wake_unlock` (Termux: `termux-wake-lock`; macOS: `caffeinate -dimsu` background; Linux: no-op best effort).
- **Notifications**: `av_notify_done` (Termux: `termux-notification`; Linux: `notify-send`; macOS: `osascript display notification`).
- **Open output folder**: `av_open_path` (Termux: `termux-open`; Linux: `xdg-open`; macOS: `open`).
- **Bash 4+ enforced** at startup with platform-specific install hint (macOS default 3.2 refused; `brew install bash` required).
- **MediaCodec** (Termux Android only) auto-skipped on Linux/macOS — silent fallback to SW encode.
- **HDR10+/DV tools**: `tools/hdr10plus_parser.sh` and `tools/dovi_parser.sh` build from source on Termux; on macOS hint to `brew install hdr10plus_tool` / `brew install dovi_tool`; on Linux hint to `cargo install`.

### HW encoding generalizat (v42)

- **5 backend-uri HW** (în plus față de MediaCodec Termux v38 și HW PowerShell v35):
  - **NVENC** (NVIDIA, Linux) — h264/hevc/av1; AV1 doar RTX 40+/Ada
  - **VAAPI** (Intel iGPU + AMD, Linux) — via `/dev/dri/renderD*`
  - **QSV** (Intel, Linux) — HDR10 pe Tiger Lake+/Alchemist+
  - **VideoToolbox** (macOS) — h264/hevc/av1/prores; AV1 doar Apple Silicon M3+; HDR10+HLG full pe AS
  - **AMF** (AMD, Linux experimental, v42.1) — h264/hevc/av1; AV1 pe RDNA3+ (RX 7000/8000 + iGPU Phoenix/Hawk Point/Strix Point — Radeon 740M-890M); `-usage transcoding` + `-profile:v main` pentru av1_amf; confirm prompt în launcher (bypass cu `HW_FORCE=1`); `AMF_GPU_ARCH` afișat în eticheta meniului
- **Detection cross-platform**: `detect_all_hw_caps()` în `av_common.sh` apelează detector-ul corect per platformă (lspci/nvidia-smi/sysctl/getprop)
- **UX uniform — preset table 1-7**: Ultrafast / Faster / Fast / **Quality (default 4)** / Slow / Slower / Veryslow. Tabelul afișează coloane filtrate per platformă (Termux→MediaCodec; macOS→VideoToolbox; Linux→NVENC+VAAPI+QSV+AMF), coloana activă highlighted cu `>` + galben, restul dim. Pe terminale înguste (`tput cols`) se afișează doar coloana activă.
- **Preset mapping**: NVENC `p1..p7` | VAAPI `q1..q7` | QSV `veryfast..veryslow` | VideoToolbox `q:v 80..50` | AMF `speed/balanced/quality` | MediaCodec `60%..150%` bitrate
- **HDR generalizat** (`show_hdr_hw_dialog`): mirror al dialogului MediaCodec pentru toate backend-urile, 4 source types (DV / HDR10+ / HLG / HDR10) cu opțiuni `sw_full` (recomandat DV/HDR10+) / `sw_degraded` (strip enhancement) / `hw_hdr10` (10-bit BT.2020 PQ) / `hw_hlg` (HLG nativ) / `hw_sdr` (tonemap) / skip
- **Profile fields noi**: `HW_BACKEND` (sw/nvenc/vaapi/qsv/videotoolbox/amf/mediacodec) + `HW_PRESET_SLOT` (1-7) + `HW_HDR_POLICY` (bypass dialog) + `HW_FORCE` (bypass detection pentru GPU-uri ne-detectate)
- **Back-compat**: MediaCodec păstrează dialog-ul HDR dedicat v38/v39 (HDR10+/DV degraded specifice); USE_MEDIACODEC=1 setat automat când HW_BACKEND=mediacodec

### Trim & Concat (v36/v37)
- **Trim** — cut a single file with stream copy (instant, ±1-2s keyframe accuracy) or re-encode (frame-accurate); multi-cut loop per file
- **Concat** — concatenate multiple files; auto compat check (codec/resolution/fps/pix_fmt) picks demuxer (stream copy, lossless) or filter (re-encode); sort by name/date/size/manual
- **Pipeline** — full trim → concat → encode in 3 explicit passes; select files, mark which need trimming, set encode params once (x265/x264/AV1, CRF, preset, audio)
- **Batch trim** (v37) — apply the same cut points to N files at once (e.g., strip intro/outro from a session); skip files shorter than end time, summary OK/FAIL/SKIP
- **Smart stream copy** (v37) — Pipeline detects when source codec already matches target codec and offers to skip re-encode entirely (instant, lossless)
- **Audio-only encoding** (v37) — Pipeline mode that re-encodes only audio while keeping video stream copy (instant for video, useful for codec changes); transparent fallback to full re-encode when concat filter is required
- **Chapter markers** (v37) — Pipeline can auto-generate FFMETADATA1 chapters (1 chapter per segment), injected via `-map_chapters`
- **Preview thumbnails** (v37) — opt-in 3-frame tile (start/mid/end at 5%/50%/95%) per file, 320p hstack PNG saved in temp; available in Concat and Pipeline
- **HDR-aware Pipeline** (v37) — auto-detects HDR mode (sdr/hdr10/hdr10plus/hlg/dv/mixed) and injects proper x265 HDR10 params (`pix_fmt yuv420p10le`, `color_primaries bt2020`, `x265-params hdr10=1:hdr10-opt=1:...`); HDR10+ opt-in with hdr10plus_tool extraction and transparent fallback to HDR10 static; DV → HDR10 baseline fallback
- **Real-time progress bar** (v37) — `-progress` based watcher with FPS / ETA / percent for all heavy ffmpeg calls; stderr tail on non-zero exit
- **Flexible time input** — `45` / `1:30` / `1:05:30` all parsed to seconds
- **Range selection** — `all` / `1,3,5` / `1-5` / `1-3,7,10-12`
- **Temp management** — lazy-created `Temp/` folder with per-run subdirs (`trim_*` / `concat_*` / `pipeline_*` / `preview_*`); residual cleanup prompt on submenu entry (>24h default)

---

## Output Locations

| Platform | Video output | CSV report | Telemetry export |
|----------|-------------|------------|------------------|
| Termux | `/storage/emulated/0/Media/OutputVideos/` | `av_check_report.csv` | `.gpx / _basic.csv / _FULL.csv / _norm.csv / .srt` |
| Windows | `output\` subfolder next to script | `av_check_report.csv` | `.gpx / _basic.csv / _FULL.csv / _norm.csv / .srt` |

---

## Optional Tools — `src/tools/`

### hdr10plus_tool (HDR10+ metadata)
```bash
# Termux (compiles from Rust source)
./tools/hdr10plus_parser.sh

# Windows (downloads release binary)
.\tools\hdr10plus_parser.ps1
```

### dovi_tool (Dolby Vision)
```bash
# Termux
./tools/dovi_parser.sh

# Windows
.\tools\dovi_parser.ps1
```

### ExifTool updater
```bash
# Termux (smart: pkg or manual build)
./tools/exiftool_update.sh

# Windows (downloads latest .exe)
.\tools\exiftool_update.ps1
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Permission denied` on `.sh` | `chmod +x src/*.sh src/tools/*.sh` |
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

## Support

If you find this project useful, consider a small donation — it helps keep the development going!

[💙 Donate via PayPal](https://paypal.me/TiberiuDobrescu)

---

## Changelog

See [docs/av_changelog.txt](docs/av_changelog.txt) for full version history.

Current: **v42** — 49 bugs fixed | 160+ features | ~16500 lines of code
