# v76 — conversie DV Profile 7 → 8.1 (dual-layer aware): PS1.
#   Source-level pe av_encode.ps1 (paritate cu bash) + hermetic pe engine dv_p7_analyze.py
#   + FUNCTIONAL end-to-end pe Windows (mkvextract→discard→mkvmerge→ffprobe profil 8),
#   gated pe tools + sample real (awaken-girl P7).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$proj   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$src    = Join-Path $proj 'src'
$enc    = Get-Content (Join-Path $src 'av_encode.ps1') -Raw
$engine = Join-Path $src 'dv_p7_analyze.py'
$engSrc = Get-Content $engine -Raw

# ── 1. Helperi PS1 (mirror) ───────────────────────────────────────────
Assert-Match $enc 'function Get-DvP7EnginePath'    "helper Get-DvP7EnginePath"
Assert-Match $enc 'function Get-DvBlPeakNits'      "helper Get-DvBlPeakNits"
Assert-Match $enc 'function Get-DvFullHevc'        "helper Get-DvFullHevc"
Assert-Match $enc 'function Get-P7ElClass'         "helper Get-P7ElClass"
Assert-Match $enc 'function Convert-P7ToProfile81' "orchestrator Convert-P7ToProfile81"

# ── 2. Resolvere env-or-default (AST-safe) ────────────────────────────
Assert-Match $enc '\$env:AV_ENGINE_DV_P7'  "engine resolver via AV_ENGINE_DV_P7"
Assert-Match $enc '\$env:AV_TOOL_MKVEXTRACT' "mkvextract resolver via AV_TOOL_MKVEXTRACT"
Assert-Match $enc 'frame_side_data=max_content' "bl_peak din MaxCLL real al BL"

# ── 3. Branch P7 in Invoke-TransformRpu ───────────────────────────────
Assert-Match $enc 'dvProf -like "\*Profil 7\*"'   "branch P7 in Invoke-TransformRpu"
Assert-Match $enc 'Convert-P7ToProfile81 -File \$file' "branch apeleaza orchestratorul"
Assert-Match $enc '_dv81\.'                       "sufix output _dv81"
Assert-Match $enc '-m 2 convert --discard'        "conversie P7->8.1 (discard EL)"
Assert-Match $enc 'Invoke-HdvCombineWithOriginal -Modified \$bl81' "re-mux dvcC via combine"

# ── 4. Gate de siguranta FEL ──────────────────────────────────────────
Assert-Match $enc 'DV_P7_FORCE'        "gate are escape DV_P7_FORCE"
Assert-Match $enc 'AV_NONINTERACTIVE'  "gate refuza non-interactiv (fara force)"

# ── 5. Engine: structura ──────────────────────────────────────────────
Assert-Match $engSrc 'def pq_to_nits'   "engine: EOTF ST.2084"
Assert-Match $engSrc 'MARGIN_NITS = 50' "engine: marja 50 niti peste BL peak"
Assert-Match $engSrc '"el_type":"MEL"'  "engine: detecteaza MEL"

# ── 6. Hermetic: verdicte engine pe JSON sintetic (doar python) ───────
$py = $null
foreach ($c in @('python','python3')) { $g = Get-Command $c -EA SilentlyContinue; if ($g) { $py = $g.Source; break } }
if ($py) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v76p7_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    function _verdict($json, $bl) { (& $py $engine $json "$bl" 2>$null | Select-Object -First 1) -split ' ' | Select-Object -First 1 }

    '[{"el_type":"MEL","dm_data":[{"Level1":{"max_pq":2400}}]}]' | Set-Content "$tmp\mel.json" -Encoding ASCII
    Assert-Eq "MEL" (_verdict "$tmp\mel.json" 1000) "MEL -> MEL (discard lossless)"

    '[{"el_type":"FEL","dm_data":[{"Level1":{"max_pq":2400}}]}]' | Set-Content "$tmp\fels.json" -Encoding ASCII
    Assert-Eq "FEL_SAFE" (_verdict "$tmp\fels.json" 1000) "FEL max_pq=2400 (214 niti) vs BL 1000 -> FEL_SAFE"

    '[{"el_type":"FEL","dm_data":[{"Level1":{"max_pq":3600}}]}]' | Set-Content "$tmp\felc.json" -Encoding ASCII
    Assert-Eq "FEL_COMPLEX" (_verdict "$tmp\felc.json" 1000) "FEL max_pq=3600 (3219 niti) vs BL 1000 -> FEL_COMPLEX"
    Assert-Eq "FEL_SAFE" (_verdict "$tmp\felc.json" 4000) "acelasi FEL vs BL 4000 -> FEL_SAFE (content-aware)"

    'nu-i json' | Set-Content "$tmp\bad.json" -Encoding ASCII
    Assert-Eq "UNKNOWN" (_verdict "$tmp\bad.json" 1000) "JSON corupt -> UNKNOWN (conservator)"

    Remove-Item -Recurse -Force $tmp -EA SilentlyContinue
} else {
    Write-Host "  (hermetic engine sarit - python lipseste)" -ForegroundColor DarkGray
}

