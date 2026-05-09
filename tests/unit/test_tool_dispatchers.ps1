# Test v44 codec-aware tool dispatchers din av_encode.ps1:
# - Get-ToolForExtract / Get-ToolForInject (codec×kind dispatch)
# - Test-DoviToolFor / Test-Hdr10PlusToolFor (codec routing)
# - Test-Av1DoviTool / Test-Av1Hdr10PlusTool
# - Test-SvtAv1Hdr10PlusCaps (cache behavior)
# - Get-SourceCodec (basic empty-input handling)
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

Import-AvEncodeFunctions -Names @(
    'Get-SourceCodec',
    'Get-ToolForExtract',
    'Get-ToolForInject',
    'Test-Av1DoviTool',
    'Test-Av1Hdr10PlusTool',
    'Test-DoviToolFor',
    'Test-Hdr10PlusToolFor',
    'Test-SvtAv1Hdr10PlusCaps'
)

# ─────────────────────────────────────────────────────────────────
# 1) Get-ToolForExtract — codec × kind dispatch
# ─────────────────────────────────────────────────────────────────
Assert-Eq "dovi_tool"           (Get-ToolForExtract -Codec hevc -Kind dovi)      "hevc + dovi"
Assert-Eq "hdr10plus_tool"      (Get-ToolForExtract -Codec hevc -Kind hdr10plus) "hevc + hdr10plus"
Assert-Eq "av1dovi_tool"        (Get-ToolForExtract -Codec av1 -Kind dovi)       "av1 + dovi"
Assert-Eq "av1hdr10plus_tool"   (Get-ToolForExtract -Codec av1 -Kind hdr10plus)  "av1 + hdr10plus"

# Default-uri (Codec=hevc, Kind=dovi)
Assert-Eq "dovi_tool"      (Get-ToolForExtract)                       "all defaults -> dovi_tool"
Assert-Eq "hdr10plus_tool" (Get-ToolForExtract -Kind hdr10plus)       "default codec=hevc + hdr10plus"

# Codec necunoscut -> back-compat hevc branch
Assert-Eq "dovi_tool"      (Get-ToolForExtract -Codec h264 -Kind dovi)      "h264 falls back to hevc"
Assert-Eq "hdr10plus_tool" (Get-ToolForExtract -Codec vp9  -Kind hdr10plus) "vp9 falls back to hevc"

# Kind invalid -> string gol
Assert-Eq "" (Get-ToolForExtract -Codec hevc -Kind bogus) "kind invalid -> empty"
Assert-Eq "" (Get-ToolForExtract -Codec av1  -Kind bogus) "kind invalid (av1) -> empty"

# ─────────────────────────────────────────────────────────────────
# 2) Get-ToolForInject — alias pentru Get-ToolForExtract
# ─────────────────────────────────────────────────────────────────
Assert-Eq "dovi_tool"         (Get-ToolForInject -Codec hevc -Kind dovi)      "inject hevc dovi"
Assert-Eq "av1dovi_tool"      (Get-ToolForInject -Codec av1 -Kind dovi)       "inject av1 dovi"
Assert-Eq "av1hdr10plus_tool" (Get-ToolForInject -Codec av1 -Kind hdr10plus)  "inject av1 hdr10plus"

# ─────────────────────────────────────────────────────────────────
# 3) Test-DoviToolFor / Test-Hdr10PlusToolFor — codec routing
# Verificam ca returneaza Boolean (nu null/throw) pentru ambii codeci.
# Valoarea efectiva depinde de PATH; testam doar tipul + ne-throw.
# ─────────────────────────────────────────────────────────────────
$r = Test-DoviToolFor -Codec hevc
Assert-Eq "Boolean" $r.GetType().Name "DoviToolFor hevc -> Boolean"
$r = Test-DoviToolFor -Codec av1
Assert-Eq "Boolean" $r.GetType().Name "DoviToolFor av1 -> Boolean"
# Default codec=hevc — apel fara arg
$r = Test-DoviToolFor
Assert-Eq "Boolean" $r.GetType().Name "DoviToolFor default -> Boolean"

$r = Test-Hdr10PlusToolFor -Codec hevc
Assert-Eq "Boolean" $r.GetType().Name "Hdr10PlusToolFor hevc -> Boolean"
$r = Test-Hdr10PlusToolFor -Codec av1
Assert-Eq "Boolean" $r.GetType().Name "Hdr10PlusToolFor av1 -> Boolean"

# Test-Av1*Tool returneaza Boolean
$r = Test-Av1DoviTool
Assert-Eq "Boolean" $r.GetType().Name "Av1DoviTool -> Boolean"
$r = Test-Av1Hdr10PlusTool
Assert-Eq "Boolean" $r.GetType().Name "Av1Hdr10PlusTool -> Boolean"

# ─────────────────────────────────────────────────────────────────
# 4) Test-SvtAv1Hdr10PlusCaps — cache via $script: var
# ─────────────────────────────────────────────────────────────────
$script:_SvtAv1Hdr10PlusCaps = $true
Assert-Eq $true (Test-SvtAv1Hdr10PlusCaps) "caps cache=true"

$script:_SvtAv1Hdr10PlusCaps = $false
Assert-Eq $false (Test-SvtAv1Hdr10PlusCaps) "caps cache=false"

# Cache invalid -> proba ffmpeg; in lipsa lui returneaza Boolean (nu throw)
$script:_SvtAv1Hdr10PlusCaps = $null
$r = Test-SvtAv1Hdr10PlusCaps 2>$null
Assert-Eq "Boolean" $r.GetType().Name "caps probe -> Boolean (no throw)"

# ─────────────────────────────────────────────────────────────────
# 5) Get-SourceCodec — handling pentru input invalid
# ─────────────────────────────────────────────────────────────────
Assert-Eq "" (Get-SourceCodec "")                  "empty path -> empty"
Assert-Eq "" (Get-SourceCodec "C:\nonexistent.mp4") "missing file -> empty"

Invoke-TestSummary
