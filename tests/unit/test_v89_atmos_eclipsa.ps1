# v89 — Atmos → Eclipsa/IAMF 7.1.4 prin Cavern (mirror test_v89_atmos_eclipsa.sh):
# render POZITIONAL al obiectelor (E-AC-3 JOC nativ; TrueHD via truehdd) → WAV 12ch →
# authoring IAMF cu canale de inaltime REALE. Invoke-AtmosRender714 (Start-Process +
# WaitForExit + Kill — CavernizeGUI e WPF, `&` nu asteapta; validare AUTORITARA pe WAV
# 12ch) + -AudioSource in Invoke-IamfAuthor + dialog render/bed/skip in audio-only
# (env AV_ATMOS_ECLIPSA_POLICY; non-interactiv → bed). Source-level (ambele platforme)
# + functional REAL pe Windows (gated Cavernize + ffmpeg-iamf + MP4Box + sample local).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$src = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "src"
$psText  = Get-Content (Join-Path $src "av_encode.ps1") -Raw
$avcText = Get-Content (Join-Path $src "av_common.sh") -Raw
$aeaText = Get-Content (Join-Path $src "av_encoder_audio.sh") -Raw

# ── source-level PS1: helper + arg AudioSource ────────────────────────
Assert-Eq 1 ([regex]::Matches($psText, '(?m)^function Invoke-AtmosRender714 \{').Count) `
    "Invoke-AtmosRender714 exista in av_encode.ps1"
Assert-Match $psText 'function Invoke-AtmosRender714 \{[\s\S]*?WaitForExit[\s\S]*?\n\}' `
    "WPF nu se asteapta cu & → Start-Process + WaitForExit cu timeout"
Assert-Match $psText 'function Invoke-AtmosRender714 \{[\s\S]*?\.Kill\(\)[\s\S]*?\n\}' `
    "Kill defensiv pe timeout (procesul nu se inchide singur pe eroare)"
Assert-Match $psText 'function Invoke-AtmosRender714 \{[\s\S]*?DOTNET_ROLL_FORWARD[\s\S]*?\n\}' `
    "roll-forward .NET (Cavernize tinteste Desktop 8, ruleaza pe 9/10)"
Assert-Match $psText 'function Invoke-AtmosRender714 \{[\s\S]*?-eq "12"[\s\S]*?\n\}' `
    "validare AUTORITARA pe WAV: 12 canale (nu exit code)"
Assert-Match $psText 'function Invoke-AtmosRender714 \{[\s\S]*?AV_TOOL_CAVERNIZE[\s\S]*?\n\}' `
    "tool prin env AV_TOOL_CAVERNIZE (nu nume hardcodat)"
Assert-Match $psText 'function Invoke-AtmosRender714 \{[\s\S]*?atmos714_[\s\S]*?\n\}' `
    "extract in temp CO-LOCAT (Cavernize scrie temp-uri LANGA input)"
Assert-Match $psText 'function Invoke-IamfAuthor \{[\s\S]*?\$AudioSource[\s\S]*?\n\}' `
    "Invoke-IamfAuthor are -AudioSource (mirror arg 5 bash)"
