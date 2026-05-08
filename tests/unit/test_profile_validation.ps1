# Test Test-ProfileFile — accepta valid, respinge enum/regex invalid, ignora cheia necunoscuta.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

Import-AvEncodeFunctions -Names @('Get-ProfileSchema','Test-ProfileFile')

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('av_test_val_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

try {
    # 1) Valid
    @"
ENCODER_NAME=libx265
CONTAINER=mkv
CRF_PARAM=22
PRESET_PARAM=slow
"@ | Set-Content -LiteralPath (Join-Path $tmpDir 'valid.conf')
    $r = Test-ProfileFile -Path (Join-Path $tmpDir 'valid.conf') *>$null
    $r2 = Test-ProfileFile -Path (Join-Path $tmpDir 'valid.conf') 6>$null
    # Capture quietly
    $r = & { Test-ProfileFile -Path (Join-Path $tmpDir 'valid.conf') } 2>$null 6>$null
    Assert-Eq $true $r.ok 'profil valid trece'

    # 2) Enum invalid
    @"
ENCODER_NAME=libx265
CONTAINER=avi
"@ | Set-Content -LiteralPath (Join-Path $tmpDir 'bad_enum.conf')
    $r = Test-ProfileFile -Path (Join-Path $tmpDir 'bad_enum.conf') 6>$null
    Assert-Eq $false $r.ok 'enum invalid esueaza'

    # 3) Regex invalid
    @"
ENCODER_NAME=libx265
CRF_PARAM=abc
"@ | Set-Content -LiteralPath (Join-Path $tmpDir 'bad_regex.conf')
    $r = Test-ProfileFile -Path (Join-Path $tmpDir 'bad_regex.conf') 6>$null
    Assert-Eq $false $r.ok 'regex invalid esueaza'

    # 4) Cheie necunoscuta — warning, NU error
    @"
ENCODER_NAME=libx265
SOME_FUTURE_FIELD=value
"@ | Set-Content -LiteralPath (Join-Path $tmpDir 'unknown.conf')
    $r = Test-ProfileFile -Path (Join-Path $tmpDir 'unknown.conf') 6>$null
    Assert-Eq $true $r.ok 'cheie necunoscuta = warning'

    # 5) Inexistent
    $r = Test-ProfileFile -Path (Join-Path $tmpDir 'nope.conf') 6>$null
    Assert-Eq $false $r.ok 'fisier inexistent esueaza'

    # 6) Built-in profiles — toate trebuie sa fie valide
    $root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
    $builtinDir = Join-Path $root 'src\profiles'
    if (Test-Path -LiteralPath $builtinDir) {
        $allBuiltins = Get-ChildItem -LiteralPath $builtinDir -Recurse -Filter '*.conf' -File
        foreach ($p in $allBuiltins) {
            $r = Test-ProfileFile -Path $p.FullName 6>$null
            Assert-Eq $true $r.ok ("built-in " + $p.BaseName)
        }
    }
}
finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-TestSummary
