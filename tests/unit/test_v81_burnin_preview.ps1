# v81 — Burn-in still layout preview (Tier 1). PS1 mirror al test_v81_burnin_preview.sh.
#   Engine burnin_render.py PARTAJAT bash<->PS1 → valideaza acelasi engine (--single/--grid)
#   + ramura still in ambele wrappere. ADITIV: render complet + clip 5s NEschimbate.
. "$PSScriptRoot\..\framework.ps1"

$src = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$src;$env:PATH" }
$engine = Get-Content (Join-Path $src 'burnin_render.py') -Raw
$bsh    = Get-Content (Join-Path $src 'av_burnin.sh') -Raw
$bps    = Get-Content (Join-Path $src 'av_burnin.ps1') -Raw

# ── 1. Engine ───────────────────────────────────────────────────────
Assert-Eq $true ($engine.Contains('"--single"'))            "engine: arg --single"
Assert-Eq $true ($engine.Contains('"--grid"'))              "engine: arg --grid"
Assert-Eq $true ($engine.Contains('out_path, grid=False)')) "engine: render_frame param grid"
Assert-Eq $true ($engine.Contains('if args.single is not None:')) "engine: ramura single"
Assert-Eq $true ($engine.Contains('grid=args.grid'))        "engine: single paseaza grid"
Assert-Eq $true ($engine.Contains('if grid:'))              "engine: bloc grila"

# ── 2. av_burnin.sh ─────────────────────────────────────────────────
Assert-Eq $true ($bsh.Contains('PREVIEW_STILL=0'))          "bash: PREVIEW_STILL"
Assert-Eq $true ($bsh.Contains('PREVIEW_GRID=0'))           "bash: PREVIEW_GRID"
Assert-Eq $true ($bsh.Contains('local allow_still='))       "bash: ask_preview allow_still"
Assert-Eq $true ($bsh.Contains('ask_preview 1'))            "bash: HUD cu still"
Assert-Eq $true ($bsh.Contains('--single "$_st_t"'))        "bash: still --single"
Assert-Eq $true ($bsh.Contains('av_open_path "$_st_out"'))  "bash: auto-open"
Assert-Eq $true ($bsh.Contains('PREVIEW_MODE=1'))           "bash: ADITIV clip 5s pastrat"

# ── 3. av_burnin.ps1 ────────────────────────────────────────────────
Assert-Eq $true ($bps.Contains('PreviewStill'))             "PS1: PreviewStill"
Assert-Eq $true ($bps.Contains('PreviewGrid'))              "PS1: PreviewGrid"
Assert-Eq $true ($bps.Contains('param([switch]$AllowStill)')) "PS1: -AllowStill"
Assert-Eq $true ($bps.Contains('Get-PreviewMode -AllowStill')) "PS1: HUD -AllowStill"
Assert-Eq $true ($bps.Contains('if ($script:PreviewStill)')) "PS1: ramura still"
Assert-Eq $true ($bps.Contains('--single'))                 "PS1: still --single"
Assert-Eq $true ($bps.Contains('Invoke-Item $stOut'))       "PS1: auto-open"
Assert-Eq $true ($bps.Contains('PreviewMode = $true'))      "PS1: ADITIV clip 5s pastrat"
# v94 (B15): still-ul cade la MIJLOCUL clipului, nu la inceputul ferestrei de 5s
Assert-Eq $true ($bps.Contains('$mid = $Duration / 2.0'))   "B15: helper-ul calculeaza mijlocul real"
Assert-Eq $true ($bps.Contains('Mid         = (Format-Inv $mid)')) "B15: mijlocul e expus in hashtable"
Assert-Eq $true ($bps.Contains('if ($pw.Valid) { $stT = $pw.Mid }')) "B15: still consuma Mid, nu Start"
Assert-Eq $true ($bps.Contains('$m = $Duration / 2.0 - 2.5')) "B15: fereastra clipului de 5s NEatinsa"
# functional: mijloc vs inceput-fereastra pe cateva durate
# NB: formatare InvariantCulture — pe locale EU „{0:0.###}" ar da virgula zecimala
# (exact motivul pentru care productia foloseste Format-Inv).
$inv = [System.Globalization.CultureInfo]::InvariantCulture
foreach ($case in @(@(8.008,'4.004','1.504'), @(6.0,'3','0.5'), @(4.0,'2','0'))) {
    $d = [double]$case[0]
    $mid = $d / 2.0
    $st  = $d / 2.0 - 2.5; if ($st -lt 0) { $st = 0.0 }
    Assert-Eq $case[1] ($mid.ToString('0.###', $inv)) "B15: durata ${d}s → still la mijloc"
    Assert-Eq $case[2] ($st.ToString('0.###', $inv))  "B15: durata ${d}s → clip 5s porneste la mid-2.5"
}

