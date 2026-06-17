# v71 — mirror al test_v71_av1_mkv_dvcc.sh (PS1).
#   dvcC de container pe hibridele AV1 DV → MKV (extensie v70 la AV1). mkvmerge scrie
#   "DOVI configuration record" si din AV1 (.ivf). AV1+MP4/MOV acoperit in v72 (vezi
#   test_v72_av1_mp4_dvcc) — aici doar calea MKV.
#   Source-level (mereu) + functional (AV1 DV sample + ffmpeg + mkvmerge + av1dovi_tool):
#   AV1 DV IVF → Invoke-HdvCombineWithOriginal REAL → MKV → dvcC + RPU.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$enc   = Get-Content (Join-Path $SRC 'av_encode.ps1') -Raw
$muxPs = Get-Content (Join-Path $SRC 'av_mux.ps1')    -Raw

# ── 1. triple-layer: ramura mkv ungateata (HEVC + AV1) ────────────────────
Assert-Match $enc ([regex]::Escape('$container -eq "mkv" -and (Invoke-DvMkvMux -RawHevc $injectedTemp -Original $outFile -Output $finalTemp)')) "triple-layer: mkv ungateat (HEVC+AV1)"
Assert-Match $enc ([regex]::Escape('elseif ($tlCodec -ne "av1" -and $container -eq "mkv")')) "triple-layer: pas MP4 ramane HEVC-only"

# ── 2. Invoke-HdvCombineWithOriginal: ramura AV1 IVF (MKV + MP4/MOV in v72) ─
Assert-Match $enc ([regex]::Escape("if (`$modExt -eq 'ivf') {")) "Invoke-HdvCombine: ramura AV1 IVF"

# ── 3. Invoke-DvMp4Mux gate: AV1 acum ACCEPTAT cu dvp= (v72; inainte respins) ──
Assert-Match $enc ([regex]::Escape("elseif (`$rext -in @('ivf','av1','obu')) { `$isAv1 = `$true }")) "Invoke-DvMp4Mux: AV1 acceptat (v72)"

# ── 4. av_mux.ps1: capturile AV1 pe MKV ───────────────────────────────────
Assert-Match $muxPs ([regex]::Escape("@('hevc','h265','265','av1')")) "av_mux: captura .av1 OBU pe MKV"
Assert-Match $muxPs ([regex]::Escape("`$Target -eq 'mkv' -and `$vExt -eq 'ivf'")) "av_mux: captura .ivf pe MKV"

# ── 5. FUNCTIONAL — AV1 DV IVF → Invoke-HdvCombineWithOriginal → MKV → dvcC ─
$mkvm = if ($env:AV_TOOL_MKVMERGE) { $env:AV_TOOL_MKVMERGE } else { "mkvmerge" }
$av1dovi = if ($env:AV_TOOL_AV1DOVI) { $env:AV_TOOL_AV1DOVI } else { "av1dovi_tool" }
$sample = Get-ChildItem $SRC -Filter '*DV*AV1*.mkv' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($sample -and (Get-Command ffmpeg -EA SilentlyContinue) -and (Get-Command $mkvm -EA SilentlyContinue) -and (Get-Command $av1dovi -EA SilentlyContinue)) {
    Import-AvEncodeFunctions -Names @('Invoke-HdvCombineWithOriginal','Invoke-DvMkvMux','Get-ContainerFlags') | Out-Null
    $td = Join-Path $env:TEMP ("v71_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force $td | Out-Null
    & ffmpeg -v error -y -t 2 -i $sample.FullName -map 0:v:0 -c:v copy -f ivf "$td\v.ivf" 2>$null
    & $av1dovi extract-rpu -i "$td\v.ivf" -o "$td\rb.bin" 2>$null | Out-Null
    if ((Test-Path "$td\rb.bin") -and (Get-Item "$td\rb.bin").Length -gt 0) {
        $r = Invoke-HdvCombineWithOriginal -Modified "$td\v.ivf" -Original $sample.FullName -Output "$td\out.mkv"
        $dvcc = ((& ffprobe -v error -select_streams v:0 -show_streams -show_entries stream_side_data=side_data_type "$td\out.mkv" 2>$null) -join "`n") -match 'DOVI configuration record'
        Assert-Eq $true $dvcc "functional: AV1 DV IVF → Invoke-HdvCombine → MKV cu dvcC"
        & ffmpeg -v error -y -i "$td\out.mkv" -map 0:v:0 -c copy -f ivf "$td\back.ivf" 2>$null
        & $av1dovi extract-rpu -i "$td\back.ivf" -o "$td\ra.bin" 2>$null | Out-Null
        $rpuOk = (Test-Path "$td\ra.bin") -and ((Get-Item "$td\ra.bin").Length -gt 0)
        Assert-Eq $true $rpuOk "functional: DV RPU supravietuieste in MKV"
    } else {
        Write-Host "  (functional sarit: sample fara RPU AV1 extractibil)" -ForegroundColor DarkGray
    }
    Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "  (functional sarit: AV1 DV sample / ffmpeg / mkvmerge / av1dovi_tool lipsesc)" -ForegroundColor DarkGray
}

Invoke-TestSummary
