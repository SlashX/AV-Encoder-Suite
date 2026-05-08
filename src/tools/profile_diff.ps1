# ═══════════════════════════════════════════════════════════════
#  profile_diff.ps1 — compara doua profile .conf
#  Usage: profile_diff.ps1 <profileA.conf> <profileB.conf>
#  Output: sectiuni "doar in A", "doar in B", "valori diferite".
# ═══════════════════════════════════════════════════════════════
param(
    [Parameter(Mandatory=$true, Position=0)][string]$ProfileA,
    [Parameter(Mandatory=$true, Position=1)][string]$ProfileB
)

foreach ($p in @($ProfileA, $ProfileB)) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host "Eroare: fisier inexistent: $p" -ForegroundColor Red
        exit 2
    }
}

function Read-ConfFile {
    param([string]$Path)
    $map = [ordered]@{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*"?([^"]*)"?\s*$') {
            $map[$Matches[1]] = $Matches[2]
        }
    }
    return $map
}

$mapA = Read-ConfFile -Path $ProfileA
$mapB = Read-ConfFile -Path $ProfileB

$nameA = [System.IO.Path]::GetFileNameWithoutExtension($ProfileA)
$nameB = [System.IO.Path]::GetFileNameWithoutExtension($ProfileB)

Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Profile diff" -ForegroundColor Cyan
Write-Host "    A: $nameA  ($ProfileA)" -ForegroundColor White
Write-Host "    B: $nameB  ($ProfileB)" -ForegroundColor White
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan

$onlyA = @($mapA.Keys | Where-Object { -not $mapB.Contains($_) })
$onlyB = @($mapB.Keys | Where-Object { -not $mapA.Contains($_) })
$diffKeys = @($mapA.Keys | Where-Object { $mapB.Contains($_) -and $mapA[$_] -cne $mapB[$_] })

if ($onlyA.Count -gt 0) {
    Write-Host ""
    Write-Host "-- Doar in A ($nameA) --" -ForegroundColor Yellow
    foreach ($k in $onlyA) {
        "  {0,-25} = `"{1}`"" -f $k, $mapA[$k] | Write-Host
    }
}

if ($onlyB.Count -gt 0) {
    Write-Host ""
    Write-Host "-- Doar in B ($nameB) --" -ForegroundColor Yellow
    foreach ($k in $onlyB) {
        "  {0,-25} = `"{1}`"" -f $k, $mapB[$k] | Write-Host
    }
}

if ($diffKeys.Count -gt 0) {
    Write-Host ""
    Write-Host "-- Valori diferite --" -ForegroundColor Yellow
    "  {0,-25} {1,-30} {2,-30}" -f "KEY", "A ($nameA)", "B ($nameB)" | Write-Host
    "  {0,-25} {1,-30} {2,-30}" -f "---", "---", "---" | Write-Host
    foreach ($k in $diffKeys) {
        "  {0,-25} {1,-30} {2,-30}" -f $k, ('"' + $mapA[$k] + '"'), ('"' + $mapB[$k] + '"') | Write-Host
    }
}

if ($onlyA.Count -eq 0 -and $onlyB.Count -eq 0 -and $diffKeys.Count -eq 0) {
    Write-Host ""
    Write-Host "  Profilele sunt identice." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "-- Sumar --" -ForegroundColor Cyan
Write-Host ("  Doar in A:        {0}" -f $onlyA.Count)
Write-Host ("  Doar in B:        {0}" -f $onlyB.Count)
Write-Host ("  Valori diferite:  {0}" -f $diffKeys.Count)

exit 1
