# v85 — santinele source-level pentru bug-urile gasite la campania v85 (F1-F9).
#   Mirror al test_v85_regression.sh. Grep-based, fara ffmpeg → rapid, cross-platform.
. "$PSScriptRoot\..\framework.ps1"
$PROJECT_ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$src = Join-Path $PROJECT_ROOT 'src'

$BURNIN    = Get-Content -LiteralPath (Join-Path $src 'av_burnin.sh') -Raw
$BURNIN_PS = Get-Content -LiteralPath (Join-Path $src 'av_burnin.ps1') -Raw
$TELEM     = Get-Content -LiteralPath (Join-Path $src 'av_telemetry.sh') -Raw
$TELEM_PS  = Get-Content -LiteralPath (Join-Path $src 'av_telemetry.ps1') -Raw
$COMMON    = Get-Content -LiteralPath (Join-Path $src 'av_common.sh') -Raw
$CHECK     = Get-Content -LiteralPath (Join-Path $src 'av_check.sh') -Raw

# ── F1: eticheta DV P7 corecta ──
Assert-Match $COMMON ([regex]::Escape('Profil 7 (DV + HDR10, dual-layer Blu-ray)')) "F1: P7 eticheta corecta (av_common)"
Assert-Match $CHECK  ([regex]::Escape('Profil 7 (DV + HDR10, dual-layer Blu-ray)')) "F1: P7 eticheta corecta (av_check)"
Assert-Eq $false ($COMMON -match [regex]::Escape('Profil 7 (DV + HDR10+)')) "F1: eticheta P7 veche (HDR10+) scoasa"

# ── F2: GPX/CSV verifica continut real ──
Assert-Match $TELEM    ([regex]::Escape('grep -q "<trkpt"')) "F2: GPX verifica trkpt real (bash)"
Assert-Match $TELEM_PS '<trkpt' "F2: GPX verifica trkpt real (PS1)"

# ── F3: template SRT mort scos; SRT din extractia per-sample ──
Assert-Eq $false ($TELEM -match 'SRT_FMT=')  "F3: SRT_FMT (template mort) scos bash"
Assert-Eq $false ($TELEM_PS -match 'srtFmt =') "F3: srtFmt (template mort) scos PS1"
Assert-Match $TELEM 'want_srt' "F3: SRT din extractia per-sample (bash)"
Assert-Match $TELEM_PS 'wantSrt' "F3: SRT din extractia per-sample (PS1)"

# ── F4: -write_tmcd 0 la strip ──
Assert-Match $TELEM 'write_tmcd' "F4: -write_tmcd 0 la strip (bash)"
Assert-Match $TELEM_PS 'write_tmcd' "F4: -write_tmcd 0 la strip (PS1)"

# ── F5: pick_files NU se termina cu [ ] && {...} sub set -e ──
Assert-Eq $false ($BURNIN -match '\[ "\$\{#SELECTED\[@\]\}" -eq 0 \] && \{') "F5: pick_files garda [ ] && {...} scoasa"
Assert-Match $BURNIN ([regex]::Escape('if [ "${#SELECTED[@]}" -eq 0 ]; then')) "F5: pick_files garda ca if (safe)"

# ── F6: format explicit dupa overlay ──
$ov = ([regex]'overlay[^]]*,format=\$\{_ov_fmt\}').Matches($BURNIN).Count
Assert-Eq $true ($ov -ge 3) "F6: format dupa overlay >=3 situri bash ($ov)"
$ovp = ([regex]'overlay[^]]*,format=\$ovFmt').Matches($BURNIN_PS).Count
Assert-Eq $true ($ovp -ge 3) "F6: format dupa overlay >=3 situri PS1 ($ovp)"

# ── F7: Invoke-BurninEncode splatat ──
Assert-Eq $false ($BURNIN_PS -match 'Invoke-BurninEncode -v error') "F7: fara tokenuri literale la Invoke-BurninEncode"
$splat = ([regex]'Invoke-BurninEncode @(ffArgs|stArgs)').Matches($BURNIN_PS).Count
Assert-Eq 6 $splat "F7: 6 apeluri Invoke-BurninEncode splatate"

