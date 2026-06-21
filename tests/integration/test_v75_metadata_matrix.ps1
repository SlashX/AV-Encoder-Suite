# ══════════════════════════════════════════════════════════════════════
# v75 — MATRICE METADATA prin ENCODE REAL (audit pre-productie).
#   Valideaza pastrarea/transformarea metadatei pe matricea ceruta:
#     HDR10+ -> HDR10+  | DV -> DV  | HDR10+ -> hibrid (HDR+DV+HDR10+)
#   × codec sursa/tinta (HEVC/AV1, inclusiv cross-codec)
#   × container (MP4 ±MP4Box, MKV ±mkvmerge)
#   + transform-only (fara encode).
#   Foloseste FUNCTIILE REALE ale suitei (Extract-Hdr10PlusMetadata,
#   Generate-DvRpuFromHdr10Plus, Get-DvRpu, Inject-DvRpu[+T.35],
#   Invoke-DvMkvMux/Invoke-DvMp4Mux, Test-DvSurvived) + encode cu params
#   reale (x265 dhdr10-info / svtav1 _av1_vui+mastering-display).
#   NOTA build: pe ffmpeg unde libsvtav1 NU expune hdr10plus-json (caps-fail),
#   AV1 HDR10+ inline cade pe HDR10 static (asertam fallback-ul, nu HDR10+).
#   Auto-skip fara unelte/sample. Ruleaza pe Windows (MP4Box+mkvmerge native).
# ══════════════════════════════════════════════════════════════════════
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$SRC  = Join-Path $root 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$MP4BOX = if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } else { 'mp4box' }
$MKVM   = if ($env:AV_TOOL_MKVMERGE) { $env:AV_TOOL_MKVMERGE } elseif (Test-Path (Join-Path $SRC 'mkvmerge.exe')) { Join-Path $SRC 'mkvmerge.exe' } else { 'mkvmerge' }
$env:AV_TOOL_MKVMERGE = $MKVM; $env:AV_TOOL_MP4BOX = $MP4BOX

foreach ($t in @('ffmpeg','ffprobe','dovi_tool','hdr10plus_tool','av1dovi_tool','av1hdr10plus_tool')) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { Skip-Test "unealta lipsa: $t" }
}
$S_HEVC_HP = Join-Path $SRC 'Upload_S02E01_HDR10Plus_40s_HEVC.mp4'
$S_AV1_HP  = Join-Path $SRC 'Upload_S02E01_HDR10Plus_40s_AV1.mkv'
$S_HEVC_DV = Join-Path $SRC 'Test-Jellyfin-4K-DV-P8.1.mp4'
$S_AV1_DV  = Join-Path $SRC 'Upload_S02E01_DV_40s_AV1.mkv'
foreach ($f in @($S_HEVC_HP,$S_AV1_HP,$S_HEVC_DV,$S_AV1_DV)) {
    if (-not (Test-Path $f)) { Skip-Test "sample lipsa: $(Split-Path $f -Leaf)" }
}
$haveMp4box = [bool](Get-Command $MP4BOX -EA SilentlyContinue)
$haveSvt    = ((& ffmpeg -hide_banner -encoders 2>$null) -join ';') -match 'libsvtav1'
$svtHp      = ((& ffmpeg -hide_banner -h encoder=libsvtav1 2>&1) -join ';') -match 'hdr10plus'  # caps suita

Import-AvEncodeFunctions -Names @(
    'Generate-DvRpuFromHdr10Plus','Get-DvRpu','Inject-DvRpu',
    'Get-RawVideo','Repair-Av1DvT35','_Get-AvPython','Test-DvSurvived','Invoke-DvMkvMux','Invoke-DvMp4Mux',
    'Get-ToolForExtract','Get-ToolForInject','Get-SourceCodec',
    'Resolve-Hdr10Static','Get-Hdr10StaticMetadata','Set-Hdr10StaticDefaults'
) | Out-Null

