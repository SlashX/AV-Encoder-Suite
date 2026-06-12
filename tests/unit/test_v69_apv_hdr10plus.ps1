# v69 — HDR10+ pe APV (mirror al test_v69_apv_hdr10plus.sh).
#   Source-level: functii PS1 (Get-ApvHdr10PlusEnginePy/Invoke-ApvHdr10Plus*),
#   dispatch apv (Test-Hdr10PlusToolFor + Extract-Hdr10PlusMetadata), probe in
#   Get-SourceInfo/Get-SourceInfoExtended, dialog APV (if/elseif, NU switch),
#   hook post-encode + reset, av_check.ps1 upgrade TYPE.
#   Functional: probe/extract/inject pe APV sintetic (AST import).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$ENC   = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
$CHECK = Get-Content (Join-Path $SRC "av_check.ps1") -Raw

# ── 1. Functii + dispatch ───────────────────────────────────────────
Assert-Match $ENC 'function Get-ApvHdr10PlusEnginePy'   "av_encode: engine helper definit"
Assert-Match $ENC 'function Invoke-ApvHdr10PlusProbe'   "av_encode: probe definit"
Assert-Match $ENC 'function Invoke-ApvHdr10PlusExtract' "av_encode: extract definit"
Assert-Match $ENC 'function Invoke-ApvHdr10PlusInject'  "av_encode: inject definit"
Assert-Match $ENC ([regex]::Escape('if ($Codec -eq "apv") { return [bool](Get-ApvHdr10PlusEnginePy) }')) "av_encode: dispatch apv in Test-Hdr10PlusToolFor"
Assert-Match $ENC ([regex]::Escape('if ($srcCodec -eq "apv") {')) "av_encode: ramura apv in Extract-Hdr10PlusMetadata"
Assert-Match $ENC ([regex]::Escape('"-f","apv","-framerate",$fps,"-i",$injected')) "av_encode: re-mux cu -f apv fortat + -framerate explicit"

# ── 2. Detectie (Get-SourceInfo + Get-SourceInfoExtended) ───────────
$probeCount = ([regex]::Matches($ENC, [regex]::Escape('(Invoke-ApvHdr10PlusProbe -File $file) -eq "hdr10plus"'))).Count
Assert-Eq 2 $probeCount "av_encode: probe APV in AMBELE functii de detectie (SourceInfo + Extended)"

# ── 3. Dialog APV + hook post-encode + reset ────────────────────────
Assert-Match $ENC ([regex]::Escape('$env:APV_HDR10PLUS_POLICY')) "av_encode: env bypass APV_HDR10PLUS_POLICY"
Assert-Match $ENC ([regex]::Escape('if ($apvHpSkipFile) { $totalSkipped++; continue }')) "av_encode: skip prin flag + if (NU continue-in-switch)"
Assert-Match $ENC ([regex]::Escape('Invoke-ApvHdr10PlusInject -OutFile $outFile -Json $script:apvHdr10PlusJson')) "av_encode: hook post-encode"
$resetCount = ([regex]::Matches($ENC, [regex]::Escape('$script:apvHdr10PlusJson = ""; $script:apvHdr10PlusInject = $false'))).Count
Assert-Eq $true ($resetCount -ge 2) "av_encode: reset state APV (per-file defensiv + sectiunea APV)"

# ── 4. av_check.ps1 ─────────────────────────────────────────────────
Assert-Match $CHECK 'function Invoke-ApvHdr10PlusProbe' "av_check: copie standalone probe"
Assert-Match $CHECK ([regex]::Escape('$si.codec -eq "apv" -and $tipHdr -in @("HDR10","SDR")')) "av_check: upgrade TYPE gate pe apv"

# ── 4b. Validator OpenAPV: installer + hook soft (optional, tacut) ──
Assert-Eq $true (Test-Path (Join-Path $SRC "tools\openapv_validator.ps1")) "tools: installer PS1 exista"
Assert-Eq $true (Test-Path (Join-Path $SRC "tools\openapv_validator.sh"))  "tools: installer bash exista"
Assert-Match $ENC ([regex]::Escape('Get-Command $oapvName -ErrorAction SilentlyContinue')) "av_encode: hook soft decoder referinta (gate pe prezenta, prin variabila)"
Assert-Match $ENC ([regex]::Escape('Join-Path $ToolsDir "$oapvName.exe"')) "av_encode: fallback pe tools/ (PATH-ul nu include tools)"
# v69: nume binare/engine centralizate (env-overridable) — sursa unica
Assert-Match $ENC ([regex]::Escape('if ($env:AV_TOOL_OAPV_DEC) { $env:AV_TOOL_OAPV_DEC } else { "oapv_app_dec" }')) "av_encode: numele oapv_app_dec env-overridable"
Assert-Match $ENC 'function Get-ApvHdr10PlusEnginePath' "av_encode: calea engine-ului centralizata (resolver)"
Assert-Match $ENC ([regex]::Escape('if ($env:AV_TOOL_DOVI) { $env:AV_TOOL_DOVI } else { "dovi_tool" }')) "av_encode: dispatcher-ul = sursa unica env-overridable pt dovi_tool"
Assert-Match $ENC ([regex]::Escape('acceptat si de decoderul de referinta OpenAPV')) "av_encode: mesaj decode-check referinta"

