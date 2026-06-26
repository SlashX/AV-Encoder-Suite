# v77 — probe functional AV1 HW pe Windows (PS1). Pana acum Get-GPUCapabilities ghicea PUR pe
#   regex WMI; v77 adauga Test-HwAv1Encoder (micro-encode real) si cableaza `regex || probe` pe
#   nvidia/intel/amd (oglinda bash). Source-level + FUNCTIONAL portabil (mecanismul helperului pe
#   libx264 vs encoder inexistent — independent de hardware) + integrare (Get-GPUCapabilities
#   ruleaza probe-ul si returneaza av1Support fara sa arunce). Calea "probe → true pe AV1 HW real"
#   e netestabila aici (boxa n-are AV1 HW discret) — ACELASI caveat ca auditul HW v75; dar
#   mecanismul e dovedit: libx264 (merge → True) vs encoder bogus (lipsa → False).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"
$proj = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$enc  = Get-Content "$proj\src\av_encode.ps1" -Raw

# ── 1. Helper Test-HwAv1Encoder definit ──
Assert-Match $enc 'function Test-HwAv1Encoder' "Test-HwAv1Encoder definit"

# ── 2. format=nv12 OBLIGATORIU + *>$null (NU pipe cu Select-Object → ar corupe $LASTEXITCODE, v75) ──
Assert-Match $enc '-vf format=nv12 -c:v \$Enc -f null - \*>\$null' "probe: format=nv12 + *>`$null (fara pipe)"
Assert-Match $enc 'return \(\$LASTEXITCODE -eq 0\)'                "probe: verdict din `$LASTEXITCODE"

# ── 3. Get-GPUCapabilities cableaza regex || probe (gated pe vendor prezent + encoder listat) ──
Assert-Match $enc "av1_\(nvenc\|qsv\|amf\)"                              "interogheaza ffmpeg -encoders pt AV1 HW"
Assert-Match $enc "-not \`$nvAv1\s+-and.+Test-HwAv1Encoder 'av1_nvenc'"  "NVIDIA: regex NU -> probe av1_nvenc"
Assert-Match $enc "-not \`$intelAv1 -and.+Test-HwAv1Encoder 'av1_qsv'"   "Intel: regex NU -> probe av1_qsv"
Assert-Match $enc "-not \`$amdAv1\s+-and.+Test-HwAv1Encoder 'av1_amf'"   "AMD: regex NU -> probe av1_amf"

# ── 4. FUNCTIONAL portabil: mecanismul helperului (independent de AV1 HW pe boxa) ──
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$proj\src;$env:PATH" }
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    Import-AvEncodeFunctions -Names @("Test-HwAv1Encoder")
    Assert-Eq $true  (Test-HwAv1Encoder 'libx264')          "helper -> True cand encoderul MERGE (libx264, surogat SW)"
    Assert-Eq $false (Test-HwAv1Encoder 'zzz_bogus_encoder') "helper -> False cand encoderul LIPSESTE/pica (fara fals-pozitiv)"

    # Integrare: Get-GPUCapabilities ruleaza probe-ul (pe edge) si returneaza structura (no-throw)
    Import-AvEncodeFunctions -Names @("Get-GPUCapabilities","Test-HwAv1Encoder")
    $caps = Get-GPUCapabilities
    Assert-Eq $true ($caps -is [hashtable])             "Get-GPUCapabilities returneaza hashtable"
    Assert-Eq $true ($caps.ContainsKey('av1Support'))   "Get-GPUCapabilities returneaza av1Support (integrare no-throw)"
    $av1s = $caps.av1Support
    Assert-Eq $true ($av1s.ContainsKey('nvidia') -and $av1s.ContainsKey('intel') -and $av1s.ContainsKey('amd')) "av1Support are cheile nvidia/intel/amd"
} else {
    Write-Host "  (functional sarit - ffmpeg lipseste)" -ForegroundColor DarkGray
}

Invoke-TestSummary
