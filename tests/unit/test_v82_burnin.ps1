# v82 — Burn-in: (A) still-preview HDR tonemap (Get-BurninStillDisplayFilter) +
#   (B) subtitle `shaping` (libass HarfBuzz) la SRT/ASS +
#   (C) fix ASS scale rupt din v48: filtrul `ass` NU are force_style -> optiunile
#       ScaleX/Y 1.25x/1.5x nu redau nimic -> SCOASE. ASS = filtru nativ `ass`
#       (respecta styling-ul embedded) + shaping optional. PS1 mirror.
#   A = filtru DOAR pe PNG-ul de preview.
. "$PSScriptRoot\..\framework.ps1"

$PROJECT_ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$src = Join-Path $PROJECT_ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$src;$env:PATH" }
$BURNIN_PS1 = Join-Path $src 'av_burnin.ps1'
$bps = Get-Content $BURNIN_PS1 -Raw
$bsh = Get-Content (Join-Path $src 'av_burnin.sh') -Raw

# ── 1. A: still display filter (PS1) ────────────────────────────────
Assert-Eq $true ($bps.Contains('function Get-BurninStillDisplayFilter'))  "PS1: helper still display filter"
Assert-Eq $true ($bps.Contains('tonemap=tonemap=hable'))                  "PS1: lant tonemap pt still"
Assert-Eq $true ($bps.Contains('BURNIN_STILL_NO_TONEMAP'))                "PS1: env bypass tonemap"
Assert-Eq $true ($bps.Contains('$stDisp = Get-BurninStillDisplayFilter')) "PS1: ramura still foloseste helper"
Assert-Eq $true ($bps.Contains('still tonemapped pentru preview'))        "PS1: nota onesta HDR-preserve"

# ── 2. B: shaping (PS1) ─────────────────────────────────────────────
Assert-Eq $true ($bps.Contains('function Test-BurninSubtitleShaping'))    "PS1: capability shaping"
Assert-Eq $true ($bps.Contains('function Get-BurninShaping'))             "PS1: prompt shaping"
Assert-Eq $true ($bps.Contains(':shaping=$subShaping'))                   "PS1: append shaping in vf"
Assert-Eq $true ($bps.Contains('-h filter=subtitles'))                    "PS1: gate capabilitate ffmpeg"
$nShp = ([regex]::Matches($bps, 'Get-BurninShaping')).Count
Assert-Eq $true ($nShp -ge 3) "PS1: Get-BurninShaping def + 2 apeluri srt/ass ($nShp)"

# ── 2b. C: ASS = filtru nativ ass, meniul scale rupt SCOS (PS1) ─────
Assert-Eq $true  ($bps.Contains("ass='`$assEsc'"))       "PS1: ASS filtru nativ ass"
Assert-Eq $true  ($bps.Contains('styling embedded pastrat')) "PS1: nota styling embedded ASS"
Assert-Eq $false ($bps.Contains('ASS FONT SCALE'))       "PS1: meniul ASS scale SCOS"
Assert-Eq $false ($bps.Contains('ScaleX=125'))           "PS1: optiune scale 1.25x SCOASA"

