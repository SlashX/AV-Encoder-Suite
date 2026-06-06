# AV Encoder Suite

Cross-platform video encoding suite for **Termux (Android), Linux, macOS and Windows** — bash + PowerShell.

**v64** — 115 bugs fixed · 236+ features · ~42 000 LoC · 132 files

---

## Overview

A smart FFmpeg wrapper for real-world video work — HDR/Dolby Vision detection and preservation, codec-aware tool dispatch (HEVC vs AV1), adaptive CRF per resolution and encoder, batch encoding with resume, action-cam telemetry extraction, and metadata-only DV/HDR10+ transforms. Built around an interactive menu that asks one targeted question per file (e.g. *"this source is DV Profile 5 — preserve, convert to HDR10, or stream-copy?"*) instead of hand-crafting ffmpeg flags.

The same workflow runs identically across all four platforms — bash and PowerShell branches are mirrored feature-for-feature, and `.conf` profiles keep settings reproducible for batches and CI. The goal is to keep Dolby Vision RPU, HDR10+ dynamic metadata, 10-bit pixel formats and color signaling intact end-to-end — the kind of detail raw `ffmpeg` calls usually mishandle without very specific flags.

## Highlights

- **Dolby Vision preserve end-to-end** — HEVC↔AV1 cross-codec (P5/P7/P8.1↔P10), SW + all 6 HW backends (v46), HDR10+ co-existence when source carries both layers
- **HDR-aware everywhere** — HDR10 · HDR10+ dynamic · DV · HLG · LOG (Apple / D-Log M / Samsung) detected automatically; per-source dialogs propose the right transform
- **DJI Osmo Action 6 D-Log M detection** (v62) — Action 6 reports `bt709` identically for Normal and D-Log M (the LOG curve lives only in the pixels); the real flag sits in the `djmd` telemetry track, which exiftool doesn't expose. A shared stdlib reader parses the djmd protobuf and tags D-Log M correctly so the LOG dialog (apply Rec.709 LUT / keep LOG) shows up. LOG/LUT flow also hardened: 10-bit detection via pixel-format fallback, HLG no longer misread as LOG, correct Rec.709 tagging across all containers (MP4/MOV/MKV — `setparams` after `lut3d`, since the filter rewrites pixels but not color metadata)
- **6 HW backends, uniform UX** — NVENC · QSV · VAAPI · VideoToolbox · AMF · MediaCodec with a single `1..7` preset table mapped per backend
- **Unified telemetry** — DJI · GoPro GPMF · Sony NMEA · Garmin VIRB FIT · QuickTime ISO 6709 → one 24-column normalized CSV (v54) + SRT overlay tracks
- **Richer telemetry** (v54) — DJI full per-sample GPS track (fixes Osmo Action 6) with computed speed/heading + G-force; GoPro ACCL/GYRO + GPS9 (Hero 11/12/13); Garmin FIT enhanced speed/altitude + fixed temperature; GPS fix quality / sats / HDOP; modern KML `<gx:Track>` import (Strava / Garmin / Google)
- **Metadata-only HDR/DV tools** (v55/v56) — RPU profile transforms (force 8.1 / P5→8.1 / 8.1 preserving mapping / →P10 AV1) via the correct `editor` path, HDR10+→DV hybrid with source-derived L6 mastering metadata, aggregated RPU inspect summary + `--verify` HDR10+ + RPU JSON export, **remove DV / remove HDR10+** layers, **plot DV L1/L2/L8 → PNG**; HEVC + AV1, lossless on video. **AV1 DV inject now works** — auto-repairs the missing T.35 alignment byte that `av1dovi_tool` drops (dav1d-compatible; HDR10+ in hybrids untouched)
- **Mux tools** (v49 + v50) — standalone script, 3 lossless flows: **Remux** (per-stream selection + per-target compat matrix), **Demux** (smart per-codec wrapping: video→`.mkv`, audio→`.mka`, subs→native ext, chapters→Matroska XML), **Mux** (combine video + N audio/subs/chapters/attachments into a fresh container). Input: mkv/webm/mp4/m4v/mov/ts/m2ts/mts/vob/mxf
- **Spec-compliant HDR10/HLG output** (v52 SW + v53 HW) — fixed a long-standing VUI signaling bug (streams reported `color_*=unknown`, silently disabling x265 `hdr10-opt`); now correct end-to-end across SW encoders and all 6 HW backends, via `-x265-params`/`-svtav1-params` plus post-encode bitstream filters
- **Rate control: CRF · 1-pass · 2-pass VBR** (v51 + v53) — true 2-pass on SW encoders, NVENC `-multipass fullres` on `ENCODE_MODE=3`; automatic VBV/Level/Tier; HDR10 static metadata (Mastering Display + MaxCLL) injected on all PQ output, with opt-in **measured** MaxCLL/MaxFALL (v63)
- **`AV_PROFILE` env var** (v52) — non-interactive profile auto-load for CI/cron/batch; resolves `UserProfiles/` → `profiles/*/`, EXTENDS + schema validation preserved
- **Batch resume + recursive folders + profile system** — quit anytime, re-run, picks up where it stopped; `.conf` profiles with `EXTENDS` inheritance and schema validation
- **DJI Osmo Action 6 presets shipped** — Airsoft Indoor/Outdoor · Moto Outdoor/Cinematic · D-Log M with LUT
- **Burn-in overlay suite** (v48 + v58 HDR-aware) — 4 flows: telemetry HUD (Python+matplotlib, 3 presets + map M2), SRT/ASS (libass styling), Image subs PGS/VobSub (external + embedded); detects source HDR/HDR10+/HLG/LOG/DV per file and proposes the right path (preserve / tonemap / brand LUT / refuse on DV); `BURNIN_HDR_POLICY` env for batch bypass; opt-in 5s preview

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

