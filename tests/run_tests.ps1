# ═══════════════════════════════════════════════════════════════
#  run_tests.ps1 — discover and run test_*.ps1 files
#  Usage: .\run_tests.ps1 [pattern]
#    pattern defaults to "test_*.ps1"
# ═══════════════════════════════════════════════════════════════
param(
    [string]$Pattern = "test_*.ps1"
)

$TestsDir   = $PSScriptRoot
$ProjectRoot = (Resolve-Path (Join-Path $TestsDir '..')).Path
$ResultsDir = Join-Path $TestsDir 'results'
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

# Discover
$tests = @()
$tests += Get-ChildItem -LiteralPath $TestsDir -Filter $Pattern -File -ErrorAction SilentlyContinue
foreach ($d in @('unit', 'integration', 'hw')) {
    $sub = Join-Path $TestsDir $d
    if (Test-Path -LiteralPath $sub) {
        $tests += Get-ChildItem -LiteralPath $sub -Filter $Pattern -File -ErrorAction SilentlyContinue
    }
}

if ($tests.Count -eq 0) {
    Write-Host "No tests matched pattern: $Pattern" -ForegroundColor Yellow
    exit 0
}

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  AV Encoder Suite — test runner (PowerShell)"
Write-Host "  $($tests.Count) test(s) discovered (pattern: $Pattern)"
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

$passed = 0; $failed = 0; $skipped = 0
$failedNames = New-Object System.Collections.Generic.List[string]
$start = Get-Date

$env:PROJECT_ROOT = $ProjectRoot
$env:TESTS_DIR    = $TestsDir

foreach ($t in $tests) {
    $rel = $t.FullName.Substring($TestsDir.Length + 1)
    $log = Join-Path $ResultsDir ($t.BaseName + '.log')
    & pwsh -NoProfile -NonInteractive -File $t.FullName *> $log
    $rc = $LASTEXITCODE
    switch ($rc) {
        0 {
            Write-Host "  + $rel" -ForegroundColor Green
            $passed++
        }
        77 {
            $skipLine = (Get-Content -LiteralPath $log -ErrorAction SilentlyContinue | Where-Object { $_ -match '^SKIP ' } | Select-Object -First 1)
            $reason = if ($skipLine) { ($skipLine -replace '^SKIP[^—]*—\s*','') } else { '?' }
            Write-Host "  ~ $rel (skip: $reason)" -ForegroundColor Yellow
            $skipped++
        }
        default {
            Write-Host "  X $rel" -ForegroundColor Red
            $failed++
            $failedNames.Add($rel) | Out-Null
            Write-Host "    --- output (last 15 lines of $log) ---" -ForegroundColor DarkGray
            Get-Content -LiteralPath $log -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
    }
}

$elapsed = [int]((Get-Date) - $start).TotalSeconds

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ("  Total: {0}  Pass: {1}  Fail: {2}  Skip: {3}  Time: {4}s" -f $tests.Count, $passed, $failed, $skipped, $elapsed)
if ($failed -gt 0) {
    Write-Host "  Failed:" -ForegroundColor Red
    foreach ($n in $failedNames) { Write-Host "    - $n" -ForegroundColor Red }
}
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