# ── F8: notify/wake return 0 ──
foreach ($fn in @('av_notify_done','av_wake_unlock','av_wake_lock')) {
    $m = [regex]::Match($COMMON, "(?s)$fn\(\) \{.*?\n\}")
    Assert-Eq $true ($m.Success -and $m.Value -match 'return 0') "F8: $fn are return 0 explicit"
}

# ── F9: DV tonemap setparams PQ pe unknown ──
Assert-Match $BURNIN    'color_trc=smpte2084:colorspace=bt2020nc' "F9: setparams PQ pe tonemap unknown (bash)"
Assert-Match $BURNIN_PS 'color_trc=smpte2084:colorspace=bt2020nc' "F9: setparams PQ pe tonemap unknown (PS1)"
Assert-Match $BURNIN ([regex]::Escape('"unknown"')) "F9: gateat pe transfer unknown (bash)"

# ── INVARIANT clasa F5: nicio functie din .sh-urile cu set -e nu se termina cu
#    garda `[ ... ] && cmd` fara `||` (functia intoarce 1 pe cazul normal) ──
$f5Viol = @()
foreach ($f in Get-ChildItem (Join-Path $src '*.sh')) {
    $txt = Get-Content -LiteralPath $f.FullName -Raw
    if ($txt -notmatch '(?m)^set -e') { continue }
    $lines = $txt -split "`n"
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\}' -and $lines[$i-1] -match '^\s*\[\[?[^\]]*\]\]? && ' -and $lines[$i-1] -notmatch '\|\|') {
            $f5Viol += "$($f.Name): $($lines[$i-1].Trim())"
        }
    }
}
Assert-Eq 0 $f5Viol.Count "INVARIANT F5: zero garzi [ ] && ca ultima linie de functie sub set -e ($($f5Viol -join '; '))"

# ── INVARIANT clasa F7: zero apeluri de FUNCTIE PS1 (Invoke-*) cu flag-uri
#    ffmpeg colon literale (-c:v / -c:a / -frames:v) ──
$f7Viol = @()
foreach ($f in Get-ChildItem (Join-Path $src '*.ps1')) {
    $ln = 0
    foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
        $ln++
        if ($line -match '^\s*#') { continue }
        if ($line -match 'Invoke-[A-Za-z]+ .*(-c:v|-c:a |-frames:v)') { $f7Viol += "$($f.Name):$ln" }
    }
}
Assert-Eq 0 $f7Viol.Count "INVARIANT F7: zero apeluri Invoke-* cu -c:v/-c:a/-frames:v literale ($($f7Viol -join '; '))"

# ── O1: paritate spatiere etichete DV bash<->PS1 (aliniate la „DV + X") ──
$CHECK_PS  = Get-Content -LiteralPath (Join-Path $src 'av_check.ps1') -Raw
$ENCODE_PS = Get-Content -LiteralPath (Join-Path $src 'av_encode.ps1') -Raw
Assert-Eq $false ($CHECK_PS -match '\(DV\+') "O1: av_check.ps1 fara eticheta DV lipita (DV+)"
Assert-Eq $false ($ENCODE_PS -match 'Profil \d.*\(DV\+') "O1: av_encode.ps1 fara eticheta DV lipita"

# ── O2: av_check.sh check upfront de ffprobe ──
$CHECK = Get-Content -LiteralPath (Join-Path $src 'av_check.sh') -Raw
Assert-Match $CHECK ([regex]::Escape('ffprobe (FFmpeg) nu este in PATH')) "O2: av_check.sh check upfront ffprobe"

# ── O5: av_extractor_gps avertisment coliziune stem (bash + PS1) ──
$GPS    = Get-Content -LiteralPath (Join-Path $src 'av_extractor_gps.sh') -Raw
$GPS_PS = Get-Content -LiteralPath (Join-Path $src 'av_extractor_gps.ps1') -Raw
Assert-Match $GPS    'output-urile se suprascriu' "O5: avertisment coliziune stem (bash)"
Assert-Match $GPS_PS 'output-urile se suprascriu' "O5: avertisment coliziune stem (PS1)"

# ── O4: av_extractor_gps trece caile prin sys.argv, delimiter quotat ──
Assert-Eq 3 ([regex]::Matches($GPS, [regex]::Escape('file_path = sys.argv[1]')).Count) "O4: 3 heredoc-uri citesc calea din sys.argv"
Assert-Eq 3 ([regex]::Matches($GPS, [regex]::Escape("<< 'PYEOF'")).Count) "O4: 3 delimitere quotate 'PYEOF'"
Assert-Eq $false ($GPS -match [regex]::Escape('file_path = "$file"')) "O4: zero interpolare de cale in text"

