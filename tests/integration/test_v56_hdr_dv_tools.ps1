# v56 — HDR/DV tools extinse (PS1): Remove-DvLayer / Remove-Hdr10PlusMetadata /
# Test-Hdr10PlusPresent / Export-DvRpuJson / Get-DvPlot. Mirror al test_v56_hdr_dv_tools.sh.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$src  = Join-Path $root 'src'

if (-not (Get-Command dovi_tool -ErrorAction SilentlyContinue)) { $env:PATH = "$src;$env:PATH" }
if (-not (Get-Command dovi_tool -ErrorAction SilentlyContinue)) { Skip-Test "dovi_tool nu este disponibil" }
if (-not (Get-Command ffmpeg    -ErrorAction SilentlyContinue)) { $env:PATH = "$src;$env:PATH" }

Import-AvEncodeFunctions -Names @(
    'Get-ToolForExtract','Get-RawVideo','Get-DvRpu',
    'Remove-DvLayer','Remove-Hdr10PlusMetadata','Test-Hdr10PlusPresent',
    'Export-DvRpuJson','Get-DvPlot','Test-DvSurvived'
)
$script:LogFile = $null

$tmp = Join-Path $env:TEMP ("v56test_"+[guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    # ── base RPU (Profile 8.1, level6) ──
    $gen = Join-Path $tmp 'gen.json'
    '{ "cm_version": "V40", "length": 5, "level6": { "max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 1, "max_content_light_level": 1000, "max_frame_average_light_level": 400 } }' | Out-File $gen -Encoding ASCII
    $base = Join-Path $tmp 'base.bin'
    & dovi_tool generate -j $gen -o $base 2>$null | Out-Null
    Assert-FileExists $base 'generate RPU base'

    # ── 1) Export-DvRpuJson (all) ──
    $exp = Join-Path $tmp 'exp.json'
    $okExp = Export-DvRpuJson -RpuIn $base -OutJson $exp -Kind 'all' -Codec hevc
    Assert-Eq $true $okExp "Export-DvRpuJson (all) returneaza true"
    Assert-FileExists $exp "export produce JSON"

    # ── 2) Get-DvPlot (l1) ──
    $png = Join-Path $tmp 'plot_l1.png'
    $okPlot = Get-DvPlot -RpuIn $base -OutPng $png -PlotType l1 -Title 'test L1' -Codec hevc
    Assert-Eq $true $okPlot "Get-DvPlot l1 returneaza true"
    Assert-FileExists $png "plot l1 produce PNG"

    # ── 3) Get-DvPlot fara titlu (ramura optionala) ──
    $png2 = Join-Path $tmp 'plot_nt.png'
    $okPlot2 = Get-DvPlot -RpuIn $base -OutPng $png2 -PlotType l1 -Title '' -Codec hevc
    Assert-Eq $true $okPlot2 "Get-DvPlot fara titlu returneaza true"

    # ── 4) Export pe RPU inexistent → false ──
    $okBad = Export-DvRpuJson -RpuIn (Join-Path $tmp 'nope.bin') -OutJson (Join-Path $tmp 'x.json') -Kind 'all' -Codec hevc
    Assert-Eq $false $okBad "export pe RPU inexistent returneaza false"

    # ── 5) Surse reale: HDR10+ HEVC → verify + remove + verify ──
    $hdrSrc = (Get-ChildItem -Path $src -Filter '*HDR10Plus*HEVC*.mp4' -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($hdrSrc -and (Get-Command hdr10plus_tool -ErrorAction SilentlyContinue)) {
        $present = Test-Hdr10PlusPresent -InputFile $hdrSrc.FullName -Codec hevc
        Assert-Eq $true $present "Test-Hdr10PlusPresent pe sursa HDR10+ → prezent"

        $raw = Join-Path $tmp 'raw.hevc'; $clean = Join-Path $tmp 'clean.hevc'
        & ffmpeg -y -v error -i $hdrSrc.FullName -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb -f hevc $raw 2>$null | Out-Null
        $okRm = Remove-Hdr10PlusMetadata -InputFile $raw -OutputFile $clean -Codec hevc
        Assert-Eq $true $okRm "Remove-Hdr10PlusMetadata returneaza true"
        Assert-FileExists $clean "remove HDR10+ produce bitstream"

        $presentAfter = Test-Hdr10PlusPresent -InputFile $clean -Codec hevc
        Assert-Eq $false $presentAfter "Test-Hdr10PlusPresent dupa remove → absent"

        # guard onestitate: sursa HDR10+ HEVC nu are DV → Test-DvSurvived false
        Assert-Eq $false (Test-DvSurvived -File $hdrSrc.FullName -Codec hevc) "Test-DvSurvived pe sursa fara DV → false"
    } else {
        Write-Host "  ~ (skip partial) niciun sample HDR10+ HEVC pentru verify/remove"
    }

    # ── 6) Sursa reala: DV AV1 → remove DV ──
    $dvSrc = (Get-ChildItem -Path $src -Filter '*DV*AV1*.mkv' -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notmatch 'HDR10Plus' } | Select-Object -First 1)
    if ($dvSrc -and (Get-Command av1dovi_tool -ErrorAction SilentlyContinue)) {
        $raw = Join-Path $tmp 'raw.ivf'; $clean = Join-Path $tmp 'clean.ivf'
        & ffmpeg -y -v error -i $dvSrc.FullName -map 0:v:0 -c:v copy -f ivf $raw 2>$null | Out-Null
        $okRmDv = Remove-DvLayer -InputFile $raw -OutputFile $clean -Codec av1
        Assert-Eq $true $okRmDv "Remove-DvLayer (AV1) returneaza true"
        Assert-FileExists $clean "remove DV produce bitstream"

        # guard onestitate: sursa DV AV1 originala are DV → Test-DvSurvived true
        Assert-Eq $true (Test-DvSurvived -File $dvSrc.FullName -Codec av1) "Test-DvSurvived pe sursa DV → true"

        # v56 T.35 repair (engine): av1dovi inject → engine repair → remux → DV
        # supravietuieste POST-REMUX (containerul filtreaza T.35 malformat).
        # ($PSScriptRoot e gol in harness AST → rulam engine-ul direct, ca Repair-Av1DvT35.)
        $engine = Join-Path $src 'av1_dv_t35_repair.py'
        $py = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' }
              elseif (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { $null }
        if ((Test-Path $engine) -and $py) {
            $rawp = Join-Path $tmp 'rp.ivf'; $rpup = Join-Path $tmp 'rp.bin'
            $injp = Join-Path $tmp 'ri.ivf'; $fxp = Join-Path $tmp 'rf.ivf'; $outp = Join-Path $tmp 'ro.mkv'
            Get-RawVideo -InputFile $dvSrc.FullName -OutputFile $rawp -Codec av1 | Out-Null
            Get-DvRpu -InputFile $dvSrc.FullName -RpuOut $rpup -SourceCodec av1 | Out-Null
            & av1dovi_tool inject-rpu -i $rawp --rpu-in $rpup -o $injp 2>$null | Out-Null
            & $py $engine $injp $fxp 2>$null | Out-Null
            if (Test-Path $fxp) { Move-Item -Force $fxp $injp }
            & ffmpeg -v error -y -i $injp -map 0:v:0 -c copy $outp 2>$null
            Assert-Eq $true (Test-DvSurvived -File $outp -Codec av1) "AV1 DV: engine T.35 repair → DV supravietuieste post-remux"
        } else {
            Write-Host "  ~ (skip partial) Python 3 / engine lipsa pt test repair T.35"
        }
    } else {
        Write-Host "  ~ (skip partial) niciun sample DV AV1 / av1dovi_tool lipsa"
    }

    # 7) wiring (independent de sample-uri): Inject-DvRpu repara T.35 pe AV1
    $encSrc = Get-Content (Join-Path $src 'av_encode.ps1') -Raw
    Assert-Match $encSrc 'function Repair-Av1DvT35' "Repair-Av1DvT35 definit in av_encode.ps1"
    Assert-Match $encSrc 'Repair-Av1DvT35 -File \$outputFile' "Inject-DvRpu apeleaza Repair-Av1DvT35 pe AV1"
    Assert-FileExists (Join-Path $src 'av1_dv_t35_repair.py') "engine av1_dv_t35_repair.py exista in src/"
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-TestSummary
