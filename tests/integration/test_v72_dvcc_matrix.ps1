# ══════════════════════════════════════════════════════════════════════
# v72 — MATRICE dvcC de container (integrare, PS1). Mirror al .sh.
#   Validare end-to-end a semnalizarii DV de container pe matricea
#   codec × container × unealta (cu/fara MP4Box+mkvmerge): dvcC scris +
#   RPU byte-identic + HDR10+ co-existenta + cross-codec (profil fortat 10)
#   + cross-container (ffmpeg -c copy) + passthrough + transform + LANT
#   ENCODE REAL (svtav1 → inject → T.35 → dvcC).
#   Auto-skip cand uneltele/sample-urile lipsesc (resurse dev-box).
#   Nascut din auditul v72 (2026-06-17) — santinela permanenta de regresie.
# ══════════════════════════════════════════════════════════════════════
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$src  = Join-Path $root 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$src;$env:PATH" }

# unelte (env-overridable; default in src/ pe dev-box)
$MP4BOX  = if ($env:AV_TOOL_MP4BOX)  { $env:AV_TOOL_MP4BOX }  else { 'mp4box' }
$gpacLocal = Join-Path $PSScriptRoot "..\..\src\GPAC\mp4box.exe"  # co-locat (v93) — fara cai absolute
if (-not (Get-Command $MP4BOX -ErrorAction SilentlyContinue) -and (Test-Path $gpacLocal)) { $MP4BOX = (Resolve-Path $gpacLocal).Path }
$MKVM    = if ($env:AV_TOOL_MKVMERGE){ $env:AV_TOOL_MKVMERGE } elseif (Test-Path (Join-Path $src 'mkvmerge.exe')) { Join-Path $src 'mkvmerge.exe' } else { 'mkvmerge' }
$DOVI    = if ($env:AV_TOOL_DOVI)    { $env:AV_TOOL_DOVI }    else { 'dovi_tool' }
$AV1DOVI = if ($env:AV_TOOL_AV1DOVI) { $env:AV_TOOL_AV1DOVI } else { 'av1dovi_tool' }

foreach ($t in @('ffmpeg','ffprobe',$MP4BOX,$MKVM,$DOVI,$AV1DOVI)) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { Skip-Test "unealta lipsa: $t" }
}
# sample-uri reale (dev-box, gitignored)
$smAv1Dv  = Get-ChildItem $src -Filter '*_DV_*AV1.mkv' -EA SilentlyContinue | Where-Object { $_.Name -notmatch 'HDR10Plus' } | Select-Object -First 1
$smAv1Hyb = Get-ChildItem $src -Filter '*DV_HDR10Plus*AV1.mkv' -EA SilentlyContinue | Select-Object -First 1
$smHevcHp = Get-ChildItem $src -Filter '*HDR10Plus*HEVC.mp4' -EA SilentlyContinue | Select-Object -First 1
if (-not ($smAv1Dv -and $smAv1Hyb -and $smHevcHp)) { Skip-Test "sample-uri AV1 DV / AV1 hibrid / HEVC HDR10+ lipsesc" }

