# v63 — HW encode HDR VUI signaling (bsf repair, v53) end-to-end (mirror PS1: Get-HwVuiBsf).
#   Source-level + functional (sursa bt709 → HDR10 cu bsf → VUI corect), guardeat pe HW HEVC encoder.
#   MediaCodec = Android-only → netestabil aici (source-level in test_v53).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$ENC = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw

# ── 1. Source-level — Get-HwVuiBsf + aplicarea $hwColorFlags ──
Assert-Match $ENC 'function Get-HwVuiBsf'                          "PS1: Get-HwVuiBsf definit"
Assert-Match $ENC ([regex]::Escape('Get-HwVuiBsf -EncCodec $hwEncCodec -Mode "hdr10"')) "PS1: Get-HwVuiBsf apelat pt hdr10"
Assert-Match $ENC 'colour_primaries'                              "PS1: HEVC colour_ (UK)"

# ── 2. Functional — Get-HwVuiBsf live + bsf produce VUI corect ──
if ((Get-Command ffmpeg -EA SilentlyContinue) -and (Get-Command ffprobe -EA SilentlyContinue)) {
    Import-AvEncodeFunctions -Names @("Get-HwVuiBsf")
    # live: valorile bsf
    $bHdr = (Get-HwVuiBsf -EncCodec "hevc_qsv" -Mode "hdr10") -join " "
    Assert-Match $bHdr "hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9" "Get-HwVuiBsf HEVC HDR10 live"
    $bHlg = (Get-HwVuiBsf -EncCodec "av1_nvenc" -Mode "hlg") -join " "
    Assert-Match $bHlg "av1_metadata=color_primaries=9:transfer_characteristics=18" "Get-HwVuiBsf AV1 HLG live"

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("hwv_"+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $hwenc = $null
    foreach ($e in @("hevc_qsv","hevc_nvenc","hevc_amf")) {
        & ffmpeg -hide_banner -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" -c:v $e -t 1 "$tmp\p.mp4" 2>$null | Out-Null
        if ((Test-Path "$tmp\p.mp4") -and (Get-Item "$tmp\p.mp4").Length -gt 0) { $hwenc = $e; break }
    }
    if ($hwenc) {
        $src = "$tmp\src709.mp4"
        & ffmpeg -hide_banner -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" `
            -c:v libx264 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 $src 2>$null | Out-Null
        $bsf = Get-HwVuiBsf -EncCodec $hwenc -Mode "hdr10"
        & ffmpeg -hide_banner -v error -y -i $src -c:v $hwenc -pix_fmt p010le @bsf "$tmp\bsf.mp4" 2>$null | Out-Null
        $trc  = (& ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer  -of default=nw=1:nk=1 "$tmp\bsf.mp4" 2>$null | Select-Object -First 1).Trim()
        $prim = (& ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$tmp\bsf.mp4" 2>$null | Select-Object -First 1).Trim()
        Assert-Eq "smpte2084" $trc  "HW ($hwenc) + bsf → transfer=smpte2084 (PQ propagat)"
        Assert-Eq "bt2020"    $prim "HW ($hwenc) + bsf → primaries=bt2020"
    } else {
        Write-Host "  (functional sarit — niciun HW HEVC encoder functional; source-level acoperit)" -ForegroundColor DarkGray
    }
    Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
}
Invoke-TestSummary
