# AV Encoder Suite

Cross-platform video encoding suite for **Termux (Android), Linux, macOS and Windows** — bash + PowerShell.

**v90** — 163 bugs fixed · 280+ features · ~47 000 LoC · 237 files

---

## Overview

A smart FFmpeg wrapper for real-world video work — HDR/Dolby Vision detection and preservation, codec-aware tool dispatch (HEVC vs AV1), adaptive CRF per resolution and encoder, batch encoding with resume, action-cam telemetry extraction, and metadata-only DV/HDR10+ transforms. Built around an interactive menu that asks one targeted question per file (e.g. *"this source is DV Profile 5 — preserve, convert to HDR10, or stream-copy?"*) instead of hand-crafting ffmpeg flags.

The same workflow runs identically across all four platforms — bash and PowerShell branches are mirrored feature-for-feature, and `.conf` profiles keep settings reproducible for batches and CI. The goal is to keep Dolby Vision RPU, HDR10+ dynamic metadata, 10-bit pixel formats and color signaling intact end-to-end — the kind of detail raw `ffmpeg` calls usually mishandle without very specific flags.

## Highlights

- **Dolby Vision preserve end-to-end** — HEVC↔AV1 cross-codec (P5/P7/P8.1↔P10), SW + all 6 HW backends (v46), HDR10+ co-existence when source carries both layers
- **Dolby Vision now recognized by TVs** (v70–v72) — the DV hybrids the suite builds carry the full DV layer in the bitstream but lacked the container signaling TVs decide by; when the right tool is available, the suite writes the DOVI configuration record so TVs engage Dolby Vision (PC players already read the in-stream RPU). Coverage is now complete: HEVC in MKV (`mkvmerge`, v70) + HEVC in MP4/MOV (`MP4Box`/GPAC, v71) + AV1 in MKV (`mkvmerge`, v71) + AV1 in MP4/MOV (`MP4Box`/GPAC, v72). Optional and silent when absent (falls back to in-stream-only); applies to DV preserve at encode, HDR/DV transforms, Mux/Remux, and stream-copy/trim/audio-only passthrough. Track metadata (audio/subtitle languages, chapters) preserved faithfully. Resolves the v69 "known limitation"
- **HDR10+ on APV** (v69) — a first: dynamic HDR10+ metadata survives encoding to Samsung APV (ffmpeg alone drops it). A dedicated stdlib engine writes the ST 2094-40 metadata per frame straight into the APV bitstream alongside static mastering-display/MaxCLL, from any HDR10+ source (HEVC / AV1 / APV) — and back: an HDR10+ APV file re-encodes to x265/AV1 with metadata intact. Output validated byte-exact against the HDR10+ ecosystem reference tools and the official test clip; optional decode-check via the OpenAPV reference decoder (`tools/openapv_validator`)
- **HDR-aware everywhere** — HDR10 · HDR10+ dynamic · DV · HLG · LOG (Apple / D-Log M / Samsung) detected automatically; per-source dialogs propose the right transform
- **Spatial audio preserved & signaled — Dolby Atmos and DTS:X** (v87) — object-based audio can't be created or re-encoded with free tools (the encoders are Dolby/DTS-licensed); it only survives a 1:1 track copy. The suite now detects Atmos (E-AC-3 JOC / TrueHD) and DTS:X per track, marks them in every selection dialog, and guards re-encodes with a copy-first prompt (`AV_ATMOS_POLICY` / `AV_DTSX_POLICY` for CI — non-interactive runs default to copy, nothing is lost silently). On MP4/MOV it also rewrites the container-level Atmos signaling that ffmpeg omits (via MP4Box, mirroring the v70-v72 DV container work) — Apple-ecosystem players decide by that box, everything else reads the bitstream. Media analysis labels the tracks, Demux marks them, Trim & Concat warns before the audio choice, and Remux now honestly drops container-incompatible spatial tracks instead of failing outright. Auro-3D (steganographic height channels in the LSBs of a normal 5.1 track) is undetectable by design — a 1:1 copy keeps it, any re-encode loses it
- **Eclipsa Audio (IAMF) — author it AND keep it** (v88) — the open, royalty-free spatial audio format from AOMedia (pushed by Samsung/Google on recent TVs and phones). IAMF isn't a codec: it's a stream GROUP (Audio Element + Mix Presentation) over Opus substreams living in the container. The audio-only menu (option 10) now *authors* IAMF from stereo/5.1/7.1 sources — scalable layers (stereo base + full bed), Opus substreams, video copied 1:1 alongside; ffmpeg builds the IAMF structure natively but can't write it into a container, so MP4Box packages it (MP4/MOV only — Matroska has no IAMF mapping yet). And since ffmpeg silently FLATTENS an existing IAMF group to plain Opus tracks on *any* mux/copy (exit 0, nothing visibly lost — the audio twin of the v70–v72 DV container signaling), every 1:1 path (encode with audio copy, stream copy, audio-only, Remux) re-grafts the group from the source byte-identically. The audio dialog treats the substreams as one atomic unit (copy as a group, no per-track selection, no loudnorm), media analysis labels tracks *(Eclipsa)*, and Trim & Concat warns that timeline edits flatten the group
- **Atmos → Eclipsa 7.1.4, objects included** (v89) — IAMF authoring now also takes 12-channel (7.1.4) sources — 7 Opus substreams (5 coupled pairs + C + LFE), scalable stereo + 7.1.4 layers — and, the bigger half: on a Dolby Atmos source (E-AC-3 JOC or TrueHD), the objects can be *positionally rendered* into 7.1.4 channels via Cavern (VoidXH — the only free renderer that decodes Atmos objects; TrueHD handled through truehdd, which Cavernize fetches automatically) and authored into Eclipsa with real height channels. Option 10 offers render / bed-only / skip (`AV_ATMOS_ECLIPSA_POLICY` for batch; non-interactive defaults to bed, render failure falls back to bed honestly). Video, subtitles, chapters and DJI native GPS still come from the source 1:1. Optional tool via `tools/cavernize_installer` (Windows validated; macOS manual guide; Linux/Termux honestly unavailable — without it everything behaves like v88). Validated on the official Dolby Tone 7.1.4: all 12 channels live in the final IAMF, heights included. DTS:X stays bed-only (no free object decoder exists). **v90** closes the last Eclipsa gap: Burn-in (HUD/subtitle overlays re-encode the video but copy the audio, which silently flattens the IAMF group) now re-grafts the group onto the full MP4/MOV output too — previews (cut clips) stay honestly ungrafted, since truncated substreams can't be regrouped
- **DJI Osmo Action 6 D-Log M detection** (v62) — Action 6 reports `bt709` identically for Normal and D-Log M (the LOG curve lives only in the pixels); the real flag sits in the `djmd` telemetry track, which exiftool doesn't expose. A shared stdlib reader parses the djmd protobuf and tags D-Log M correctly so the LOG dialog (apply Rec.709 LUT / keep LOG) shows up. LOG/LUT flow also hardened: 10-bit detection via pixel-format fallback, HLG no longer misread as LOG, correct Rec.709 tagging across all containers (MP4/MOV/MKV — `setparams` after `lut3d`, since the filter rewrites pixels but not color metadata). **v83**: brand-aware LUT matching — LUTs are now recognized by their real names (`AppleLog*`, `*Samsung*Log*`, `*D-LogM*`), not just a fixed prefix, so the brand's LUT is surfaced first (default) while the full list stays selectable for manual choice; applies to encode, burn-in and trim/concat. Validated end-to-end on a real iPhone 17 Pro Max Apple Log clip (ProRes 10-bit → detected as Apple Log → correct Rec.709 on x265 / AV1 / burn-in / trim-concat). **v85**: Apple Log detection now survives trimming/remuxing — it also keys off the video stream's encoder tag (`Apple ProRes`), which persists through `-c copy`, so a clip trimmed with Trim & Concat before encoding still gets the right brand LUT (no false positives: a suite-re-encoded ProRes isn't mistaken for Apple)
- **DJI native GPS preserved on encode** (v78) — encoding a DJI clip (Osmo Action 6 etc.) used to silently drop the native GPS telemetry track (its `codec=none` format can't pass through ffmpeg into *any* container). Now the suite re-grafts the GPS track onto the MP4/MOV output after encoding (via MP4Box) — on full re-encode, fast stream-copy, and audio-only alike (anywhere the picture stays 1:1). The bulky debug track is dropped; on MKV (which can't hold it either) the suite points you to the telemetry *embed* option. Controlled by `DJI_PRESERVE_META` (auto/on/off). The old "switch to MKV to keep tracks" option — which actually crashed the encode (those tracks can't enter MKV) — is gone, replaced by this honest, automatic path
- **6 HW backends, uniform UX** — NVENC · QSV · VAAPI · VideoToolbox · AMF · MediaCodec with a single `1..7` preset table mapped per backend
- **Hardware encoding correctness audit** (v75) — across all 6 backends: fixed inverted quality presets on VAAPI / VideoToolbox (picking "quality" no longer gave you "fast"), AV1 HW now offered only on GPUs that can actually run it (Intel Arc / Core Ultra+, with a live capability probe on Linux), NVENC constant-quality VBR, explicit HDR10 color signaling on every card, and an honest warning that HDR10+ degrades to static HDR10 on HW encode. MediaCodec recognizes modern Snapdragon (`QTI`) / Exynos (codename) SoCs and no longer claims nonexistent mobile AV1 HW encode (→ clean SW fallback). On Windows, Dolby Vision Profile 8.1 / 8.4 and AV1 DV — which carry a standard/empty codec tag rather than the DV-dedicated one — are now detected from side-data on the encode path, so the preserve dialog appears and DV is no longer silently lost; P8.4 (HLG-compatible) is also no longer mislabeled as Profile 5 in MP4/MOV
- **HDR10+ preserved on hardware encode** (v76) — every HW encoder drops dynamic HDR10+ (only static HDR10 survives); when the HDR10+ tool is present the suite re-injects the per-scene metadata onto the HW-encoded bitstream, restoring dynamic HDR10+ intact on HEVC and AV1 — including hybrid DV + HDR10+ sources (both layers kept, DV signaled via the container record). On an HDR10+ source picked for HW, preserve-via-inject is the default. Also new: **Dolby Vision Profile 7 → 8.1** in HDR/DV tools — P7 (dual-layer, typical of UHD discs) isn't read by many TVs/players, so the suite converts to universal 8.1, keeping the HDR10 base + DV metadata and warning before discarding an enhancement layer that actually carries luminance (FEL-safe; `DV_P7_FORCE=1` to override). Same conversion is now applied automatically when re-encoding a P7 source with DV preserve, so the output is valid single-layer 8.1. Validated on QSV HEVC; other HW backends spec-level
- **AV1 HW detection hardened + VFR awareness** (v77) — the AV1-capable check now confirms *real* capability with a quick on-GPU probe across every backend (NVENC / AMF / VideoToolbox, joining QSV / VAAPI from v75) and on Windows, not just GPU-model matching — a future AV1-capable card the suite doesn't recognize by name is picked up automatically, no whitelist update needed (clean SW fallback if it can't encode AV1). Plus: on variable-frame-rate (VFR) sources, preserving dynamic HDR10+/DV on hardware now warns that metadata aligns positionally (tools may report a small tail frame-count difference, auto-adjusted, no visible impact) instead of staying silent — APV now keeps dynamic HDR10+ on small gaps too (tail-aligned like DV/HW), falling back to static HDR10 only on a large mismatch. Built-in DJI profiles + burn-in presets realigned to the current schema (test-guarded)
- **More accurate HDR brightness measurement** (v79) — the opt-in *measure real MaxCLL/MaxFALL from video* pass (used mainly for HLG→HDR10, where the source carries no light-level metadata) now takes the brightest of the three colors (max R/G/B) per pixel per CTA-861.3 instead of perceived luma, so highly saturated bright highlights (red/blue) are no longer underestimated and the written MaxCLL reflects the true peak. Still opt-in (`HDR10_MEASURE_CLL`), one analysis pass, mastering display unchanged
- **Unified telemetry** — DJI · GoPro GPMF · Sony NMEA · Garmin VIRB FIT · QuickTime ISO 6709 → one 24-column normalized CSV (v54) + SRT overlay tracks
- **Richer telemetry** (v54) — DJI full per-sample GPS track (fixes Osmo Action 6) with computed speed/heading + G-force; GoPro ACCL/GYRO + GPS9 (Hero 11/12/13); Garmin FIT enhanced speed/altitude + fixed temperature; GPS fix quality / sats / HDOP; modern KML `<gx:Track>` import (Strava / Garmin / Google)
- **Metadata-only HDR/DV tools** (v55/v56) — RPU profile transforms (force 8.1 / P5→8.1 / P7→8.1 dual-layer-aware / 8.1 preserving mapping / →P10 AV1) via the correct `editor` path, HDR10+→DV hybrid with source-derived L6 mastering metadata, aggregated RPU inspect summary + `--verify` HDR10+ + RPU JSON export, **remove DV / remove HDR10+** layers, **plot DV L1/L2/L8 → PNG**; HEVC + AV1, lossless on video. **AV1 DV inject now works** — auto-repairs the missing T.35 alignment byte that `av1dovi_tool` drops (dav1d-compatible; HDR10+ in hybrids untouched)
- **Mux tools** (v49 + v50) — standalone script, 3 lossless flows: **Remux** (per-stream selection + per-target compat matrix), **Demux** (smart per-codec wrapping: video→`.mkv`, audio→`.mka`, subs→native ext, chapters→Matroska XML), **Mux** (combine video + N audio/subs/chapters/attachments into a fresh container). Input: mkv/webm/mp4/m4v/mov/ts/m2ts/mts/vob/mxf
- **Spec-compliant HDR10/HLG output** (v52 SW + v53 HW) — fixed a long-standing VUI signaling bug (streams reported `color_*=unknown`, silently disabling x265 `hdr10-opt`); now correct end-to-end across SW encoders and all 6 HW backends, via `-x265-params`/`-svtav1-params` plus post-encode bitstream filters
- **Rate control: CRF · 1-pass · 2-pass VBR** (v51 + v53) — true 2-pass on SW encoders, NVENC `-multipass fullres` on `ENCODE_MODE=3`; automatic VBV/Level/Tier; HDR10 static metadata (Mastering Display + MaxCLL) injected on all PQ output, with opt-in **measured** MaxCLL/MaxFALL (v63)
- **Per-track audio control** (v67–v68) — on multi-track files, choose per track: re-encode / copy lossless / drop, with bitrate + downmix computed per track's channel count; correct multi-codec re-encode order so a chosen codec actually applies (v66); `AV_AUDIO_TRACKS` / `AV_AUDIO_DROP` env for non-interactive selection; **container-compat warnings** when a copied track can't fit the target container (encode + concat); smart stream-copy keeps your per-track audio choice on every platform. Single-track files are untouched
- **`AV_PROFILE` env var** (v52) — non-interactive profile auto-load for CI/cron/batch; resolves `UserProfiles/` → `profiles/*/`, EXTENDS + schema validation preserved
- **Batch resume + recursive folders + profile system** — quit anytime, re-run, picks up where it stopped; `.conf` profiles with `EXTENDS` inheritance and schema validation
- **DJI Osmo Action 6 presets shipped** — Airsoft Indoor/Outdoor · Moto Outdoor/Cinematic · D-Log M with LUT
- **Burn-in overlay suite** (v48 + v58 HDR-aware) — 4 flows: telemetry HUD (Python+matplotlib, 3 presets + map M2), SRT/ASS (libass styling), Image subs PGS/VobSub (external + embedded); detects source HDR/HDR10+/HLG/LOG/DV per file and proposes the right path (preserve / tonemap / brand LUT / refuse on DV); `BURNIN_HDR_POLICY` env for batch bypass; opt-in 5s preview. **v80**: configurable overlay font (`FONT_FAMILY` — family name or `.ttf`/`.otf` path, applied to all overlay text) + three new corner readouts — altitude / heading / temperature (`HUD_ALTITUDE/HEADING/TEMPERATURE`, shown when the data-strip is off so they never duplicate it). **v81**: instant **still-layout preview** on the HUD flow — instead of a full render (or the 5s clip), composite one HUD frame over a real video frame from mid-clip, optionally with a positioning grid, to check element placement and readability fast (`<name>_preview.png`, auto-opened). **v82**: the still preview is now tonemapped on HDR-preserve sources so it no longer looks dim (only the preview PNG — the real encode keeps HDR; `BURNIN_STILL_NO_TONEMAP=1` for the raw frame) + optional **text shaping** for complex scripts (Arabic / Hebrew / Indic) on SRT/ASS; the broken ASS font-scale options (1.25x/1.5x, dead since v48) were removed since ASS files carry their own styling. **v84**: a visual **HUD layout designer** in your browser — pick a video (with its telemetry CSV, or demo mode with synthetic data), drag the HUD elements (data strip, map, corner readouts) directly over real video frames rendered by the same production engine (true WYSIWYG, HDR frames tonemapped for display), scrub the timeline, tune fonts/colors/sizes live, then save the layout as a custom preset (`UserProfiles/burnin/`) selectable in the HUD flow; runs strictly local (127.0.0.1), zero new dependencies

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
| **Audio encode** | AAC · Opus · FLAC · E-AC3 · AC3 · LPCM · Eclipsa/IAMF authoring incl. 7.1.4 + Atmos→Eclipsa render via Cavern (v88/v89) · per-track encode/copy/skip + container-compat warnings (v67–v68) |
| **Audio passthrough** | TrueHD · DTS · DTS-HD (auto stream copy; AC3 source copies too) · Atmos/DTS:X guarded (v87) · Eclipsa/IAMF group re-grafted (v88) |
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
| **APV** (FF 8.1+) | 10/12 · 4:2:2/4:4:4 (+alpha) | ✅ preserve | ✅ per-frame (v69) | — | ✅ preserve | ✅ |

