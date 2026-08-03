# v94 — AV1 VBR / 2-pass pe SVT-AV1 (mirror PS1 al test_v94_av1_vbr.sh).
#
#   B12 (fatal): suita calculeaza mereu maxrate = target x 1.5 si il trimitea si la
#     libsvtav1, care il REFUZA in VBR — „Svt[error]: Max Bitrate only supported with CRF
#     mode" → encoderul nici nu porneste (0 octeti). AV1 VBR (1-pass SI 2-pass) nu a
#     functionat niciodata pe SVT. maxrate/bufsize raman pentru x265/x264/libaom.
#
#   B13 (tacut): sintaxa inline `pass=N:stats=` nu e implementata pe toate build-urile;
#     acolo mesajul e pe nivel info (invizibil cu `-v error`), exit code-ul ramane 0, dar
#     statisticile nu se scriu → pass 2 moare cu „RC stats buffer not available". Detectia
#     veche ghicea din `ffmpeg -version`; acum se probeaza REZULTATUL (fisierul).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$ENC = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw

# ── B12 source-level ──
Assert-Match $ENC ([regex]::Escape('$svtNoVbv = ($useAV1 -and $av1Impl -eq "libsvtav1")')) `
    "B12: gate pe libsvtav1 pentru rate control"
Assert-Match $ENC ([regex]::Escape('$rateParams = @("-b:v",$vbrTarget)')) `
    "B12: pe SVT se trimite doar -b:v (fara plafon)"
Assert-Match $ENC ([regex]::Escape('$rateParams = @("-b:v",$vbrTarget,"-maxrate",$vbrMaxrate,"-bufsize",$vbrBufsize)')) `
    "B12: restul encoderelor pastreaza maxrate/bufsize"
Assert-Match $ENC 'SVT-AV1 nu suporta maxrate in VBR' "B12: mesaj onest catre utilizator"

# ── B13 source-level ──
Assert-Match $ENC ([regex]::Escape('$script:svtav1DetectSource = "proba=inline-scrie-stats"')) `
    "B13: verdict pozitiv doar cand statisticile chiar apar"
Assert-Match $ENC ([regex]::Escape('stats=svtprobe.passlog')) `
    "B13: proba foloseste nume gol + CWD (ca in productie)"
Assert-Eq $false ($ENC -match 'assumed-modern') `
    "B13: fallback-ul 'assumed-modern' (ghicit din versiune) a disparut"

# ── Functional ──
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    $hasSvt = (& ffmpeg -hide_banner -encoders 2>$null | Select-String 'libsvtav1')
    if ($hasSvt) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("av1vbr_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            # CANAR B12: daca un SVT viitor accepta maxrate in VBR, testul pica si regula
            # (plus mesajul „fara plafon") pot fi re-evaluate.
            $out = (& ffmpeg -v error -y -f lavfi -i "testsrc2=s=256x256:r=30:d=1" `
                    -c:v libsvtav1 -b:v 2000k -maxrate 3000k -bufsize 4000k `
                    -svtav1-params "preset=12:rc=1" -f null - 2>&1) -join "`n"
            Assert-Eq $true ($out -match 'Max Bitrate only supported with CRF') `
                "CANAR B12: SVT-AV1 inca refuza maxrate in VBR"

            $vbr = Join-Path $tmp "vbr.mkv"
            & ffmpeg -v error -y -f lavfi -i "testsrc2=s=256x256:r=30:d=1" `
                -c:v libsvtav1 -b:v 2000k -svtav1-params "preset=12:rc=1" $vbr 2>$null | Out-Null
            Assert-FileExists $vbr "B12: VBR fara plafon produce output"

            # B13: verdictul probei trebuie sa corespunda realitatii
            $AV_TEMP_DIR = $tmp
            function Ensure-TempDir { }
            Import-AvEncodeFunctions -Names @('Test-SvtAv1TwoPassCaps')
            $supported = Test-SvtAv1TwoPassCaps
            Push-Location $tmp
            try {
                & ffmpeg -v error -y -f lavfi -i "testsrc2=s=256x256:r=30:d=1" `
                    -c:v libsvtav1 -b:v 2000k -svtav1-params "preset=12:pass=1:stats=chk.passlog" `
                    -f null - 2>&1 | Out-Null
            } finally { Pop-Location }
            $chk = Join-Path $tmp "chk.passlog"
            $inlineOk = (Test-Path $chk) -and ((Get-Item $chk).Length -gt 0)
            Assert-Eq $inlineOk $supported `
                "B13: verdictul probei corespunde realitatii (inline scrie stats? $inlineOk)"

            if (-not $inlineOk) {
                Push-Location $tmp
                try {
                    & ffmpeg -v error -y -f lavfi -i "testsrc2=s=256x256:r=30:d=1" `
                        -c:v libsvtav1 -b:v 2000k -svtav1-params "preset=12" `
                        -pass 1 -passlogfile gen -f null - 2>&1 | Out-Null
                } finally { Pop-Location }
                Assert-Eq $true (@(Get-ChildItem "$tmp\gen*.log" -EA SilentlyContinue).Count -gt 0) `
                    "B13: sintaxa generica -pass/-passlogfile scrie statisticile"
            }
        } finally { Remove-Item $tmp -Recurse -Force -EA SilentlyContinue }
    } else {
        Write-Host "  (functional sarit — libsvtav1 lipseste)" -ForegroundColor DarkGray
    }
}

Invoke-TestSummary