Drop your files into the input folder shown on first run (Termux: `/storage/emulated/0/Media/InputVideos/`; Linux/macOS/Windows: `InputVideos/` next to the script). Pick **1) Encode** from the menu, accept the defaults — done. Output lands in the matching `OutputVideos/` folder, with a per-batch summary on screen.

---

## At a Glance

| | |
|---|---|
| **Video** | HEVC · H.264 · AV1 (SVT-AV1 / libaom) · DNxHR · ProRes · APV |
| **HW backends** | NVENC · QSV · VAAPI · VideoToolbox · AMF · MediaCodec |
| **HDR** | HDR10 · HDR10+ · Dolby Vision (P5/P7/P8.1 HEVC + P10 AV1) · HLG · LOG |
| **Audio encode** | AAC · Opus · FLAC · E-AC3 · AC3 · LPCM |
| **Audio passthrough** | TrueHD · DTS · DTS-HD (auto stream copy; AC3 source copies too) |
| **Telemetry** | DJI · GoPro GPMF · Sony NMEA · Garmin VIRB FIT · QuickTime ISO 6709 |
| **Workflows** | Encode · Audio-only · Trim & Concat · Remux · HDR/DV tools · Telemetry · GPS · Burn-in (HUD/SRT/ASS/Image) · Analysis |

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
| **DNxHR** | 8/10 | ✅ preserve¹ | — | — | ✅ preserve¹ | ✅¹ |
| **ProRes** KS | 10/12 | ✅ preserve | — | — | ✅ preserve | ✅ |
| **APV** (FF 8.1+) | 10 / 4:2:2 / 4:4:4 | ✅ | — | — | — | ✅ |

¹ DNxHR HQX/444 = 10-bit (HDR); LB/SQ/HQ = 8-bit (SDR/proxy — lose wide gamut on LOG, warned). **Mezzanine codecs** (DNxHR/ProRes/APV) preserve the HDR10/HLG picture + color tags but do **not** carry Dolby Vision RPU or HDR10+ dynamic metadata → v64 adds honest per-source warnings (DV / HDR10+ → clean HDR10 base; use x265/AV1 to keep DV). ProRes 4444 XQ = native XQ profile (v64). DNxHR MXF audio = PCM only (v64).

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

Uniform preset table `1..7` (Ultrafast → Veryslow, default `4=Quality`) across all backends. `show_hdr_hw_dialog` per-source-type (DV / HDR10+ / HLG / HDR10) with `sw_full` / `sw_degraded` / `hw_hdr10` / `hw_hlg` / `hw_sdr` / `hw_preserve` (v46, DV preserve via HW) / skip. Bypass via `HW_HDR_POLICY`.

**v46 — HW DV preserve**: all 6 HW backends now support DV preserve (HEVC target via Profile 8.1, AV1 target via Profile 10). Extracts source RPU → HW encode HDR10 base → post-encode RPU inject. MediaCodec adds SEI signaling repair between encode and inject. Available on 12 combinations (6 backends × 2 codecs).

---

## HDR / Color Science

| Format | Encode | Stream copy | Cross-codec | Transform-only |
|---|---|---|---|---|
| **HDR10** | all encoders | ✅ | HEVC↔AV1 | — |
| **HDR10+** dynamic | HEVC + SVT-AV1 v1.5+ | ✅ | all 4 directions | synthesize DV from HDR10+ (v45) |
| **Dolby Vision** | HEVC 8.1 (v45) · AV1 P10 (v44) | ✅ | HEVC↔AV1 (v44/v45) | profile transform 5/7→8.1, 8.1↔10 |
| **HLG** | all encoders + HW + MediaCodec (v39) | ✅ | ✅ | — |
| **LOG** (Apple/D-Log M/Samsung) | `.cube` LUT → Rec.709 / HLG · keep LOG | ✅ | — | — |
| **SDR tonemap** | Hable zscale → Rec.709 | — | — | — |

