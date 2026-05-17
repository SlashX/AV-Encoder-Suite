# AV Encoder Suite

Cross-platform video encoding suite for **Termux (Android), Linux, macOS and Windows** — bash + PowerShell. Smart FFmpeg wrapper with full HDR/DV/HLG awareness, 6 HW backends, unified telemetry and metadata-only HDR/DV transforms.

**v45** — 49 bugs fixed · 178+ features · ~18 550 LoC · 62 files

---

## At a Glance

| | |
|---|---|
| **Video** | HEVC · H.264 · AV1 (SVT-AV1 / libaom) · DNxHR · ProRes · APV |
| **HW backends** | NVENC · QSV · VAAPI · VideoToolbox · AMF · MediaCodec |
| **HDR** | HDR10 · HDR10+ · Dolby Vision (P5/P7/P8.1 HEVC + P10 AV1) · HLG · LOG |
| **Audio encode** | AAC · Opus · FLAC · E-AC3 · LPCM |
| **Audio passthrough** | AC3 · TrueHD · DTS · DTS-HD (auto stream copy) |
| **Telemetry** | DJI · GoPro GPMF · Sony NMEA · Garmin VIRB FIT · QuickTime ISO 6709 |
| **Workflows** | Encode · Audio-only · Trim & Concat · HDR/DV tools · Telemetry · GPS · Analysis |

---

## Platforms

| Platform | Scripts | Setup |
|---|---|---|
| Termux (Android) | `.sh` | `pkg install ffmpeg termux-api exiftool python` |
| Linux | `.sh` (bash 4+) | distro pkg: `ffmpeg python3 exiftool` |
| macOS | `.sh` (bash 4+) | `brew install bash ffmpeg python3 exiftool` |
| Windows | `.ps1` (PS 5.1+) | FFmpeg from [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) in PATH |

`detect_platform()` discriminates Termux/Linux/macOS at startup; wrappers abstract GNU vs BSD coreutils, wake-lock and notifications.

---

## Video Encoders

| Encoder | Bitdepth | HDR10 | HDR10+ | DV | HLG | LOG |
|---|---|---|---|---|---|---|
| **libx265** | 8/10 | ✅ | ✅ inline | ✅ 8.1 preserve/convert/copy (v45) | ✅ | ✅ |
| **libx264** | 8/10 | ⚠ basic | — | — | ⚠ native only | ✅ |
| **SVT-AV1** | 10 | ✅ | ✅ inline (v1.5+) | ✅ P10 preserve (v44) | ✅ | ✅ |
| **libaom-av1** | 10 | ✅ | fallback HDR10 | — | ✅ | ✅ |
| **DNxHR** | 8/10 | — | — | — | — | mezzanine |
| **ProRes** KS | 10/12 | ✅ HQ/4444 | — | — | ✅ | ✅ |
| **APV** (FF 8.1+) | 10 / 4:2:2 / 4:4:4 | ✅ | — | — | — | ✅ |

DV preserve: extract source RPU codec-aware (`dovi_tool` HEVC / `av1dovi_tool` AV1) → re-encode HDR10 base → post-encode RPU inject → re-mux audio.

---

## Hardware Encoding

| Backend | Platform | H.264 | H.265 | AV1 (HW) | HDR10 | Notes |
|---|---|---|---|---|---|---|
| **NVENC** | Win + Linux | ✅ | ✅ | RTX 40+ / Ada | ✅ 10-bit | `p1..p7` |
| **QSV** | Win + Linux | ✅ | ✅ | Alchemist+ | Tiger Lake+ | `veryfast..veryslow` |
| **VAAPI** | Linux | ✅ | ✅ | ATS / Battlemage | ✅ | `/dev/dri/renderD*`, `q1..q7` |
| **VideoToolbox** | macOS | ✅ | ✅ + ProRes | M3+ Apple Silicon | AS only (+ HLG) | `q:v 80..50` |
| **AMF** | Win + Linux exp (v42.1) | ✅ | ✅ | RDNA3+ (RX 7000/8000 + 740M–890M) | ✅ | `speed/balanced/quality` |
| **MediaCodec** | Termux/Android | ✅ | ✅ + HDR10 repair | SoC-dependent | via `hevc_metadata` bsf | `60%..150%`, SoC whitelist |

Uniform preset table `1..7` (Ultrafast → Veryslow, default `4=Quality`) across all backends. `show_hdr_hw_dialog` per-source-type (DV / HDR10+ / HLG / HDR10) with `sw_full` / `sw_degraded` / `hw_hdr10` / `hw_hlg` / `hw_sdr` / skip. Bypass via `HW_HDR_POLICY`.

---

## HDR / Color Science

