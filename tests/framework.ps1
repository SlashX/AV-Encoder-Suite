# ═══════════════════════════════════════════════════════════════
#  framework.ps1 — minimal assertion library for AV Encoder Suite tests
#  Dot-source at top of every test_*.ps1:
#      . "$PSScriptRoot\..\framework.ps1"
# ═══════════════════════════════════════════════════════════════

if (-not $script:TEST_NAME) {
    $script:TEST_NAME = if ($MyInvocation.PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath) } else { "unknown" }
}

$script:_assertions = 0
$script:_failures = 0
$script:_failure_msgs = New-Object System.Collections.Generic.List[string]

function _pass { $script:_assertions++ }
function _fail([string]$msg) {
    $script:_assertions++
    $script:_failures++
    $script:_failure_msgs.Add($msg) | Out-Null
}

function Assert-Eq {
    param($Expected, $Actual, [string]$Msg = "assert_eq")
    if ("$Expected" -ceq "$Actual") { _pass }
    else { _fail ("{0}: expected '{1}' got '{2}'" -f $Msg, $Expected, $Actual) }
}

function Assert-Neq {
    param($A, $B, [string]$Msg = "assert_neq")
    if ("$A" -cne "$B") { _pass }
    else { _fail ("{0}: both equal '{1}'" -f $Msg, $A) }
}

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Msg = "assert_contains")
    if ($Haystack -clike "*$Needle*") { _pass }
    else { _fail ("{0}: '{1}' not found" -f $Msg, $Needle) }
}

function Assert-NotContains {
    param([string]$Haystack, [string]$Needle, [string]$Msg = "assert_not_contains")
    if ($Haystack -cnotlike "*$Needle*") { _pass }
    else { _fail ("{0}: '{1}' was found but should not be" -f $Msg, $Needle) }
}

function Assert-Match {
    param([string]$Str, [string]$Pattern, [string]$Msg = "assert_match")
    if ($Str -cmatch $Pattern) { _pass }
    else { _fail ("{0}: '{1}' does not match /{2}/" -f $Msg, $Str, $Pattern) }
}

function Assert-FileExists {
    param([string]$Path, [string]$Msg = "file should exist")
    if (Test-Path -LiteralPath $Path -PathType Leaf) { _pass }
    else { _fail ("{0}: '{1}'" -f $Msg, $Path) }
}

function Assert-FileNotExists {
    param([string]$Path, [string]$Msg = "file should NOT exist")
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { _pass }
    else { _fail ("{0}: '{1}'" -f $Msg, $Path) }
}

function Assert-DirExists {
    param([string]$Path, [string]$Msg = "dir should exist")
    if (Test-Path -LiteralPath $Path -PathType Container) { _pass }
    else { _fail ("{0}: '{1}'" -f $Msg, $Path) }
}

function Assert-Zero {
    param([int]$Code, [string]$Msg = "expected exit 0")
    if ($Code -eq 0) { _pass }
    else { _fail ("{0}: got exit {1}" -f $Msg, $Code) }
}

function Assert-Nonzero {
    param([int]$Code, [string]$Msg = "expected nonzero exit")
    if ($Code -ne 0) { _pass }
    else { _fail ("{0}: got exit 0" -f $Msg) }
}

function Skip-Test {
    param([string]$Reason)
    Write-Host "SKIP $script:TEST_NAME — $Reason" -ForegroundColor Yellow
    $script:TEST_SKIPPED = $true
    exit 77
}

function Invoke-TestSummary {
    if ($script:TEST_SKIPPED) { exit 77 }
    if ($script:_failures -eq 0) {
        Write-Host ("PASS {0} ({1} assertions)" -f $script:TEST_NAME, $script:_assertions) -ForegroundColor Green
        exit 0
    } else {
        Write-Host ("FAIL {0} ({1}/{2} failed)" -f $script:TEST_NAME, $script:_failures, $script:_assertions) -ForegroundColor Red
        foreach ($m in $script:_failure_msgs) { Write-Host "  - $m" -ForegroundColor Red }
        exit 1
    }
}
