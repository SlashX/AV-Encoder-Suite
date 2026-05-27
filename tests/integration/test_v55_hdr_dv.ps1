# v55 — HDR/DV tools (PS1): Convert-RpuProfile (editor pattern) + generate L6 din sursa.
# Mirror al test_v55_hdr_dv.sh. Prinde regresia: `dovi_tool convert -m N --rpu-out` esua in 2.x.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$src  = Join-Path $root 'src'

# dovi_tool: global (PATH) sau in src/ (Windows testing)
if (-not (Get-Command dovi_tool -ErrorAction SilentlyContinue)) { $env:PATH = "$src;$env:PATH" }
if (-not (Get-Command dovi_tool -ErrorAction SilentlyContinue)) { Skip-Test "dovi_tool nu este disponibil" }
if (-not (Get-Command ffmpeg   -ErrorAction SilentlyContinue)) { $env:PATH = "$src;$env:PATH" }

Import-AvEncodeFunctions -Names @(
    'Convert-RpuProfile','Get-ToolForInject','Get-ToolForExtract',
    'Generate-DvRpuFromHdr10Plus',
    'Resolve-Hdr10Static','Get-Hdr10StaticMetadata','Set-Hdr10StaticDefaults'
)
$script:LogFile = $null

$tmp = Join-Path $env:TEMP ("v55test_"+[guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    # ── base RPU ──
    $gen = Join-Path $tmp 'gen.json'
    '{ "cm_version": "V40", "length": 5, "level6": { "max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 1, "max_content_light_level": 1000, "max_frame_average_light_level": 400 } }' | Out-File $gen -Encoding ASCII
    $base = Join-Path $tmp 'base.bin'
    & dovi_tool generate -j $gen -o $base 2>$null | Out-Null
    Assert-FileExists $base 'generate RPU base'

    # ── 1) REGRESIE: sintaxa veche `convert -m N --rpu-out` trebuie sa esueze ──
    & dovi_tool convert -m 2 --rpu-out (Join-Path $tmp 'old.bin') $base 2>$null | Out-Null
    Assert-Nonzero $LASTEXITCODE "sintaxa veche 'convert -m --rpu-out' esueaza in dovi_tool 2.x"

    # ── 2) FIX: Convert-RpuProfile mode=2 ──
    $conv2 = Join-Path $tmp 'conv2.bin'
    $ok2 = Convert-RpuProfile -RpuIn $base -RpuOut $conv2 -Mode 2 -TargetCodec hevc
    Assert-Eq $true $ok2 "Convert-RpuProfile mode=2 returneaza true"
    Assert-FileExists $conv2 "convert mode=2 produce RPU"

    # ── 3) FIX: Convert-RpuProfile mode=5 (8.1 preserving mapping) ──
    $conv5 = Join-Path $tmp 'conv5.bin'
    $ok5 = Convert-RpuProfile -RpuIn $base -RpuOut $conv5 -Mode 5 -TargetCodec hevc
    Assert-Eq $true $ok5 "Convert-RpuProfile mode=5 returneaza true"
    Assert-FileExists $conv5 "convert mode=5 produce RPU"

    # ── 4) info -s (summary) ──
    $summary = (& dovi_tool info -i $conv2 -s 2>$null) -join "`n"
    Assert-Match $summary 'Profile' "info -s contine 'Profile'"
    Assert-Match $summary 'Frames' "info -s contine 'Frames'"

    # ── 5) Generate-DvRpuFromHdr10Plus cu SourceFile (L6 din sursa) ──
    # Extragem HDR10+ JSON direct cu binarul (evita lantul Extract-Hdr10PlusMetadata,
    # fragil in harness-ul AST). Necesita o sursa HDR10+ HEVC reala; altfel skip.
    $hdrSrc = (Get-ChildItem -Path $src -Filter '*HDR10Plus*HEVC*.mp4' -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($hdrSrc -and (Get-Command hdr10plus_tool -ErrorAction SilentlyContinue)) {
        $raw = Join-Path $tmp 'raw.hevc'; $hpj = Join-Path $tmp 'hp.json'
        & ffmpeg -v error -i $hdrSrc.FullName -c:v copy -bsf:v hevc_mp4toannexb -f hevc $raw 2>$null | Out-Null
        & hdr10plus_tool extract -i $raw -o $hpj 2>$null | Out-Null
        if ((Test-Path $hpj) -and (Get-Item $hpj).Length -gt 0) {
            $rpuG = [string](Generate-DvRpuFromHdr10Plus -hdr10plusJson $hpj -TargetCodec hevc -SourceFile $hdrSrc.FullName)
            Assert-Eq $true ([bool]($rpuG -and (Test-Path -LiteralPath $rpuG))) "Generate-DvRpuFromHdr10Plus (SourceFile) produce RPU"
            if ($rpuG -and (Test-Path -LiteralPath $rpuG)) { Remove-Item -LiteralPath $rpuG -Force -ErrorAction SilentlyContinue }
        }
    } else {
        Write-Host "  ~ (skip partial) niciun sample HDR10+ pentru test generate L6"
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-TestSummary