| Format | Encode | Stream copy | Cross-codec | Transform-only |
|---|---|---|---|---|
| **HDR10** | all encoders | ✅ | HEVC↔AV1 | — |
| **HDR10+** dynamic | HEVC + SVT-AV1 v1.5+ | ✅ | all 4 directions | synthesize DV from HDR10+ (v45) |
| **Dolby Vision** | HEVC 8.1 (v45) · AV1 P10 (v44) | ✅ | HEVC↔AV1 (v44/v45) | profile transform 5/7→8.1, 8.1↔10 |
| **HLG** | all encoders + HW + MediaCodec (v39) | ✅ | ✅ | — |
| **LOG** (Apple/D-Log M/Samsung) | `.cube` LUT or tonemap | ✅ | Log→HDR10/HLG/Rec.709 | — |
| **SDR tonemap** | Hable zscale → Rec.709 | — | — | — |

- **Triple-layer hybrid** — DV 8.1 (HEVC) or DV P10 (AV1) + HDR10 base + HDR10+ dynamic in one bitstream; v45 preserves both layers when source has DV + HDR10+ embedded
- **HDR10+ → DV hybrid** (v45, transform-only) — extract HDR10+ JSON → synthesize DV RPU → inject → re-mux; 100% lossless on video

---

## Audio

### Encoding

| Codec | Default | Surround auto | Container |
|---|---|---|---|
| **AAC** | 192k | 5.1 → 384k · 7.1 → 768k | all |
| **Opus** | 128k | 5.1 → 256k · 7.1 → 512k | mkv/webm |
| **E-AC3** | 224k stereo | 5.1 → 640k · 7.1 → 1024k | ❌ MOV |
| **FLAC** lossless | level 8 | passthrough | mkv only |
| **LPCM** | 16/24/32 le | passthrough | all |

### Stream-copy passthrough

| Codec | Behaviour |
|---|---|
| **AC3** | preserved 1:1 |
| **TrueHD** | preserved 1:1 (+ HD warning) |
| **DTS / DTS-HD MA** | preserved 1:1 (+ HD warning) |

**Loudnorm** EBU R128 two-pass to -24 LUFS, optional per batch.

---

## Telemetry (v40 Unified)

| Brand | Detection | Parser | Norm CSV | SRT |
|---|---|---|---|---|
| **DJI** | `djmd`/`dbgi` | ExifTool | ✅ (Python post) | ✅ |
| **GoPro** | `gpmd` | GPMF KLV (Python) | ✅ | ✅ |
| **Sony Action Cam** | `nmea` | NMEA 0183 (Python) | ✅ | ✅ |
| **Garmin VIRB** | `fdsc` | FIT (Python) | ✅ + HR/cadence/power | ✅ |
| **QuickTime** | `com.apple.quicktime.location.ISO6709` | ExifTool | ✅ (single point) | ✅ |

- **Norm CSV** (18 cols) — `timestamp,lat,lon,alt_m,speed_mps,speed_kmh,heading_deg,gforce_xyz,gyro_xyz,temp_c,hr_bpm,cadence_rpm,power_w,source_brand`
- **DJI strip** sub-modes — dbgi-only · djmd+dbgi · total
- **Excluded by design** — Insta360, Yi/Akaso/SJCAM
- **External GPS import** — GPX/FIT/KML → CSV/SRT/GPX/KML via `av_extractor_gps`

---

## Workflows

1. **Encode** — per-file HDR/DV/HLG/LOG dialogs; recursive scan with `PRESERVE_FOLDER_STRUCTURE=1`
2. **Audio-only re-encode** — video stream copy + audio re-encode
3. **Media analysis** (`av_check`) — 30-50 field CSV
4. **Telemetry** — 6 modes: Standard / Full / SRT / All / Raw / Strip
5. **External GPS** — GPX/FIT/KML → CSV/SRT
6. **Trim & Concat** — single trim · concat (auto demuxer/filter) · pipeline 3-pass · batch trim · HDR-aware
7. **HDR/DV Tools** (v44/v45, metadata-only, no re-encode):

   | Option | Action |
   |---|---|
   | Transform RPU | DV profile convert (5/7→8.1, force 8.1, 8.1↔10) |
   | Remux container | MKV ↔ MP4/MOV + `tag:v hvc1/av01/avc1` + faststart + preflight |
   | Inspect | ffprobe + `dovi_tool info` + HDR10+ scene count |
   | HDR10+ → DV hybrid (v45) | Synthesize DV RPU from HDR10+ → inject → re-mux |

---

## Project Structure

