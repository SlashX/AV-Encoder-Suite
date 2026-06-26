# v77 (PS1) — Constatarea VFR pe caile de preserve cu extract -> inject (HW HDR10+, DV, hibrid, APV).
# Oglinda test_v77_vfr_hdr10plus.sh. Pe sursa VFR numarul de cadre CODATE (din care se extrage
# metadata) difera de cele DECODATE (baza re-encodata). Tratare per cale: DV (dovi_tool) + HW HDR10+
# (hdr10plus_tool) = GRATIOS (aliniaza la coada); APV (engine apv_hdr10plus.py) = BOUNDED-GRACEFUL
# (aliniaza pe decalaj mic ca DV/HW; honest-fail -> HDR10 static doar pe decalaj mare). Suita AVERTIZEAZA
# userul (Test-VfrSource). Test: (1) source-level helper +
# cele 3 avertismente DISTINCTE (DV chokepoint / HW HDR10+ standalone / APV bounded) + avertismentul
# hibrid redundant SCOS + paritate bash; (2) functional Test-VfrSource pe CFR generat vs VFR real.
# NB canarul inject-mismatch testeaza o proprietate a TOOL-ului extern (identica cross-platform) ->
# validat in testul bash; aici acoperim codul NOSTRU (helper + avertismente + detectie).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$proj = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SRC  = Join-Path $proj "src"
$psRaw   = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
$bashRaw = Get-Content (Join-Path $SRC "av_common.sh") -Raw
$apvRaw  = Get-Content (Join-Path $SRC "av_encoder_apv.sh") -Raw

# ── 1. Source-level: helper + avertismente distincte (PS1) ──
Assert-Match $psRaw 'function Test-VfrSource'  "Test-VfrSource definit (PS1)"
Assert-Match $psRaw 'stream=r_frame_rate'      "Test-VfrSource citeste r_frame_rate"
Assert-Match $psRaw 'stream=avg_frame_rate'    "Test-VfrSource citeste avg_frame_rate"
# DV chokepoint (Get-PreserveRpu — acopera HW DV + SW DV + hibridul DV)
Assert-Contains $psRaw 'RPU DV se aliniaza pe pozitie' "avertisment VFR DV in Get-PreserveRpu (PS1)"
# HW HDR10+ standalone
Assert-Contains $psRaw 'HDR10+ se aliniaza pe pozitie la cadrele de output' "avertisment VFR HW HDR10+ standalone (PS1)"
# avertismentul hibrid HDR10+ scos (acoperit de chokepoint-ul DV -> ar fi dublu)
Assert-NotContains $psRaw 'HDR10+ (din lantul DV) se aliniaza' "avertisment hibrid HDR10+ redundant scos (PS1)"
# APV bounded-graceful (aceeasi cale PS1) — fraza distincta de DV / HW HDR10+
Assert-Contains $psRaw 'HDR10+ pe APV se aliniaza la coada' "avertisment VFR APV bounded (PS1)"

# ── 1b. Paritate bash: helper + cele 3 avertismente ──
Assert-Match $bashRaw '_is_vfr_source\(\)' "_is_vfr_source definit (bash paritate)"
Assert-Contains $bashRaw 'RPU DV se aliniaza pe pozitie' "avertisment VFR DV in _extract_preserve_rpu (bash)"
Assert-Contains $bashRaw 'HDR10+ se aliniaza pe pozitie la cadrele de output' "avertisment VFR HW HDR10+ standalone (bash)"
Assert-NotContains $bashRaw 'HDR10+ (din lantul DV) se aliniaza' "avertisment hibrid HDR10+ redundant scos (bash)"
Assert-Contains $apvRaw 'HDR10+ pe APV se aliniaza la coada' "avertisment VFR APV bounded (bash)"

# ── 1c. Santinela regresie -y: extract->temp in run_encode_loop (av_mktemp_ext PRE-CREEAZA
# fisierul → ffmpeg fara -y se agata interactiv / 0 octeti neinteractiv). Dupa fix toate sunt
# "ffmpeg -v error -y -i ..." → forma fara -y NU mai exista. ──
Assert-NotContains $bashRaw 'ffmpeg -v error -i "$output"'         "av_common: extract HW HDR10+/DV are -y (regresie -y)"
Assert-NotContains $bashRaw 'ffmpeg -v error -i "$injected_temp"' "av_common: re-mux fallback are -y (regresie -y)"
Assert-NotContains $bashRaw 'ffmpeg -v error -i "$encoded" -c copy' "av_common: repair HDR10 signaling are -y (regresie -y)"
Assert-NotContains $psRaw   '& ffmpeg -v error -i $outFile'       "av_encode.ps1: extract HW HDR10+/DV are -y (paritate regresie -y)"

# ── 2. Functional: Test-VfrSource clasifica corect ──
Import-AvEncodeFunctions -Names @('Test-VfrSource')
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }

if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("vfr_"+[guid]::NewGuid().ToString("N")+".mp4")
    & ffmpeg -v error -y -f lavfi -i "testsrc=size=128x128:rate=30:duration=1" -c:v libx264 -r 30 $tmp *>$null
    if (Test-Path $tmp) {
        Assert-Eq $false (Test-VfrSource $tmp) "clip CFR generat (r=avg=30) -> NU VFR"
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "  (nota: generare CFR esuata, sar verificarea CFR)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  (nota: ffmpeg lipseste, sar verificarea CFR generat)" -ForegroundColor DarkGray
}

$vfrSample = Join-Path $SRC "Upload_S02E01_HDR10Plus_40s_HEVC.mp4"
if (Test-Path $vfrSample) {
    Assert-Eq $true (Test-VfrSource $vfrSample) "sample HEVC HDR10+ real (r=120 avg~59.76) -> VFR"
} else {
    Write-Host "  (nota: sample VFR real lipseste, sar verificarea VFR)" -ForegroundColor DarkGray
}

Invoke-TestSummary