Assert-Match $psText 'function Invoke-IamfAuthor \{[\s\S]*?\$audioIn[\s\S]*?\n\}' `
    "linia ffmpeg citeste audio-ul din `$audioIn (video/subs/capitole din `$Source)"

# ── source-level PS1: dialog in audio-only ────────────────────────────
Assert-Match $psText 'AV_ATMOS_ECLIPSA_POLICY' "policy env in dialogul audio-only"
Assert-Contains $psText 'Render 7.1.4 → Eclipsa cu canale de inaltime' `
    "dialogul ofera render 7.1.4 ca optiunea 1"
Assert-Contains $psText '-AudioSource $iamfRenderWav' `
    "authoring-ul primeste WAV-ul randat prin -AudioSource"
Assert-Contains $psText 'Remove-Item $iamfRenderWav' `
    "WAV-ul de render se curata dupa authoring"
Assert-Contains $psText 'tools/cavernize_installer' `
    "sursa Atmos fara tool → hint onest la installer"

# ── paritate bash ─────────────────────────────────────────────────────
Assert-Match $avcText '(?m)^AV_TOOL_CAVERNIZE="\$\{AV_TOOL_CAVERNIZE:-' `
    "bash: AV_TOOL_CAVERNIZE in blocul config (forma canonica)"
Assert-Match $avcText '(?m)^_atmos_render_714\(\)' "bash: helperul _atmos_render_714 exista"
Assert-Match $avcText 'audio_src="\$\{5:-\$1\}"' "bash: _iamf_author are arg 5 audio_src"
foreach ($msg in @(
    'Render 7.1.4 → Eclipsa cu canale de inaltime',
    'Render esuat → fallback pe bed-ul de canale',
    'render Cavern 12ch',
    'sarit de user (sursa Atmos)')) {
    Assert-Contains $psText $msg "paritate mesaj PS1: '$msg'"
    Assert-Eq $true (($avcText + $aeaText) -clike "*$msg*") "paritate mesaj bash: '$msg'"
}
Assert-Contains $avcText 'Cavern nu a produs un WAV 7.1.4 valid' "paritate mesaj helper bash"
Assert-Contains $psText  'Cavern nu a produs un WAV 7.1.4 valid' "paritate mesaj helper PS1"

# ── installere ────────────────────────────────────────────────────────
Assert-FileExists (Join-Path $src "tools\cavernize_installer.sh")  "installer bash exista"
Assert-FileExists (Join-Path $src "tools\cavernize_installer.ps1") "installer PS1 exista"
$instPs = Get-Content (Join-Path $src "tools\cavernize_installer.ps1") -Raw
Assert-Match $instPs 'cavern\.sbence\.hu' "installer PS1: site oficial (GitHub are doar demo Unity pe Windows)"
Assert-Match $instPs 'WindowsDesktop' "installer PS1: check .NET Desktop Runtime 8+"

# ── functional REAL pe Windows (gated: Cavernize + ffmpeg-iamf + MP4Box + sample) ─
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$src;" + $env:PATH }
$hasIamfMux = ((& ffmpeg -hide_banner -muxers 2>$null) | Out-String) -match ' iamf '
$cav = if ($env:AV_TOOL_CAVERNIZE) { $env:AV_TOOL_CAVERNIZE } else { "CavernizeGUI" }
$oldMp4boxEnv = $env:AV_TOOL_MP4BOX
$mp4box = if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } else { "mp4box" }
if (-not (Get-Command $mp4box -ErrorAction SilentlyContinue) -and (Test-Path "D:\Pers\APPS\APPPortable\GPAC\MP4Box.exe")) {
    $mp4box = "D:\Pers\APPS\APPPortable\GPAC\MP4Box.exe"; $env:AV_TOOL_MP4BOX = $mp4box
}
$sample = Join-Path $src "Dolby_Tone714_Atmos_20s.mkv"
if ($hasIamfMux -and (Get-Command $cav -ErrorAction SilentlyContinue) -and `
    (Get-Command $mp4box -ErrorAction SilentlyContinue) -and (Test-Path $sample)) {
    # dependinte tranzitive (regula v63): Render714 e standalone; Author/probe cer Get-IamfLayout
    Import-AvEncodeFunctions -Names @('Get-IamfLayout','Invoke-IamfAuthor','Invoke-AtmosRender714')
    $tmpd = Join-Path $env:TEMP ("v89atmos_" + [guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Force $tmpd | Out-Null
    try {
        # fara tool → false curat, fara WAV partial
        $oldCav = $env:AV_TOOL_CAVERNIZE
        $env:AV_TOOL_CAVERNIZE = "C:\nonexistent_cavern_$([guid]::NewGuid().ToString('N'))"
        Assert-Eq $false (Invoke-AtmosRender714 -Source $sample -WavOut (Join-Path $tmpd "no.wav")) `
            "render fara tool: false curat"
        if ($null -ne $oldCav) { $env:AV_TOOL_CAVERNIZE = $oldCav } else { Remove-Item Env:\AV_TOOL_CAVERNIZE -EA SilentlyContinue }
        Assert-Eq $false (Test-Path (Join-Path $tmpd "no.wav")) "render fara tool: zero WAV partial"

        # render REAL pe sample-ul Atmos 20s (NB: sample-ul lumineaza doar FL — Tone-ul
        # oficial e secvential; toate 12 canalele validate pe Tone-ul COMPLET. Aici
        # validam contractul: WAV 12ch layout 7.1.4 + lantul author cu -AudioSource.)
        $rwav = Join-Path $tmpd "r714.wav"
        Assert-Eq $true (Invoke-AtmosRender714 -Source $sample -WavOut $rwav) "render 20s: true"
        $rch = @(& ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 $rwav 2>$null)[0]
        Assert-Eq "12" "$rch".Trim() "render 20s: WAV are 12 canale"
        $rlay = @(& ffprobe -v error -select_streams a:0 -show_entries stream=channel_layout -of default=noprint_wrappers=1:nokey=1 $rwav 2>$null)[0]
        Assert-Eq "7.1.4" "$rlay".Trim() "render 20s: layout nativ ffmpeg 7.1.4 (zero remapare)"

        # authoring cu -AudioSource: audio din WAV, video din sursa
        $out714 = Join-Path $tmpd "out714.mp4"
        Assert-Eq $true (Invoke-IamfAuthor -Source $sample -Output $out714 -Layout "7.1.4" -AudioSource $rwav) `
            "author cu -AudioSource: true"
        Assert-Eq "7.1.4" (Get-IamfLayout -File $out714) "author cu -AudioSource: probe -> 7.1.4"
        $vCnt = @(@(& ffprobe -hide_banner $out714 2>&1) | Select-String 'Stream #.*Video:').Count
        Assert-Eq 1 $vCnt "author cu -AudioSource: video-ul din SURSA e pastrat (copy)"

        # zero temp-uri orfane atmos714_ (extractul MKV se curata)
        $orph = @(Get-ChildItem $tmpd -File | Where-Object { $_.Name -match 'atmos714_.*\.mkv' }).Count
        Assert-Eq 0 $orph "zero temp-uri orfane atmos714_ (extract MKV curatat)"
    } finally {
        if ($null -ne $oldMp4boxEnv) { $env:AV_TOOL_MP4BOX = $oldMp4boxEnv }
        Remove-Item -Recurse -Force $tmpd -ErrorAction SilentlyContinue
    }
} else {
    Assert-Eq 1 1 "skip-equivalent: Cavernize/ffmpeg-iamf/MP4Box/sample lipseste (source-level a rulat)"
}

Invoke-TestSummary
