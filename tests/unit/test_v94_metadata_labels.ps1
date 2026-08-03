# v94 — onestitatea mesajelor din pipeline-ul de metadata (mirror PS1 al
# test_v94_metadata_labels.sh).
#
#   B14 (onestitate): eticheta „Triple-layer" era HARDCODATA cu trei straturi, dar
#     tripleLayerMode se seteaza la ORICE DV-preserve — inclusiv pe surse fara HDR10+.
#     Dovedit prin meniuri: „DV 8.1 + HDR10 + HDR10+ (HEVC) — OK" pe fisier cu ZERO cadre
#     HDR10+; iar pe AV1 fara `hdr10plus-json` stratul chiar se pierdea, cu userul
#     informat ca a supravietuit.
#   O7: „N scene descriptors" numara doua chei care coexista in aceeasi intrare → 2x.
#   O8: linia „HEVC level" aparea si pe APV/ProRes/DNxHR (bash nu o afiseaza acolo).
#   O9: ramura KB din Format-Bytes n-avea specificator → „490,43359375 KB".
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
$ENC  = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw

# ── B14: eticheta e COMPUSA, nu hardcodata ─────────────────────────────
Assert-Match $ENC ([regex]::Escape('$tlHp    = if ($script:hdr10PlusInlineApplied) { " + HDR10+" } else { "" }')) `
    "B14: sufixul HDR10+ vine din flagul de stare"
Assert-Match $ENC ([regex]::Escape('$tlLabel = if ($tlCodec -eq "av1") { "DV P10 + HDR10$tlHp (AV1)" } else { "DV 8.1 + HDR10$tlHp (HEVC)" }')) `
    "B14: ambele etichete compuse din flag"
# santinela anti-revert: in run-loop nu mai exista eticheta cu HDR10+ hardcodat.
# (Show-Hdr10PlusDialog descrie OPTIUNEA de meniu — acolo „HDR10+" e legitim.)
$loopPart = $ENC.Substring($ENC.IndexOf('# ── Triple-layer: injecteaza DV RPU in output'))
$hard = ([regex]::Matches($loopPart, 'HDR10 \+ HDR10\+ \((AV1|HEVC)\)')).Count
Assert-Eq 0 $hard "B14: zero etichete cu HDR10+ hardcodat pe calea de raportare"

# ── B14: flagul se seteaza la fiecare sit care chiar aplica inline-ul ──
$applied = ([regex]::Matches($ENC, [regex]::Escape('$script:hdr10PlusInlineApplied = $true'))).Count
Assert-Eq 6 $applied "B14: toate cele 6 situri de inject inline marcheaza flagul"

# ── B14: reset per-fisier (regula obligatorie de state) ────────────────
Assert-Match $ENC ([regex]::Escape('$script:hdr10PlusInlineApplied = $false')) `
    "B14: flagul e resetat defensiv per fisier"

# ── B14: mesajele de fallback folosesc acelasi sufix conditionat ───────
Assert-Match $ENC ([regex]::Escape('output pastreaza HDR10$tlHp')) `
    "B14: mesajul de DV-pierdut nu mai revendica HDR10+ fix"
Assert-Match $ENC ([regex]::Escape('output fara DV (HDR10$tlHp pastrat)')) `
    "B14: mesajul de re-mux esuat nu mai revendica HDR10+ fix"

# ── O7: numaram SCENE, nu chei care coexista in aceeasi intrare ────────
Assert-Match $ENC ([regex]::Escape('$count = (Select-String -Path $jsonFile -Pattern "SequenceFrameIndex" -AllMatches).Matches.Count')) `
    "O7: numaratoarea foloseste o cheie unica per intrare"
# Al 2-lea sit, gasit chiar de santinela asta: HDR/DV tools → Inspect metadata.
Assert-Match $ENC ([regex]::Escape('$scenes = (Select-String -Path $hpJson -Pattern "SequenceFrameIndex" -AllMatches).Matches.Count')) `
    "O7: si fluxul Inspect numara scene, nu chei"
# anti-revert: pattern-ul dublu nu mai apare in COD (comentariile care il explica sunt OK)
$dbl = @(Get-Content (Join-Path $SRC "av_encode.ps1") |
         Where-Object { $_ -match 'BezierCurveData' -and $_ -notmatch '^\s*#' }).Count
Assert-Eq 0 $dbl "O7: pattern-ul care numara dublu a disparut din cod"

# ── O8: linia de level e gateata pe codecurile care CHIAR au level-uri ─
Assert-Match $ENC ([regex]::Escape('if (-not $useDNxHR -and -not $useProRes -and -not $useAPV) {')) `
    "O8: level-ul nu se mai afiseaza pe mezzanine"

# ── O9 + B14 functional: logica pe valori reale ────────────────────────
Import-AvEncodeFunctions -Names @('Format-Bytes')
Assert-Eq "490 KB"  (Format-Bytes 502204)    "O9: KB fara zecimale parazite"
Assert-Eq "11 KB"   (Format-Bytes 11304)     "O9: KB mic"
Assert-Eq "12,2 MB" (Format-Bytes 12800000)  "O9: ramura MB neschimbata"

# O9 — TOATE copiile, nu doar cea din av_encode. `Format-Bytes` e duplicat in av_check.ps1
# (standalone, nu importa av_encode) si acolo fixul lipsea la prima trecere — gasit la
# auditul Faza 4. av_telemetry.ps1 are propria varianta cu `{0:N2}` pe toate ramurile,
# deci e deja formatata; o verificam sa nu regreseze la double brut.
foreach ($cp in @(
    @{ File = 'av_encode.ps1';   Want = '490 KB' },
    @{ File = 'av_check.ps1';    Want = '490 KB' },
    @{ File = 'av_telemetry.ps1';Want = '490,43 KB' }
)) {
    $txt = Get-Content (Join-Path $SRC $cp.File) -Raw
    $m   = [regex]::Match($txt, '(?ms)^function Format-Bytes.*?^\}')
    Assert-Eq $true $m.Success "O9: Format-Bytes exista in $($cp.File)"
    $got = & ([scriptblock]::Create($m.Value + "`nFormat-Bytes 502204"))
    Assert-Eq $cp.Want $got "O9: $($cp.File) formateaza KB (fara double brut)"
}

# B14 — eticheta compusa, pe toate cele 4 combinatii (aceeasi expresie ca in productie)
foreach ($hpOn in $false, $true) {
    foreach ($codec in 'hevc', 'av1') {
        $tlHp    = if ($hpOn) { " + HDR10+" } else { "" }
        $tlLabel = if ($codec -eq "av1") { "DV P10 + HDR10$tlHp (AV1)" } else { "DV 8.1 + HDR10$tlHp (HEVC)" }
        $want = if ($hpOn) {
            if ($codec -eq 'av1') { "DV P10 + HDR10 + HDR10+ (AV1)" } else { "DV 8.1 + HDR10 + HDR10+ (HEVC)" }
        } else {
            if ($codec -eq 'av1') { "DV P10 + HDR10 (AV1)" } else { "DV 8.1 + HDR10 (HEVC)" }
        }
        Assert-Eq $want $tlLabel "B14: eticheta corecta (hdr10plus_aplicat=$hpOn, codec=$codec)"
    }
}

Invoke-TestSummary
