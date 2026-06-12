# v69 — invarianti pe sursa (mirror al test_v69_source_invariants.sh):
#   A. Zero CRLF in fisierele .sh
#   B. Zero anti-pattern-uri ffprobe (frame_side_data=type / side_data_list)
#   F. Zero `$env:TEMP`/GetTempPath/GetTempFileName in productia PS1 (src/*.ps1;
#      regula v63 — temp-urile merg in $AV_TEMP_DIR/$TempBase; tools/ exceptat)
#   G. Zero mentiuni de asistent in fisierele user-facing
#   D. Meta-test: orice test_*.ps1 contine Invoke-TestSummary (fara el, Assert-*
#      doar incrementeaza contoare → exit 0 mereu = no-op) + garda runner 0-asertiuni.
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'

# ── A. CRLF in .sh ───────────────────────────────────────────────────
$crlf = @()
$shFiles = @(Get-ChildItem "$SRC\*.sh") + @(Get-ChildItem "$SRC\tools\*.sh") +
           @(Get-ChildItem "$ROOT\tests\*.sh") + @(Get-ChildItem "$ROOT\tests\unit\*.sh") +
           @(Get-ChildItem "$ROOT\tests\integration\*.sh") + @(Get-ChildItem "$ROOT\tests\fixtures\*.sh" -ErrorAction SilentlyContinue)
foreach ($f in $shFiles) {
    if ((Get-Content $f.FullName -Raw) -match "`r") { $crlf += $f.Name }
}
Assert-Eq 0 $crlf.Count "A: zero CRLF in fisierele .sh ($($crlf -join ', '))"

# ── B. Anti-pattern-uri ffprobe ──────────────────────────────────────
$bHits = @()
foreach ($f in (Get-ChildItem "$SRC\*.sh", "$SRC\*.ps1")) {
    $n = 0
    foreach ($line in (Get-Content $f.FullName)) {
        $n++
        if ($line -match '^\s*#') { continue }
        if ($line -match 'frame_side_data=type\b|side_data_list') { $bHits += "$($f.Name):$n" }
    }
}
Assert-Eq 0 $bHits.Count "B: zero frame_side_data=type / side_data_list in src ($($bHits -join ', '))"

# ── F. $env:TEMP in productia PS1 ────────────────────────────────────
$fHits = @()
foreach ($f in (Get-ChildItem "$SRC\*.ps1")) {
    $n = 0
    foreach ($line in (Get-Content $f.FullName)) {
        $n++
        # doar aparitiile DINAINTEA unui eventual comentariu inline
        $code = ($line -split '#', 2)[0]
        if ($code -match '\$env:TEMP\b|GetTempPath|GetTempFileName') { $fHits += "$($f.Name):$n" }
    }
}
Assert-Eq 0 $fHits.Count "F: zero `$env:TEMP/GetTempPath in src/*.ps1 ($($fHits -join ', '))"

# ── G. Mentiuni asistent in fisiere user-facing ──────────────────────
$gHits = @()
foreach ($doc in @("$ROOT\README.md", "$ROOT\docs\av_info.txt", "$ROOT\docs\av_changelog.txt")) {
    if ((Get-Content $doc -Raw) -imatch 'claude|anthropic|chatgpt|copilot|openai') { $gHits += (Split-Path -Leaf $doc) }
}
Assert-Eq 0 $gHits.Count "G: zero mentiuni asistent in docs user-facing ($($gHits -join ', '))"

# ── D. Meta-test pe teste + garda runner ─────────────────────────────
$dMissing = @()
foreach ($f in (Get-ChildItem "$ROOT\tests\unit\test_*.ps1", "$ROOT\tests\integration\test_*.ps1" -ErrorAction SilentlyContinue)) {
    if ((Get-Content $f.FullName -Raw) -notmatch 'Invoke-TestSummary') { $dMissing += $f.Name }
}
Assert-Eq 0 $dMissing.Count "D: toate testele PS1 au Invoke-TestSummary ($($dMissing -join ', '))"
Assert-Match (Get-Content "$ROOT\tests\run_tests.ps1" -Raw) ([regex]::Escape('(0 assertions)')) "D: run_tests.ps1 are garda 0-asertiuni"
Assert-Match (Get-Content "$ROOT\tests\run_tests.sh" -Raw)  ([regex]::Escape('(0 assertions)')) "D: run_tests.sh are garda 0-asertiuni"

# ── H. Fix v69 audit: HEVC-raw → MKV prin pas intermediar MP4 ────────
Assert-Match (Get-Content "$SRC\av_hdr_dv_tools.sh" -Raw) ([regex]::Escape('_step1=$(av_mktemp_ext mp4)')) "H: combine bash are pas intermediar MP4"
Assert-Match (Get-Content "$SRC\av_common.sh" -Raw)       ([regex]::Escape('_tl_step1=$(av_mktemp_ext mp4)')) "H: triple-layer bash are pas intermediar MP4"
$encH = Get-Content "$SRC\av_encode.ps1" -Raw
Assert-Match $encH 'hdvstep1_' "H: combine PS1 are pas intermediar MP4"
Assert-Match $encH 'tlstep1_'  "H: triple-layer PS1 are pas intermediar MP4"
Assert-Match (Get-Content "$SRC\av_mux.sh" -Raw)  ([regex]::Escape('_raw_wrap=$(av_mktemp_ext mp4)')) "H: Mux bash pre-wrap video brut"
Assert-Match (Get-Content "$SRC\av_mux.ps1" -Raw) 'muxwrap_' "H: Mux PS1 pre-wrap video brut"

Invoke-TestSummary
