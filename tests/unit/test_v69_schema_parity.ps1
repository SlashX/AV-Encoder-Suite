# v69 — paritate scheme de profile bash ↔ PS1 (enforcement al regulii
# "Do not add profile fields without updating BOTH schemas").
#   Legea (din design, CLAUDE.md): profilele NU sunt cross-platform — PS1 are
#   IN PLUS aliasurile native (ENCODER, AUDIO_CODEC, CUSTOM_CRF...). Deci:
#     (1) ORICE cheie bash ∈ schema PS1        → camp adaugat doar in bash = FAIL
#     (2) cheile PS1-only ⊆ lista de aliasuri  → camp NOU adaugat doar in PS1 = FAIL
#         (un camp partajat nou nu e alias → pica; un alias nou se adauga AICI)
#   PS1-only prin natura: testul citeste AMBELE fisiere (bash-ul nu poate parsa
#   comod hashtable-ul PS1; acoperirea e completa dintr-o singura parte).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'

# ── extrage cheile din schema bash (case ... esac) ───────────────────
# IndexOf (nu regex multiline pe tot fisierul) — robust pe fisiere mari
$common = Get-Content (Join-Path $SRC "av_common.sh") -Raw
$i = $common.IndexOf('profile_schema_get()')
$j = $common.IndexOf('esac', $i)
$bashBody = if ($i -ge 0 -and $j -gt $i) { $common.Substring($i, $j - $i) } else { "" }
$bashKeys = [regex]::Matches($bashBody, '(?m)^\s*([A-Z][A-Z0-9_]+)\)\s+echo') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

# ── extrage cheile din schema PS1 (switch 'KEY' { ... }) ─────────────
$enc = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
$ps1Body = [regex]::Match($enc, "(?s)function Get-ProfileSchema.*?\n\}").Value
$ps1Keys = [regex]::Matches($ps1Body, "(?m)^\s*'([A-Z][A-Z0-9_]+)'\s*\{") |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

Assert-Eq $true ($bashKeys.Count -ge 30) "schema bash extrasa (>=30 chei; gasit: $($bashKeys.Count))"
Assert-Eq $true ($ps1Keys.Count -ge ($bashKeys.Count + 10)) "schema PS1 extrasa (bash + aliasuri; gasit: $($ps1Keys.Count))"

# ── (1) bash ⊆ PS1 ───────────────────────────────────────────────────
$missingInPs1 = @($bashKeys | Where-Object { $_ -notin $ps1Keys })
Assert-Eq 0 $missingInPs1.Count "toate cheile bash exista si in schema PS1 (lipsesc: $($missingInPs1 -join ', '))"

# ── (2) PS1-only ⊆ aliasurile cunoscute ──────────────────────────────
# Aliasurile native PS1 (curatoriale — un alias NOU se adauga si aici):
$knownAliases = @(
    'ENCODER','AV1_IMPL','CUSTOM_CRF','PRESET','TUNE','VF_PRESET','EXTRA_PARAMS',
    'AUDIO_CODEC','AUDIO_BITRATE','AUDIO_COPY','AUDIO_FLAC_LEVEL','PCM_DEPTH',
    'VBR_TARGET','VBR_MAXRATE','VBR_BUFSIZE','VBR_PARAM'
)
$ps1Only = @($ps1Keys | Where-Object { $_ -notin $bashKeys })
$unknownPs1Only = @($ps1Only | Where-Object { $_ -notin $knownAliases })
Assert-Eq 0 $unknownPs1Only.Count "cheile PS1-only sunt DOAR aliasurile cunoscute (necunoscute: $($unknownPs1Only -join ', '))"

# si invers: aliasurile din lista chiar exista in schema PS1 (guard la stergere)
$staleAliases = @($knownAliases | Where-Object { $_ -notin $ps1Keys })
Assert-Eq 0 $staleAliases.Count "toate aliasurile cunoscute exista in schema PS1 (disparute: $($staleAliases -join ', '))"

Invoke-TestSummary