$tmp = Join-Path $env:TEMP ("v75mx_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
# functiile reale folosesc $AV_TEMP_DIR (Generate-DvRpuFromHdr10Plus / Test-DvSurvived)
$global:AV_TEMP_DIR = $tmp

# HDR10+ extract direct prin tool (echivalent cu Extract-Hdr10PlusMetadata, robust la AST)
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

# ── validatori ─────────────────────────────────────────────────────────
function HasDvcc($f){ if(-not(Test-Path $f)){return $false}; ((& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type -of default=nw=1:nk=1 $f 2>$null) -join ';') -match 'DOVI configuration record' }
function DvProf($f){ $p=(& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_profile -of default=nw=1:nk=1 $f 2>$null|Select-Object -First 1); $c=(& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_bl_signal_compatibility_id -of default=nw=1:nk=1 $f 2>$null|Select-Object -First 1); "$(($p -replace '\s','')).$(($c -replace '\s',''))" }
function VTag($f){ ((& ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=nw=1:nk=1 $f 2>$null|Select-Object -First 1) -replace '\s','') }
function Trc($f){ ((& ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 $f 2>$null|Select-Object -First 1) -replace '\s','') }
function HasHdr10pStream($f,$codec){
    $ext = if ($codec -eq 'av1') {'ivf'} else {'hevc'}
    $raw = Join-Path $tmp ("hpck_"+[guid]::NewGuid().ToString('N')+".$ext")
    if ($codec -eq 'av1') { & ffmpeg -y -loglevel error -i $f -map 0:v:0 -c copy -f ivf $raw 2>$null }
    else { & ffmpeg -y -loglevel error -i $f -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb $raw 2>$null }
    $tool = if ($codec -eq 'av1') {'av1hdr10plus_tool'} else {'hdr10plus_tool'}
    $j = Join-Path $tmp ("hpck_"+[guid]::NewGuid().ToString('N')+".json")
    & $tool extract -i $raw -o $j 2>$null | Out-Null
    $ok = (Test-Path $j) -and ((Get-Item $j).Length -gt 200)
    Remove-Item $raw,$j -Force -EA SilentlyContinue
    return $ok
}
# encode base (HDR10 PQ) + optional dhdr10-info; intoarce raw stream (hevc/ivf)
function EncodeBase($srcFile, $targetCodec, $hpJson) {
    Push-Location $tmp
    try {
        $rawOut = "base_" + [guid]::NewGuid().ToString('N') + $(if ($targetCodec -eq 'av1') {'.ivf'} else {'.hevc'})
        if ($targetCodec -eq 'av1') {
            $p = "color-primaries=9:transfer-characteristics=16:matrix-coefficients=9:mastering-display=G(0.265,0.690)B(0.150,0.060)R(0.680,0.320)WP(0.3127,0.3290)L(1000,0.0001):content-light=1000,400"
            if ($hpJson -and $svtHp) { $p += ":hdr10plus-json=$(Split-Path $hpJson -Leaf)" }
            & ffmpeg -y -loglevel error -t 3 -i $srcFile -an -c:v libsvtav1 -preset 12 -pix_fmt yuv420p10le `
                -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -svtav1-params $p -f ivf $rawOut 2>$null
        } else {
            $p = "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400:hdr10-opt=1"
            if ($hpJson) { $p += ":dhdr10-info=$(Split-Path $hpJson -Leaf)" }
            & ffmpeg -y -loglevel error -t 3 -i $srcFile -an -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le `
                -x265-params $p -f hevc $rawOut 2>$null
        }
        if ((Test-Path $rawOut) -and (Get-Item $rawOut).Length -gt 0) { return (Join-Path $tmp $rawOut) }
        return $null
    } finally { Pop-Location }
}
# muxeaza raw DV in container cu/fara unealta de signaling
function MuxDv($rawDv, $origSrc, $targetExt, $useTool, $dvRef) {
    $out = Join-Path $tmp ("o_"+[guid]::NewGuid().ToString('N')+".$targetExt")
    if ($useTool) {
        if ($targetExt -eq 'mkv') { Invoke-DvMkvMux -RawHevc $rawDv -Original $origSrc -Output $out | Out-Null }
        else { Invoke-DvMp4Mux -RawHevc $rawDv -Original $origSrc -Output $out -DvRef $dvRef | Out-Null }
    } else {
        # fallback fara unealta: raw -> MP4 -> tinta (ca v69; raw HEVC nu poarta PTS la MKV)
        $isAv1 = ([System.IO.Path]::GetExtension($rawDv).TrimStart('.') -in @('ivf','av1','obu'))
        $step = Join-Path $tmp ("st_"+[guid]::NewGuid().ToString('N')+".mp4")
        & ffmpeg -y -loglevel error -i $rawDv -c copy $step 2>$null
        if (Test-Path $step) { & ffmpeg -y -loglevel error -i $step -c copy $out 2>$null; Remove-Item $step -Force -EA SilentlyContinue }
    }
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 0) { return $out } else { return $null }
}

$srcMap = @{ 'hevc' = @{hp=$S_HEVC_HP; dv=$S_HEVC_DV}; 'av1' = @{hp=$S_AV1_HP; dv=$S_AV1_DV} }

