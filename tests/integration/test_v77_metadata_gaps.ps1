# v77 (PS1) — MATRICE METADATA: golurile fata de v75 (hibrid → HDR10+ / hibrid → DV).
# Oglinda test_v77_metadata_gaps.sh. Foloseste FUNCTIILE REALE (Remove-DvLayer /
# Remove-Hdr10PlusMetadata / Test-DvSurvived / Test-Hdr10PlusPresent) prin AST import.
#   hibrid (DV + HDR10+) → HDR10+ : remove DV, pastreaza HDR10+
#   hibrid (DV + HDR10+) → DV      : remove HDR10+, pastreaza DV
# × HEVC (sintetizat) + AV1 (sample real). Auto-skip fara unelte/sample.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$SRC  = Join-Path $root 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
foreach ($t in @('ffmpeg','ffprobe','dovi_tool','hdr10plus_tool','av1dovi_tool','av1hdr10plus_tool')) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { Skip-Test "unealta lipsa: $t" }
}
$S_HEVC_HP = Join-Path $SRC 'hdr10+test_lake_2021_02_01.mp4'
$S_AV1_HYB = Join-Path $SRC 'Upload_S02E01_DV_HDR10Plus_40s_AV1.mkv'
foreach ($f in @($S_HEVC_HP,$S_AV1_HYB)) { if (-not (Test-Path $f)) { Skip-Test "sample lipsa: $(Split-Path $f -Leaf)" } }

Import-AvEncodeFunctions -Names @(
    'Get-RawVideo','Generate-DvRpuFromHdr10Plus','Inject-DvRpu','Repair-Av1DvT35','_Get-AvPython',
    'Remove-DvLayer','Remove-Hdr10PlusMetadata','Test-Hdr10PlusPresent','Test-DvSurvived','Get-DvRpu',
    'Get-ToolForExtract','Get-ToolForInject','Get-SourceCodec',
    'Resolve-Hdr10Static','Get-Hdr10StaticMetadata','Set-Hdr10StaticDefaults'
) | Out-Null

$tmp = Join-Path $env:TEMP ("v77gap_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$global:AV_TEMP_DIR = $tmp
function B($cmd) { try { if (& $cmd) { 1 } else { 0 } } catch { 0 } }
# extract HDR10+ direct prin tool (robust la AST, ca v75)
function ExtractHp($src, $codec, $out) {
    $ext = if ($codec -eq 'av1') {'ivf'} else {'hevc'}
    $raw = Join-Path $tmp ("hpx_"+[guid]::NewGuid().ToString('N')+".$ext")
    if ($codec -eq 'av1') { & ffmpeg -y -loglevel error -i $src -map 0:v:0 -c copy -f ivf $raw 2>$null }
    else { & ffmpeg -y -loglevel error -i $src -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb $raw 2>$null }
    $tool = if ($codec -eq 'av1') {'av1hdr10plus_tool'} else {'hdr10plus_tool'}
    & $tool extract -i $raw -o $out 2>$null | Out-Null
    Remove-Item $raw -Force -EA SilentlyContinue
    return ((Test-Path $out) -and (Get-Item $out).Length -gt 200)
}

try {
    # ── HEVC hibrid sintetizat (HDR10+ → genereaza DV → inject) ──
    $hevcHyb = Join-Path $tmp 'hevc_hyb.hevc'
    $hevcRaw = Join-Path $tmp 'hevc_src.hevc'
    if (Get-RawVideo -InputFile $S_HEVC_HP -OutputFile $hevcRaw -Codec 'hevc') {
        $hp = Join-Path $tmp 'hp.json'
        if (ExtractHp $S_HEVC_HP 'hevc' $hp) {
            $rpu = Generate-DvRpuFromHdr10Plus $hp -TargetCodec 'hevc' -SourceFile $S_HEVC_HP
            if ($rpu -and (Test-Path $rpu)) { Inject-DvRpu -hevcFile $hevcRaw -rpuFile $rpu -outputFile $hevcHyb -TargetCodec 'hevc' | Out-Null }
        }
    }
    # ── AV1 hibrid (sample real) ──
    $av1Hyb = Join-Path $tmp 'av1_hyb.ivf'
    Get-RawVideo -InputFile $S_AV1_HYB -OutputFile $av1Hyb -Codec 'av1' | Out-Null

    function RunCodec($codec, $hyb, $ext) {
        if (-not ((Test-Path $hyb) -and (Get-Item $hyb).Length -gt 0)) { Write-Host "  (nota: hibrid $codec indisponibil, sar)" -ForegroundColor DarkGray; return }
        Assert-Eq 1 (B { Test-DvSurvived -File $hyb -Codec $codec })       "$codec hibrid: are DV (premisa)"
        Assert-Eq 1 (B { Test-Hdr10PlusPresent -InputFile $hyb -Codec $codec }) "$codec hibrid: are HDR10+ (premisa)"

        # hibrid → HDR10+ (remove DV, pastreaza HDR10+)
        $nodv = Join-Path $tmp "${codec}_nodv.$ext"
        if (Remove-DvLayer -InputFile $hyb -OutputFile $nodv -Codec $codec) {
            Assert-Eq 1 (B { Test-Hdr10PlusPresent -InputFile $nodv -Codec $codec }) "$codec hibrid->HDR10+: HDR10+ PASTRAT dupa remove DV"
            Assert-Eq 0 (B { Test-DvSurvived -File $nodv -Codec $codec })            "$codec hibrid->HDR10+: DV ELIMINAT"
        } else { Assert-Eq 'ok' 'fail' "$codec hibrid->HDR10+: Remove-DvLayer esuat" }

        # hibrid → DV (remove HDR10+, pastreaza DV)
        $nohp = Join-Path $tmp "${codec}_nohp.$ext"
        if (Remove-Hdr10PlusMetadata -InputFile $hyb -OutputFile $nohp -Codec $codec) {
            Assert-Eq 1 (B { Test-DvSurvived -File $nohp -Codec $codec })            "$codec hibrid->DV: DV PASTRAT dupa remove HDR10+"
            Assert-Eq 0 (B { Test-Hdr10PlusPresent -InputFile $nohp -Codec $codec }) "$codec hibrid->DV: HDR10+ ELIMINAT"
        } else { Assert-Eq 'ok' 'fail' "$codec hibrid->DV: Remove-Hdr10PlusMetadata esuat" }
    }

    Write-Host "`n────────── HEVC hibrid → HDR10+ / DV ──────────" -ForegroundColor Magenta
    RunCodec 'hevc' $hevcHyb 'hevc'
    Write-Host "`n────────── AV1 hibrid → HDR10+ / DV ──────────" -ForegroundColor Magenta
    RunCodec 'av1' $av1Hyb 'ivf'
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Invoke-TestSummary