¹ DNxHR HQX/444 = 10-bit (HDR); LB/SQ/HQ = 8-bit (SDR/proxy — lower precision on LOG/HDR, warned). **Mezzanine codecs** (DNxHR/ProRes/APV) preserve the HDR10/HLG picture + color tags but do **not** carry Dolby Vision RPU → honest per-source warnings (DV → clean HDR10 base; use x265/AV1 to keep DV). HDR10+ dynamic metadata is lost on DNxHR/ProRes — but **preserved on APV** since v69 (suite engine, see Highlights). ProRes 4444 XQ = native XQ profile (v64). **ProRes** (v74): analysis shows the exact profile (Proxy…4444 XQ), 4444/XQ add an alpha channel only when the source has one, container MOV **or** MXF; runs on all platforms via software `prores_ks` (VideoToolbox HW is macOS-only). **DNxHR** (v74): analysis shows the exact profile (LB/SQ/HQ/HQX/444). DNxHR MXF audio = PCM only (v64). **APV** (v65) = `liboapv`/`libopenapv` auto-detect, independent profile/preset/QP knobs (x265-style), mp4/mov/mkv; full bash + PowerShell parity. **APV** (v74): analysis shows the exact profile (4:2:2 / 4:4:4 / 4:4:4:4 · 10/12-bit) + new 4:4:4-alpha 12-bit (4444-12) profile.