try {
    Write-Host "`n────────── GRUP A: HDR10+ -> HDR10+ (preserve prin encode) ──────────" -ForegroundColor Magenta
    foreach ($sc in @('hevc','av1')) {
        foreach ($tc in @('hevc','av1')) {
            $src = $srcMap[$sc].hp
            $hp = Join-Path $tmp ("hpA_"+[guid]::NewGuid().ToString('N')+".json")
            $hpOk = ExtractHp $src $sc $hp
            $hpFile = if ($hpOk) { $hp } else { $null }
            $base = EncodeBase $src $tc $hpFile
            if (-not $base) { Assert-Eq $true $false "A $sc->$tc encode base esuat"; continue }
            # mux raw -> MP4 (raw HEVC/IVF -> MP4 deriva timestamps; raw->MKV direct = clasa
            # de bug v69 pe HEVC). Grup A e pur HDR10+ (fara DV) → container irelevant pt dvcC.
            $outA = Join-Path $tmp ("A_$($sc)_$($tc).mp4")
            & ffmpeg -y -loglevel error -i $base -c copy $outA 2>$null
            if ($tc -eq 'hevc') {
                Assert-Eq $true (HasHdr10pStream $outA 'hevc') "A $sc->HEVC: HDR10+ SUPRAVIETUIESTE (dhdr10-info)"
            } else {
                # AV1 tinta: HDR10+ inline doar daca build-ul expune hdr10plus-json; altfel HDR10 static
                if ($svtHp) { Assert-Eq $true (HasHdr10pStream $outA 'av1') "A $sc->AV1: HDR10+ supravietuieste (hdr10plus-json)" }
                else { Assert-Eq 'smpte2084' (Trc $outA) "A $sc->AV1: HDR10 static (build fara hdr10plus-json inline - fallback corect)" }
            }
            Remove-Item $base -Force -EA SilentlyContinue
        }
    }

    Write-Host "`n────────── GRUP B: DV -> DV (preserve prin encode, ±unealta) ──────────" -ForegroundColor Magenta
    foreach ($sc in @('hevc','av1')) {
        foreach ($tc in @('hevc','av1')) {
            $src = $srcMap[$sc].dv
            $rpu = Join-Path $tmp ("rpuB_"+[guid]::NewGuid().ToString('N')+".bin")
            if (-not (Get-DvRpu -InputFile $src -RpuOut $rpu -SourceCodec $sc)) { Assert-Eq $true $false "B $sc->$tc extract RPU esuat"; continue }
            $base = EncodeBase $src $tc $null
            if (-not $base) { Assert-Eq $true $false "B $sc->$tc encode base esuat"; continue }
            $inj = Join-Path $tmp ("injB_"+[guid]::NewGuid().ToString('N')+$(if($tc -eq 'av1'){'.ivf'}else{'.hevc'}))
            $iok = Inject-DvRpu -hevcFile $base -rpuFile $rpu -outputFile $inj -TargetCodec $tc
            Assert-Eq $true $iok "B $sc->$($tc): inject RPU (cross-codec auto-profil)"
            if (-not $iok) { continue }
            # MKV + mkvmerge
            $mkv = MuxDv $inj $src 'mkv' $true $src
            if ($mkv) {
                Assert-Eq $true (HasDvcc $mkv) "B $sc->$tc MKV+mkvmerge: dvcC scris"
                $wantP = if ($tc -eq 'av1') { '^10' } else { '^8' }
                Assert-Match (DvProf $mkv) $wantP "B $sc->$tc MKV: profil corect pe codec tinta"
                Assert-Eq $true (Test-DvSurvived -File $mkv -Codec $tc) "B $sc->$tc MKV: DV supravietuieste (RPU)"
            }
            # MP4 + MP4Box
            if ($haveMp4box) {
                $mp4 = MuxDv $inj $src 'mp4' $true $src
                if ($mp4) {
                    Assert-Eq $true (HasDvcc $mp4) "B $sc->$tc MP4+MP4Box: dvcC scris"
                    Assert-Eq $true (Test-DvSurvived -File $mp4 -Codec $tc) "B $sc->$tc MP4: DV supravietuieste (RPU)"
                }
            }
            # MKV fara unealta -> DV in bitstream (RPU), fara dvcC
            $mkvNo = MuxDv $inj $src 'mkv' $false $src
            if ($mkvNo) { Assert-Eq $true (Test-DvSurvived -File $mkvNo -Codec $tc) "B $sc->$tc MKV fara unealta: DV in bitstream supravietuieste" }
            Remove-Item $base -Force -EA SilentlyContinue
        }
    }

    Write-Host "`n────────── GRUP C: HDR10+ -> HIBRID (genereaza DV + pastreaza HDR10+) ──────────" -ForegroundColor Magenta
    foreach ($sc in @('hevc','av1')) {
        foreach ($tc in @('hevc','av1')) {
            $src = $srcMap[$sc].hp
            $hp = Join-Path $tmp ("hpC_"+[guid]::NewGuid().ToString('N')+".json")
            $hpOk = ExtractHp $src $sc $hp
            if (-not $hpOk) { Assert-Eq $true $false "C $sc->$tc extract HDR10+ esuat"; continue }
            $rpu = Generate-DvRpuFromHdr10Plus $hp -TargetCodec $tc -SourceFile $src
            Assert-Eq $true ([bool]($rpu -and (Test-Path $rpu))) "C $sc->$($tc): genereaza DV RPU din HDR10+"
            if (-not ($rpu -and (Test-Path $rpu))) { continue }
            $hpFile = if ($tc -eq 'hevc') { $hp } else { $hp }  # inline doar pe HEVC efectiv
            $base = EncodeBase $src $tc $hpFile
            if (-not $base) { Assert-Eq $true $false "C $sc->$tc encode esuat"; continue }
            $inj = Join-Path $tmp ("injC_"+[guid]::NewGuid().ToString('N')+$(if($tc -eq 'av1'){'.ivf'}else{'.hevc'}))
            $iok = Inject-DvRpu -hevcFile $base -rpuFile $rpu -outputFile $inj -TargetCodec $tc
            if (-not $iok) { Assert-Eq $true $false "C $sc->$tc inject esuat"; continue }
            $mkv = MuxDv $inj $src 'mkv' $true $src
            if ($mkv) {
                Assert-Eq $true (HasDvcc $mkv) "C $sc->$tc hibrid MKV: dvcC (DV)"
                Assert-Eq $true (Test-DvSurvived -File $mkv -Codec $tc) "C $sc->$tc hibrid MKV: DV supravietuieste"
                if ($tc -eq 'hevc') { Assert-Eq $true (HasHdr10pStream $mkv 'hevc') "C $sc->HEVC hibrid: HDR10+ pastrat (al 3-lea strat)" }
                else { Assert-Eq 'smpte2084' (Trc $mkv) "C $sc->AV1 hibrid: HDR10 base (HDR10+ inline indisp. build)" }
            }
            Remove-Item $base -Force -EA SilentlyContinue
        }
    }

    Write-Host "`n────────── GRUP D: TRANSFORM-ONLY HDR10+ -> hibrid (fara encode) ──────────" -ForegroundColor Magenta
    foreach ($sc in @('hevc','av1')) {
        $src = $srcMap[$sc].hp
        $raw = Join-Path $tmp ("rawD_"+[guid]::NewGuid().ToString('N')+$(if($sc -eq 'av1'){'.ivf'}else{'.hevc'}))
        if (-not (Get-RawVideo -InputFile $src -OutputFile $raw -Codec $sc)) { Assert-Eq $true $false "D $sc raw extract esuat"; continue }
        $hp = Join-Path $tmp ("hpD_"+[guid]::NewGuid().ToString('N')+".json")
        $hpOk = ExtractHp $src $sc $hp
        if (-not $hpOk) { Assert-Eq $true $false "D $sc extract HDR10+ esuat"; continue }
        $rpu = Generate-DvRpuFromHdr10Plus $hp -TargetCodec $sc -SourceFile $src
        if (-not ($rpu -and (Test-Path $rpu))) { Assert-Eq $true $false "D $sc generate RPU esuat"; continue }
        $inj = Join-Path $tmp ("injD_"+[guid]::NewGuid().ToString('N')+$(if($sc -eq 'av1'){'.ivf'}else{'.hevc'}))
        $iok = Inject-DvRpu -hevcFile $raw -rpuFile $rpu -outputFile $inj -TargetCodec $sc
        Assert-Eq $true $iok "D $sc transform: inject DV (fara re-encode)"
        if (-not $iok) { continue }
        $mkv = MuxDv $inj $src 'mkv' $true $src
        if ($mkv) {
            Assert-Eq $true (HasDvcc $mkv) "D $sc transform MKV: dvcC"
            Assert-Eq $true (Test-DvSurvived -File $mkv -Codec $sc) "D $sc transform MKV: DV supravietuieste"
            Assert-Eq $true (HasHdr10pStream $mkv $sc) "D $sc transform: HDR10+ pastrat (lossless, fara encode)"
        }
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-TestSummary
