# ══════════════════════════════════════════════════════════════════════
# v75 — Fluxuri DV pe HEVC real (P5 / P8.1 / P8.4). Mirror al .sh.
#   Acopera ce v72 NU acoperea: sample-uri HEVC DV REALE pe profile
#   distincte + REGRESIA codec_tag/dvcC per profil.
#   FOCUS: Invoke-DvMp4Mux scrie dvcC + codec_tag CORECT per profil prin
#   dvp= EXPLICIT — auto-detect-ul MP4Box mislabeleaza P8.4 (HLG) ca
#   profil 5 (dvh1). Canary: demonstram bug-ul auto-detect (fara dvp).
#   + avertismentele P5 din transform/remove (single-layer, fara HDR10).
#   Source-level ruleaza MEREU; functionalul se sare gratios fara
#   ffprobe/MP4Box/sample. Pe Windows PS1 ruleaza si functionalul
#   (MP4Box accepta cai Windows — spre deosebire de bash/MSYS).
# ══════════════════════════════════════════════════════════════════════
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$src  = Join-Path $root 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$src;$env:PATH" }
$enc = Get-Content (Join-Path $src 'av_encode.ps1') -Raw

# ── SOURCE-LEVEL (mereu) ──────────────────────────────────────────────
# B+ : avertisment P5 in Invoke-TransformRpu + Invoke-RemoveDv (gateat pe "Profil 5")
Assert-Match $enc '\$dvProf = Get-DVProfile \$file' "flow-urile DV citesc Get-DVProfile pt avertisment P5"
Assert-Match $enc '\$dvProf -like "\*Profil 5\*"'   "warning P5 gateat pe -like Profil 5"
Assert-Match $enc 'Conversia P5'                    "transform: text avertisment P5->8.1 no-op"
Assert-Match $enc 'baza IPT bruta'                  "remove: text avertisment P5 lasa IPT (nu HDR10)"
# dvp= derivare HEVC din referinta in Invoke-DvMp4Mux
Assert-Match $enc 'dvp=\$\{hp\}\.\$\{hc\}'          "Invoke-DvMp4Mux HEVC: dvp=profil.compat din referinta"
Assert-Match $enc 'stream_side_data=dv_profile'     "Invoke-DvMp4Mux HEVC: citeste dv_profile din ref"

# ── FUNCTIONAL (gardat) ───────────────────────────────────────────────
$MP4BOX = if ($env:AV_TOOL_MP4BOX)  { $env:AV_TOOL_MP4BOX } else { 'mp4box' }
$gpacLocal = Join-Path $PSScriptRoot "..\..\src\GPAC\mp4box.exe"  # co-locat (v93) — fara cai absolute
if (-not (Get-Command $MP4BOX -ErrorAction SilentlyContinue) -and (Test-Path $gpacLocal)) { $MP4BOX = (Resolve-Path $gpacLocal).Path }
$MKVM   = if ($env:AV_TOOL_MKVMERGE){ $env:AV_TOOL_MKVMERGE } elseif (Test-Path (Join-Path $src 'mkvmerge.exe')) { Join-Path $src 'mkvmerge.exe' } else { 'mkvmerge' }
$smP5  = Join-Path $src 'Test-Jellyfin-4K-DV-P5.mp4'
$smP81 = Join-Path $src 'Test-Jellyfin-4K-DV-P8.1.mp4'
$smP84 = Join-Path $src 'Test-Jellyfin-4K-DV-P8.4.mp4'

function DvProf($f){ $p=(& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_profile -of default=nw=1:nk=1 $f 2>$null|Select-Object -First 1); $c=(& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_bl_signal_compatibility_id -of default=nw=1:nk=1 $f 2>$null|Select-Object -First 1); "$($p -replace '\s','').$($c -replace '\s','')" }
function VTag($f){ ((& ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=nw=1:nk=1 $f 2>$null|Select-Object -First 1) -replace '\s','') }
function FpsOf($f){ ((& ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 $f 2>$null|Select-Object -First 1) -replace '\s','') }
function RawOf($f,$o){ & ffmpeg -y -loglevel error -i $f -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -t 2 $o 2>$null }

