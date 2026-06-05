# Test Build-ExtendsChain + Resolve-ExtendsPath + Get-ExtendsField.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

Import-AvEncodeFunctions -Names @('Resolve-ExtendsPath','Get-ExtendsField','Build-ExtendsChain','Get-CanonicalPath')

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('av_test_ext_' + [guid]::NewGuid().ToString('N'))
$userDir    = Join-Path $tmpDir 'user'
$builtinDir = Join-Path $tmpDir 'builtin\cat1'
New-Item -ItemType Directory -Force -Path $userDir, $builtinDir | Out-Null

# Set the dirs visible to Resolve-ExtendsPath (uses $script:UserProfilesDir / $script:ProfilesDir)
$global:UserProfilesDir = $userDir
$global:ProfilesDir = (Join-Path $tmpDir 'builtin')

try {
    # Root in builtin
    @"
ENCODER=libx265
CONTAINER=mkv
CUSTOM_CRF=22
PRESET=slow
"@ | Set-Content -LiteralPath (Join-Path $builtinDir 'base.conf')

    # Child in user, refers to builtin (short name)
    @"
EXTENDS=base
CUSTOM_CRF=18
"@ | Set-Content -LiteralPath (Join-Path $userDir 'child.conf')

    # Grandchild in user, refers to sibling
    @"
EXTENDS=child
PRESET=veryslow
"@ | Set-Content -LiteralPath (Join-Path $userDir 'grand.conf')

    # 1) Lant 3 niveluri
    $r = Build-ExtendsChain -LeafPath (Join-Path $userDir 'grand.conf')
    Assert-Eq $true $r.ok 'chain build reuseste'
    Assert-Eq 3 $r.chain.Count 'chain are 3 niveluri'
    Assert-Contains $r.chain[0] 'base.conf' 'root e base.conf'
    Assert-Contains $r.chain[2] 'grand.conf' 'leaf e grand.conf'

    # 2) Cycle
    @"
EXTENDS=cycB
"@ | Set-Content -LiteralPath (Join-Path $userDir 'cycA.conf')
    @"
EXTENDS=cycA
"@ | Set-Content -LiteralPath (Join-Path $userDir 'cycB.conf')
    $r = Build-ExtendsChain -LeafPath (Join-Path $userDir 'cycA.conf')
    Assert-Eq $false $r.ok 'cycle detectat'
    Assert-Contains $r.error 'ciclu' 'mesaj contine "ciclu"'

    # 3) Missing parent
    @"
EXTENDS=nu_exista
"@ | Set-Content -LiteralPath (Join-Path $userDir 'orphan.conf')
    $r = Build-ExtendsChain -LeafPath (Join-Path $userDir 'orphan.conf')
    Assert-Eq $false $r.ok 'missing parent detectat'
    Assert-Contains $r.error 'negasit' 'mesaj contine "negasit"'

    # 4) Fara EXTENDS → chain de 1
    $r = Build-ExtendsChain -LeafPath (Join-Path $builtinDir 'base.conf')
    Assert-Eq $true $r.ok 'leaf fara EXTENDS ok'
    Assert-Eq 1 $r.chain.Count 'chain de 1'

    # 5) Depth limit — 6 niveluri
    Set-Content -LiteralPath (Join-Path $userDir 'd1.conf') -Value 'ENCODER=libx265'
    for ($i = 2; $i -le 6; $i++) {
        $prev = $i - 1
        Set-Content -LiteralPath (Join-Path $userDir "d$i.conf") -Value "EXTENDS=d$prev"
    }
    $r = Build-ExtendsChain -LeafPath (Join-Path $userDir 'd6.conf')
    Assert-Eq $false $r.ok 'depth limit 5 enforced'

    # 6) Resolve-ExtendsPath gaseste pe sibling
    $resolved = Resolve-ExtendsPath -Ref 'child' -ChildDir $userDir
    Assert-Contains $resolved 'child.conf' 'sibling resolution'

    # 7) Resolve-ExtendsPath gaseste pe builtin/cat1
    $resolved = Resolve-ExtendsPath -Ref 'base' -ChildDir $userDir
    Assert-Contains $resolved 'base.conf' 'builtin cat1 resolution'
    Assert-Contains $resolved 'cat1' 'builtin cat1 resolution path'

    # 8) Get-ExtendsField
    $field = Get-ExtendsField -Path (Join-Path $userDir 'child.conf')
    Assert-Eq 'base' $field 'EXTENDS field extracted'
    $field = Get-ExtendsField -Path (Join-Path $builtinDir 'base.conf')
    Assert-Eq '' "$field" 'no EXTENDS = empty'

    # 9) Leaf inexistent — eroare clara, nu crash
    $r = Build-ExtendsChain -LeafPath (Join-Path $userDir 'nu_exista_pe_disc.conf')
    Assert-Eq $false $r.ok 'leaf inexistent detectat'
    Assert-Contains $r.error 'leaf inexistent' 'mesaj corect pentru leaf lipsa'

    # 10) Leaf gol
    $r = Build-ExtendsChain -LeafPath ''
    Assert-Eq $false $r.ok 'leaf gol detectat'

    # 11) Cycle prin path duplicat (Windows case-insensitive: dupA.conf vs DUPA.conf)
    Set-Content -LiteralPath (Join-Path $userDir 'dupA.conf') -Value ("EXTENDS=" + (Join-Path $userDir 'DUPA.conf'))
    $r = Build-ExtendsChain -LeafPath (Join-Path $userDir 'dupA.conf')
    Assert-Eq $false $r.ok 'cycle via case-difference detectat (canonicalized)'
}
finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-TestSummary