```
AV-Encoder-Suite/
├── src/
│   ├── av_launcher.sh          # Interactive main menu (Termux/Linux/macOS)
│   ├── av_common.sh            # Shared functions (HDR, DJI, audio, progress, HW dispatch)
│   ├── av_encoder_x265.sh      # H.265/HEVC encoder
│   ├── av_encoder_x264.sh      # H.264/AVC encoder
│   ├── av_encoder_av1.sh       # AV1 encoder (SVT-AV1 / libaom)
│   ├── av_encoder_dnxhr.sh     # DNxHR encoder (Avid mezzanine)
│   ├── av_encoder_prores.sh    # ProRes encoder (Apple professional)
│   ├── av_encoder_apv.sh       # APV encoder (Samsung, ffmpeg 8.1+)
│   ├── av_encoder_audio.sh     # Audio-only re-encode (video stream copy)
│   ├── av_trimconcat.sh        # Trim & Concat pipeline (v36/v37)
│   ├── av_hdr_dv_tools.sh      # HDR/DV tools submenu (v44 + v45)
│   ├── av_check.sh             # Media analysis + CSV export (Termux/Linux/macOS)
│   ├── av_check.ps1            # Media analysis + CSV export (Windows)
│   ├── av_encode.ps1           # All-in-one PowerShell script (Windows)
│   ├── av_telemetry.sh         # Unified telemetry extractor (5 brands)
│   ├── av_telemetry.ps1        # PS1 mirror standalone
│   ├── av_extractor_gps.sh     # External GPS import GPX/FIT/KML
│   ├── av_extractor_gps.ps1    # PS1 mirror standalone
│   ├── profiles/
│   │   ├── example_profile.conf       # Documented profile example (all fields)
│   │   └── dji_action6/        # DJI Osmo Action 6 preset profiles
│   │       ├── DJI_Action6_Airsoft_Indoor.conf
│   │       ├── DJI_Action6_Airsoft_Outdoor.conf
│   │       ├── DJI_Action6_Moto_Outdoor.conf
│   │       ├── DJI_Action6_Moto_Cinematic.conf   # D-Log M + LUT
│   │       └── DJI_Action6_DLogM_Outdoor.conf    # D-Log M + LUT
│   └── tools/
│       ├── hdr10plus_parser.sh     # hdr10plus_tool HEVC installer (quietvoid; Rust)
│       ├── hdr10plus_parser.ps1    # hdr10plus_tool HEVC installer (Windows, prebuilt)
│       ├── av1hdr10plus_parser.sh  # v44 — sven-pke fork installer (AV1 OBU); binary `av1hdr10plus_tool`
│       ├── av1hdr10plus_parser.ps1 # v44 — sven-pke fork installer (Windows, cargo build)
│       ├── dovi_parser.sh          # dovi_tool HEVC installer (quietvoid; Rust)
│       ├── dovi_parser.ps1         # dovi_tool HEVC installer (Windows, prebuilt)
│       ├── av1dovi_parser.sh       # v44 — sven-pke fork installer (AV1 RPU); binary `av1dovi_tool`
│       ├── av1dovi_parser.ps1      # v44 — sven-pke fork installer (Windows, cargo build)
│       ├── exiftool_update.sh      # ExifTool smart updater (Termux/Linux/macOS)
│       ├── exiftool_update.ps1     # ExifTool smart updater (Windows)
│       ├── profile_diff.sh         # v43 — compare two .conf profiles (bash)
│       └── profile_diff.ps1        # v43 — compare two .conf profiles (PS1 mirror)
├── docs/
│   ├── av_info.txt             # Full setup & usage documentation
│   └── av_changelog.txt        # Version history
├── tests/                      # bash + PS1 test framework (v43)
│   ├── framework.sh / .ps1     # Assertion library
│   ├── run_tests.sh / .ps1     # Discover + run test_*.{sh,ps1}; per-test log + summary
│   ├── _helpers.ps1            # AST-based function importer for PS1 tests
│   ├── fixtures/
│   │   ├── generate_samples.sh / .ps1   # ffmpeg-driven synthetic samples (idempotent)
│   │   └── samples/            # Generated samples (gitignored)
│   ├── unit/                   # Pure-logic tests (no ffmpeg required)
│   ├── integration/            # ffmpeg/ffprobe/python-dependent (auto-skip on missing deps)
│   └── results/                # Per-test logs (gitignored)
├── .gitignore
├── LICENSE
└── README.md
```

---

## Quick Start

```bash
# Termux / Linux / macOS
chmod +x src/*.sh src/tools/*.sh
cd src && ./av_launcher.sh
```

```powershell
# Windows
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned   # once
cd src; .\av_encode.ps1
```

### Tests

