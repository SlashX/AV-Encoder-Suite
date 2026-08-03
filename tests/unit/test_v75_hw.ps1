# v75 — HW encode audit (PS1): NVENC CRF (constqp -> vbr -cq, paritate bash), ramura
#   HDR10+ pe HW (avertisment drop dinamic), AMF usage transcoding + profile AV1.
#   Source-level pe av_encode.ps1. NVENC/AMF = netestabile functional (lipsa GPU NVIDIA/AMD).
. "$PSScriptRoot\..\framework.ps1"
$proj = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$enc  = Get-Content "$proj\src\av_encode.ps1" -Raw

# ── 1. NVENC CRF: vbr -cq -b:v 0 (nu constqp) ──
Assert-Match       $enc '"-rc","vbr","-cq",\$hwEncQP,"-b:v","0"' "NVENC CRF = vbr -cq -b:v 0 (paritate bash)"
Assert-NotContains $enc '"constqp"'                              "flag constqp eliminat din NVENC CRF"

# ── 2. Ramura HDR10+ pe HW (avertisment + skip; static HDR10 ramane) ──
Assert-Match $enc '\$si\.isHDRPlus -and -not \$hwDoVi'  "ramura HDR10+ pe HW prezenta"
Assert-Match $enc 'HDR10\+ dinamic'                     "avertisment drop HDR10+ dinamic"

# ── 3. AMF: usage transcoding + profile main pe AV1 (paritate bash) ──
Assert-Match $enc '\$hwAmfExtra'                  "hwAmfExtra definit"
Assert-Match $enc '"-usage","transcoding"'        "AMF usage transcoding"
Assert-Match $enc 'av1_amf.*-profile:v","main"'   "AMF AV1 profile main"

# ── 4. v75 audit: AV1 DV detectat pe caile de ENCODE via $logInfo.isDV (Get-SourceInfoExtended,
#      fallback side_data) — NU codec_tag. AV1 DV are codec_tag [0][0][0][0] (DV in side_data) →
#      check-ul vechi pe codec_tag il rata → dialogul DV (inclusiv preserve P10/8.1) nu aparea,
#      DV pierdut tacut + blocul HDR10+ HW trata hibridul AV1 DV+HDR10+ ca simplu HDR10+.
#      Paritate cu bash detect_source_info (DOVI via side_data, fix v58). ──
Assert-Match $enc 'isDV\s+= \[bool\]\$dovi'      "Get-SourceInfoExtended returneaza isDV (cu fallback side_data)"
Assert-Match $enc '\$doViAv1 = \$logInfo\.isDV'  "av1 encode gate: DV via logInfo.isDV (prinde AV1 DV)"
Assert-Match $enc '\$hwDoVi = \$logInfo\.isDV'   "HW encode gate: DV via logInfo.isDV (prinde AV1 DV)"
Assert-Match $enc '\$doVi = \$logInfo\.isDV'     "x265 encode gate: DV via logInfo.isDV (prinde AV1 DV)"
# Smart-copy GUARD ramane pe codec_tag (deliberat — ofera copy lossless pe AV1 DV inainte de dialog)
Assert-Match $enc '\$doviSmart = & ffprobe.*codec_tag_string' "smart-copy guard ramane codec_tag (copy lossless AV1 DV)"

# ── 5. v75 audit: etichetele de afisare DV folosesc detectia side_data (nu codec_tag) →
#      AV1 DV nu mai apare gresit "HDR10" in analiza x264 / sumarul pre-encode. ──
Assert-Match $enc '\[bool\]\$isHdr, \[bool\]\$isDV'      "Show-X264Dialog primeste param isDV"
Assert-Match $enc 'if \(\$isDV\) \{ \$srcLabel = "Dolby Vision' "eticheta x264 DV via param isDV (nu codec_tag)"
Assert-Match $enc 'Show-X264Dialog .+\$logInfo\.isDV'   "call-site x264 paseaza logInfo.isDV"
# NB (v94): regexul e tolerant la spatiere — linia face parte dintr-un lant `if/elseif`
# aliniat pe coloane, iar santinela pazeste PROPRIETATEA (conditia e `$chkLogInfo.isDV`,
# adica detectia din side_data, NU `codec_tag`), nu formatarea.
Assert-Match $enc 'if\s+\(\$chkLogInfo\.isDV\)\s*\{\s*\$tipHdr = "Dolby Vision"' "sumar pre-encode foloseste chkLogInfo.isDV"

