# v72 — mirror al test_v72_av1_mp4_dvcc.sh (PS1).
#   dvcC de container pe hibridele AV1 DV → MP4/MOV (inchide ultimul gap din harta dvcC).
#   MP4Box nu auto-detecteaza DV pe AV1 → dvp= EXPLICIT il scrie oricum (RPU byte-identic).
#   Source-level (mereu) + functional (AV1 DV sample + ffmpeg + MP4Box + av1dovi_tool, pe
#   cai Windows native): AV1 DV IVF → Invoke-DvMp4Mux REAL → MP4 → dvcC + RPU identic +
#   fallback 10.1 + mecanism passthrough (->MP4 pierde dvcC, re-signal il pune la loc).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$enc   = Get-Content (Join-Path $SRC 'av_encode.ps1') -Raw
$muxPs = Get-Content (Join-Path $SRC 'av_mux.ps1')    -Raw

# ── 1. Invoke-DvMp4Mux: AV1 acceptat (gate) + derivare dvp= ────────────────
Assert-Match $enc ([regex]::Escape("elseif (`$rext -in @('ivf','av1','obu')) { `$isAv1 = `$true }")) "Invoke-DvMp4Mux: gate AV1 (.ivf/.av1/.obu)"
Assert-Match $enc ([regex]::Escape('stream_side_data=dv_bl_signal_compatibility_id')) "Invoke-DvMp4Mux: citeste compat-ul pt dvp"
# FIX audit v72: profilul AV1 e FORTAT la 10 (NU citit din ref) -> cross-codec hevc-DV(8.x)->av1 safe
Assert-Match $enc ([regex]::Escape('$dvp = "10.$c"')) "Invoke-DvMp4Mux: profil AV1 fortat la 10 (cross-codec safe)"
Assert-Match $enc ([regex]::Escape('$firstAdd = "${RawHevc}:dvp=${dvp}:fps=${afr}"')) "Invoke-DvMp4Mux: -add cu dvp= la AV1"
Assert-Match $enc ([regex]::Escape('$dvp = "10.1"')) "Invoke-DvMp4Mux: fallback dvp=10.1"
# v75: ramura AV1 foloseste $av1Ref (redenumit din $dvRef ca sa nu coincida case-insensitive cu parametrul $DvRef)
Assert-Match $enc ([regex]::Escape('$av1Ref = if ($DvRef) { $DvRef } else { $Original }')) "Invoke-DvMp4Mux: referinta compat AV1 = DvRef sau Original"

# ── 2. triple-layer: ramura mp4/mov ungateata (HEVC+AV1) + DvRef=$f ────────
Assert-Match $enc ([regex]::Escape("`$container -in @('mp4','mov','m4v') -and (Invoke-DvMp4Mux -RawHevc `$injectedTemp -Original `$outFile -Output `$finalTemp -DvRef `$f)")) "triple-layer: mp4/mov ungateat cu DvRef"

# ── 3. Invoke-HdvCombineWithOriginal: ramura AV1 IVF → MP4/MOV ─────────────
Assert-Match $enc ([regex]::Escape("`$ext -in @('mp4','mov','m4v')")) "Invoke-HdvCombine: ramura IVF acopera MP4/MOV"

# ── 4. passthrough: Invoke-DvResignalCopy accepta AV1 + DvRef ──────────────
Assert-Match $enc ([regex]::Escape("if (`$sc -notin @('hevc','av1')) { return }")) "Invoke-DvResignalCopy: accepta HEVC + AV1"
Assert-Match $enc ([regex]::Escape('-map 0:v:0 -c:v copy -f ivf $raw')) "Invoke-DvResignalCopy: extractie AV1 ca IVF"
Assert-Match $enc ([regex]::Escape('-Built $Output -Target $Target -DvRef $Source')) "Invoke-DvResignalCopy: paseaza sursa ca referinta compat"

# ── 5. dispatch Invoke-DvContainerSignal forwardeaza DvRef ─────────────────
Assert-Match $enc ([regex]::Escape('-Output $tmp -DvRef $DvRef')) "Invoke-DvContainerSignal: forwardeaza DvRef la Invoke-DvMp4Mux"

# ── 6. av_mux.ps1: captura AV1 pe MP4/MOV + Invoke-AvMuxDvSignal cu dvp ─────
Assert-Match $muxPs ([regex]::Escape("@('hevc','h265','265','av1','ivf')")) "av_mux: captura AV1/IVF pe MP4/MOV"
Assert-Match $muxPs ([regex]::Escape('$isAv1 = $rawExt -in @(''ivf'',''av1'',''obu'')')) "av_mux Invoke-AvMuxDvSignal: derivare dvp AV1"