# ── O3: env override pe cele 3 standalone PS1 ──
foreach ($f in @('av_telemetry.ps1','av_extractor_gps.ps1','av_mux.ps1')) {
    $c = Get-Content -LiteralPath (Join-Path $src $f) -Raw
    Assert-Match $c 'env:AV_INPUT_DIR' "O3: $f are env override AV_INPUT_DIR"
}

# ── O6: av_filtergraph_path exista + folosit non-eval (burnin/trimconcat) ──
$COMMON2 = Get-Content -LiteralPath (Join-Path $src 'av_common.sh') -Raw
$BURN2   = Get-Content -LiteralPath (Join-Path $src 'av_burnin.sh') -Raw
$TC2     = Get-Content -LiteralPath (Join-Path $src 'av_trimconcat.sh') -Raw
Assert-Match $COMMON2 ([regex]::Escape('av_filtergraph_path()')) "O6: helper av_filtergraph_path definit"
Assert-Match $COMMON2 'command -v cygpath' "O6: cygpath guard pt MSYS"
Assert-Match $BURN2 ([regex]::Escape('av_filtergraph_path "$1"')) "O6: burnin escape deleaga la helper"
Assert-Match $TC2   ([regex]::Escape('av_filtergraph_path "$TC_LUT_FILE"')) "O6: trimconcat LUT foloseste helper"

# ── Apple Log robust la taiere (v85): fallback pe encoderul de stream la toate 5 site-uri ──
foreach ($f in @('av_common.sh','av_check.sh','av_encode.ps1','av_check.ps1','av_burnin.ps1')) {
    $c = Get-Content -LiteralPath (Join-Path $src $f) -Raw
    Assert-Match $c 'Apple ProRes' "AppleLog-cut: fallback encoder in $f"
}

# ── CANARE functionale F6 + F9 (cer ffmpeg + libx265; skip gratios) ──
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$src;$env:PATH" }
$hasX265 = (Get-Command ffmpeg -ErrorAction SilentlyContinue) -and ((& ffmpeg -hide_banner -encoders 2>$null | Select-String 'libx265').Count -gt 0)
if ($hasX265) {
    $td = Join-Path $env:TEMP "v85reg_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $td | Out-Null
    try {
        & ffmpeg -v error -f lavfi -i "color=c=red@0.5:s=160x90:d=0.2" -vf format=rgba -frames:v 1 (Join-Path $td 'a.png') -y 2>$null
        & ffmpeg -v error -f lavfi -i "testsrc=duration=0.2:size=160x90:rate=10" -pix_fmt yuv420p10le -c:v libx265 -x265-params log-level=none (Join-Path $td 'b.mp4') -y 2>$null
        & ffmpeg -v error -i (Join-Path $td 'b.mp4') -i (Join-Path $td 'a.png') `
            -filter_complex "[0:v][1:v]overlay=0:0:shortest=0,format=yuv420p[v]" `
            -map "[v]" -c:v libx265 -x265-params log-level=none -f null - 2>$null | Out-Null
        Assert-Eq 0 $LASTEXITCODE "F6 CANAR: overlay RGBA + format explicit → x265 OK"
        & ffmpeg -v error -i (Join-Path $td 'b.mp4') `
            -vf "setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc,zscale=transfer=linear:matrix=bt709:primaries=bt709,tonemap=hable:desat=0,zscale=transfer=bt709:matrix=bt709:primaries=bt709,format=yuv420p" `
            -frames:v 1 -f null - 2>$null | Out-Null
        Assert-Eq 0 $LASTEXITCODE "F9 CANAR: tonemap cu setparams-prefix pe transfer unknown → OK"
    } finally { Remove-Item -Recurse -Force $td -ErrorAction SilentlyContinue }
} else {
    Assert-Eq $true $true "CANARE sarite (ffmpeg/libx265 lipsesc)"
    Assert-Eq $true $true "CANARE sarite (ffmpeg/libx265 lipsesc)"
}

Invoke-TestSummary
