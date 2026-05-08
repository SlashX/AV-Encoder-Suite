#!/usr/bin/env bash
# Test hw_list_backends_for_codec — combineaza disponibilitati per platforma.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"

# Reset toate flag-urile la 0 si verifica fallback gol
MC_AVAILABLE=0; NVENC_AVAILABLE=0; QSV_AVAILABLE=0; VAAPI_AVAILABLE=0; AMF_AVAILABLE=0; VT_AVAILABLE=0
MC_ENCODERS=""; NVENC_ENCODERS=""; QSV_ENCODERS=""; VAAPI_ENCODERS=""; AMF_ENCODERS=""; VT_ENCODERS=""
out=$(hw_list_backends_for_codec hevc)
assert_eq "" "$out" "fara backends → empty list"

# Activeaza doar NVENC pentru hevc
NVENC_AVAILABLE=1; NVENC_ENCODERS="hevc_nvenc h264_nvenc av1_nvenc"
out=$(hw_list_backends_for_codec hevc)
assert_eq "nvenc" "$out" "doar nvenc"

# h264 → tot nvenc
out=$(hw_list_backends_for_codec h264)
assert_eq "nvenc" "$out" "h264 nvenc"

# av1 → nvenc (lista include av1_nvenc)
out=$(hw_list_backends_for_codec av1)
assert_eq "nvenc" "$out" "av1 nvenc"

# Adauga QSV — av1 doar pe nvenc daca QSV_ENCODERS nu il listeaza
QSV_AVAILABLE=1; QSV_ENCODERS="hevc_qsv h264_qsv"
out=$(hw_list_backends_for_codec hevc)
# Asteptam ambele in ordine prefixata: nvenc + qsv
assert_match "$out" "nvenc" "hevc include nvenc"
assert_match "$out" "qsv" "hevc include qsv"

out=$(hw_list_backends_for_codec av1)
assert_eq "nvenc" "$out" "av1 NU include qsv (lipseste din QSV_ENCODERS)"

# VAAPI + AMF + MediaCodec
VAAPI_AVAILABLE=1; VAAPI_ENCODERS="hevc_vaapi h264_vaapi"
AMF_AVAILABLE=1;   AMF_ENCODERS="hevc_amf h264_amf av1_amf"
MC_AVAILABLE=1;    MC_ENCODERS="hevc_mediacodec h264_mediacodec"

out=$(hw_list_backends_for_codec hevc | tr '\n' ' ')
assert_contains "$out" "nvenc" "hevc include nvenc"
assert_contains "$out" "qsv"   "hevc include qsv"
assert_contains "$out" "vaapi" "hevc include vaapi"
assert_contains "$out" "amf"   "hevc include amf"
assert_contains "$out" "mediacodec" "hevc include mediacodec"

out=$(hw_list_backends_for_codec av1 | tr '\n' ' ')
assert_contains "$out" "nvenc" "av1 nvenc"
assert_contains "$out" "amf"   "av1 amf"
assert_not_contains "$out" "vaapi"      "av1 nu vaapi (lipseste)"
assert_not_contains "$out" "qsv"        "av1 nu qsv (lipseste)"
assert_not_contains "$out" "mediacodec" "av1 nu mediacodec (lipseste)"

# VideoToolbox cu prores
VT_AVAILABLE=1; VT_ENCODERS="hevc_videotoolbox h264_videotoolbox prores_videotoolbox"; VT_CAP_PRORES=1
out=$(hw_list_backends_for_codec prores)
assert_eq "videotoolbox" "$out" "prores doar pe videotoolbox"

# Codec necunoscut → empty
out=$(hw_list_backends_for_codec dnxhr)
assert_eq "" "$out" "dnxhr nu are HW backends listate"
