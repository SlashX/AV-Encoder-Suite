# v80 — Burn-in: cablare chei moarte. PS1 mirror al test_v80_burnin_deadkeys.sh.
#   Engine burnin_render.py PARTAJAT bash<->PS1 → testul valideaza ACELASI engine
#   (FONT_FAMILY + HUD_ALTITUDE/HEADING/TEMPERATURE gauge-uri colt, gateate not HUD_DATA_STRIP).
. "$PSScriptRoot\..\framework.ps1"

$src     = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src'
$engine  = Get-Content (Join-Path $src 'burnin_render.py') -Raw
$minimal = Get-Content (Join-Path $src 'burnin_presets\minimal.conf') -Raw
$full    = Get-Content (Join-Path $src 'burnin_presets\full.conf') -Raw

# ── 1. FONT_FAMILY cablat (dead->live) ──
Assert-Eq $true ($engine.Contains('cfg.get("FONT_FAMILY"'))  "engine: FONT_FAMILY citit din preset"
Assert-Eq $true ($engine.Contains('fontfamily'))             "engine: aplicat ca fontfamily="
Assert-Eq $true ($engine.Contains('FontProperties(fname='))  "engine: cale .ttf/.otf via FontProperties(fname=)"
Assert-Eq $true ($engine.Contains('from matplotlib.font_manager import FontProperties')) "engine: import FontProperties"
Assert-Eq $true ($engine.Contains('logging.getLogger("matplotlib.font_manager").setLevel(logging.ERROR)')) "engine: warning findfont silentiat (nume familie invalid -> fallback tacut)"

# ── 2. HUD_ALTITUDE/HEADING/TEMPERATURE gauge-uri colt ──
Assert-Eq $true ($engine.Contains('HUD_ALTITUDE'))     "engine: HUD_ALTITUDE cablat"
Assert-Eq $true ($engine.Contains('HUD_HEADING'))      "engine: HUD_HEADING cablat"
Assert-Eq $true ($engine.Contains('HUD_TEMPERATURE'))  "engine: HUD_TEMPERATURE cablat"
Assert-Eq $true ($engine.Contains('POS_ALTITUDE'))     "engine: POS_ALTITUDE configurabil"
Assert-Eq $true ($engine.Contains('POS_HEADING'))      "engine: POS_HEADING configurabil"
Assert-Eq $true ($engine.Contains('POS_TEMPERATURE'))  "engine: POS_TEMPERATURE configurabil"
Assert-Eq $true ($engine.Contains('HUD_ALTITUDE") and not cfg_bool(cfg, "HUD_DATA_STRIP")')) "engine: ALT gateat not HUD_DATA_STRIP (non-redundant cu STRIP_FIELDS)"
Assert-Eq $true ($engine.Contains('fmt_value(sample.get("alt_m"), "{:.1f}", " m")'))     "engine: ALT refoloseste formatul din strip"
Assert-Eq $true ($engine.Contains('fmt_value(sample.get("heading_deg"), "{:.0f}", "°")')) "engine: HDG refoloseste formatul din strip"
Assert-Eq $true ($engine.Contains('fmt_value(sample.get("temp_c"), "{:.1f}", "°C")'))    "engine: TEMP refoloseste formatul din strip"

# ── 3. FRAME_W/FRAME_H/PRESET_DESC raman scoase ──
Assert-Eq $false ($engine.Contains('FRAME_W'))     "engine: FRAME_W ramane scos (latimea din --width)"
Assert-Eq $false ($engine.Contains('FRAME_H'))     "engine: FRAME_H ramane scos (inaltimea din --height)"
Assert-Eq $false ($engine.Contains('PRESET_DESC')) "engine: PRESET_DESC ramane scos"

# ── 4. Presets documenteaza cheile noi ──
Assert-Eq $true ($minimal.Contains('HUD_ALTITUDE')) "minimal.conf: documenteaza gauge-urile noi"
Assert-Eq $true ($minimal.Contains('FONT_FAMILY'))  "minimal.conf: documenteaza FONT_FAMILY"
Assert-Eq $true ($full.Contains('FONT_FAMILY'))     "full.conf: documenteaza FONT_FAMILY"

# ── 5. Functional: render 1 cadru cu FONT_FAMILY + gauge-uri → PNG ──
$py = Get-Command python -ErrorAction SilentlyContinue
$hasMpl = $false
if ($py) { & $py.Source -c "import matplotlib" 2>$null; $hasMpl = ($LASTEXITCODE -eq 0) }
if ($hasMpl) {
    $g  = [guid]::NewGuid().ToString('N').Substring(0,8)
    $td = Join-Path $env:TEMP "bi_dk_$g"
    New-Item -ItemType Directory -Force $td | Out-Null
    @"
timestamp,lat,lon,alt_m,speed_mps,speed_kmh,heading_deg,temp_c,source_brand
2024-03-15T12:30:45,44.37,26.10,512.4,12.5,45.0,278,23.7,dji
2024-03-15T12:30:47,44.371,26.101,540.9,14.0,50.4,281,24.1,dji
"@ | Set-Content -Path (Join-Path $td 't.csv') -Encoding ascii
    @"
PRESET_NAME=deadkeys_test
HUD_TIMESTAMP=1
HUD_SPEED=1
HUD_DATA_STRIP=0
HUD_ALTITUDE=1
HUD_HEADING=1
HUD_TEMPERATURE=1
POS_ALTITUDE=tl:24,80
POS_HEADING=tl:24,116
POS_TEMPERATURE=tl:24,152
FONT_FAMILY=monospace
"@ | Set-Content -Path (Join-Path $td 't.conf') -Encoding ascii
    & $py.Source (Join-Path $src 'burnin_render.py') --csv (Join-Path $td 't.csv') `
        --preset (Join-Path $td 't.conf') --output-dir (Join-Path $td 'out') `
        --fps 1 --duration 1 --width 320 --height 240 2>$null | Out-Null
    $png = Join-Path $td 'out\frame_000001.png'
    Assert-Eq $true (Test-Path $png) "functional: PNG randat (FONT_FAMILY + gauge-uri colt)"
    if (Test-Path $png) {
        Assert-Eq $true ((Get-Item $png).Length -gt 0) "functional: PNG non-gol"
    }
    # font invalid (nume familie negasit) → fallback TACUT (fara spam warning findfont)
    $badConf = Join-Path $td 'bad.conf'
    @"
PRESET_NAME=bad
HUD_TIMESTAMP=1
HUD_ALTITUDE=1
HUD_DATA_STRIP=0
FONT_FAMILY=NoSuchFamilyZZ123
"@ | Set-Content -Path $badConf -Encoding ascii
    $badErr = & $py.Source (Join-Path $src 'burnin_render.py') --csv (Join-Path $td 't.csv') `
        --preset $badConf --output-dir (Join-Path $td 'bad') --fps 1 --duration 1 --width 240 --height 160 2>&1
    $hasFindfont = $null -ne ($badErr | Select-String -SimpleMatch 'findfont')
    Assert-Eq $false $hasFindfont "functional: font invalid → fallback tacut (fara warning findfont)"
    Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-TestSummary
