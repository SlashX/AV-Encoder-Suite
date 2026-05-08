# Smoke test pentru framework.ps1 — verifica fiecare assertion helper.
. "$PSScriptRoot\..\framework.ps1"

Assert-Eq "abc" "abc" "string equal"
Assert-Eq 42 42 "int equal"
Assert-Neq "abc" "def" "string not equal"
Assert-Contains "hello world" "world" "substring present"
Assert-NotContains "hello world" "xyz" "substring absent"
Assert-Match "v42.1" "^v[0-9]+\.[0-9]+$" "regex match"
Assert-Zero 0 "exit 0"
Assert-Nonzero 1 "exit 1"

$tmp = [System.IO.Path]::GetTempFileName()
Assert-FileExists $tmp "tempfile created"
Remove-Item -LiteralPath $tmp
Assert-FileNotExists $tmp "tempfile removed"
Assert-DirExists $PSScriptRoot "tests dir exists"

Invoke-TestSummary
