# v84 — Burn-in Designer (Tier 2) — PS1 mirror al test_v84_burnin_designer.sh.
#   Server HTTP local (burnin_designer.py, stdlib) + UI browser
#   (burnin_designer.html) + integrare av_burnin (flow 5 „Designer vizual" +
#   optiunea „custom" in LAYOUT PRESET, preseturi in UserProfiles/burnin/).
#   Source-level + functional headless REAL pe Windows (server → API round-trip).
. "$PSScriptRoot\..\framework.ps1"
$PROJECT_ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$src = Join-Path $PROJECT_ROOT 'src'

$engine = Join-Path $src 'burnin_designer.py'
$ui     = Join-Path $src 'burnin_designer.html'
Assert-Eq $true (Test-Path $engine) "engine burnin_designer.py exista"
Assert-Eq $true (Test-Path $ui)     "UI burnin_designer.html exista"

$ENG = Get-Content -LiteralPath $engine -Raw
$UIT = Get-Content -LiteralPath $ui -Raw
$BSH = Get-Content -LiteralPath (Join-Path $src 'av_burnin.sh') -Raw
$BPS = Get-Content -LiteralPath (Join-Path $src 'av_burnin.ps1') -Raw

# ── Engine: rute API + principii ─────────────────────────────────────
Assert-Match $ENG '/api/overlay'          "engine: ruta /api/overlay"
Assert-Match $ENG '/api/save'             "engine: ruta /api/save"
Assert-Match $ENG '/api/shutdown'         "engine: ruta /api/shutdown"
Assert-Match $ENG 'import burnin_render'  "engine: reuse burnin_render (render REAL = WYSIWYG)"
Assert-Match $ENG '127\.0\.0\.1'          "engine: bind localhost-only"
Assert-Match $ENG 'synth_points'          "engine: mod DEMO fara CSV"
Assert-Match $ENG 'tonemap=tonemap=hable' "engine: tonemap display pe HDR (ca still v82)"
Assert-Match $ENG 'BURNIN_STILL_NO_TONEMAP' "engine: onoreaza env-ul v82 de bypass tonemap"

# ── Engine render (burnin_render) — fix-uri v84 expuse de designer ──
# G-force/HR ignorau ancora (ha/va fixe left/top → text iesit din cadru pe
# tr/br) + map crapa pe route_xy=(None,None,None) (CSV fara GPS).
$RND = Get-Content -LiteralPath (Join-Path $src 'burnin_render.py') -Raw
Assert-Match $RND ([regex]::Escape('f"G {gmag:.2f}", font_medium, ha=ha, va=va')) "render: G-force aliniat dupa ancora (ha/va)"
Assert-Match $RND ([regex]::Escape('bpm", font_medium, ha=ha, va=va'))            "render: HR aliniat dupa ancora (ha/va)"
Assert-Match $RND ([regex]::Escape('route_xy is not None and route_xy[0]'))       "render: guard map pe route_xy[0] (CSV fara GPS)"

# ── UI ───────────────────────────────────────────────────────────────
Assert-Match $UIT 'api/overlay'           "UI: cere overlay de la server"
Assert-Match $UIT 'applyDrop'             "UI: drag→anchor:x,y (applyDrop)"
Assert-Match $UIT 'STRIP_FIELDS'          "UI: editor campuri strip"

# ── Integrare PS1 (fisierul propriu) ─────────────────────────────────
Assert-Match $BPS 'Invoke-DesignerFlow'                       "PS1: Invoke-DesignerFlow exista"
Assert-Match $BPS ([regex]::Escape('$DesignerPy'))            "PS1: `$DesignerPy definit"
Assert-Match $BPS ([regex]::Escape('5) Designer vizual layout HUD')) "PS1: optiunea 5 in meniul principal"
Assert-Match $BPS ([regex]::Escape('6) Anulare'))             "PS1: Anulare renumerotata 6"
Assert-Match $BPS ([regex]::Escape('custom      — preset salvat (Designer)')) "PS1: LAYOUT PRESET opt 4 = custom"
Assert-Match $BPS ([regex]::Escape('"5" { Invoke-DesignerFlow }')) "PS1: dispatcher 5 → Invoke-DesignerFlow"

# ── Paritate bash ────────────────────────────────────────────────────
Assert-Match $BSH 'designer_flow\(\)'                         "bash: designer_flow exista (paritate)"
Assert-Match $BSH ([regex]::Escape('5) Designer vizual layout HUD')) "bash: optiunea 5 (paritate)"
Assert-Match $BSH ([regex]::Escape('USER_PROFILES_DIR/burnin')) "bash: UserProfiles/burnin (paritate)"

# ── Functional headless (python + matplotlib + ffmpeg; skip gratios) ──
$py = $null
if (Get-Command python3 -ErrorAction SilentlyContinue) { $py = 'python3' }
elseif (Get-Command python -ErrorAction SilentlyContinue) {
    if ((& python --version 2>&1) -match '^Python 3') { $py = 'python' }
}
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$src;$env:PATH" }
$ffOk = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)
$mplOk = $false
if ($py) { & $py -c "import matplotlib" 2>$null; $mplOk = ($LASTEXITCODE -eq 0) }

