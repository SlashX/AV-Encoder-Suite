# Test profile_diff.ps1 — output, exit codes, sectiuni.
. "$PSScriptRoot\..\framework.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$diffTool = Join-Path $root 'src\tools\profile_diff.ps1'
Assert-FileExists $diffTool 'profile_diff.ps1 exista'

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('av_test_diff_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

try {
    @"
ENCODER_NAME=libx265
CONTAINER=mkv
CRF_PARAM=22
ONLY_IN_A=foo
"@ | Set-Content -LiteralPath (Join-Path $tmpDir 'a.conf')

    @"
ENCODER_NAME=libx265
CONTAINER=mp4
CRF_PARAM=22
ONLY_IN_B=bar
"@ | Set-Content -LiteralPath (Join-Path $tmpDir 'b.conf')

    # 1) Diff
    $out = & pwsh -NoProfile -File $diffTool (Join-Path $tmpDir 'a.conf') (Join-Path $tmpDir 'b.conf') 2>&1 | Out-String
    Assert-Eq 1 $LASTEXITCODE 'exit=1 cand exista diferente'
    Assert-Contains $out 'ONLY_IN_A' 'raporteaza ONLY_IN_A'
    Assert-Contains $out 'ONLY_IN_B' 'raporteaza ONLY_IN_B'
    Assert-Contains $out 'CONTAINER' 'raporteaza CONTAINER diferit'
    Assert-Contains $out 'Doar in A' 'sectiune Doar in A'
    Assert-Contains $out 'Doar in B' 'sectiune Doar in B'
    Assert-Contains $out 'Valori diferite' 'sectiune Valori diferite'

    # 2) Identice
    Copy-Item (Join-Path $tmpDir 'a.conf') (Join-Path $tmpDir 'a2.conf')
    $out = & pwsh -NoProfile -File $diffTool (Join-Path $tmpDir 'a.conf') (Join-Path $tmpDir 'a2.conf') 2>&1 | Out-String
    Assert-Eq 0 $LASTEXITCODE 'exit=0 cand identice'
    Assert-Contains $out 'identice' 'raporteaza identice'

    # 3) Argument lipsa → param required exception (pwsh exits non-zero)
    & pwsh -NoProfile -NonInteractive -File $diffTool 2>&1 | Out-Null
    Assert-Nonzero $LASTEXITCODE 'fara args → exit non-zero'

    # 4) Fisier inexistent → exit 2
    & pwsh -NoProfile -NonInteractive -File $diffTool (Join-Path $tmpDir 'nope1') (Join-Path $tmpDir 'nope2') 2>&1 | Out-Null
    Assert-Eq 2 $LASTEXITCODE 'fisier inexistent → exit 2'
}
finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-TestSummary