- **Triple-layer hybrid** — DV 8.1 (HEVC) or DV P10 (AV1) + HDR10 base + HDR10+ dynamic in one bitstream; v45 preserves both layers when source has DV + HDR10+ embedded
- **HDR10+ → DV hybrid** (v45, transform-only) — extract HDR10+ JSON → synthesize DV RPU → inject → re-mux; 100% lossless on video
- **HDR10 → HLG** (v63) — encode-time conversion (HEVC + AV1), symmetric with HLG → HDR10; HLG is metadata-free and plays gracefully on SDR screens (broadcast/phone-friendly)

---

## Audio

### Encoding

| Codec | Default | Surround auto | Container |
|---|---|---|---|
| **AAC** | 192k | 5.1 → 384k · 7.1 → 768k | all |
| **Opus** | 128k | 5.1 → 256k · 7.1 → 512k | mkv/webm |
| **E-AC3** | 224k stereo | 5.1 → 640k · 7.1 → 1024k | ❌ MOV |
| **AC3** legacy (v53) | 224k stereo | 5.1 → 448k (max 640k) · 7.1 → 5.1 downmix | ❌ MOV |
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
| **DJI** | `djmd`/`dbgi` | ExifTool (per-sample) | ✅ full track + computed speed/heading + G-force | ✅ |
| **GoPro** | `gpmd` | GPMF KLV (Python) | ✅ | ✅ |
| **Sony Action Cam** | `nmea` | NMEA 0183 (Python) | ✅ | ✅ |
| **Garmin VIRB** | `fdsc` | FIT (Python) | ✅ + HR/cadence/power | ✅ |
| **QuickTime** | `com.apple.quicktime.location.ISO6709` | ExifTool | ✅ (single point) | ✅ |

- **Norm CSV** (24 cols, v54) — `timestamp,lat,lon,alt_m,speed_mps,speed_kmh,heading_deg,gforce_xyz,gyro_xyz,temp_c,hr_bpm,cadence_rpm,power_w,pitch_deg,roll_deg,yaw_deg,fix_quality,num_sats,hdop,source_brand`
- **DJI strip** sub-modes — dbgi-only · djmd+dbgi · total
- **Excluded by design** — Insta360, Yi/Akaso/SJCAM
- **External GPS import** — GPX/FIT/KML → CSV/SRT/GPX/KML via `av_extractor_gps`
- **Embed lossless** (opt 7) — extract telemetry then re-mux as SRT subtitle track + attachments (MKV); video stream copy, no re-encode. Submenu with 4 profiles: `srt` (SRT only, any container) · `srt_csv` (SRT + norm CSV, MKV) · `srt_csv_gpx` (default, SRT + norm CSV + GPX, MKV) · `all` (SRT + basic + FULL + GPX + KML, MKV mandatory). KML auto-generated for profile `all` from norm CSV (or DJI exiftool template). Mimetypes: `text/csv`, `application/gpx+xml`, `application/vnd.google-earth.kml+xml`.

---

## Workflows

1. **Encode** — per-file HDR/DV/HLG/LOG dialogs; recursive scan with `PRESERVE_FOLDER_STRUCTURE=1`
2. **Audio-only re-encode** — video stream copy + audio re-encode
3. **Media analysis** (`av_check`) — 30-50 field CSV
4. **Telemetry** — 6 modes: Standard / Full / SRT / All / Raw / Strip
5. **External GPS** — GPX/FIT/KML → CSV/SRT
6. **Trim & Concat** — single trim · concat (auto demuxer/filter) · pipeline 3-pass (+ dry-run preview, v63) · batch trim · HDR/LOG-aware re-encode (v60: per-file dialog — preserve HDR10/HLG · tonemap · LUT · keep LOG · skip; pipeline x265 + svtav1 HDR, codec_tag)
7. **Mux tools** (v49 + v50, no re-encode, lossless):

   | Flow | Action |
   |---|---|
   | Remux container | Per-stream selection (video/audio/sub/attach/chapters) → mkv/mp4/mov/webm with per-target compat matrix + preflight |
   | Demux streams | Smart per-codec wrap: video→`.mkv`, audio→`.mka`, sub→native ext, cover→jpg/png, chapters→XML, attachments+data→folders |
   | Mux streams (v50) | Combine video + N audio + N subs + chapters + attachments → fresh container. Manual selection, VobSub pair handling, per-track metadata opt-in (lang/title/default/forced). Compat matrix reused from Remux. Input only from `InputVideos/`. |