if ($py -and $mplOk -and $ffOk) {
    $g  = [guid]::NewGuid().ToString('N').Substring(0,8)
    $td = Join-Path $env:TEMP "dsg_v84_$g"
    New-Item -ItemType Directory -Force -Path $td, (Join-Path $td 'user') | Out-Null

    # functional: render_frame supravietuieste route_xy=(None,None,None)
    # (contract build_route_xy pe CSV fara GPS; fix v84 — inainte: TypeError)
    $nogpsPy = Join-Path $td 'nogps.py'
    @'
import sys
sys.path.insert(0, sys.argv[1])
import burnin_render as br
br.render_frame({"HUD_MAP": "1", "HUD_TIMESTAMP": "1"}, {}, (None, None, None), 320, 180, sys.argv[2])
print("NOGPS ok")
'@ | Set-Content -LiteralPath $nogpsPy -Encoding UTF8
    $nogpsOut = (& $py $nogpsPy $src (Join-Path $td 'nogps.png') 2>&1 | Out-String)
    Assert-Match $nogpsOut 'NOGPS ok' "functional: render cu route_xy=(None,None,None) nu crapa (fix v84)"

    $vid = Join-Path $td 'dsg.mp4'
    & ffmpeg -v error -f lavfi -i "testsrc=duration=2:size=320x180:rate=25" -c:v libx264 -pix_fmt yuv420p $vid -y 2>$null
    $outLog = Join-Path $td 'out.log'; $errLog = Join-Path $td 'err.log'
    $proc = Start-Process -FilePath $py -ArgumentList @(
        $engine, "--video", $vid, "--user-presets-dir", (Join-Path $td 'user'),
        "--temp-dir", $td, "--port", "0", "--no-open"
    ) -PassThru -NoNewWindow -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    try {
        $port = $null
        foreach ($i in 1..60) {
            Start-Sleep -Milliseconds 250
            if ($proc.HasExited) { break }
            $log = Get-Content $outLog -Raw -ErrorAction SilentlyContinue
            if ($log -match 'URL: http://127\.0\.0\.1:(\d+)/') { $port = $Matches[1]; break }
        }
        Assert-Eq $true ($null -ne $port) "functional: server pornit (URL in log)"
        if ($port) {
            $base = "http://127.0.0.1:$port"
            $state = Invoke-RestMethod "$base/api/state" -TimeoutSec 15
            Assert-Eq 320 ([int]$state.video.width)          "functional: state → width 320 (probe JSON)"
            Assert-Eq "demo" $state.telemetry.mode           "functional: fara CSV → mod demo"
            $fr = Invoke-WebRequest "$base/frame?t=1.0" -UseBasicParsing -TimeoutSec 30
            Assert-Eq $true ($fr.Content[1] -eq 0x50) "functional: /frame → PNG valid (imun la range pe HDR)"
            $cfgHt = @{}
            $state.cfg.PSObject.Properties | ForEach-Object { $cfgHt[$_.Name] = "$($_.Value)" }
            $ov = Invoke-RestMethod -Uri "$base/api/overlay" -Method Post -TimeoutSec 60 `
                -Body (@{ cfg = $cfgHt; t = 1.0; grid = $false } | ConvertTo-Json -Depth 5) `
                -ContentType "application/json"
            $png = [Convert]::FromBase64String($ov.png)
            Assert-Eq $true ($png[1] -eq 0x50)               "functional: /api/overlay → PNG valid"
            Assert-Eq $true ($ov.boxes.Count -gt 0)          "functional: hitbox-uri de drag prezente"
            $sv = Invoke-RestMethod -Uri "$base/api/save" -Method Post -TimeoutSec 15 `
                -Body (@{ name = "v84_smoke"; cfg = $cfgHt } | ConvertTo-Json -Depth 5) `
                -ContentType "application/json"
            Assert-Eq $true ([bool]$sv.ok)                   "functional: /api/save ok"
            $confPath = Join-Path (Join-Path $td 'user') 'v84_smoke.conf'
            Assert-Eq $true (Test-Path $confPath)            "functional: conf scris in user dir"
            Assert-Match (Get-Content $confPath -Raw) '(?m)^PRESET_NAME=v84_smoke' "functional: conf contine PRESET_NAME"
            $null = Invoke-RestMethod -Uri "$base/api/shutdown" -Method Post -Body "{}" -ContentType "application/json" -TimeoutSec 15
            foreach ($i in 1..20) { Start-Sleep -Milliseconds 250; if ($proc.HasExited) { break } }
            Assert-Eq $true $proc.HasExited                  "functional: serverul s-a oprit dupa shutdown"
            if ($proc.HasExited) { Assert-Eq 0 $proc.ExitCode "functional: exit code 0" }
        }
    } finally {
        if (-not $proc.HasExited) { $proc.Kill() }
        Remove-Item -Recurse -Force $td -ErrorAction SilentlyContinue
    }
} else {
    Assert-Eq $true $true "functional sarit (python/matplotlib/ffmpeg lipsesc pe boxa)"
}

Invoke-TestSummary