if ((Get-Command ffprobe -EA SilentlyContinue) -and (Test-Path $smP84) -and (Get-Command $MP4BOX -EA SilentlyContinue)) {
    Import-AvEncodeFunctions -Names @('Invoke-DvMp4Mux','Invoke-DvMkvMux') | Out-Null
    $tmp = Join-Path $env:TEMP ("v75dv_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        # Tabel asteptat: profil -> (dvcC prof.compat, codec_tag)
        #   P5   -> 5.0  / dvh1   (DV only, single-layer)
        #   P8.1 -> 8.1  / hvc1   (HDR10-compatible)
        #   P8.4 -> 8.4  / hvc1   (HLG-compatible)  ← REGRESIA: NU 5/dvh1
        $matrix = [ordered]@{
            "P5"   = @{ sm=$smP5;  prof="5.0"; tag="dvh1" }
            "P8.1" = @{ sm=$smP81; prof="8.1"; tag="hvc1" }
            "P8.4" = @{ sm=$smP84; prof="8.4"; tag="hvc1" }
        }
        foreach ($k in $matrix.Keys) {
            $m = $matrix[$k]
            if (-not (Test-Path $m.sm)) { Write-Host "  ($k sample lipsa)" -ForegroundColor DarkGray; continue }
            $raw = Join-Path $tmp "$k.hevc"; $out = Join-Path $tmp "$k.mp4"
            RawOf $m.sm $raw
            Invoke-DvMp4Mux -RawHevc $raw -Original $m.sm -Output $out -DvRef $m.sm | Out-Null
            if (Test-Path $out) {
                Assert-Eq $m.prof (DvProf $out) "Invoke-DvMp4Mux $k`: dvcC $($m.prof) (dvp= corect)"
                Assert-Eq $m.tag  (VTag $out)   "Invoke-DvMp4Mux $k`: codec_tag $($m.tag)"
            } else { Write-Host "  ($k`: Invoke-DvMp4Mux fara output - sarit)" -ForegroundColor DarkGray }
        }

        # REGRESIE transform: combine paseaza $Original PRE-transform (alt profil decat
        # stream-ul 8.1 PRODUS) FARA -DvRef → HEVC TREBUIE sa cada pe auto-detect (corect
        # pe 8.1), NU sa derive profilul din $Original (ar scrie 5.0 pe un stream 8.1).
        # Simulam: modified = stream 8.1 real, original = fisier P5, fara -DvRef.
        if ((Test-Path $smP81) -and (Test-Path $smP5)) {
            $r81 = Join-Path $tmp "r81.hevc"; $tregr = Join-Path $tmp "tregr.mp4"
            RawOf $smP81 $r81
            Invoke-DvMp4Mux -RawHevc $r81 -Original $smP5 -Output $tregr | Out-Null
            if (Test-Path $tregr) {
                Assert-Eq "8.1" (DvProf $tregr) "REGRESIE transform: fara -DvRef NU deriva din original PRE-transform (8.1 nu 5.0)"
            }
        }

        # CANARY: auto-detect MP4Box (FARA dvp) mislabeleaza P8.4 ca profil 5.
        # Demonstreaza ca dvp= face munca reala. Daca un MP4Box viitor repara
        # auto-detect-ul (→ 8.4), acest assert pica → re-evalueaza necesitatea dvp.
        $craw = Join-Path $tmp "canary.hevc"; $cout = Join-Path $tmp "canary.mp4"
        RawOf $smP84 $craw
        & $MP4BOX -add "${craw}:fps=$(FpsOf $smP84)" -new $cout 2>$null | Out-Null
        if (Test-Path $cout) {
            $cp = DvProf $cout
            Assert-Match $cp '^5\.' "CANARY: MP4Box auto-detect mislabeleaza P8.4 ca $cp (de-aia dvp=; daca pica, MP4Box a reparat auto-detect-ul)"
        }

        # MKV (mkvmerge): calea P8.4 era CORECTA si fara dvp (contrast cu MP4)
        if (Get-Command $MKVM -EA SilentlyContinue) {
            $env:AV_TOOL_MKVMERGE = $MKVM
            $p84o = Join-Path $tmp "p84_o.mkv"; $p84 = Join-Path $tmp "p84.mkv"
            & ffmpeg -y -loglevel error -i $smP84 -f lavfi -i "sine=r=48000:d=2" -map 0:v -map 1:a -c copy -c:a aac -shortest $p84o 2>$null
            Invoke-DvMkvMux -RawHevc (Join-Path $tmp "P8.4.hevc") -Original $p84o -Output $p84 | Out-Null
            if (Test-Path $p84) {
                Assert-Eq "8.4" (DvProf $p84) "Invoke-DvMkvMux P8.4: dvcC 8.4 (mkvmerge corect, fara dvp)"
            }
        }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "  (functional sarit: lipsa ffprobe/MP4Box/sample P8.4)" -ForegroundColor DarkGray
}

Invoke-TestSummary