# ── 6. v75 audit: ramura HDR10 simplu pe HW re-afirma VUI prin BSF (paritate bash
#      _hw_hdr_setup hw_hdr10; robust pe TOATE backendurile, nu doar QSV-propagare). ──
Assert-Match $enc '\$si\.isHDR -and -not \$si\.isHDRPlus -and -not \$hwDoVi -and -not \$logInfo\.isHLG' "ramura HDR10 simplu izolata (non-plus/non-DV/non-HLG)"

# ── 7. v75 audit FUNCTIONAL: Get-SourceInfoExtended.isDV pe matricea DV reala ──
#   Bug-ul (gate-uri codec_tag-only) rata ORICE DV cu codec_tag != dvhe/dvh1:
#     • AV1 DV       → codec_tag [0][0][0][0] (DV in side_data)
#     • HEVC DV P8.1 → codec_tag hvc1 (HDR10-compatible) → fara fix = "HDR10"
#     • HEVC DV P8.4 → codec_tag hvc1 (HLG-compatible)   → fara fix = "HLG"
#   Doar HEVC P5/P7 poarta dvhe/dvh1. Fix-ul (isDV via side_data "Dolby Vision Metadata",
#   codec-AGNOSTIC) le prinde pe toate. Importam FUNCTIA REALA (nu o replica) — pe surse
#   non-DJI/non-APV doar Get-FFprobeValue ruleaza efectiv. Skip gratios fara ffprobe/sample.
. "$PSScriptRoot\..\_helpers.ps1"
$SRC = Join-Path $proj "src"
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$dvMatrix = [ordered]@{
    "Test-Jellyfin-4K-DV-P5.mp4"             = $true   # HEVC DV P5  (dvh1 → calea codec_tag)
    "Test-Jellyfin-4K-DV-P8.1.mp4"           = $true   # HEVC DV P8.1 (hvc1 → DOAR side_data)
    "Test-Jellyfin-4K-DV-P8.4.mp4"           = $true   # HEVC DV P8.4 (hvc1 → DOAR side_data)
    "Upload_S02E01_DV_40s_AV1.mkv"           = $true   # AV1 DV (tag gol → side_data)
    "Upload_S02E01_DV_HDR10Plus_40s_AV1.mkv" = $true   # AV1 hibrid DV+HDR10+ (nu = HDR10+only)
    "Upload_S02E01_HDR10Plus_40s_AV1.mkv"    = $false  # AV1 HDR10+only → fara fals-pozitiv
    "Upload_S02E01_HDR10Plus_40s_HEVC.mp4"   = $false  # HEVC HDR10+only → fara fals-pozitiv
}
$dvPresent = @($dvMatrix.Keys | Where-Object { Test-Path (Join-Path $SRC $_) })
if ((Get-Command ffprobe -ErrorAction SilentlyContinue) -and $dvPresent.Count -gt 0) {
    $script:forceLogDetection = $false
    Import-AvEncodeFunctions -Names @("Get-FFprobeValue","Get-SourceInfoExtended")
    $djiStub = @{ isDji = $false }
    foreach ($name in $dvPresent) {
        $info = Get-SourceInfoExtended (Join-Path $SRC $name) $djiStub
        Assert-Eq $dvMatrix[$name] ([bool]$info.isDV) "isDV real: $name -> $($dvMatrix[$name])"
    }
    # Premisa bug-ului (santinela): P8.1/P8.4 au codec_tag hvc1 (NU dvhe/dvh1) — codec_tag-only
    # le-ar rata. Daca cineva revine la codec_tag pe gate-uri, aceste 2 aserturi cad.
    foreach ($p8 in @("Test-Jellyfin-4K-DV-P8.1.mp4","Test-Jellyfin-4K-DV-P8.4.mp4")) {
        $pp = Join-Path $SRC $p8
        if (Test-Path $pp) {
            $tag = (& ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=noprint_wrappers=1:nokey=1 $pp 2>$null | Select-Object -First 1)
            Assert-Eq $false ([bool]("$tag" -match 'dovi|dvhe|dvh1')) "premisa bug: $p8 tag='$tag' (NU dvhe/dvh1) -> codec_tag-only l-ar rata"
        }
    }
} else {
    Write-Host "  (sectiunea 7 functionala sarita - lipsa ffprobe sau sample-uri DV in src/)" -ForegroundColor DarkGray
}

Invoke-TestSummary