DV preserve: extract source RPU codec-aware (`dovi_tool` HEVC / `av1dovi_tool` AV1) → re-encode HDR10 base → post-encode RPU inject → re-mux audio. Container DV signaling (DOVI configuration record) is written when the tool is available — HEVC: MKV via `mkvmerge` (v70) + MP4/MOV via `MP4Box` (v71); AV1: MKV via `mkvmerge` (v71) + MP4/MOV via `MP4Box` (v72) → DV recognized by TVs, not just PC players (silent in-stream-only fallback when absent). All common combinations (HEVC/AV1 × MKV/MP4/MOV) are covered.

---

## Hardware Encoding

| Backend | Platform | H.264 | H.265 | AV1 (HW) | HDR10 | Notes |
|---|---|---|---|---|---|---|
| **NVENC** | Win + Linux | ✅ | ✅ | RTX 40+ / Ada | ✅ 10-bit | `p1..p7` |
| **QSV** | Win + Linux | ✅ | ✅ | Arc / Core Ultra / Meteor+ | Tiger Lake+ | `veryfast..veryslow` |
| **VAAPI** | Linux | ✅ | ✅ | Arc / Core Ultra / Meteor+ | ✅ | `/dev/dri/renderD*`, `-quality 7..1` |
| **VideoToolbox** | macOS | ✅ | ✅ + ProRes | M3+ Apple Silicon | AS only (+ HLG) | `q:v 50..80` |
| **AMF** | Win + Linux exp (v42.1) | ✅ | ✅ | RDNA3+ (RX 7000/8000 + 740M–890M) | ✅ | `speed/balanced/quality` |
| **MediaCodec** | Termux/Android | ✅ | ✅ + HDR10 repair (8-bit input) | none on mobile → SW fallback | via `hevc_metadata` bsf | `60%..150%`, SoC whitelist |

