# v97 — av_check accepta si fisiere DOAR-audio (perechea PS1).
#
# Partea de paritate source-level e verificata si din testul bash; aici se ruleaza
# FUNCTIONAL pe Windows, unde av_check.ps1 e scriptul care chiar se executa.
. "$PSScriptRoot\..\framework.ps1"
$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$PSC  = Join-Path $ROOT 'src\av_check.ps1'
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { $env:PATH = "$ROOT\src;$env:PATH" }
$txt = Get-Content $PSC -Raw

# ── source-level ─────────────────────────────────────────────────────
$err = $null; $tok = $null
[System.Management.Automation.Language.Parser]::ParseFile($PSC, [ref]$tok, [ref]$err) | Out-Null
Assert-Eq 0 $err.Count "av_check.ps1 parseaza fara erori"
Assert-Match $txt 'inputFiles[^\r\n]*\*\.m4a'  "glob-ul de intrare include formate audio native"
Assert-Match $txt 'outFiles[^\r\n]*\*\.flac'   "si lista de output (comparatia input↔output)"
Assert-Match $txt '\$audioOnlyFile = \$true'   "exista modul audio-only"
Assert-Match $txt 'fara stream video sau audio valid' "se sare doar ce n-are NICI audio, NICI video"
Assert-Match $txt '\$resStr = "N/A"'           "audio-only: rezolutia devine N/A"
Assert-Match $txt '\$tipHdr = "N/A"'           "audio-only: Tip_HDR devine N/A (nu ramane 'SDR')"
Assert-Match $txt '\$encRec = "N/A"'           "audio-only: recomandarea de encoder devine N/A"
Assert-Match $txt 'Audio — '                   "Format_sursa foloseste liniuta (codecul poate purta paranteze)"
# randul CSV trebuie sa consume variabilele normalizate, altfel fixul n-ar ajunge in raport
$csvLine = ($txt -split "`n" | Where-Object { $_ -match '^\s*"`"\$\(\$f\.Name\)`"' } | Select-Object -First 1)
Assert-Eq $true ($csvLine -match '\$fmtStr' -and $csvLine -match '\$resStr' -and $csvLine -match '\$pixStr') `
    "randul CSV foloseste fmtStr/resStr/pixStr (normalizarea ajunge in raport)"

# ── functional ───────────────────────────────────────────────────────
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "  (functional sarit — ffmpeg lipseste)"
} else {
    $W = Join-Path $env:TEMP ("v97chk_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path "$W\in","$W\out" | Out-Null
    & ffmpeg -y -v error -f lavfi -i "sine=f=440:d=1:r=48000" -af "pan=stereo|c0=c0|c1=c0" "$W\st.wav" 2>$null
    & ffmpeg -y -v error -i "$W\st.wav" -c:a aac  "$W\in\a_track.m4a"  2>$null
    & ffmpeg -y -v error -i "$W\st.wav" -c:a flac "$W\in\a_track.flac" 2>$null
    & ffmpeg -y -v error -f lavfi -i "testsrc=size=160x120:rate=25:duration=1" -f lavfi -i "sine=f=440:d=1:r=48000" `
        -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$W\in\v_clip.mp4" 2>$null
    Set-Content -Path "$W\in\invalid.mka" -Value "nu sunt media" -NoNewline

    $env:AV_INPUT_DIR = "$W\in"; $env:AV_OUTPUT_DIR = "$W\out"
    & pwsh -NonInteractive -File $PSC 2>&1 | Out-Null
    $csv = Join-Path "$W\out" "av_check_report.csv"
    Assert-Eq $true (Test-Path $csv) "CSV generat"

    if (Test-Path $csv) {
        $rows = Import-Csv $csv
        $m4a  = $rows | Where-Object { $_.Fisier -like "a_track.m4a*" } | Select-Object -First 1
        $vid  = $rows | Where-Object { $_.Fisier -like "v_clip*" }      | Select-Object -First 1

        Assert-Eq $true ($null -ne $m4a) "fisierul .m4a a fost analizat"
        Assert-Eq $true (($rows | Where-Object { $_.Fisier -like "a_track.flac*" }).Count -ge 1) "fisierul .flac a fost analizat"
        if ($m4a) {
            Assert-Eq "N/A" $m4a.Rezolutie          "audio: Rezolutie = N/A"
            Assert-Eq "N/A" $m4a.PixelFormat        "audio: PixelFormat = N/A"
            Assert-Eq "N/A" $m4a.Tip_HDR            "audio: Tip_HDR = N/A (nu 'SDR')"
            Assert-Eq "N/A" $m4a.Recomandat_encoder "audio: Recomandat_encoder = N/A"
            Assert-Match $m4a.Format_sursa 'Audio'  "audio: Format_sursa spune ca e audio"
        }
        # regresie: fisierul video ramane exact ca inainte
        if ($vid) {
            Assert-Eq "160x120" $vid.Rezolutie "REGRESIE: fisierul video isi pastreaza rezolutia"
            Assert-Eq "SDR"     $vid.Tip_HDR   "REGRESIE: fisierul video isi pastreaza Tip_HDR"
        }
        Assert-Eq 0 (($rows | Where-Object { $_.Fisier -like "invalid*" }).Count) `
            "fisierul fara audio SI fara video e sarit"
        # schema CSV neschimbata — nu stricam consumatorii raportului
        Assert-Eq 38 ((Get-Content $csv -TotalCount 1).Split(',').Count) "schema CSV ramane 38 de coloane"
    }
    Remove-Item $W -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-TestSummary
