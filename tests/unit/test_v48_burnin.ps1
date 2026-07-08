# Test v48 burn-in features (PS1 mirror):
# - av_burnin.ps1 with 3 flows (HUD / SRT / ASS) + main dispatcher
# - Shared helpers: Get-Encoder / Get-PairedFiles / Select-Pairs / Get-EscapedFfmpegFilterPath
# - av_encode.ps1 main menu opt 8 dispatches to av_burnin.ps1, opt 9 exits
# - Presets + render engine (shared with bash)

. "$PSScriptRoot\..\framework.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$burninPath = Join-Path $root 'src\av_burnin.ps1'
$renderPath = Join-Path $root 'src\burnin_render.py'
$encodePath = Join-Path $root 'src\av_encode.ps1'

# ─────────────────────────────────────────────────────────────────
# 1) Files exist + syntax
# ─────────────────────────────────────────────────────────────────
if (Test-Path $burninPath) { _pass } else { _fail "av_burnin.ps1 exists" }
if (Test-Path $renderPath) { _pass } else { _fail "burnin_render.py exists" }
if (Test-Path (Join-Path $root 'src\burnin_presets\minimal.conf'))    { _pass } else { _fail "preset minimal.conf" }
if (Test-Path (Join-Path $root 'src\burnin_presets\data-strip.conf')) { _pass } else { _fail "preset data-strip.conf" }
if (Test-Path (Join-Path $root 'src\burnin_presets\full.conf'))       { _pass } else { _fail "preset full.conf" }

$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile($burninPath, [ref]$null, [ref]$errs) | Out-Null
if (-not $errs -or $errs.Count -eq 0) { _pass } else { _fail "av_burnin.ps1 syntax (errors: $($errs.Count))" }

$burninText = Get-Content -LiteralPath $burninPath -Raw
$encodeText = Get-Content -LiteralPath $encodePath -Raw
$renderText = Get-Content -LiteralPath $renderPath -Raw

# ─────────────────────────────────────────────────────────────────
# 2) Main dispatcher (3 flow + Anulare)
# ─────────────────────────────────────────────────────────────────
Assert-Match $burninText 'BURN-IN — selecteaza tipul' "main menu header"
Assert-Match $burninText '1\) Telemetry HUD'              "main menu opt 1 = HUD"
Assert-Match $burninText '2\) Subtitrari SRT'             "main menu opt 2 = SRT"
Assert-Match $burninText '3\) Subtitrari ASS'             "main menu opt 3 = ASS"
Assert-Match $burninText '4\) Image subs PGS/VobSub'      "main menu opt 4 = Image subs"
Assert-Match $burninText '6\) Anulare'                    "main menu opt 6 = Anulare (v84: opt 5 = Designer)"
Assert-Match $burninText '\$burninType'                   "dispatcher reads burninType"
Assert-Match $burninText 'Invoke-HudFlow'                 "dispatcher calls Invoke-HudFlow"
Assert-Match $burninText 'Invoke-SrtFlow'                 "dispatcher calls Invoke-SrtFlow"
Assert-Match $burninText 'Invoke-AssFlow'                 "dispatcher calls Invoke-AssFlow"
Assert-Match $burninText 'Invoke-ImgFlow'                 "dispatcher calls Invoke-ImgFlow"

# ─────────────────────────────────────────────────────────────────
# 3) av_encode.ps1 main menu integration
# ─────────────────────────────────────────────────────────────────
# v49: renumerotat — opt 9 = Burn-in, opt 10 = Iesire (Remux ocupa opt 7)
Assert-Match $encodeText '9-Burn-in \(HUD/SRT/ASS/Image\)'  "av_encode main menu opt 9 = Burn-in (v49)"
Assert-Match $encodeText '10-Iesire'              "av_encode main menu opt 10 = Iesire (v49)"
Assert-Match $encodeText '\$mainChoice -eq "10"'  "opt 10 triggers exit (v49)"
Assert-Match $encodeText '\$mainChoice -eq "9"'   "opt 9 dispatches burnin (v49)"
Assert-Match $encodeText 'av_burnin\.ps1'         "dispatches av_burnin.ps1"

# ─────────────────────────────────────────────────────────────────
# 4) Shared helpers
# ─────────────────────────────────────────────────────────────────
Assert-Match $burninText 'function Get-Encoder'                    "shared: Get-Encoder"
Assert-Match $burninText 'function Get-PairedFiles'                "shared: Get-PairedFiles"
Assert-Match $burninText 'function Select-Pairs'                   "shared: Select-Pairs"
Assert-Match $burninText 'function Get-EscapedFfmpegFilterPath'    "shared: Get-EscapedFfmpegFilterPath"
Assert-Match $burninText 'function Get-BrandFromCsv'               "shared: Get-BrandFromCsv"
Assert-Match $burninText 'libx265'                                 "encoder opt 1 = libx265"
Assert-Match $burninText 'libx264'                                 "encoder opt 2 = libx264"
Assert-Match $burninText 'libsvtav1'                               "encoder opt 3 = libsvtav1"