Import-AvEncodeFunctions -Names @('Invoke-DvMp4Mux','Invoke-DvMkvMux','Invoke-HdvCombineWithOriginal','Get-ContainerFlags') | Out-Null
$tmp = Join-Path $env:TEMP ("v72matrix_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function HasDvcc($f){ if(-not(Test-Path $f)){return $false}; ((& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type -of default=nw=1:nk=1 $f 2>$null) -join ';') -match 'DOVI configuration record' }
function DvProf($f){ $p=(& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_profile -of default=nw=1:nk=1 $f 2>$null|Select-Object -First 1); $c=(& ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_bl_signal_compatibility_id -of default=nw=1:nk=1 $f 2>$null|Select-Object -First 1); "$p.$c" }
function HasHdr10p($f){ ((& ffprobe -v error -select_streams v:0 -read_intervals '%+#6' -show_entries frame_side_data=side_data_type -of default=nw=1:nk=1 $f 2>$null) -join ';') -match 'SMPTE2094-40' }
function RpuAv1($ivf){ $o="$ivf.rpu"; & $AV1DOVI extract-rpu -i $ivf -o $o 2>$null|Out-Null; if((Test-Path $o)-and(Get-Item $o).Length-gt 0){(Get-FileHash $o -Algorithm MD5).Hash}else{'NORPU'} }
function RpuHevc($hevc){ $o="$hevc.rpu"; & $DOVI extract-rpu -i $hevc -o $o 2>$null|Out-Null; if((Test-Path $o)-and(Get-Item $o).Length-gt 0){(Get-FileHash $o -Algorithm MD5).Hash}else{'NORPU'} }
function ToIvf($mp4,$out){ & ffmpeg -y -loglevel error -i $mp4 -map 0:v:0 -c copy -f ivf $out 2>$null }

try {
    # ── PREP ──────────────────────────────────────────────────────────
    & ffmpeg -y -loglevel error -i $smAv1Dv.FullName -map 0:v:0 -c copy -f ivf "$tmp\av1dv.ivf" 2>$null
    & ffmpeg -y -loglevel error -i "$tmp\av1dv.ivf" -f lavfi -i "sine=r=48000:d=2" -map 0:v -map 1:a -c copy -c:a aac -shortest "$tmp\av1dv_o.mp4" 2>$null
    $rpuAv1Dv = RpuAv1 "$tmp\av1dv.ivf"
    & ffmpeg -y -loglevel error -i $smAv1Hyb.FullName -map 0:v:0 -c copy -f ivf "$tmp\av1hyb.ivf" 2>$null
    & ffmpeg -y -loglevel error -i "$tmp\av1hyb.ivf" -f lavfi -i "sine=r=48000:d=2" -map 0:v -map 1:a -c copy -c:a aac -shortest "$tmp\av1hyb_o.mp4" 2>$null
    $rpuAv1Hyb = RpuAv1 "$tmp\av1hyb.ivf"
    # ref HEVC DV 8.1 reala (din HEVC HDR10+ + inject) — pt testul cross-codec
    & ffmpeg -y -loglevel error -i $smHevcHp.FullName -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb "$tmp\h.hevc" 2>$null
    Set-Content "$tmp\cfg.json" '{ "cm_version":"V40","length":48,"level6":{"max_display_mastering_luminance":1000,"min_display_mastering_luminance":1,"max_content_light_level":1000,"max_frame_average_light_level":400} }' -Encoding ascii
    & $DOVI generate -j "$tmp\cfg.json" -o "$tmp\h_rpu.bin" 2>$null|Out-Null
    & $DOVI inject-rpu -i "$tmp\h.hevc" --rpu-in "$tmp\h_rpu.bin" -o "$tmp\hevcdv.hevc" 2>$null|Out-Null
    & $MP4BOX -add "$tmp\hevcdv.hevc:fps=23.976" -new "$tmp\hevcdv_ref.mp4" 2>$null|Out-Null
    & ffmpeg -y -loglevel error -i "$tmp\hevcdv_ref.mp4" -f lavfi -i "sine=r=48000:d=2" -map 0:v -map 1:a -c copy -c:a aac -shortest "$tmp\hevcdv_o.mp4" 2>$null
    $rpuHevcDv = RpuHevc "$tmp\hevcdv.hevc"

    # ── 1. AV1 DV → MP4 (MP4Box) ──────────────────────────────────────
    Invoke-DvMp4Mux -RawHevc "$tmp\av1dv.ivf" -Original "$tmp\av1dv_o.mp4" -Output "$tmp\1.mp4" -DvRef $smAv1Dv.FullName | Out-Null
    ToIvf "$tmp\1.mp4" "$tmp\1.ivf"
    Assert-Eq $true (HasDvcc "$tmp\1.mp4") "av1 DV -> MP4: dvcC scris"
    Assert-Eq "10.1" (DvProf "$tmp\1.mp4") "av1 DV -> MP4: profil 10.1"
    Assert-Eq $rpuAv1Dv (RpuAv1 "$tmp\1.ivf") "av1 DV -> MP4: RPU byte-identic"

    # ── 2. AV1 DV → MKV (mkvmerge) ────────────────────────────────────
    Invoke-DvMkvMux -RawHevc "$tmp\av1dv.ivf" -Original "$tmp\av1dv_o.mp4" -Output "$tmp\2.mkv" | Out-Null
    ToIvf "$tmp\2.mkv" "$tmp\2.ivf"
    Assert-Eq $true (HasDvcc "$tmp\2.mkv") "av1 DV -> MKV: dvcC scris"
    Assert-Eq $rpuAv1Dv (RpuAv1 "$tmp\2.ivf") "av1 DV -> MKV: RPU byte-identic"

    # ── 3. fallback fara unealta (no output partial) ──────────────────
    $oldMp = $env:AV_TOOL_MP4BOX; $env:AV_TOOL_MP4BOX = 'C:\nul\nope.exe'
    $rfb = Invoke-DvMp4Mux -RawHevc "$tmp\av1dv.ivf" -Original "$tmp\av1dv_o.mp4" -Output "$tmp\3.mp4"; $env:AV_TOOL_MP4BOX = $oldMp
    Assert-Eq $false $rfb "av1 DV -> MP4 fara MP4Box: fallback (false)"
    Assert-Eq $false (Test-Path "$tmp\3.mp4") "av1 DV -> MP4 fara MP4Box: fara output partial"

    # ── 4. AV1 hibrid (DV+HDR10+) → MP4 + MKV ─────────────────────────
    Invoke-DvMp4Mux -RawHevc "$tmp\av1hyb.ivf" -Original "$tmp\av1hyb_o.mp4" -Output "$tmp\4.mp4" -DvRef $smAv1Hyb.FullName | Out-Null
    ToIvf "$tmp\4.mp4" "$tmp\4.ivf"
    Assert-Eq $true (HasDvcc "$tmp\4.mp4") "av1 hibrid -> MP4: dvcC scris"
    Assert-Eq $true (HasHdr10p "$tmp\4.mp4") "av1 hibrid -> MP4: HDR10+ pastrat"
    Assert-Eq $rpuAv1Hyb (RpuAv1 "$tmp\4.ivf") "av1 hibrid -> MP4: RPU byte-identic"
    Invoke-DvMkvMux -RawHevc "$tmp\av1hyb.ivf" -Original "$tmp\av1hyb_o.mp4" -Output "$tmp\4.mkv" | Out-Null
    Assert-Eq $true (HasDvcc "$tmp\4.mkv") "av1 hibrid -> MKV: dvcC scris"
    Assert-Eq $true (HasHdr10p "$tmp\4.mkv") "av1 hibrid -> MKV: HDR10+ pastrat"

    # ── 5. CROSS-CODEC dvp (FIX audit v72): av1 raw + ref HEVC-DV(8.x) → profil MUST 10 ──
    Assert-Match (DvProf "$tmp\hevcdv_ref.mp4") '^8\.' "prep: ref HEVC DV e profil 8.x (non-10)"
    Invoke-DvMp4Mux -RawHevc "$tmp\av1dv.ivf" -Original "$tmp\av1dv_o.mp4" -Output "$tmp\5.mp4" -DvRef "$tmp\hevcdv_ref.mp4" | Out-Null
    Assert-Eq $true (HasDvcc "$tmp\5.mp4") "cross-codec av1+refHEVC -> MP4: dvcC scris"
    Assert-Match (DvProf "$tmp\5.mp4") '^10\.' "cross-codec: profil FORTAT la 10 (nu 8 din ref)"

    # ── 6. HEVC DV → MP4 (auto-detect) + MKV ──────────────────────────
    Invoke-DvMp4Mux -RawHevc "$tmp\hevcdv.hevc" -Original "$tmp\hevcdv_o.mp4" -Output "$tmp\6.mp4" | Out-Null
    & ffmpeg -y -loglevel error -i "$tmp\6.mp4" -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb "$tmp\6.hevc" 2>$null
    Assert-Eq $true (HasDvcc "$tmp\6.mp4") "hevc DV -> MP4: dvcC scris"
    Assert-Match (DvProf "$tmp\6.mp4") '^8\.' "hevc DV -> MP4: profil 8.x (auto-detect)"
    Assert-Eq $rpuHevcDv (RpuHevc "$tmp\6.hevc") "hevc DV -> MP4: RPU byte-identic"
    Invoke-DvMkvMux -RawHevc "$tmp\hevcdv.hevc" -Original "$tmp\hevcdv_o.mp4" -Output "$tmp\6.mkv" | Out-Null
    Assert-Eq $true (HasDvcc "$tmp\6.mkv") "hevc DV -> MKV: dvcC scris"

    # ── 7. CROSS-CONTAINER: ffmpeg -c copy PASTREAZA →MKV, PIERDE →MP4 ──
    & ffmpeg -y -loglevel error -i $smAv1Dv.FullName -map 0:v:0 -c copy "$tmp\cc.mkv" 2>$null
    & ffmpeg -y -loglevel error -i $smAv1Dv.FullName -map 0:v:0 -c copy "$tmp\cc.mp4" 2>$null
    Assert-Eq $true  (HasDvcc "$tmp\cc.mkv") "cross-container: ffmpeg -c copy PASTREAZA dvcC →MKV"
    Assert-Eq $false (HasDvcc "$tmp\cc.mp4") "cross-container: ffmpeg -c copy PIERDE dvcC →MP4 (premisa passthrough)"

    # ── 8. PASSTHROUGH: re-signal pe MP4-ul fara dvcC ─────────────────
    ToIvf "$tmp\cc.mp4" "$tmp\cc.ivf"
    Invoke-DvMp4Mux -RawHevc "$tmp\cc.ivf" -Original "$tmp\cc.mp4" -Output "$tmp\8.mp4" -DvRef $smAv1Dv.FullName | Out-Null
    Assert-Eq $true (HasDvcc "$tmp\8.mp4") "passthrough: re-signal restaureaza dvcC pe AV1 MP4"
    Assert-Eq "10.1" (DvProf "$tmp\8.mp4") "passthrough: profil 10.1"

    # ── 9. TRANSFORM (Invoke-HdvCombine): av1 hibrid IVF → MP4 + MKV ───
    (Invoke-HdvCombineWithOriginal -Modified "$tmp\av1hyb.ivf" -Original "$tmp\av1hyb_o.mp4" -Output "$tmp\9.mp4") | Out-Null
    Assert-Eq $true (HasDvcc "$tmp\9.mp4") "transform av1 hibrid -> MP4: dvcC"
    Assert-Eq $true (HasHdr10p "$tmp\9.mp4") "transform av1 hibrid -> MP4: HDR10+"
    (Invoke-HdvCombineWithOriginal -Modified "$tmp\av1hyb.ivf" -Original "$tmp\av1hyb_o.mp4" -Output "$tmp\9.mkv") | Out-Null
    Assert-Eq $true (HasDvcc "$tmp\9.mkv") "transform av1 hibrid -> MKV: dvcC"
    Assert-Eq $true (HasHdr10p "$tmp\9.mkv") "transform av1 hibrid -> MKV: HDR10+"

    # ── 10. LANT ENCODE REAL (svtav1 → inject → T.35 → dvcC) ──────────
    $hasSvt = ((& ffmpeg -hide_banner -encoders 2>$null) -join ';') -match 'libsvtav1'
    $py = (Get-Command python -EA SilentlyContinue).Source; if (-not $py) { $py = (Get-Command python3 -EA SilentlyContinue).Source }
    if ($hasSvt -and $py) {
        & ffmpeg -y -loglevel error -t 2 -i $smAv1Dv.FullName -map 0:v:0 -c copy -f ivf "$tmp\e_src.ivf" 2>$null
        $eRpu = RpuAv1 "$tmp\e_src.ivf"
        & ffmpeg -y -loglevel error -i "$tmp\e_src.ivf" -c:v libsvtav1 -crf 40 -preset 10 -svtav1-params "enable-hdr=1" -pix_fmt yuv420p10le -f ivf "$tmp\e_base.ivf" 2>$null
        & $AV1DOVI inject-rpu -i "$tmp\e_base.ivf" --rpu-in "$tmp\e_src.ivf.rpu" -o "$tmp\e_inj.ivf" 2>$null|Out-Null
        & $py (Join-Path $src 'av1_dv_t35_repair.py') "$tmp\e_inj.ivf" "$tmp\e_rep.ivf" 2>$null
        & ffmpeg -y -loglevel error -i "$tmp\e_rep.ivf" -f lavfi -i "sine=r=48000:d=2" -map 0:v -map 1:a -c copy -c:a aac -shortest "$tmp\e_o.mp4" 2>$null
        Invoke-DvMp4Mux -RawHevc "$tmp\e_rep.ivf" -Original "$tmp\e_o.mp4" -Output "$tmp\e_final.mp4" -DvRef $smAv1Dv.FullName | Out-Null
        ToIvf "$tmp\e_final.mp4" "$tmp\e_out.ivf"
        $dec = & ffmpeg -v warning -i "$tmp\e_final.mp4" -f null - 2>&1
        $decErr = ($dec | Select-String 'Malformed|T.35|error' | Measure-Object).Count
        Assert-Eq $true (HasDvcc "$tmp\e_final.mp4") "ENCODE REAL: av1 DV svtav1 -> dvcC MP4"
        Assert-Eq "10.1" (DvProf "$tmp\e_final.mp4") "ENCODE REAL: profil 10.1"
        Assert-Eq $eRpu (RpuAv1 "$tmp\e_out.ivf") "ENCODE REAL: RPU byte-identic prin lant (extract→encode→inject→T.35→mux)"
        Assert-Eq 0 $decErr "ENCODE REAL: decode dav1d curat (0 erori T.35)"
    } else {
        Write-Host "  (lant encode real sarit: libsvtav1 / python lipsesc)" -ForegroundColor DarkGray
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-TestSummary
