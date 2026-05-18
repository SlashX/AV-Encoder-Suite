# Test v47 features (PS1 mirror):
# - av_telemetry.ps1 menu has opt 7 + opt 8 = Anulare
# - Invoke-EmbedTelemetryLossless function defined
# - Container routing mirror (MKV/MP4)
# - EmbedAfter flag override mechanism
# - Main loop hook present

. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$telemPath = Join-Path $root 'src\av_telemetry.ps1'
$telemText = Get-Content -LiteralPath $telemPath -Raw

# ─────────────────────────────────────────────────────────────────
# 1) Menu structure
# ─────────────────────────────────────────────────────────────────
Assert-Match $telemText '7\) Extract \+ embed lossless' "menu has opt 7 'Extract + embed lossless'"
Assert-Match $telemText '8\) Anulare' "menu opt 8 = Anulare (shifted from 7)"
Assert-Match $telemText 'Alege 1-8 \[implicit: 1\]' "Read prompt updated to 'Alege 1-8'"
Assert-Match $telemText 'if \(\$choice -eq "8"\) \{ exit \}' "choice=8 triggers exit"

# ─────────────────────────────────────────────────────────────────
# 2) EmbedAfter override
# ─────────────────────────────────────────────────────────────────
Assert-Match $telemText '\$EmbedAfter = \$false' "EmbedAfter flag default false"
Assert-Match $telemText '\$EmbedAfter = \$true' "EmbedAfter=true when choice=7"
Assert-Match $telemText 'if \(\$choice -eq "7"\)' "choice=7 triggers EmbedAfter"
Assert-Match $telemText '\$choice = "4"' "choice overridden to 4 for extraction reuse"

# ─────────────────────────────────────────────────────────────────
# 3) Function defined via AST inspection
# ─────────────────────────────────────────────────────────────────
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($telemPath, [ref]$tokens, [ref]$errors)
$funcs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$embedFn = $funcs | Where-Object { $_.Name -eq 'Invoke-EmbedTelemetryLossless' } | Select-Object -First 1
if ($embedFn) { _pass } else { _fail "Invoke-EmbedTelemetryLossless defined" }
$fnText = $embedFn.Extent.Text

# ─────────────────────────────────────────────────────────────────
# 4) Artifact detection
# ─────────────────────────────────────────────────────────────────
Assert-Match $fnText '\$srtFile\s+= Join-Path \$OutputDir "\$\{name\}\.srt"' "detects SRT path"
Assert-Match $fnText '\$csvNorm\s+= Join-Path \$OutputDir "\$\{name\}_norm\.csv"' "detects norm CSV path"
Assert-Match $fnText '\$gpxFile\s+= Join-Path \$OutputDir "\$\{name\}\.gpx"' "detects GPX path"

# ─────────────────────────────────────────────────────────────────
# 5) Container routing
# ─────────────────────────────────────────────────────────────────
Assert-Match $fnText 'switch -Regex \(\$srcExt\)' "container switch on srcExt"
Assert-Match $fnText 'mp4\|mov\|m4v' "handles mp4/mov/m4v containers"
Assert-Match $fnText '\$targetExt = "mkv"' "default target mkv"

# ─────────────────────────────────────────────────────────────────
# 6) Attachments only for MKV
# ─────────────────────────────────────────────────────────────────
Assert-Match $fnText 'if \(\$targetExt -eq "mkv"\)' "attachments gated on target=mkv"
Assert-Match $fnText '-attach.*\$csvNorm' "ffmpeg -attach for norm CSV"
Assert-Match $fnText '-attach.*\$gpxFile' "ffmpeg -attach for GPX"
Assert-Match $fnText 'mimetype=text/csv' "CSV mimetype"
Assert-Match $fnText 'mimetype=application/gpx\+xml' "GPX mimetype"

