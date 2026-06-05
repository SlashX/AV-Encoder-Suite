# v63 — HDR/DV transformation round-trip (mirror PS1: Inject-DvRpu + Repair-Av1DvT35 + Test-DvSurvived).
#   Lantul critic AV1 DV: extract → remove → inject (+T.35 repair) → mux → verify. Functionalul ruleaza
#   DOAR cand sample-urile reale + tool-urile (av1dovi_tool, python) sunt prezente; altfel source-level.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$ENC    = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
$ENGINE = Get-Content (Join-Path $SRC "av1_dv_t35_repair.py") -Raw

# ── 1. Source-level — lantul T.35 repair (PS1) ──
Assert-Match $ENC 'function Repair-Av1DvT35'                      "PS1: Repair-Av1DvT35 definit"
Assert-Match $ENC ([regex]::Escape('$TargetCodec -eq "av1"'))    "PS1 Inject-DvRpu: T.35 repair gateat pe AV1"
Assert-Match $ENC 'Repair-Av1DvT35'                              "PS1 Inject-DvRpu: cheama Repair-Av1DvT35"
Assert-Match $ENC 'function Test-DvSurvived'                     "PS1: Test-DvSurvived (plasa de siguranta)"
Assert-Match $ENC 'function Get-DvRpu'                           "PS1: Get-DvRpu (extract RPU)"

# ── 2. Engine Python — surgical DV (0x003B), sare HDR10+ (0x003C) ──
Assert-Match $ENGINE ([regex]::Escape('DV_PROVIDER = 0x003B'))   "engine: provider DV 0x003B"
Assert-Match $ENGINE ([regex]::Escape('b"\x80"'))               "engine: re-adauga 0x80"
Assert-Match $ENGINE 'copy verbatim'                            "engine: non-DV (HDR10+) intact"

# ── 3. Functional — round-trip pe sample real (skip daca lipseste) ──
$dvAv1 = Join-Path $SRC "Upload_S02E01_DV_40s_AV1.mkv"
$haveTool = [bool](Get-Command av1dovi_tool -EA SilentlyContinue) -and `
            ([bool](Get-Command python3 -EA SilentlyContinue) -or [bool](Get-Command python -EA SilentlyContinue)) -and `
            [bool](Get-Command ffmpeg -EA SilentlyContinue)
if ($haveTool -and (Test-Path $dvAv1)) {
    $script:AV_TEMP_DIR = Join-Path ([IO.Path]::GetTempPath()) ("hrt_"+[guid]::NewGuid().ToString('N'))
    $AV_TEMP_DIR = $script:AV_TEMP_DIR; New-Item -ItemType Directory -Force $AV_TEMP_DIR | Out-Null
    Import-AvEncodeFunctions -Names @("Get-FFprobeValue","Get-SourceCodec","Get-ToolForExtract","Get-ToolForInject","Get-DvRpu","Get-RawVideo","Remove-DvLayer","Inject-DvRpu","Repair-Av1DvT35","_Get-AvPython","Test-DvSurvived")
    $T = $AV_TEMP_DIR
    $ok = (Get-DvRpu -InputFile $dvAv1 -RpuOut "$T\rpu.bin" -SourceCodec av1)
    Get-RawVideo -InputFile $dvAv1 -OutputFile "$T\raw.ivf" -Codec av1 | Out-Null
    Remove-DvLayer -InputFile "$T\raw.ivf" -OutputFile "$T\base.ivf" -Codec av1 | Out-Null
    Inject-DvRpu -hevcFile "$T\base.ivf" -rpuFile "$T\rpu.bin" -outputFile "$T\inj.ivf" -TargetCodec av1 2>$null | Out-Null
    & ffmpeg -y -v error -i "$T\inj.ivf" -c:v copy "$T\final.mkv" 2>$null | Out-Null
    if (Test-Path "$T\final.mkv") {
        Assert-Eq $true (Test-DvSurvived -File "$T\final.mkv" -Codec av1) "functional: AV1 DV supravietuieste (PS1 T.35 repair)"
        # Contrast: inject FARA repair → DV pierdut
        & av1dovi_tool inject-rpu -i "$T\base.ivf" --rpu-in "$T\rpu.bin" -o "$T\nr.ivf" 2>$null | Out-Null
        & ffmpeg -y -v error -i "$T\nr.ivf" -c:v copy "$T\nr.mkv" 2>$null | Out-Null
        if (Test-Path "$T\nr.mkv") {
            Assert-Eq $false (Test-DvSurvived -File "$T\nr.mkv" -Codec av1) "functional contrast: fara repair → DV pierdut (repair esential)"
        }
    }
    Remove-Item $AV_TEMP_DIR -Recurse -Force -EA SilentlyContinue
} else {
    Write-Host "  (functional sarit — sample AV1 DV / tool av1dovi_tool/python lipsa; source-level acoperit)" -ForegroundColor DarkGray
}
Invoke-TestSummary
