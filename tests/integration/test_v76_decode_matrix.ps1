# v76 — matrice DECODE-survival + fidelitate-exacta metadata (PS1, integration).
# COMPLEMENTAR fata de test_v75_metadata_matrix (structural: Test-DvSurvived re-extract +
# dvcC + containere) si test_v72_dvcc_matrix (1 decode). Aici: DECODE dav1d real pe TOATA
# matricea AV1 (singura dovada ca av1_dv_t35_repair.py mode=dv/hdr10plus merge la decoder —
# re-extract e fals-pozitiv pe AV1, av1dovi tolereaza output buggy) + scene-count HDR10+ EXACT
# (out==sursa, prinde pierderi partiale/frame-mismatch). Encode REAL (svtav1/x265/liboapv) pe
# clipuri 2s scalate (metadata e per-frame, independenta de rezolutie). Auto-skip pe tools/sample.
. "$PSScriptRoot\..\framework.ps1"
$src = (Resolve-Path "$PSScriptRoot\..\..\src").Path
$env:PATH = "$src;$env:PATH"
$py = (Get-Command python3 -EA SilentlyContinue).Source; if (-not $py) { $py = (Get-Command python -EA SilentlyContinue).Source }
$t35 = Join-Path $src 'av1_dv_t35_repair.py'
$apvEng = Join-Path $src 'apv_hdr10plus.py'

# ── gating: tools + sample-uri ────────────────────────────────────────
$need = @('ffmpeg','ffprobe','dovi_tool','hdr10plus_tool','av1dovi_tool','av1hdr10plus_tool')
$haveTools = $py -and ($need | ForEach-Object { Get-Command $_ -EA SilentlyContinue } | Where-Object { $_ } | Measure-Object).Count -eq $need.Count
$sHevcHp = Join-Path $src 'Upload_S02E01_HDR10Plus_40s_HEVC.mp4'
$sAv1Hp  = Join-Path $src 'Upload_S02E01_HDR10Plus_40s_AV1.mkv'
$sAv1Dv  = Join-Path $src 'Upload_S02E01_DV_40s_AV1.mkv'
$haveSamples = (Test-Path $sHevcHp) -and (Test-Path $sAv1Hp) -and (Test-Path $sAv1Dv)
if (-not ($haveTools -and $haveSamples)) { Skip-Test "tools sau sample-uri lipsesc (ffmpeg/dovi_tool/av1*/sample-uri HDR10+/DV)" }

