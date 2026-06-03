# Test v45 features (PS1 mirror):
# - Show-Hdr10PlusDialog: source-codec gate (P3 fix)
# - Invoke-Hdr10PlusToDv: function presence (P2)
# - DV preserve in x265 HEVC flow: source markers in av_encode.ps1
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$srcPath = Join-Path $root 'src\av_encode.ps1'
$srcText = Get-Content -LiteralPath $srcPath -Raw

# ─────────────────────────────────────────────────────────────────
# 1) P3 — Show-Hdr10PlusDialog foloseste source-codec pentru gate
# Verificare prin inspectie sursa (parse AST si verifica corpul functiei).
# ─────────────────────────────────────────────────────────────────
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($srcPath, [ref]$tokens, [ref]$errors)
$funcs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

$dlg = $funcs | Where-Object { $_.Name -eq 'Show-Hdr10PlusDialog' } | Select-Object -First 1
if ($dlg) { _pass } else { _fail "Show-Hdr10PlusDialog defined" }
$dlgText = $dlg.Extent.Text

# Trebuie sa apeleze Get-SourceCodec pentru a obtine codec-ul sursei
Assert-Match $dlgText 'Get-SourceCodec' "P3: dialog calls Get-SourceCodec"
# Gate-ul folosit pt Hdr10Plus tool trebuie sa primeasca srcCodec, nu TargetCodec
Assert-Match $dlgText 'Test-Hdr10PlusToolFor\s+-Codec\s+\$srcCodec' "P3: hdr10plus gate uses srcCodec"
# Branch-ul de tool-missing trebuie sa raporteze codec-ul sursei
Assert-Match $dlgText '\$srcCodec\s+-eq\s+"av1"' "P3: missing-tool branch decides hint by source codec"

# ─────────────────────────────────────────────────────────────────
# 2) P2 — Invoke-Hdr10PlusToDv definita + wired in Invoke-HdrDvTools
# ─────────────────────────────────────────────────────────────────
$hdvFn = $funcs | Where-Object { $_.Name -eq 'Invoke-Hdr10PlusToDv' } | Select-Object -First 1
if ($hdvFn) { _pass } else { _fail "Invoke-Hdr10PlusToDv defined" }

$menu = $funcs | Where-Object { $_.Name -eq 'Invoke-HdrDvTools' } | Select-Object -First 1
if ($menu) { _pass } else { _fail "Invoke-HdrDvTools defined" }
$menuText = $menu.Extent.Text
Assert-Match $menuText 'HDR10\+ → DV hybrid' "menu has HDR10+ → DV hybrid label"
# v49: renumerotat dupa scoaterea Remux container; v56: meniu extins la 7 opt
Assert-Match $menuText '"3"\s*\{\s*Invoke-Hdr10PlusToDv' "menu opt 3 wired to Invoke-Hdr10PlusToDv (v49)"
Assert-Match $menuText '"7"\s*\{\s*return' "menu opt 7 = Inapoi (v56: meniu extins 1-7)"

# ─────────────────────────────────────────────────────────────────
# 3) P1 — DV preserve markers in HEVC encode flow
# ─────────────────────────────────────────────────────────────────
Assert-Match $srcText 'DV preserve \(HEVC' "P1: HEVC DV preserve dialog text present"
Assert-Match $srcText '\$tripleLayerTargetCodec\s*=\s*"hevc"' "P1: HEVC DV preserve sets tripleLayerTargetCodec=hevc"
Assert-Match $srcText 'canDvPreserve' "P1: HEVC DV preserve gating variable present"

# ─────────────────────────────────────────────────────────────────
# 4) Helpers folosite de pipeline (P1 + P2)
# ─────────────────────────────────────────────────────────────────
foreach ($name in @('Get-DvRpu','Generate-DvRpuFromHdr10Plus','Extract-Hdr10PlusMetadata','Get-RawVideo','Inject-DvRpu')) {
    $f = $funcs | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($f) { _pass } else { _fail "$name defined" }
}

# ─────────────────────────────────────────────────────────────────
# 5) DOVI + HDR10+ co-existence fix (PS1 mirror)
# Verifica ca branch-urile DV preserve in HEVC si AV1 contin extract
# HDR10+ inline cand sursa are AMANDOUA (si tripleLayerMode setat).
# ─────────────────────────────────────────────────────────────────
# HEVC DV preserve branch trebuie sa extraga HDR10+ inline:
Assert-Match $srcText 'HDR10\+ embedded \+ DV preserve' "DOVI+HDR10+ co-existence: HEVC branch has inline HDR10+ extract path"
# v61: calea JSON e referita prin nume gol (Get-InlineParamName) — drive-colon Windows
Assert-Match $srcText 'dhdr10-info=\$\(Get-InlineParamName \$hdr10PlusJson\)' "DOVI+HDR10+ co-existence: HEVC branch sets dhdr10-info= (v61 nume gol)"
# AV1 DV preserve branch trebuie sa extraga HDR10+ inline (svtav1-params):
Assert-Match $srcText 'hdr10plus-json=\$\(Get-InlineParamName \$hdr10PlusJson\)' "DOVI+HDR10+ co-existence: AV1 branch sets hdr10plus-json= (v61 nume gol)"

# ─────────────────────────────────────────────────────────────────
# 6) DOVI_PRESERVE_POLICY — schema + dialog bypass markers
# ─────────────────────────────────────────────────────────────────
Import-AvEncodeFunctions -Names @('Get-ProfileSchema','Test-ProfileFile')
Assert-Eq "enum:,auto,preserve,convert,copy,skip" (Get-ProfileSchema -Key "DOVI_PRESERVE_POLICY") "DOVI_PRESERVE_POLICY schema enum"

$testProf = New-TemporaryFile
'DOVI_PRESERVE_POLICY="preserve"' | Out-File -LiteralPath $testProf.FullName -Encoding ASCII
$res = Test-ProfileFile -Path $testProf.FullName
if ($res.ok) { _pass } else { _fail "DOVI_PRESERVE_POLICY=preserve valid" }

'DOVI_PRESERVE_POLICY="bogus"' | Out-File -LiteralPath $testProf.FullName -Encoding ASCII
$res = Test-ProfileFile -Path $testProf.FullName
if (-not $res.ok) { _pass } else { _fail "DOVI_PRESERVE_POLICY=bogus rejected" }
Remove-Item -LiteralPath $testProf.FullName -Force

# Dialog bypass markers in source
Assert-Match $srcText 'DOVI_PRESERVE_POLICY' "PS1 honors DOVI_PRESERVE_POLICY in DV dialogs"

Invoke-TestSummary