# ── 4. Functional: engine single/grid + render complet + composite ──
$py = Get-Command python -ErrorAction SilentlyContinue
$hasMpl = $false
if ($py) { & $py.Source -c "import matplotlib" 2>$null; $hasMpl = ($LASTEXITCODE -eq 0) }
if ($hasMpl) {
    $g = [guid]::NewGuid().ToString('N').Substring(0,8)
    $td = Join-Path $env:TEMP "bi_pv_$g"; New-Item -ItemType Directory -Force $td | Out-Null
    @"
timestamp,lat,lon,alt_m,speed_mps,speed_kmh,heading_deg,temp_c,source_brand
2024-03-15T12:30:45,44.37,26.10,512.4,12.5,45.0,278,23.7,dji
2024-03-15T12:30:47,44.371,26.101,540.9,14.0,50.4,281,24.1,dji
"@ | Set-Content -Path (Join-Path $td 't.csv') -Encoding ascii
    $preset = Join-Path $src 'burnin_presets\full.conf'
    $rp = Join-Path $src 'burnin_render.py'
    # --single + --grid → exact 1 cadru
    & $py.Source $rp --csv (Join-Path $td 't.csv') --preset $preset --output-dir (Join-Path $td 'single') `
        --fps 10 --duration 1 --single 1.0 --grid --width 480 --height 270 2>$null | Out-Null
    $nSingle = @(Get-ChildItem (Join-Path $td 'single') -Filter 'frame_*.png' -ErrorAction SilentlyContinue).Count
    Assert-Eq 1 $nSingle "functional: --single -> exact 1 cadru (grid)"
    # render complet (fara --single) → multi-cadru (ADITIV)
    & $py.Source $rp --csv (Join-Path $td 't.csv') --preset $preset --output-dir (Join-Path $td 'full') `
        --fps 2 --duration 1 --width 320 --height 240 2>$null | Out-Null
    $nFull = @(Get-ChildItem (Join-Path $td 'full') -Filter 'frame_*.png' -ErrorAction SilentlyContinue).Count
    Assert-Eq $true ($nFull -ge 2) "functional: render complet multi-cadru ($nFull)"
    # composite: ffmpeg testsrc + overlay HUD → PNG non-gol
    if ((Get-Command ffmpeg -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $td 'single\frame_000001.png'))) {
        & ffmpeg -v error -y -f lavfi -i "testsrc=size=480x270:rate=10:duration=1" -pix_fmt yuv420p (Join-Path $td 'v.mp4') 2>$null | Out-Null
        & ffmpeg -v error -ss 0.5 -i (Join-Path $td 'v.mp4') -i (Join-Path $td 'single\frame_000001.png') `
            -filter_complex "[0:v][1:v]overlay=0:0[v]" -map "[v]" -frames:v 1 -y (Join-Path $td 'comp.png') 2>$null | Out-Null
        $comp = Join-Path $td 'comp.png'
        Assert-Eq $true ((Test-Path $comp) -and ((Get-Item $comp).Length -gt 0)) "functional: compozitie HUD pe cadru video -> PNG non-gol"
    }
    Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-TestSummary