$svtHasApv = [bool](& ffmpeg -hide_banner -encoders 2>$null | Select-String '\bliboapv\b')
$WS = Join-Path ([IO.Path]::GetTempPath()) ("v76dec_" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force $WS | Out-Null

# ── helpers (logica probata in auditul harness) ───────────────────────
function Seg($sample,$tag) { $e=[IO.Path]::GetExtension($sample); $o=Join-Path $WS "$tag$e"; & ffmpeg -y -v error -i $sample -t 2 -map 0:v:0 -c copy $o 2>$null; return $o }
function RawHevc($seg,$tag) { $r=Join-Path $WS "$tag.hevc"; & ffmpeg -y -v error -i $seg -c copy -bsf:v hevc_mp4toannexb -f hevc $r 2>$null; return $r }
function RawAv1($seg,$tag) { $r=Join-Path $WS "$tag.ivf"; & ffmpeg -y -v error -i $seg -c copy -f ivf $r 2>$null; return $r }
function EncHevc($seg,$tag) { $c=Join-Path $WS "$tag.mp4"; & ffmpeg -y -v error -i $seg -c:v libx265 -preset ultrafast -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" -pix_fmt yuv420p10le $c 2>$null; if(-not(Test-Path $c)){return $null}; $r=Join-Path $WS "$tag.hevc"; & ffmpeg -y -v error -i $c -c copy -bsf:v hevc_mp4toannexb -f hevc $r 2>$null; return $r }
function EncAv1($seg,$tag) { $c=Join-Path $WS "$tag.mkv"; & ffmpeg -y -v error -i $seg -c:v libsvtav1 -preset 9 -crf 40 -pix_fmt yuv420p10le -svtav1-params "color-primaries=9:transfer-characteristics=16:matrix-coefficients=9" $c 2>$null; if(-not(Test-Path $c)){return $null}; $r=Join-Path $WS "$tag.ivf"; & ffmpeg -y -v error -i $c -c copy -f ivf $r 2>$null; return $r }
function ScenesHevc($raw) { $j=Join-Path $WS ("sh"+[guid]::NewGuid().ToString('N').Substring(0,5)+".json"); & hdr10plus_tool extract $raw -o $j 2>$null|Out-Null; if(-not(Test-Path $j)){return -1}; return (Select-String -Path $j -Pattern 'SceneFrameIndex' -SimpleMatch).Count }
function ScenesAv1($raw) { $j=Join-Path $WS ("sa"+[guid]::NewGuid().ToString('N').Substring(0,5)+".json"); & av1hdr10plus_tool extract $raw -o $j 2>$null|Out-Null; if(-not(Test-Path $j)){return -1}; return (Select-String -Path $j -Pattern 'SceneFrameIndex' -SimpleMatch).Count }
function JsonHevc($raw) { $j=Join-Path $WS ("jh"+[guid]::NewGuid().ToString('N').Substring(0,5)+".json"); & hdr10plus_tool extract $raw -o $j 2>$null|Out-Null; return $j }
function JsonAv1($raw) { $j=Join-Path $WS ("ja"+[guid]::NewGuid().ToString('N').Substring(0,5)+".json"); & av1hdr10plus_tool extract $raw -o $j 2>$null|Out-Null; return $j }
function InjHpHevc($raw,$json,$out) { & hdr10plus_tool inject -i $raw -j $json -o $out 2>$null|Out-Null }
function InjHpAv1($raw,$json,$out) { & av1hdr10plus_tool inject -i $raw -j $json -o $out 2>$null|Out-Null; & $py $t35 $out "$out.f" hdr10plus 2>$null; if(Test-Path "$out.f"){Move-Item -Force "$out.f" $out} }
function RpuFrom($raw,$codec) { $r=Join-Path $WS ("rp"+[guid]::NewGuid().ToString('N').Substring(0,5)+".bin"); if($codec -eq 'av1'){& av1dovi_tool extract-rpu $raw -o $r 2>$null|Out-Null}else{& dovi_tool extract-rpu $raw -o $r 2>$null|Out-Null}; return $r }
function InjDvAv1($raw,$rpu,$out) { & av1dovi_tool inject-rpu -i $raw --rpu-in $rpu -o $out 2>$null|Out-Null; & $py $t35 $out "$out.f" dv 2>$null; if(Test-Path "$out.f"){Move-Item -Force "$out.f" $out} }
function RpuPresentAv1($raw) { $r=RpuFrom $raw 'av1'; $ok=((Test-Path $r) -and (Get-Item $r).Length -gt 0); Remove-Item $r -Force -EA SilentlyContinue; return $ok }
# DECODE dav1d — singura dovada reala ca T.35 e valid (re-extract e fals-pozitiv pe AV1)
function Dav1dClean($ivf) { $e = & ffmpeg -v error -i $ivf -f null - 2>&1; return (-not ($e -match 'Malformed|T\.35')) }

# ── segmente + JSON-uri sursa ─────────────────────────────────────────
$segHevcHp = Seg $sHevcHp 'hevchp'; $segAv1Hp = Seg $sAv1Hp 'av1hp'; $segAv1Dv = Seg $sAv1Dv 'av1dv'
$rawHevcHpSrc = RawHevc $segHevcHp 'hevchpsrc'; $rawAv1HpSrc = RawAv1 $segAv1Hp 'av1hpsrc'; $rawAv1DvSrc = RawAv1 $segAv1Dv 'av1dvsrc'
$nHevcSrc = ScenesHevc $rawHevcHpSrc; $nAv1Src = ScenesAv1 $rawAv1HpSrc
$jHevc = JsonHevc $rawHevcHpSrc; $jAv1 = JsonAv1 $rawAv1HpSrc

Write-Host "  (surse: HEVC HDR10+ $nHevcSrc scene, AV1 HDR10+ $nAv1Src scene)" -ForegroundColor DarkGray

# 1. AV1 HDR10+ -> AV1 : scene EXACT + DECODE (T.35 mode=hdr10plus)
$base = EncAv1 $segAv1Hp 'm1'; $o = Join-Path $WS 'm1_out.ivf'; InjHpAv1 $base $jAv1 $o
Assert-Eq $nAv1Src (ScenesAv1 $o) "1. AV1 HDR10+ -> AV1: scene-count EXACT pastrat"
Assert-Eq $true (Dav1dClean $o)   "1. AV1 HDR10+ -> AV1: DECODE dav1d curat (0 erori T.35, mode=hdr10plus)"

# 2. AV1 DV -> AV1 : DECODE (T.35 mode=dv)
$rpu = RpuFrom $rawAv1DvSrc 'av1'; $base = EncAv1 $segAv1Dv 'm2'; $o = Join-Path $WS 'm2_out.ivf'; InjDvAv1 $base $rpu $o
Assert-Eq $true (RpuPresentAv1 $o) "2. AV1 DV -> AV1: RPU prezent dupa inject"
Assert-Eq $true (Dav1dClean $o)    "2. AV1 DV -> AV1: DECODE dav1d curat (0 erori T.35, mode=dv)"

# 3. AV1 hibrid (HDR10+ + DV, lant mode-specific) : ambele + DECODE
$base = EncAv1 $segAv1Hp 'm3'; $hp = Join-Path $WS 'm3_hp.ivf'; InjHpAv1 $base $jAv1 $hp
$rpu = RpuFrom $rawAv1HpSrc 'av1'  # din sursa HDR10+ nu exista DV; generam din JSON in schimb
$genCfg = Join-Path $WS 'm3_gen.json'; '{"length":0,"level6":{"max_display_mastering_luminance":1000,"min_display_mastering_luminance":1,"max_content_light_level":1000,"max_frame_average_light_level":200}}' | Set-Content $genCfg -Encoding ASCII
$rpuGen = Join-Path $WS 'm3.rpu'; & av1dovi_tool generate -j $genCfg --hdr10plus-json $jAv1 -o $rpuGen 2>$null|Out-Null
$o = Join-Path $WS 'm3_out.ivf'; InjDvAv1 $hp $rpuGen $o
Assert-Eq $true ((ScenesAv1 $o) -gt 0) "3. AV1 hibrid: HDR10+ pastrat (scene>0) dupa lantul HDR10++DV"
Assert-Eq $true (RpuPresentAv1 $o)      "3. AV1 hibrid: DV RPU pastrat (av1dovi paseaza OBU HDR10+ verbatim)"
Assert-Eq $true (Dav1dClean $o)         "3. AV1 hibrid: DECODE dav1d curat (ambele T.35 valide, repair mode-specific)"

# 4. HEVC HDR10+ -> AV1 (cross) : scene>0 + DECODE
$base = EncAv1 $segHevcHp 'm4'; $o = Join-Path $WS 'm4_out.ivf'; InjHpAv1 $base $jHevc $o
Assert-Eq $true ((ScenesAv1 $o) -gt 0) "4. HEVC HDR10+ -> AV1 (cross): HDR10+ pastrat"
Assert-Eq $true (Dav1dClean $o)        "4. HEVC HDR10+ -> AV1 (cross): DECODE dav1d curat"

# 5. APV+ -> AV1 HDR10+ : encode APV, extract via engine, encode av1, inject + DECODE
if ($svtHasApv) {
    $apvC = Join-Path $WS 'm5.mp4'; & ffmpeg -y -v error -i $segHevcHp -c:v liboapv -qp 32 -pix_fmt yuv422p10le $apvC 2>$null
    $apvR = Join-Path $WS 'm5.apv'; & ffmpeg -y -v error -i $apvC -c copy -f apv $apvR 2>$null
    $apvHp = Join-Path $WS 'm5_hp.apv'; & $py $apvEng inject -i $apvR -j $jHevc -o $apvHp 2>$null|Out-Null
    $backJson = Join-Path $WS 'm5_back.json'; & $py $apvEng extract -i $apvHp -o $backJson 2>$null|Out-Null
    $base = Join-Path $WS 'm5.mkv'; & ffmpeg -y -v error -f apv -framerate 30 -i $apvHp -c:v libsvtav1 -preset 9 -crf 40 -pix_fmt yuv420p10le -svtav1-params "color-primaries=9:transfer-characteristics=16:matrix-coefficients=9" $base 2>$null
    $baseR = Join-Path $WS 'm5_base.ivf'; & ffmpeg -y -v error -i $base -c copy -f ivf $baseR 2>$null
    $o = Join-Path $WS 'm5_out.ivf'; InjHpAv1 $baseR $backJson $o
    Assert-Eq $true ((ScenesAv1 $o) -gt 0) "5. APV+ -> AV1 HDR10+: HDR10+ pastrat (engine APV extract)"
    Assert-Eq $true (Dav1dClean $o)        "5. APV+ -> AV1 HDR10+: DECODE dav1d curat"
} else {
    Write-Host "  (5. APV sarit - liboapv indisponibil)" -ForegroundColor DarkGray
}

# 6. HEVC HDR10+ -> HEVC : scene-count EXACT (fidelitate)
$base = EncHevc $segHevcHp 'm6'; $o = Join-Path $WS 'm6_out.hevc'; InjHpHevc $base $jHevc $o
Assert-Eq $nHevcSrc (ScenesHevc $o) "6. HEVC HDR10+ -> HEVC: scene-count EXACT pastrat (fidelitate)"

Remove-Item -Recurse -Force $WS -EA SilentlyContinue
Invoke-TestSummary