# ── 5. Functional (hermetic; AST import) ────────────────────────────
$apvEncOk = (& ffmpeg -hide_banner -encoders 2>$null | Select-String '\bliboapv\b')
$pyOk = (Get-Command python3 -EA SilentlyContinue) -or (Get-Command python -EA SilentlyContinue)
if ($apvEncOk -and $pyOk) {
    . "$PSScriptRoot\..\_helpers.ps1"
    Import-AvEncodeFunctions -Names @('_Get-AvPython','Get-ApvHdr10PlusEnginePath','Get-ApvHdr10PlusEnginePy',
        'Invoke-ApvHdr10PlusProbe','Invoke-ApvHdr10PlusExtract','Invoke-ApvHdr10PlusInject',
        'Get-FFprobeValue','Ensure-TempDir','Resolve-Hdr10Static','Get-Hdr10StaticMetadata',
        'Set-Hdr10StaticDefaults','Measure-Hdr10Cll','Read-Hdr10MeasureChoice','Get-ContainerFlags') | Out-Null
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v69apv_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $global:AV_TEMP_DIR = Join-Path $tmp "avtemp"; New-Item -ItemType Directory -Force $global:AV_TEMP_DIR | Out-Null
    $global:LogFile = Join-Path $tmp "test.log"

    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=0.2:size=160x128:rate=10" `
        -frames:v 2 -c:v liboapv -qp 40 -pix_fmt yuv422p10le (Join-Path $tmp "src.mp4") 2>$null | Out-Null
    $meta = @'
{"SceneInfo":[
{"BezierCurveData":{"Anchors":[102,205,307],"KneePointX":10,"KneePointY":20},"LuminanceParameters":{"AverageRGB":500,"LuminanceDistributions":{"DistributionIndex":[1,5,10,25,50,75,90,95,99],"DistributionValues":[1,2,3,4,5,6,7,8,9]},"MaxScl":[1000,1100,1200]},"NumberOfWindows":1,"TargetedSystemDisplayMaximumLuminance":400},
{"BezierCurveData":{"Anchors":[110,210,310],"KneePointX":11,"KneePointY":21},"LuminanceParameters":{"AverageRGB":600,"LuminanceDistributions":{"DistributionIndex":[1,5,10,25,50,75,90,95,99],"DistributionValues":[9,8,7,6,5,4,3,2,1]},"MaxScl":[2000,2100,2200]},"NumberOfWindows":1,"TargetedSystemDisplayMaximumLuminance":450}
]}
'@
    $metaPath = Join-Path $tmp "meta.json"
    [IO.File]::WriteAllText($metaPath, $meta)

    if ((Test-Path (Join-Path $tmp "src.mp4")) -and (Get-Item (Join-Path $tmp "src.mp4")).Length -gt 0) {
        $outSim = Join-Path $tmp "out.mp4"
        Copy-Item (Join-Path $tmp "src.mp4") $outSim -Force
        $ok = Invoke-ApvHdr10PlusInject -OutFile $outSim -Json $metaPath -SrcFile (Join-Path $tmp "src.mp4") -Container "mp4"
        Assert-Eq $true $ok "functional: inject rc=true (cu verificare probe interna)"
        Assert-Eq "hdr10plus" (Invoke-ApvHdr10PlusProbe -File $outSim) "functional: probe → hdr10plus"
        Assert-Eq "none" (Invoke-ApvHdr10PlusProbe -File (Join-Path $tmp "src.mp4")) "functional: sursa ne-injectata → none"

        $ej = Invoke-ApvHdr10PlusExtract -File $outSim
        Assert-Eq $true ([bool]$ej) "functional: extract intoarce JSON"
        if ($ej) {
            $b = (Get-Content $ej -Raw | ConvertFrom-Json).SceneInfo
            Assert-Eq 2 $b.Count "functional: 2 frames extrase"
            Assert-Eq 500 $b[0].LuminanceParameters.AverageRGB "functional: AverageRGB[0] round-trip"
            Assert-Eq 450 $b[1].TargetedSystemDisplayMaximumLuminance "functional: TSDML[1] round-trip"
            Assert-Eq 307 $b[0].BezierCurveData.Anchors[2] "functional: Bezier anchors round-trip"
            Remove-Item $ej -Force -ErrorAction SilentlyContinue
        }
        & ffmpeg -v error -y -i $outSim -c:v copy -bsf:v apv_metadata -f apv (Join-Path $tmp "cbs.apv") 2>$null
        Assert-Eq 0 $LASTEXITCODE "functional: CBS apv_metadata passthrough exit 0"
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "  (functional sarit: liboapv sau python lipsesc)" -ForegroundColor Yellow
}
Invoke-TestSummary
