# v53 PS1 mirror: HW VUI BSF + NVENC multipass + AC3 + downmix
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$srcPath = Join-Path $root 'src\av_encode.ps1'
$srcText = Get-Content -LiteralPath $srcPath -Raw

# ── HW VUI BSF helper markers ────────────────────────────────────────
Assert-Match $srcText 'function Get-HwVuiBsf' "Get-HwVuiBsf helper defined"
Assert-Match $srcText '\$bsfName = "\$\{codecKey\}_metadata"' "BSF name built per codec"
Assert-Match $srcText '"colour_primaries"' "HEVC uses colour_ naming"
Assert-Match $srcText '"color_primaries"' "AV1/H.264 use color_ naming"
Assert-Match $srcText "transfer_characteristics=16" "PQ transfer=16 in BSF"
Assert-Match $srcText "transfer_characteristics=18" "HLG transfer=18 in BSF"

# Live functional test of Get-HwVuiBsf
Import-AvEncodeFunctions -Names @('Get-HwVuiBsf')
$r = Get-HwVuiBsf -EncCodec "hevc_nvenc" -Mode "hdr10"
Assert-Match ($r -join " ") "hevc_metadata=colour_primaries=9:transfer_characteristics=16" "HEVC HDR10 BSF live output"
$r = Get-HwVuiBsf -EncCodec "av1_nvenc" -Mode "hdr10"
Assert-Match ($r -join " ") "av1_metadata=color_primaries=9:transfer_characteristics=16" "AV1 HDR10 BSF live output"
$r = Get-HwVuiBsf -EncCodec "h264_nvenc" -Mode "hlg"
Assert-Match ($r -join " ") "h264_metadata=color_primaries=9:transfer_characteristics=18" "H.264 HLG BSF live output"
$r = Get-HwVuiBsf -EncCodec "hevc_qsv" -Mode "sdr"
Assert-Match ($r -join " ") "hevc_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1" "HEVC SDR BSF live output"
$r = Get-HwVuiBsf -EncCodec "libx265" -Mode "hdr10"
Assert-Eq 0 $r.Count "Get-HwVuiBsf returns empty for non-HW encoder"

# ── HW HDR branches use Get-HwVuiBsf instead of -color_primaries arrays ──
Assert-Match $srcText 'Get-HwVuiBsf -EncCodec \$hwEncCodec -Mode "hdr10"' "HW DV→HDR10 uses BSF"
Assert-Match $srcText 'Get-HwVuiBsf -EncCodec \$hwEncCodec -Mode "hlg"' "HW HLG native uses BSF"
Assert-Match $srcText 'Get-HwVuiBsf -EncCodec \$hwEncCodec -Mode "sdr"' "HW SDR tonemap uses BSF"

# ── NVENC multipass on mode 3 ────────────────────────────────────────
Assert-Match $srcText '\$hwSupports2Pass = \(\$useHWEnc -and \(\$hwEncCodec -match "nvenc"\)\)' "NVENC 2-pass detection"
Assert-Match $srcText 'NVENC multipass' "NVENC multipass UI message"
Assert-Match $srcText '"-multipass","fullres"' "NVENC multipass fullres flag"
Assert-Match $srcText '"-bf","4"' "NVENC bf=4 quality boost"
Assert-Match $srcText '"-rc-lookahead","32"' "NVENC rc-lookahead=32"
Assert-Match $srcText '"-aq-strength","10"' "NVENC aq-strength=10"
Assert-Match $srcText '"-weighted_pred","1"' "NVENC weighted_pred=1 (HEVC/H.264)"
Assert-Match $srcText 'av1_nvenc' "AV1 NVENC special case"
# v53 audit: NVENC default tune/AQ paritate bash
Assert-Match $srcText '"-tune","hq"' "NVENC -tune hq paritate bash"
Assert-Match $srcText '"-spatial_aq","1"' "NVENC -spatial_aq 1 paritate bash"
Assert-Match $srcText '"-temporal_aq","1"' "NVENC -temporal_aq 1 paritate bash"

# ── Mode menu HW gate ────────────────────────────────────────────────
Assert-Match $srcText 'isHwActive -and -not \$hwSupports2Pass' "menu gate hides mode 3 only when HW lacks 2-pass"

# ── HW build uses Get-HwVuiBsf output ────────────────────────────────
Assert-Match $srcText '\$nvencQualityFlag' "nvencQualityFlag variable"
Assert-Match $srcText '\$hwQpFlag \+ \$hwPresetFlag \+ \$nvencTuneFlag \+ \$nvencQualityFlag' "ffArgs include quality flags"

# ── Schema/profile validation if needed (no new schema fields in v53) ──
Assert-Match $srcText "'AUDIO_CODEC_ARG'.*ac3:" "AUDIO_CODEC_ARG schema accepts ac3"
Assert-Match $srcText "'AUDIO_CODEC'.*ac3" "AUDIO_CODEC enum includes ac3"

# ── AC3 codec branch in audio-only flow ──────────────────────────────
Assert-Match $srcText 'AC3 \(Dolby Digital legacy\)' "audio-only menu has AC3 option"
Assert-Match $srcText '\$eaCodec = "ac3"; \$eaBr = "224k"' "audio-only option 8 sets AC3"
Assert-Match $srcText '\$ac3DownmixFlag = @\("-ac:a:0","6"\)' "AC3 force downmix to 5.1 from 7.1"
Assert-Match $srcText 'AC3 incompatibil cu mov' "AC3 + mov warning in PS1 audio-only"

# ── AC3 + AV_DOWNMIX_STEREO in PS1 main encode loop ──────────────────
Assert-Match $srcText '"ac3" \{' "main flow has ac3 codec branch"
Assert-Match $srcText 'AV_DOWNMIX_STEREO -eq "1"' "AV_DOWNMIX_STEREO env var honored"

# ── WebM in audio-only encoder ───────────────────────────────────────
Assert-Match $srcText 'Container: 1-mp4  2-mkv \[impl\]  3-mov  4-webm' "audio-only container menu has webm"
Assert-Match $srcText 'WebM accepta DOAR vp8/vp9/av1' "audio-only WebM source codec check"
Assert-Match $srcText '\$eaSubArgs = if \(\$eaContainer -eq "webm"\)' "audio-only WebM strips subs"
Assert-Match $srcText 'WebM suporta doar Opus' "audio-only WebM Opus enforcement"

# ── Inter-batch audio change prompt mentions AC3 ─────────────────────
Assert-Match $srcText 'ac3 224k' "inter-batch audio prompt lists ac3"

Invoke-TestSummary   # v63: inlocuit `exit 0` hardcodat (mascha esecurile → testul nu valida nimic)
