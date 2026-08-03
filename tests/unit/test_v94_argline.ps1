# v94 (B11) — cai/LUT-uri cu SPATII in comanda ffmpeg (PS1).
#
# `Start-Process -ArgumentList <array>` uneste elementele cu spatiu si NU le citeaza →
# orice argument cu spatiu (fisier „my clip.mp4", folder „My Videos", LUT-ul livrat de DJI
# „DJI OSMO Action 6 D-LogM to Rec.709 LUT-11.17.cube") se rupe si ffmpeg primeste gunoi
# („Error opening input file …\my." / „Error initializing the muxer for OSMO") → 0 octeti.
# Fix: `ConvertTo-NativeArgLine` citeaza dupa regulile CommandLineToArgvW, iar toate
# apelurile Start-Process pentru ffmpeg trec prin el.
#
# Bash e NEafectat (test separat: test_v94_argline.sh) — caile intra in filtre intre
# ghilimele simple, pe care `eval` le respecta.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'

Import-AvEncodeFunctions -Names @('ConvertTo-NativeArgLine')

# ── 1. Comportamentul helperului ─────────────────────────────────────
Assert-Eq '-i C:\a\b.mp4' (ConvertTo-NativeArgLine @('-i','C:\a\b.mp4')) "fara spatii → neschimbat"
Assert-Eq '-i "C:\my clip.mp4"' (ConvertTo-NativeArgLine @('-i','C:\my clip.mp4')) "cale cu spatiu → citata"
Assert-Eq '"a b" "c d"' (ConvertTo-NativeArgLine @('a b','c d')) "doua argumente cu spatii"
Assert-Eq '-vf "lut3d=''D\:/L/DJI OSMO 6.cube''"' `
          (ConvertTo-NativeArgLine @('-vf',"lut3d='D\:/L/DJI OSMO 6.cube'")) "filtergraph cu LUT spatiat"
Assert-Eq '""' (ConvertTo-NativeArgLine @('')) "argument gol → `"`""
# regula CommandLineToArgvW: backslash-urile dinaintea unui ghilimel se dubleaza,
# iar ghilimelul se escapeaza — `a\"b` → `a` + `\\` + `\"` + `b`
Assert-Eq '"a\\\"b"' (ConvertTo-NativeArgLine @('a\"b')) "ghilimel intern escapat"
# backslash-ul final conteaza DOAR cand argumentul e citat (altfel ar inchide ghilimelul)
Assert-Eq 'C:\dir\' (ConvertTo-NativeArgLine @('C:\dir\')) "fara spatiu → necitat, backslash final intact"
Assert-Eq '"C:\my dir\\"' (ConvertTo-NativeArgLine @('C:\my dir\')) "citat + backslash final dublat"
# argumentele fara spatii NU se ating (zero regresie pe cazul normal)
$plain = @('-y','-threads','0','-c:v','libx265','-preset','slow','-crf','21')
Assert-Eq ($plain -join ' ') (ConvertTo-NativeArgLine $plain) "comanda uzuala → identica"

# ── 2. Toate apelurile ffmpeg prin Start-Process folosesc helperul ───
$encPs = Get-Content "$SRC\av_encode.ps1" -Raw
$spLines = @(Select-String -Path "$SRC\av_encode.ps1" -Pattern 'Start-Process\s+(-FilePath\s+)?ffmpeg\s+-ArgumentList' -AllMatches)
Assert-Eq $true ($spLines.Count -ge 5) "exista situri Start-Process ffmpeg ($($spLines.Count))"
$unwrapped = @($spLines | Where-Object { $_.Line -notmatch 'ConvertTo-NativeArgLine' } | ForEach-Object { "L$($_.LineNumber)" })
Assert-Eq 0 $unwrapped.Count "toate apelurile ffmpeg citeaza argumentele ($($unwrapped -join ', '))"

# ── 3. Standalone-urile folosesc operatorul de apel (deja sigur) ─────
foreach ($n in @('av_burnin.ps1','av_mux.ps1','av_check.ps1','av_telemetry.ps1','av_extractor_gps.ps1')) {
    $hits = @(Select-String -Path "$SRC\$n" -Pattern 'Start-Process\s+(-FilePath\s+)?ffmpeg' -AllMatches)
    Assert-Eq 0 $hits.Count "$n nu foloseste Start-Process pt ffmpeg (ramane pe & ffmpeg @args)"
}

# ── 4. Functional: encode real pe un fisier al carui NUME are spatiu ─
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    if (Test-Path "$SRC\ffmpeg.exe") { $env:PATH = "$SRC;$env:PATH" }
}
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "  (functional sarit — ffmpeg lipseste)" -ForegroundColor DarkGray
} else {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("avargline_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $src = Join-Path $tmp "my clip.mp4"
        $dst = Join-Path $tmp "out A.mkv"
        & ffmpeg -v error -y -f lavfi -i "testsrc2=s=160x120:r=10:d=1" -c:v libx264 -preset ultrafast $src 2>&1 | Out-Null
        Assert-FileExists $src "fixture cu spatiu in nume creat"
        $args1 = @("-v","error","-y","-i",$src,"-c:v","libx264","-preset","ultrafast",$dst)
        $errF  = Join-Path $tmp "err.txt"
        $p = Start-Process ffmpeg -ArgumentList (ConvertTo-NativeArgLine $args1) -NoNewWindow -PassThru -RedirectStandardError $errF
        $p.WaitForExit()
        Assert-Eq 0 $p.ExitCode "Start-Process + citare → ffmpeg accepta calea cu spatiu"
        Assert-FileExists $dst "output cu spatiu in nume scris"
        # CANAR: fara citare, aceeasi comanda esueaza — daca un PowerShell viitor
        # incepe sa citeze singur, testul asta pica si regula poate fi reevaluata.
        Remove-Item $dst -Force -ErrorAction SilentlyContinue
        $p2 = Start-Process ffmpeg -ArgumentList $args1 -NoNewWindow -PassThru -RedirectStandardError $errF
        $p2.WaitForExit()
        Assert-Eq $true ($p2.ExitCode -ne 0) "CANAR: array necitat inca rupe calea cu spatiu (exit $($p2.ExitCode))"
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-TestSummary