# ── 7. FUNCTIONAL — AV1 DV IVF → Invoke-DvMp4Mux REAL → MP4 → dvcC + RPU ────
$mp4box  = if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } else { "mp4box" }
$gpacLocal = Join-Path $PSScriptRoot "..\..\src\GPAC\mp4box.exe"  # co-locat (v93) — fara cai absolute
if (-not (Get-Command $mp4box -ErrorAction SilentlyContinue) -and (Test-Path $gpacLocal)) { $mp4box = (Resolve-Path $gpacLocal).Path }
$av1dovi = if ($env:AV_TOOL_AV1DOVI) { $env:AV_TOOL_AV1DOVI } else { "av1dovi_tool" }
$sample  = Get-ChildItem $SRC -Filter '*DV*AV1*.mkv' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($sample -and (Get-Command ffmpeg -EA SilentlyContinue) -and (Get-Command ffprobe -EA SilentlyContinue) `
    -and (Get-Command $mp4box -EA SilentlyContinue) -and (Get-Command $av1dovi -EA SilentlyContinue)) {
    Import-AvEncodeFunctions -Names @('Invoke-DvMp4Mux') | Out-Null
    $td = Join-Path $env:TEMP ("v72_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force $td | Out-Null
    & ffmpeg -v error -y -t 2 -i $sample.FullName -map 0:v:0 -c:v copy -f ivf "$td\v.ivf" 2>$null
    & $av1dovi extract-rpu -i "$td\v.ivf" -o "$td\rb.bin" 2>$null | Out-Null
    & ffmpeg -v error -y -i "$td\v.ivf" -f lavfi -i "sine=r=48000:d=2" -map 0:v -map 1:a -c copy -c:a aac -shortest "$td\orig.mp4" 2>$null
    function _HasDovi($f) { ((& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type -of default=nw=1:nk=1 $f 2>$null) -join ';') -match 'DOVI' }
    if ((Test-Path "$td\rb.bin") -and (Get-Item "$td\rb.bin").Length -gt 0 -and (Test-Path "$td\orig.mp4")) {
        # T1: creatie cu DvRef=sursa → dvcC + RPU byte-identic
        $r1 = Invoke-DvMp4Mux -RawHevc "$td\v.ivf" -Original "$td\orig.mp4" -Output "$td\out.mp4" -DvRef $sample.FullName
        Assert-Eq $true $r1 "functional: Invoke-DvMp4Mux reuseste pe AV1 DV → MP4"
        Assert-Eq $true (_HasDovi "$td\out.mp4") "functional: dvcC scris in MP4 (AV1)"
        & ffmpeg -v error -y -i "$td\out.mp4" -map 0:v:0 -c copy -f ivf "$td\back.ivf" 2>$null
        & $av1dovi extract-rpu -i "$td\back.ivf" -o "$td\ra.bin" 2>$null | Out-Null
        $same = (Test-Path "$td\ra.bin") -and ((Get-FileHash "$td\rb.bin" -Algorithm MD5).Hash -eq (Get-FileHash "$td\ra.bin" -Algorithm MD5).Hash)
        Assert-Eq $true $same "functional: RPU AV1 byte-identic dupa dvp= mux"
        # T2: passthrough — MKV→copy→MP4 pierde dvcC, re-signal il pune la loc
        & ffmpeg -v error -y -i $sample.FullName -map 0:v:0 -c copy "$td\copy.mp4" 2>$null
        Assert-Eq $false (_HasDovi "$td\copy.mp4") "functional: ffmpeg -c copy → MP4 PIERDE dvcC (premisa passthrough)"
        & ffmpeg -v error -y -i "$td\copy.mp4" -map 0:v:0 -c copy -f ivf "$td\copy.ivf" 2>$null
        $r2 = Invoke-DvMp4Mux -RawHevc "$td\copy.ivf" -Original "$td\copy.mp4" -Output "$td\fixed.mp4" -DvRef $sample.FullName
        Assert-Eq $true (_HasDovi "$td\fixed.mp4") "functional: re-signal restaureaza dvcC pe AV1 MP4"
    } else {
        Write-Host "  (functional sarit: build IVF/orig esuat)" -ForegroundColor DarkGray
    }
    Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "  (functional sarit: AV1 DV sample / ffmpeg / MP4Box / av1dovi_tool lipsesc)" -ForegroundColor DarkGray
}

Invoke-TestSummary