# ─────────────────────────────────────────────────────────────────
# 5) HUD flow
# ─────────────────────────────────────────────────────────────────
Assert-Match $burninText 'function Invoke-HudFlow'    "Invoke-HudFlow defined"
Assert-Match $burninText 'HUD TELEMETRY OVERLAY'      "hud: banner"
Assert-Match $burninText 'LAYOUT PRESET'              "hud: layout menu"
Assert-Match $burninText '\$preset = "minimal"'       "hud: preset minimal"
Assert-Match $burninText '\$preset = "data-strip"'    "hud: preset data-strip"
Assert-Match $burninText '\$preset = "full"'          "hud: preset full"
Assert-Match $burninText '\$outSuffix = "hud"'        "hud: output naming hud suffix"
Assert-Match $burninText '"\{0\}_\{1\}\.\{2\}"'        "hud/srt/ass/img: output template {0}_{1}.{2}"
Assert-Match $burninText 'filter_complex.*overlay'    "hud: filter_complex overlay"
Assert-Match $burninText 'frame_%06d\.png'            "hud: PNG seq pattern"
Assert-Match $burninText 'external_\*'                "hud: external_* sync offset"
Assert-Match $burninText 'import matplotlib, numpy'   "hud: matplotlib+numpy probed"

# ─────────────────────────────────────────────────────────────────
# 6) SRT flow
# ─────────────────────────────────────────────────────────────────
Assert-Match $burninText 'function Invoke-SrtFlow'    "Invoke-SrtFlow defined"
Assert-Match $burninText 'SRT BURN-IN'                "srt: banner"
Assert-Match $burninText 'STIL SRT'                   "srt: style menu"
Assert-Match $burninText 'FontSize=18'                "srt: Small font 18"
Assert-Match $burninText 'FontSize=24'                "srt: Medium font 24"
Assert-Match $burninText 'FontSize=32'                "srt: Large font 32"
Assert-Match $burninText 'force_style'                "srt: force_style applied"
Assert-Match $burninText 'subtitles='                 "srt: subtitles= filter"
$subsHits = ([regex]::Matches($burninText, '\$outSuffix = "subs"')).Count
if ($subsHits -ge 3) { _pass } else { _fail "srt/ass/img: subs suffix used (>=3 occurrences, found $subsHits)" }

# ─────────────────────────────────────────────────────────────────
# 7) ASS flow
# ─────────────────────────────────────────────────────────────────
Assert-Match $burninText 'function Invoke-AssFlow'    "Invoke-AssFlow defined"
Assert-Match $burninText 'ASS BURN-IN'                "ass: banner"
Assert-Eq $true ($burninText.Contains("ass='`$assEsc'")) "ass: filtru nativ ass (v82: styling embedded)"
Assert-Match $burninText 'styling embedded pastrat'   "ass: nota styling embedded (v82: fara meniu scale)"

# ─────────────────────────────────────────────────────────────────
# 7b) Image subs flow (PGS / VobSub, ext + embedded)
# ─────────────────────────────────────────────────────────────────
Assert-Match $burninText 'function Invoke-ImgFlow'   "Invoke-ImgFlow defined"
Assert-Match $burninText 'function Get-ImgPairs'     "Get-ImgPairs defined"
Assert-Match $burninText 'IMAGE SUBS BURN-IN'        "img: banner"
Assert-Match $burninText 'PGS \.sup'                 "img: external PGS .sup scan"
Assert-Match $burninText 'VobSub \.idx/\.sub'        "img: external VobSub .idx+.sub scan"
Assert-Match $burninText 'hdmv_pgs_subtitle'         "img: PGS codec detection"
Assert-Match $burninText 'dvd_subtitle'              "img: VobSub codec detection"
Assert-Match $burninText 'ext_pgs'                   "img: ext_pgs kind"
Assert-Match $burninText 'ext_vob'                   "img: ext_vob kind"
Assert-Match $burninText 'emb_pgs'                   "img: emb_pgs kind"
Assert-Match $burninText 'emb_vob'                   "img: emb_vob kind"
Assert-Match $burninText '\[0:v\]\[1:s\]overlay'     "img: ext overlay filter"
Assert-Match $burninText '\[0:v\]\[0:s:\$\(\$p\.Track\)\]overlay' "img: embedded overlay filter"