# ── 7. Functional end-to-end (gated pe tools + sample real) ───────────
# NB: NU folosim Skip-Test aici (ar face exit 77 si ar masca aserturile source+hermetic
# de mai sus). Functional e bonus → cand lipsesc tools/sample, doar notam si continuam.
$env:PATH = "$src;$env:PATH"   # tools portabile din src/ (ffprobe/mkvextract/dovi_tool/mkvmerge)
$sample = Join-Path $src 'awaken-girl.4K.HDR.DV.mkv'
$haveTools = (Test-Path $sample) -and $py `
    -and (Get-Command ffprobe    -EA SilentlyContinue) `
    -and (Get-Command mkvextract -EA SilentlyContinue) `
    -and (Get-Command dovi_tool  -EA SilentlyContinue) `
    -and (Get-Command mkvmerge   -EA SilentlyContinue)
if ($haveTools) {
    Import-AvEncodeFunctions -Names @('Convert-P7ToProfile81','Get-DvFullHevc','Get-P7ElClass','Get-DvBlPeakNits','Get-DvP7EnginePath','Get-ToolForExtract','_Get-AvPython','Invoke-HdvCombineWithOriginal','Invoke-DvMkvMux','Get-ContainerFlags','Ensure-TempDir','Get-PreserveRpu','Get-DVProfile','Get-DvRpu','Get-ToolForInject','Test-VfrSource') | Out-Null
    $env:AV_ENGINE_DV_P7 = $engine
    $global:AV_TEMP_DIR = Join-Path ([IO.Path]::GetTempPath()) ("v76p7f_" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force $global:AV_TEMP_DIR | Out-Null
    $out = Join-Path $global:AV_TEMP_DIR 'awaken_dv81.mkv'
    $rc = Convert-P7ToProfile81 -File $sample -FinalOut $out
    Assert-Eq "0" "$rc" "Convert-P7ToProfile81 (awaken-girl MEL) -> rc=0"
    if (Test-Path $out) {
        $info = (& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_profile,el_present_flag,rpu_present_flag,dv_bl_signal_compatibility_id -of default=noprint_wrappers=1 $out 2>$null) -join "`n"
        Assert-Match $info 'dv_profile=8'        "output este Profil 8 (DV)"
        Assert-Match $info 'el_present_flag=0'   "EL aruncat (single-layer)"
        Assert-Match $info 'rpu_present_flag=1'  "RPU pastrat (DV activ)"
        Assert-Match $info 'dv_bl_signal_compatibility_id=1' "compat 1 (8.1 HDR10-compatible)"
    } else {
        _fail "output P7->8.1 negasit"
    }
    # v76 audit FIX — encode-preserve P7: RPU extras pt inject TREBUIE profil 8 (NU 7).
    # Regresie prinsa la audit: -m 2 editor pe RPU P7 e no-op (ramane profil 7) → injectat
    # intr-o baza single-layer = DV invalid. Fix: -m 2 convert --discard pe STREAM + extract-rpu.
    $presRpu = Join-Path $global:AV_TEMP_DIR 'preserve.rpu'
    if (Get-PreserveRpu -File $sample -RpuOut $presRpu -Codec 'hevc') {
        $dovi = Get-ToolForExtract -Codec hevc -Kind 'dovi'
        $rinfo = (& $dovi info -i $presRpu -s 2>$null) -join "`n"
        Assert-Match $rinfo 'Profile: 8' "Get-PreserveRpu (P7 encode-preserve) -> RPU profil 8 (NU 7)"
    } else {
        _fail "Get-PreserveRpu (P7) a esuat"
    }
    Remove-Item -Recurse -Force $global:AV_TEMP_DIR -EA SilentlyContinue
} else {
    Write-Host "  (functional P7->8.1 sarit - tools/sample lipsesc)" -ForegroundColor DarkGray
}

# ── 8. Situatia 2: DV-preserve P7-aware pe calea de ENCODE ─────────────
# Baza re-encodata e single-layer HDR10 → un RPU profil-7 injectat = DV invalid.
# Get-PreserveRpu converteste 7→8.1 inainte de inject; restul (P8.x / AV1 P10) → Get-DvRpu normal.
Assert-Match $enc 'function Get-PreserveRpu'                 "helper Get-PreserveRpu (Situatia 2)"
Assert-Match $enc 'Get-DVProfile \$File\) -notlike "\*Profil 7\*"' "gate Get-PreserveRpu pe Profil 7"
Assert-Match $enc 'Get-DvFullHevc -File \$File -OutFile \$full\)'  "P7 → extract stream complet (EL in MKV)"
Assert-Match $enc '-m 2 convert --discard -i \$full'        "P7 → convert STREAM 7→8.1 (NU -m editor pe RPU = no-op)"
Assert-Match $enc 'extract-rpu \$conv -o \$RpuOut'          "P7 → extract RPU profil-8 din streamul convertit"
# Cele 3 situri de DV-preserve pe encode (av1 SW / HW / x265) trec prin Get-PreserveRpu
$presCount = ([regex]::Matches($enc, 'Get-PreserveRpu -File \$f\.FullName')).Count
Assert-Eq "3" "$presCount" "3 situri preserve via Get-PreserveRpu (av1 SW / HW / x265)"

# ── 8b. Advisory P7 pe copy-paths (v91, echo-only) ─────────────────────
# Mirror bash _dv_resignal_copy: mesaj identic in av_encode.ps1 (Invoke-DvResignalCopy)
# + av_mux.ps1 (Remux inline) + av_common.sh (chokepoint bash), gate numeric dv_profile==7.
$advMsg = 'Sursa e DV Profil 7 \(dual-layer Blu-ray\)'
Assert-Match $enc $advMsg                 "advisory P7 in Invoke-DvResignalCopy (av_encode.ps1)"
Assert-Match $enc '"\$dvp7"\.Trim\(\) -eq "7"' "gate numeric dv_profile==7 (av_encode.ps1)"
$muxPs = Get-Content (Join-Path $src 'av_mux.ps1') -Raw
Assert-Match $muxPs $advMsg               "advisory P7 in av_mux.ps1 (Remux inline)"
$cmnSh = Get-Content (Join-Path $src 'av_common.sh') -Raw
Assert-Match $cmnSh $advMsg               "paritate mesaj advisory in av_common.sh (_dv_resignal_copy)"

# ── 9. FEL REAL (sample-gated — src\DVFEL local, gitignored; campanie 2026-07-16) ──
# 3 mostre P7 FEL reale au deblocat validarea: clasificatorul pe FEL real (ambele
# ramuri) + gate-ul FEL_COMPLEX (refuz non-interactiv / DV_P7_FORCE) + encode-preserve
# pe FEL. Note (nu Skip-Test) cand lipsesc mostrele/tools — source+hermetic raman.
$felMp4 = Join-Path $src 'DVFEL\DV FEL Test DT DL P7 CMV4.0 4000nits v3.mp4'   # FEL_COMPLEX (CM v4.0, L1 10000 nits)
$felMkv = Join-Path $src 'DVFEL\DV FEL All Layers Test (Woman at 80s).mkv'     # FEL_SAFE (CM v2.9, L1 961 nits)
$haveFel = (Test-Path $felMp4) -and $py `
    -and (Get-Command ffprobe   -EA SilentlyContinue) `
    -and (Get-Command dovi_tool -EA SilentlyContinue) `
    -and (Get-Command mkvmerge  -EA SilentlyContinue)
if ($haveFel) {
    # re-import defensiv (sectiunea 7 poate fi sarita cand awaken-girl lipseste)
    Import-AvEncodeFunctions -Names @('Convert-P7ToProfile81','Get-DvFullHevc','Get-P7ElClass','Get-DvBlPeakNits','Get-DvP7EnginePath','Get-ToolForExtract','_Get-AvPython','Invoke-HdvCombineWithOriginal','Invoke-DvMkvMux','Get-ContainerFlags','Ensure-TempDir','Get-PreserveRpu','Get-DVProfile','Get-DvRpu','Get-ToolForInject','Test-VfrSource','Invoke-DvResignalCopy','Get-SourceCodec','Invoke-DvContainerSignal') | Out-Null
    $env:AV_ENGINE_DV_P7 = $engine
    $global:AV_TEMP_DIR = Join-Path ([IO.Path]::GetTempPath()) ("v76felf_" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force $global:AV_TEMP_DIR | Out-Null

    # (a) clasificatorul pe FEL REAL — ramura FEL_COMPLEX (MP4, calea ffmpeg)
    $fullF = Join-Path $global:AV_TEMP_DIR 'fel_full.hevc'
    if (Get-DvFullHevc -File $felMp4 -OutFile $fullF) {
        $vF = Get-P7ElClass -Stream $fullF -Orig $felMp4
        Assert-Eq "FEL_COMPLEX" (($vF -split ' ')[0]) "FEL real CM v4.0 (L1 10000 nits) -> FEL_COMPLEX (helperi reali)"
    } else { _fail "extract stream complet pe FEL MP4 esuat" }
    Remove-Item $fullF -Force -EA SilentlyContinue

    # (b) gate: AV_NONINTERACTIVE=1 fara force -> refuz rc=2, fara output
    $outF = Join-Path $global:AV_TEMP_DIR 'fel_dv81.mkv'
    $env:AV_NONINTERACTIVE = "1"
    $rcF = Convert-P7ToProfile81 -File $felMp4 -FinalOut $outF
    Remove-Item Env:AV_NONINTERACTIVE -EA SilentlyContinue
    Assert-Eq "2" "$rcF" "FEL_COMPLEX non-interactiv fara DV_P7_FORCE -> refuz rc=2"
    Assert-Eq "False" "$(Test-Path $outF)" "refuz -> niciun output creat"

    # (c) DV_P7_FORCE=1 -> conversie completa -> dvcC profil 8 single-layer (mkvmerge)
    $env:DV_P7_FORCE = "1"
    $rcG = Convert-P7ToProfile81 -File $felMp4 -FinalOut $outF
    Remove-Item Env:DV_P7_FORCE -EA SilentlyContinue
    Assert-Eq "0" "$rcG" "FEL_COMPLEX + DV_P7_FORCE=1 -> conversie rc=0"
    if ((Test-Path $outF) -and (Get-Item $outF).Length -gt 0) {
        $infoF = (& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_profile,el_present_flag -of default=noprint_wrappers=1 $outF 2>$null) -join "`n"
        Assert-Match $infoF 'dv_profile=8'      "output force este Profil 8 (DV)"
        Assert-Match $infoF 'el_present_flag=0' "EL aruncat (single-layer)"
    } else { _fail "output force P7->8.1 negasit" }

    # (d) encode-preserve pe FEL -> RPU profil 8 (nu 7)
    $presF = Join-Path $global:AV_TEMP_DIR 'fel_preserve.rpu'
    if (Get-PreserveRpu -File $felMp4 -RpuOut $presF -Codec 'hevc') {
        $dvF = Get-ToolForExtract -Codec hevc -Kind 'dovi'
        $riF = (& $dvF info -i $presF -s 2>$null) -join "`n"
        Assert-Match $riF 'Profile: 8' "Get-PreserveRpu pe FEL real -> RPU profil 8 (NU 7)"
    } else { _fail "Get-PreserveRpu pe FEL a esuat" }

    # (d2) advisory P7 pe copy (v91, functional): copy MP4→MKV pastreaza dvcC →
    #      Invoke-DvResignalCopy face early-return DUPA advisory (capturat via 6>&1)
    $cpyF = Join-Path $global:AV_TEMP_DIR 'fel_cpy.mkv'
    & ffmpeg -y -v error -i $felMp4 -map 0:v:0 -c copy $cpyF 2>$null
    if ((Test-Path $cpyF) -and (Get-Item $cpyF).Length -gt 0) {
        $advF = (Invoke-DvResignalCopy -Source $felMp4 -Output $cpyF -Target 'mkv' 6>&1) -join "`n"
        Assert-Match $advF 'Sursa e DV Profil 7 \(dual-layer Blu-ray\)' "advisory P7 afisat pe copy real (functional)"
    } else { _fail "copy MP4->MKV pt advisory a esuat" }

    # (e) FEL_SAFE pe MKV real (cealalta ramura a clasificatorului; cere mkvextract)
    if ((Test-Path $felMkv) -and (Get-Command mkvextract -EA SilentlyContinue)) {
        $fullS = Join-Path $global:AV_TEMP_DIR 'fels_full.hevc'
        if (Get-DvFullHevc -File $felMkv -OutFile $fullS) {
            $vS = Get-P7ElClass -Stream $fullS -Orig $felMkv
            Assert-Eq "FEL_SAFE" (($vS -split ' ')[0]) "FEL real CM v2.9 (L1 961 nits) -> FEL_SAFE"
        } else { _fail "extract stream complet pe FEL MKV esuat" }
        Remove-Item $fullS -Force -EA SilentlyContinue
    }
    Remove-Item -Recurse -Force $global:AV_TEMP_DIR -EA SilentlyContinue
} else {
    Write-Host "  (nota: mostre FEL src\DVFEL absente sau tools lipsa - sectiunea FEL REAL sarita)" -ForegroundColor DarkGray
}

Invoke-TestSummary