# ── 3. bash mirror (source-level) ───────────────────────────────────
Assert-Eq $true  ($bsh.Contains('_burnin_still_display_filter()'))        "bash: helper still"
Assert-Eq $true  ($bsh.Contains('ask_burnin_shaping()'))                  "bash: prompt shaping"
Assert-Eq $true  ($bsh.Contains(':shaping=${SUB_SHAPING}'))               "bash: append shaping"
Assert-Eq $true  ($bsh.Contains("vf=`"ass='"))                            "bash: ASS filtru nativ ass"
Assert-Eq $false ($bsh.Contains('ASS FONT SCALE'))                        "bash: meniul ASS scale SCOS"

# ── 4. Functional A: dot-source + stari helper ──────────────────────
$env:AV_BURNIN_TEST_MODE = "1"
try { . $BURNIN_PS1 } catch { Write-Host "WARN dot-source: $($_.Exception.Message)" -ForegroundColor Yellow }
$env:AV_BURNIN_TEST_MODE = $null

$env:BURNIN_STILL_NO_TONEMAP = $null
$script:BurninPreFilter = ""; $script:BurninSourceType = "hdr10"
Assert-Eq $true ((Get-BurninStillDisplayFilter) -match 'tonemap') "A funct: HDR-preserve -> tonemap"
$script:BurninSourceType = "sdr"
Assert-Eq "" (Get-BurninStillDisplayFilter) "A funct: SDR -> gol"
$env:BURNIN_STILL_NO_TONEMAP = "1"; $script:BurninSourceType = "hdr10"
Assert-Eq "" (Get-BurninStillDisplayFilter) "A funct: NO_TONEMAP=1 -> gol (raw)"
$env:BURNIN_STILL_NO_TONEMAP = $null
$script:BurninPreFilter = "lut3d=x.cube"; $script:BurninSourceType = "log"
Assert-Eq "lut3d=x.cube" (Get-BurninStillDisplayFilter) "A funct: pre-filter -> verbatim"
$script:BurninPreFilter = ""

# ── 5. Functional B: capability parity + render-uri reale ───────────
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    $direct = $false
    $h = (& ffmpeg -hide_banner -h filter=subtitles 2>&1) -join "`n"
    if ($h -match 'shaping') { $direct = $true }
    $script:BurninShapingCap = $null
    $helper = [bool](Test-BurninSubtitleShaping)
    Assert-Eq $direct $helper "B funct: capability helper == check direct ffmpeg"

    $g = [guid]::NewGuid().ToString('N').Substring(0,8)
    $td = Join-Path $env:TEMP "bi_v82_$g"; New-Item -ItemType Directory -Force $td | Out-Null
    "1`r`n00:00:00,000 --> 00:00:01,000`r`nHello shaping test" | Set-Content (Join-Path $td 's.srt') -Encoding ascii
    & ffmpeg -v error -y -f lavfi -i "color=c=navy:s=320x240:d=1" -pix_fmt yuv420p (Join-Path $td 'v.mp4') 2>$null | Out-Null
    & ffmpeg -v error -y -i (Join-Path $td 's.srt') (Join-Path $td 's.ass') 2>$null | Out-Null
    Push-Location $td
    # v96 (paritate cu .sh): rularile cu shaping se fac DOAR daca build-ul chiar il are.
    # Testul masura capabilitatea mai sus ($direct), apoi o folosea neconditionat — pe un
    # ffmpeg fara libharfbuzz raspunsul e "Option not found" si testul pica, desi codul de
    # PRODUCTIE e corect (`Get-BurninShaping` sare promptul cand poarta zice nu).
    if ($direct) {
        & ffmpeg -v error -i v.mp4 -vf "subtitles=s.srt:force_style='FontSize=24':shaping=complex" -frames:v 1 -y o1.png 2>$null | Out-Null
        Assert-Eq 0 $LASTEXITCODE "B funct: SRT force_style+shaping=complex -> rc=0"
        if (Test-Path 's.ass') {
            & ffmpeg -v error -i v.mp4 -vf "ass=s.ass:shaping=complex" -frames:v 1 -y o2.png 2>$null | Out-Null
            Assert-Eq 0 $LASTEXITCODE "B funct: ASS(filtru nativ ass)+shaping -> rc=0"
        }
    } else {
        & ffmpeg -v error -i v.mp4 -vf "subtitles=s.srt:force_style='FontSize=24'" -frames:v 1 -y o1.png 2>$null | Out-Null
        Assert-Eq 0 $LASTEXITCODE "B funct: SRT force_style (build fara shaping) -> rc=0"
    }
    $chain = "format=yuv420p10le,setparams=color_trc=smpte2084:color_primaries=bt2020:colorspace=bt2020nc,zscale=t=linear:npl=100,tonemap=tonemap=hable,zscale=t=bt709:m=bt709:p=bt709:r=tv,format=yuv420p"
    & ffmpeg -v error -y -f lavfi -i "color=c=gray:s=320x240:d=1" -vf "$chain" -frames:v 1 o3.png 2>$null | Out-Null
    Assert-Eq 0 $LASTEXITCODE "A funct: lant tonemap valid pe frame PQ -> rc=0"
    Pop-Location
    Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-TestSummary