# ─────────────────────────────────────────────────────────────────
# 7c) Preview mode (shared, opt-in pe toate 4 flow-uri)
# ─────────────────────────────────────────────────────────────────
Assert-Match $burninText 'function Get-PreviewMode'    "preview: Get-PreviewMode defined"
Assert-Match $burninText 'function Get-PreviewWindow'  "preview: Get-PreviewWindow defined"
Assert-Match $burninText '\$script:PreviewMode'        "preview: script-scoped PreviewMode"
Assert-Match $burninText '5s clip la mid-point'        "preview: prompt text 5s mid-point"
Assert-Match $burninText '_preview\.'                  "preview: output naming _preview"
$callCount = ([regex]::Matches($burninText, 'Get-PreviewMode')).Count
if ($callCount -ge 5) { _pass } else { _fail "preview: 4 flow-uri cheama Get-PreviewMode (definitie + 4 apeluri, found $callCount)" }
# v85 (F7): seekArgs nu mai e splatat inline la apel (flag-urile cu `:` se corupeau);
# e concatenat in array-ul $ffArgs care se splateaza intreg spre Invoke-BurninEncode.
Assert-Match $burninText ([regex]::Escape('+ $seekArgs +')) "preview: seekArgs concatenat in array-ul ffmpeg (F7)"
Assert-Match $burninText '-copyts'                     "preview: -copyts pt subtitle filters"

# Bug-uri rezolvate v48 audit:
# - Get-PreviewWindow returneaza Valid=$false pe durata invalida
Assert-Match $burninText 'Valid\s*=\s*\$false'         "preview: PreviewWindow Valid=false la durata invalida"
Assert-Match $burninText 'Valid\s*=\s*\$true'          "preview: PreviewWindow Valid=true la durata valida"
# - 4 flow-uri verifica $pw.Valid si fall-back
$validHits = ([regex]::Matches($burninText, '\$pw\.Valid')).Count
if ($validHits -ge 4) { _pass } else { _fail "preview: 4 flow-uri verifica \$pw.Valid (found $validHits)" }
Assert-Match $burninText 'Durata invalida'             "preview: WARN message la fall-back"
# - Format-Inv helper pt locale-safe (decimal "." nu ",")
Assert-Match $burninText 'function Format-Inv'         "preview: Format-Inv helper pt locale safety"
Assert-Match $burninText 'InvariantCulture'            "preview: InvariantCulture folosit explicit"
# - scan exclude *_preview
$prevHits = ([regex]::Matches($burninText, '\*_preview')).Count
if ($prevHits -ge 2) { _pass } else { _fail "scan: *_preview in exclude list (Get-PairedFiles + Get-ImgPairs, found $prevHits)" }

# ─────────────────────────────────────────────────────────────────
# 8) Preset content
# ─────────────────────────────────────────────────────────────────
$minPath  = Join-Path $root 'src\burnin_presets\minimal.conf'
$striPath = Join-Path $root 'src\burnin_presets\data-strip.conf'
$fullPath = Join-Path $root 'src\burnin_presets\full.conf'
Assert-Match (Get-Content -LiteralPath $minPath  -Raw) 'PRESET_NAME=minimal'    "minimal.conf"
Assert-Match (Get-Content -LiteralPath $striPath -Raw) 'PRESET_NAME=data-strip' "data-strip.conf"
Assert-Match (Get-Content -LiteralPath $fullPath -Raw) 'PRESET_NAME=full'       "full.conf"
Assert-Match (Get-Content -LiteralPath $fullPath -Raw) 'HUD_MAP=1'              "full preset enables map"
Assert-Match (Get-Content -LiteralPath $striPath -Raw) 'HUD_DATA_STRIP=1'       "data-strip enables strip"
Assert-Match (Get-Content -LiteralPath $minPath  -Raw) 'HUD_DATA_STRIP=0'       "minimal disables strip"

# ─────────────────────────────────────────────────────────────────
# 9) Render engine (HUD shared)
# ─────────────────────────────────────────────────────────────────
Assert-Match $renderText 'def load_csv_points'  "render: load_csv_points"
Assert-Match $renderText 'def sample_at'        "render: sample_at"
Assert-Match $renderText 'def render_frame'     "render: render_frame"
Assert-Match $renderText 'def build_route_xy'   "render: build_route_xy"
Assert-Match $renderText '\-\-csv'              "render CLI: --csv"
Assert-Match $renderText '\-\-preset'           "render CLI: --preset"
Assert-Match $renderText '\-\-fps'              "render CLI: --fps"
Assert-Match $renderText '\-\-offset'           "render CLI: --offset"

Invoke-TestSummary