```bash
bash tests/fixtures/generate_samples.sh && bash tests/run_tests.sh
.\tests\fixtures\generate_samples.ps1; .\tests\run_tests.ps1
```

Tests dependent on ffmpeg/ffprobe/python3/exiftool auto-skip when the binary is missing.

---

## Menu

1. Encode video + audio
2. Encode audio only (video stream copy)
3. Analyze media (CSV export)
4. Telemetry — DJI / GoPro / Sony / Garmin / QuickTime
5. Import external GPS — GPX/FIT/KML
6. Trim & Concat — trim / concat / pipeline / batch
7. **HDR/DV tools** — transform RPU / remux / inspect / HDR10+ → DV (v45)
8. Exit

---

## Profile System (v43)

`KEY=VALUE` files (bash `source` / PS1 `Get-Content`); user profiles in `UserProfiles/`. Built-in DJI Osmo Action 6 presets (airsoft indoor/outdoor, moto outdoor/cinematic, D-Log M). Schema validation per key (enum / regex / int / path) before load; unknown keys are forward-compat warnings.

**EXTENDS inheritance** — `EXTENDS=parent_name` resolves through sibling dir → `UserProfiles/` → `src/profiles/*/`; root→leaf override; cycle detection + depth limit 5.

**Bypass fields for batches**: `HW_HDR_POLICY`, `MEDIACODEC_HDR_POLICY`, `DOVI_PRESERVE_POLICY` (v45), `HW_FORCE`.

**profile_diff CLI** — `src/tools/profile_diff.{sh,ps1} A.conf B.conf` — exit `0` identical / `1` different / `2` invalid.

---

## Output Locations

| Platform | Video | CSV | Telemetry |
|---|---|---|---|
| Termux | `/storage/emulated/0/Media/OutputVideos/` | `av_check_report.csv` | `.gpx / _basic.csv / _FULL.csv / _norm.csv / .srt` |
| Linux / macOS | `$SCRIPT_DIR/OutputVideos/` | same | same |
| Windows | `output\` next to script | same | same |

---

## Optional Tools (`src/tools/`)

| Tool | Purpose | bash | PS1 |
|---|---|---|---|
| `hdr10plus_tool` | HDR10+ HEVC (quietvoid) | `hdr10plus_parser.sh` | `hdr10plus_parser.ps1` (prebuilt) |
| `av1hdr10plus_tool` | HDR10+ AV1 (sven-pke fork) | `av1hdr10plus_parser.sh` (cargo) | `av1hdr10plus_parser.ps1` (rustup + git) |
| `dovi_tool` | DV RPU HEVC (quietvoid) | `dovi_parser.sh` | `dovi_parser.ps1` (prebuilt) |
| `av1dovi_tool` | DV RPU AV1 (sven-pke fork) | `av1dovi_parser.sh` (cargo) | `av1dovi_parser.ps1` (rustup + git) |
| ExifTool updater | Latest version | `exiftool_update.sh` | `exiftool_update.ps1` |
| Profile diff | Compare `.conf` files | `profile_diff.sh A B` | `profile_diff.ps1 A B` |

AV1 forks install with renamed binaries (`av1dovi_tool`, `av1hdr10plus_tool`) so they coexist with HEVC upstream.

---

## Troubleshooting

| Problem | Solution |
|---|---|
| `Permission denied` on `.sh` | `chmod +x src/*.sh src/tools/*.sh` |
| `command not found: ffmpeg` | `pkg install ffmpeg` / `brew install ffmpeg` / `apt install ffmpeg` / PATH (Win) |
| PS1 script blocked | `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned` |
| Termux wake-lock fails | Install Termux:API from F-Droid (not Play Store) |
| DJI files lose GPS | Use MKV — DJI tracks incompatible with MP4/MOV |
| PGS/DVDSUB subs lost | Normal in MP4/MOV; use MKV |
| GPS export empty | DJI Action 6 has no internal GPS — needs DJI RC or DJI Mimo |
| macOS bash startup fails | Default 3.2 unsupported — `brew install bash` |
| AV1 HDR10+ inline missing | Requires SVT-AV1 v1.5+; libaom falls back to HDR10 static |
| `av1dovi_tool` not found | `./tools/av1dovi_parser.sh` (cargo build from sven-pke fork) |

---

## License

[MIT License](LICENSE) — free to use, modify and distribute.

---

## Support

If you find this project useful, consider a small donation — it helps keep development going.

[💙 Donate via PayPal](https://paypal.me/TiberiuDobrescu)

---

## Changelog

See [docs/av_changelog.txt](docs/av_changelog.txt) for full version history.

Current: **v45** — 49 bugs fixed · 178+ features · ~18 550 LoC · 62 files