8. **HDR/DV Tools** (v44/v45/v56, metadata-only, no re-encode):

   | Option | Action |
   |---|---|
   | Transform RPU | DV profile convert (5→8.1, force 8.1, 8.1 preserving mapping, →P10 AV1) |
   | Inspect | ffprobe + `dovi_tool info -s` + RPU JSON export + HDR10+ `--verify` |
   | HDR10+ → DV hybrid (v45) | Synthesize DV RPU from HDR10+ → inject → re-mux |
   | Remove DV → HDR10 (v56) | Strip DV layer, keep HDR10/HDR10+ (HEVC + AV1) |
   | Remove HDR10+ (v56) | Strip HDR10+ metadata, keep HDR10/DV (HEVC + AV1) |
   | Plot DV metadata (v56) | L1/L2/L8 brightness/trims → PNG (native) |

9. **Burn-in overlay** (v48, re-encode with baked-in pixels):

   | Flow | Source | ffmpeg pipeline |
   |---|---|---|
   | Telemetry HUD | `<name>_norm.csv` | `burnin_render.py` → PNG seq → `[0:v][1:v]overlay` |
   | SRT | `<name>.srt` | `subtitles='<path>':force_style='FontSize=N,...'` (libass) |
   | ASS | `<name>.ass` | `ass='<path>'[:force_style='ScaleX=N,ScaleY=N']` (libass) |
   | Image subs | `<name>.sup` · `<name>.idx+.sub` · embedded PGS/VobSub | `[0:v][1:s]overlay` (ext) · `[0:v][0:s:N]overlay` (emb) |

   **Preview mode** (opt-in per flow): generates 5s clip at mid-point as `<name>_preview.<ext>` — quick check before committing to full encode.

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
│   ├── av_trimconcat.sh        # Trim & Concat pipeline (v36/v37 + v60 HDR/LOG, standalone)
│   ├── av_mux.sh               # v49+v50 — Mux tools standalone (remux + demux + mux)
│   ├── av_mux.ps1              # v49+v50 — PS1 mirror standalone
│   ├── av_hdr_dv_tools.sh      # HDR/DV tools submenu (v44/v45/v56; remux moved to av_mux in v49)
│   ├── av_check.sh             # Media analysis + CSV export (Termux/Linux/macOS)
│   ├── av_check.ps1            # Media analysis + CSV export (Windows)
│   ├── av_encode.ps1           # All-in-one PowerShell script (Windows)
│   ├── av_telemetry.sh         # Unified telemetry extractor (5 brands)
│   ├── av_telemetry.ps1        # PS1 mirror standalone
│   ├── av_extractor_gps.sh     # External GPS import GPX/FIT/KML
│   ├── av_extractor_gps.ps1    # PS1 mirror standalone
│   ├── av_burnin.sh            # v48 — Burn-in overlay (HUD/SRT/ASS/Image)
│   ├── av_burnin.ps1           # v48 — PS1 mirror standalone
│   ├── burnin_render.py        # v48 — Python+matplotlib HUD render engine
│   ├── av1_dv_t35_repair.py    # v56 — AV1 DV T.35 trailing-byte repair (dav1d compat)
│   ├── dji_djmd_dlogm.py       # v62 — DJI Action 6 D-Log M detector (djmd protobuf .2.4.1==19)
│   ├── burnin_presets/         # v48 — HUD layout presets (.conf)
│   │   ├── minimal.conf        # timestamp + speed corner overlay
│   │   ├── data-strip.conf     # bottom bar gauges (speed/alt/heading/temp)
│   │   └── full.conf           # data-strip + map M2 + G-force/HR gauges
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

## Tests

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
7. **Mux tools** (v49 + v50) — Remux + Demux + Mux, no re-encode · 10 input formats (Blu-ray/DVD/broadcast) · remux to mkv/mp4/mov/webm · demux to mkv/mka/native sub ext + cover/chapters/attach · **mux** (v50): combine separate video + audio[N] + subs[N] + chapters + attachments into fresh container (manual selection, VobSub pair handling, per-track metadata opt-in)
8. **HDR/DV tools** — transform / inspect / HDR10+→DV / remove DV / remove HDR10+ / plot (v56)
9. **Burn-in overlay** (v48) — HUD telemetry / SRT / ASS / Image subs (PGS/VobSub)
10. Exit

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

Current: **v64** — 115 bugs fixed · 236+ features · ~42 000 LoC · 132 files