# ─────────────────────────────────────────────────────────────────
# 7) Subtitle codec branch
# ─────────────────────────────────────────────────────────────────
Assert-Match $fnText '"srt"' "MKV subtitle codec srt"
Assert-Match $fnText '"mov_text"' "MP4 subtitle codec mov_text"

# ─────────────────────────────────────────────────────────────────
# 8) Main loop hook
# ─────────────────────────────────────────────────────────────────
Assert-Match $telemText 'if \(\$EmbedAfter -and \$brand -ne "unknown"\)' "main loop hook gated on EmbedAfter"
Assert-Match $telemText 'Invoke-EmbedTelemetryLossless \$f \$name' "main loop invokes embed function"

# ─────────────────────────────────────────────────────────────────
# 9) Output naming
# ─────────────────────────────────────────────────────────────────
Assert-Match $fnText '\$\{name\}_telem\.\$\{targetExt\}' "output naming <name>_telem.<ext>"

# ─────────────────────────────────────────────────────────────────
# 10) v47 submenu — 4 profile options + Anulare
# ─────────────────────────────────────────────────────────────────
Assert-Match $telemText 'EMBED LOSSLESS — selecteaza continut' "submenu header present"
Assert-Match $telemText '1\) SRT only' "submenu opt 1 = SRT only"
Assert-Match $telemText '2\) SRT \+ norm CSV' "submenu opt 2 = SRT + norm CSV"
Assert-Match $telemText '3\) SRT \+ norm CSV \+ GPX' "submenu opt 3 = SRT + norm CSV + GPX"
Assert-Match $telemText '4\) Toate' "submenu opt 4 = Toate"
Assert-Match $telemText '5\) Anulare' "submenu opt 5 = Anulare"
Assert-Match $telemText '\$EmbedProfile = "srt"' "EmbedProfile=srt for opt 1"
Assert-Match $telemText '\$EmbedProfile = "srt_csv"' "EmbedProfile=srt_csv for opt 2"
Assert-Match $telemText '\$EmbedProfile = "srt_csv_gpx"' "EmbedProfile=srt_csv_gpx for opt 3"
Assert-Match $telemText '\$EmbedProfile = "all"' "EmbedProfile=all for opt 4"

# ─────────────────────────────────────────────────────────────────
# 11) v47 — choice override per profile
# ─────────────────────────────────────────────────────────────────
Assert-Match $telemText '"1"\s*\{\s*\$EmbedProfile\s*=\s*"srt";\s*\$choice = "3"' "opt 1 overrides choice=3"
Assert-Match $telemText '"4"\s*\{\s*\$EmbedProfile\s*=\s*"all";\s*\$choice = "4"' "opt 4 overrides choice=4"

# ─────────────────────────────────────────────────────────────────
# 12) v47 — EmbedProfile honored in embed function
# ─────────────────────────────────────────────────────────────────
Assert-Match $fnText '\$profile = if \(\$EmbedProfile\)' "embed function reads EmbedProfile with default"
Assert-Match $fnText 'switch \(\$profile\)' "embed function branches per profile"
Assert-Match $fnText '\$wantCsvBasic = \(Test-Path \$csvBasic\)' "profile=all attaches basic CSV"
Assert-Match $fnText '\$wantCsvFull\s+= \(Test-Path \$csvFull\)' "profile=all attaches FULL CSV"
Assert-Match $fnText '\$wantKml\s+= \(Test-Path \$kmlFile\)' "profile=all attaches KML"

# ─────────────────────────────────────────────────────────────────
# 13) v47 — KML generator + KML mimetype
# ─────────────────────────────────────────────────────────────────
Assert-Match $telemText 'function New-KmlFromNormCsv' "KML generator helper defined"
Assert-Match $fnText 'mimetype=application/vnd\.google-earth\.kml\+xml' "KML mimetype set"
Assert-Match $fnText '"all"\s*\{\s*\$targetExt = "mkv"' "profile=all forces MKV"

Invoke-TestSummary