Uniform preset table `1..7` (Ultrafast → Veryslow, default `4=Quality`) across all backends. `show_hdr_hw_dialog` per-source-type (DV / HDR10+ / HLG / HDR10) with `sw_full` / `sw_degraded` / `hw_hdr10` / `hw_hlg` / `hw_sdr` / `hw_preserve` (v46, DV preserve via HW) / skip. Bypass via `HW_HDR_POLICY`.

**v75 — HW correctness audit (all 6 backends)**: VAAPI `-quality` + VideoToolbox `q:v` preset direction was inverted vs slot → fixed (NVENC/QSV/AMF were already correct). Intel AV1 (QSV/VAAPI) now gated by GPU model — older Intel that lists `av1_qsv` but fails at runtime (UHD) is no longer offered → clean SW fallback. NVENC quality path uses constant-quality VBR (`-rc vbr -cq`); AMF sends explicit `usage=transcoding` (+ `main` profile on AV1); PS1 HW warns on HDR10+ (dynamic metadata dropped → HDR10 static, opt-skip). MediaCodec: flagship Snapdragon (`QTI` vendor) + modern Exynos (`s5e` codename) now recognized as `[verificat]`; 10-bit HDR is signaled/containered but **8-bit input precision** (ffmpeg MediaCodec encoders accept only 8-bit — validated on SD 8 Gen 3 + Exynos 1380). **AV1 HW encode no longer claimed on any SoC** — mobile AV1 hardware *encode* is near-nonexistent (decode is widespread; encode absent on SD 8 Gen 3 + Exynos 1380, both verified) → `MC_CAP_AV1=0` everywhere, so `av1_mediacodec` falls back to the suite's libsvtav1 (better quality/control than the hidden MediaCodec SW libaom; `HW_FORCE=1` to override). Encoder presence ≠ HW: MediaCodec falls back to SW transparently.

