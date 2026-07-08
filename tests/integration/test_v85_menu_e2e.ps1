# v85 — E2E prin MENIU pe scripturile standalone PS1 (clasa de acoperire care
#   lipsea). Piloteaza meniul REAL cu stdin pe fixture testsrc si verifica
#   output-ul. Ar fi prins F7 (Invoke-BurninEncode cu -c:v literal → burn-in PS1
#   rupt din v61) + F6 (overlay alpha). Mirror al test_v85_menu_e2e.sh.
. "$PSScriptRoot\..\framework.ps1"
$PROJECT_ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$src = Join-Path $PROJECT_ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$src;$env:PATH" }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Write-Host "SKIP test_v85_menu_e2e — ffmpeg lipseste"; exit 77 }
if (((& ffmpeg -hide_banner -encoders 2>$null | Select-String 'libx265').Count) -eq 0) { Write-Host "SKIP — libx265 lipseste"; exit 77 }

$td = Join-Path $env:TEMP "v85e2e_$([guid]::NewGuid().ToString('N').Substring(0,8))"
# av_burnin.ps1 e standalone si-si deriva InputVideos/OutputVideos de langa el →
# copiem scriptul + engine + presets in $td si punem fixture-urile in structura.
New-Item -ItemType Directory -Force -Path (Join-Path $td 'InputVideos'), (Join-Path $td 'OutputVideos') | Out-Null
Copy-Item (Join-Path $src 'av_burnin.ps1') $td -Force
Copy-Item (Join-Path $src 'burnin_render.py') $td -Force
Copy-Item (Join-Path $src 'burnin_presets') (Join-Path $td 'burnin_presets') -Recurse -Force
try {
    $clip = Join-Path $td 'InputVideos\clip.mp4'
    & ffmpeg -v error -f lavfi -i "testsrc=duration=2:size=320x180:rate=25" -pix_fmt yuv420p -c:v libx265 -x265-params log-level=none $clip -y 2>$null
    Assert-Eq $true (Test-Path $clip) "fixture clip.mp4 generat"
    "1`r`n00:00:00,200 --> 00:00:01,500`r`nMENU E2E v85`r`n`r`n" | Set-Content -LiteralPath (Join-Path $td 'OutputVideos\clip.srt') -Encoding ASCII

    # ── av_burnin PS1: fluxul SRT prin meniul REAL (main 2 → file 1 → defaults) ──
    #    ar fi prins F7 (Invoke-BurninEncode cu -c:v literal → output 'v')
    $burnLog = Join-Path $td 'burnin.log'
    "2`n1`n`n`n`n`n`n`n`n`n" | & pwsh -NoProfile -File (Join-Path $td 'av_burnin.ps1') *>$burnLog
    $subsOut = Join-Path $td 'OutputVideos\clip_subs.mp4'
    if ((Test-Path $subsOut) -and (Get-Item $subsOut).Length -gt 0) {
        Assert-Eq $true $true "burnin SRT menu PS1: output exista"
        $vc = (& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 $subsOut 2>$null | Select-Object -First 1)
        Assert-Eq "hevc" "$vc".Trim() "burnin SRT menu PS1: output hevc valid (F7 nu regreseaza)"
    } else {
        Assert-Eq $true $false "burnin SRT menu PS1: output lipsa"
        (Get-Content $burnLog -Raw) -replace "`e\[[0-9;]*m","" | Select-String "EROARE|output for" | Select-Object -First 2 | ForEach-Object { Write-Host "    $_" }
    }
} finally {
    Remove-Item -Recurse -Force $td -ErrorAction SilentlyContinue
}

Invoke-TestSummary
