# v77 — Test-invariant (PS1): profilele built-in (example + DJI Action 6) trebuie sa fie
# la zi cu schema curenta. Oglinda test_v77_builtin_profiles.sh. Prinde drift-ul "APV_PROFILE
# rot" (cheie veche ramasa intr-un profil dupa reorganizarea schemei) SI violari de schema.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$proj = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$profilesDir = Join-Path $proj "src\profiles"

# Importam functiile reale (Test-ProfileFile cheama Get-ProfileSchema → import tranzitiv)
Import-AvEncodeFunctions -Names @('Test-ProfileFile','Get-ProfileSchema')

$builtins = @(
    "example_profile.conf"
    "dji_action6\DJI_Action6_Airsoft_Indoor.conf"
    "dji_action6\DJI_Action6_Airsoft_Outdoor.conf"
    "dji_action6\DJI_Action6_DLogM_Outdoor.conf"
    "dji_action6\DJI_Action6_Moto_Cinematic.conf"
    "dji_action6\DJI_Action6_Moto_Outdoor.conf"
)

foreach ($rel in $builtins) {
    $pf = Join-Path $profilesDir $rel
    $name = Split-Path $rel -Leaf
    Assert-FileExists $pf "profil livrat exista: $name"

    # (1) Rot guard: fiecare cheie e cunoscuta de schema (mirror "cheie necunoscuta")
    foreach ($line in (Get-Content -LiteralPath $pf)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=') {
            $key = $Matches[1]
            $schema = Get-ProfileSchema -Key $key
            Assert-Neq '' $schema "schema cunoaste cheia '$key' in $name"
        }
    }

    # (2) Schema guard: zero violari (errors = 0). Suprimam Write-Host (stream 6).
    $res = Test-ProfileFile -Path $pf 6>$null
    Assert-Zero ([int]$res.errors) "Test-ProfileFile fara violari pe $name"
}

# Regresie specifica: putregaiul APV_PROFILE reparat in v77 — example foloseste
# campurile APV noi (v65), NU vechiul APV_PROFILE.
$exampleRaw = Get-Content -LiteralPath (Join-Path $profilesDir "example_profile.conf") -Raw
Assert-Match $exampleRaw '(?m)^APV_PIXFMT='  "example are APV_PIXFMT (camp v65 nou)"
$apvProfCount = ([regex]::Matches($exampleRaw, '(?m)^APV_PROFILE=')).Count
Assert-Eq 0 $apvProfCount "example NU mai are APV_PROFILE (camp mort)"

# Cheile moarte de burn-in scoase din preset-uri (v77 cleanup)
$burninDir = Join-Path $proj "src\burnin_presets"
$burninRaw = (Get-ChildItem -LiteralPath $burninDir -Filter *.conf | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
foreach ($dead in @('HUD_ALTITUDE','HUD_HEADING','HUD_TEMPERATURE','FONT_FAMILY','FRAME_W','FRAME_H','PRESET_DESC')) {
    $cnt = ([regex]::Matches($burninRaw, "(?m)^$dead=")).Count
    Assert-Eq 0 $cnt "cheie burn-in moarta scoasa: $dead"
}
foreach ($live in @('PRESET_NAME','HUD_TIMESTAMP','STRIP_FIELDS','MAP_SIZE','SPEED_UNIT')) {
    Assert-Match $burninRaw "(?m)^$live=" "cheie burn-in vie pastrata: $live"
}

Invoke-TestSummary