**v77 — AV1 HW probe extended to all backends**: the "real capability > model" principle (v75, Intel-only) now covers NVENC / AMF / VideoToolbox (bash) and every vendor on Windows (`Get-GPUCapabilities`). A short `model || probe` runs only when the GPU name isn't recognized (zero cost on known cards) — so a future AV1-capable GPU is detected at runtime without a whitelist update, and a listed-but-incapable encoder still falls back cleanly to SW. Probe can't false-positive (an incapable encoder fails the micro-encode clearly).

**v46 — HW DV preserve**: all 6 HW backends now support DV preserve (HEVC target via Profile 8.1, AV1 target via Profile 10). Extracts source RPU → HW encode HDR10 base → post-encode RPU inject. MediaCodec adds SEI signaling repair between encode and inject. Available on 12 combinations (6 backends × 2 codecs).

---

## HDR / Color Science

| Format | Encode | Stream copy | Cross-codec | Transform-only |
|---|---|---|---|---|
| **HDR10** | all encoders | ✅ | HEVC↔AV1 | — |
| **HDR10+** dynamic | HEVC + SVT-AV1 v1.5+ · **APV (v69)** | ✅ | all directions incl. APV↔HEVC/AV1 | synthesize DV from HDR10+ (v45) |
| **Dolby Vision** | HEVC 8.1 (v45) · AV1 P10 (v44) | ✅ | HEVC↔AV1 (v44/v45) | profile transform 5/7→8.1, 8.1↔10 · **container signaling: HEVC + AV1 in MKV & MP4/MOV (mkvmerge / MP4Box, v70–v72)** |
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
| **Eclipsa (IAMF)** (v88/v89) | Opus 256k substreams | layout follows source (2/6/8/12 ch); Atmos sources can render objects → 7.1.4 via Cavern (v89) | mp4/mov only (needs MP4Box) |

### Stream-copy passthrough

| Codec | Behaviour |
|---|---|
| **AC3** | preserved 1:1 |
| **TrueHD** | preserved 1:1 (+ HD warning) |
| **DTS / DTS-HD MA** | preserved 1:1 (+ HD warning) |
| **Dolby Atmos / DTS:X** (v87) | copy-first guard (objects survive only a 1:1 copy) + MP4/MOV Atmos container signaling |
| **Eclipsa / IAMF** (v88/v90) | group re-grafted onto MP4/MOV output after any 1:1 flow, incl. Burn-in full outputs (v90) — ffmpeg alone flattens it |

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
- **DJI strip** sub-modes — strip telemetry · strip telemetry + cover · keep native GPS (drop cover only, re-graft djmd via MP4Box, v78)
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
6. **Trim & Concat** — single trim · concat (auto demuxer/filter) · pipeline 3-pass (+ dry-run preview, v63) · batch trim · HDR/LOG-aware re-encode (v60: per-file dialog — preserve HDR10/HLG · tonemap · LUT · keep LOG · skip; pipeline x265 + svtav1 HDR, codec_tag); v73: LOG also detected at concat (brand LUT / keep LOG / skip) + DV container signaling kept on stream-copy / pipeline smart-copy / audio-only paths; v86: honest message when re-encode is forced by variable frame rate (VFR) sources — lossless concat on VFR cuts would corrupt timestamps at the joins, so the compat check correctly re-encodes and now says exactly why (CFR sources still concat lossless)
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
   | SRT | `<name>.srt` | `subtitles='<path>':force_style='FontSize=N,...'[:shaping=<mode>]` (libass) |
   | ASS | `<name>.ass` | `ass='<path>'[:shaping=<mode>]` (libass — ASS carries its own styling) |
   | Image subs | `<name>.sup` · `<name>.idx+.sub` · embedded PGS/VobSub | `[0:v][1:s]overlay` (ext) · `[0:v][0:s:N]overlay` (emb) |

   **Text shaping** (v82, SRT/ASS): optional `auto` / `simple` / `complex` for complex scripts (Arabic/Hebrew/Indic), gated on ffmpeg support; `auto` = unchanged default.

   **Preview mode** (opt-in per flow): HUD offers a still-layout preview (one composited frame at mid-point, tonemapped on HDR-preserve sources so it isn't dim — v81/v82) or a 5s clip; SRT/ASS/Image offer the 5s clip. Output `<name>_preview.<ext>` (`.png` for the still) — a quick check before committing to full encode.

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
│   ├── burnin_designer.py      # v84 — local web server for the visual HUD layout designer
│   ├── burnin_designer.html    # v84 — designer UI (single page, vanilla JS, served locally)
│   ├── av1_dv_t35_repair.py    # v56 — AV1 DV T.35 trailing-byte repair (dav1d compat)
│   ├── dji_djmd_dlogm.py       # v62 — DJI Action 6 D-Log M detector (djmd protobuf .2.4.1==19)
│   ├── apv_hdr10plus.py        # v69 — APV HDR10+ engine (ST 2094-40 inject/extract/probe)
│   ├── dv_p7_analyze.py        # v76 — DV Profile 7 enhancement-layer classifier (MEL / FEL-safe / FEL-complex)
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
│       ├── openapv_validator.sh    # v69 — OpenAPV reference decoder installer (cmake build)
│       ├── openapv_validator.ps1   # v69 — OpenAPV reference decoder installer (Windows, prebuilt)
│       ├── mkvmerge_installer.sh   # v70 — mkvmerge installer (pkg manager; dvcC DV on MKV, HEVC+AV1)
│       ├── mkvmerge_installer.ps1  # v70 — mkvmerge installer (Windows, portable .7z)
│       ├── mp4box_installer.sh     # v71 — MP4Box/GPAC installer (pkg manager; dvcC DV on MP4/MOV)
│       ├── mp4box_installer.ps1    # v71 — MP4Box/GPAC installer (Windows, winget)
│       ├── cavernize_installer.sh  # v89 — Cavernize guide (macOS manual; Linux/Termux unavailable)
│       ├── cavernize_installer.ps1 # v89 — Cavernize installer (Windows, official portable zip)
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
| `oapv_app_dec` | OpenAPV reference decoder — optional APV decode-check (v69) | `openapv_validator.sh` (cmake) | `openapv_validator.ps1` (prebuilt) |
| `mkvmerge` | MKVToolNix — optional, DV container signaling (dvcC) on MKV for HEVC (v70) + AV1 (v71) | `mkvmerge_installer.sh` (pkg manager) | `mkvmerge_installer.ps1` (portable .7z) |
| `MP4Box` (GPAC) | optional, DV container signaling (dvcC) on MP4/MOV for HEVC (v71) + AV1 (v72) | `mp4box_installer.sh` (pkg manager) | `mp4box_installer.ps1` (winget) |
| `Cavernize` (Cavern) | optional, renders Atmos objects → 7.1.4 channels for Eclipsa/IAMF authoring (v89); needs .NET Desktop 8+ | `cavernize_installer.sh` (macOS guide; Linux/Termux unavailable) | `cavernize_installer.ps1` (official portable zip) |
| Profile diff | Compare `.conf` files | `profile_diff.sh A B` | `profile_diff.ps1 A B` |

AV1 forks install with renamed binaries (`av1dovi_tool`, `av1hdr10plus_tool`) so they coexist with HEVC upstream. Since v69, every external tool name is overridable via `AV_TOOL_*` environment variables (plain name or full path) — e.g. `AV_TOOL_DOVI=dovi-tool` for distros that ship renamed binaries.

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

Current: **v90** — 163 bugs fixed · 280+ features · ~47 000 LoC · 237 files
