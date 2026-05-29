# v57: av_check — TIER 1 + TIER 2 partial fixes (mirror PS1 al test_v57_av_check.sh)
. "$PSScriptRoot\..\framework.ps1"

$PROJECT_ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SH  = Join-Path $PROJECT_ROOT "src\av_check.sh"
$PS1 = Join-Path $PROJECT_ROOT "src\av_check.ps1"

if (-not (Test-Path $SH))  { Skip-Test "lipseste av_check.sh" }
if (-not (Test-Path $PS1)) { Skip-Test "lipseste av_check.ps1" }

$SH_TEXT  = Get-Content $SH  -Raw
$PS1_TEXT = Get-Content $PS1 -Raw

# ══════════════════════════════════════════════════════════════════════
# 1. CSV header — 38 coloane in PS1 (37 + Container)
# ══════════════════════════════════════════════════════════════════════
$ps1Header = ($PS1_TEXT -split "`n" | Where-Object { $_ -match '"Fisier,Format_sursa' } | Select-Object -First 1)
if ($ps1Header -match '"([^"]+)"') {
    $cols = ($matches[1] -split ',').Count
    Assert-Eq 38 $cols "PS1 CSV header = 38 coloane (incl Container)"
}

# Coloanele noi (paritate bash; 7 HDR rich + 1 Container)
foreach ($col in @('Container','ColorPrimaries','ColorSpace','ColorRange','MaxCLL','MaxFALL','MasterDisplay','HDR10Plus_Scenes')) {
    Assert-Contains $PS1_TEXT $col "PS1 CSV header contine $col"
}

# ══════════════════════════════════════════════════════════════════════
# 2. 12-bit depth detection in Get-SourceInfo
# ══════════════════════════════════════════════════════════════════════
Assert-Contains $PS1_TEXT 'bits_per_raw_sample' "PS1 fetch bits_per_raw_sample"
foreach ($pat in @('p10|p010','p12|p012','p16|p016')) {
    Assert-Contains $PS1_TEXT $pat "PS1 pix_fmt pattern '$pat'"
}
Assert-Contains $PS1_TEXT 'depthLabel' "PS1 depthLabel variabila"

# ══════════════════════════════════════════════════════════════════════
# 3. AV1 DV detection via side_data
# ══════════════════════════════════════════════════════════════════════
Assert-Contains $PS1_TEXT 'isDVFrames' "PS1 isDVFrames marker"
Assert-Contains $PS1_TEXT 'Dolby Vision Metadata' "PS1 DV side_data match"

# Get-DVProfile codec_tag fallback (paritate bash)
Assert-Contains $PS1_TEXT 'dvhe' "PS1 Get-DVProfile fallback codec_tag dvhe"
Assert-Contains $PS1_TEXT 'dvh1' "PS1 Get-DVProfile fallback codec_tag dvh1"

# ══════════════════════════════════════════════════════════════════════
# 4. TYPE/LOG mutual exclusion
# ══════════════════════════════════════════════════════════════════════
Assert-Contains $PS1_TEXT 'SDR (LOG)' "PS1 TYPE=SDR (LOG) override"

# ══════════════════════════════════════════════════════════════════════
# 5. MKV bitrate fallback
# ══════════════════════════════════════════════════════════════════════
Assert-Contains $PS1_TEXT 'fmtBr' "PS1 format=bit_rate fallback variabila"
Assert-Contains $PS1_TEXT '(est)' "PS1 size/dur estimate label"

# ══════════════════════════════════════════════════════════════════════
# 6. HDR rich fields helper
# ══════════════════════════════════════════════════════════════════════
Assert-Contains $PS1_TEXT 'function Get-HdrRichInfo' "PS1 Get-HdrRichInfo definita"
foreach ($prop in @('colorPrimaries','colorSpace','colorRange','maxCll','maxFall','masterDisplay','hdr10PlusScenes')) {
    Assert-Contains $PS1_TEXT $prop "PS1 hash property $prop"
}
foreach ($prim in @('BT.2020','DCI-P3','BT.709')) {
    Assert-Contains $PS1_TEXT $prim "PS1 mastering display primaries detect: $prim"
}
# InvariantCulture pentru locale-safe formatting (rule CLAUDE.md)
Assert-Contains $PS1_TEXT 'InvariantCulture' "PS1 InvariantCulture pentru luminance"

# ══════════════════════════════════════════════════════════════════════
# 7. HDR10+ scene count — keyframe scan
# ══════════════════════════════════════════════════════════════════════
Assert-Contains $PS1_TEXT '-skip_frame nokey' "PS1 HDR10+ keyframe scan"

# ══════════════════════════════════════════════════════════════════════
# 8. Per-track audio detail (nou)
# ══════════════════════════════════════════════════════════════════════
Assert-Contains $PS1_TEXT 'audioTracksDetail' "PS1 audioTracksDetail variabila"
Assert-Contains $PS1_TEXT 'compact=nk=0:p=0' "PS1 audio per-track compact format"

# ══════════════════════════════════════════════════════════════════════
# 9. Stale comparison suffix list expansion
# ══════════════════════════════════════════════════════════════════════
foreach ($sfx in @('_prores','_apv','_remux','_mux','_telem','_hud','_subs','_preview','_nodv','_nohdr10plus','_dvhybrid','_hwenc')) {
    Assert-Contains $PS1_TEXT $sfx "PS1 comp suffix $sfx prezent"
}

# ══════════════════════════════════════════════════════════════════════
# 10. PS1 attachments mimes display
# ══════════════════════════════════════════════════════════════════════
Assert-Contains $PS1_TEXT 'attMimes' "PS1 attachments mimes parsing"

# ══════════════════════════════════════════════════════════════════════
# 11. PS1 env override AV_INPUT_DIR / AV_OUTPUT_DIR
# ══════════════════════════════════════════════════════════════════════
Assert-Contains $PS1_TEXT 'AV_INPUT_DIR'  "PS1 AV_INPUT_DIR env override"
Assert-Contains $PS1_TEXT 'AV_OUTPUT_DIR' "PS1 AV_OUTPUT_DIR env override"

# ══════════════════════════════════════════════════════════════════════
# 12. PS1 DJI tracks emit 0/1 nu True/False (paritate bash CSV)
# ══════════════════════════════════════════════════════════════════════
Assert-Contains $PS1_TEXT 'csv_djmd' "PS1 CSV DJI int marker (0/1)"

# ══════════════════════════════════════════════════════════════════════
# 13. PS1 sintaxa AST valida
# ══════════════════════════════════════════════════════════════════════
$astTokens = $null; $astErrs = $null
[System.Management.Automation.Language.Parser]::ParseFile($PS1, [ref]$astTokens, [ref]$astErrs) | Out-Null
Assert-Eq 0 $astErrs.Count "PS1 av_check.ps1 — AST parse fara erori"

# ══════════════════════════════════════════════════════════════════════
# 14. side_data query correctness — bug critic descoperit pe real samples
#     `frame_side_data=type` e invalid (ignora selector → full frame dump);
#     corect e `frame_side_data=side_data_type`. Toate site-urile HDR10+/DV
#     per-frame trebuie sa foloseasca varianta corecta.
# ══════════════════════════════════════════════════════════════════════
$badSh = ([regex]::Matches($SH_TEXT,  'frame_side_data=type\b')).Count
$badPs = ([regex]::Matches($PS1_TEXT, 'frame_side_data=type\b')).Count
Assert-Eq 0 $badSh "bash zero query frame_side_data=type (invalid)"
Assert-Eq 0 $badPs "PS1 zero query frame_side_data=type (invalid)"
$goodSh = ([regex]::Matches($SH_TEXT,  'frame_side_data=side_data_type')).Count
$goodPs = ([regex]::Matches($PS1_TEXT, 'frame_side_data=side_data_type')).Count
if ($goodSh -lt 2) { Assert-Eq 2 $goodSh "bash >=2 site-uri side_data_type" }
if ($goodPs -lt 3) { Assert-Eq 3 $goodPs "PS1 >=3 site-uri side_data_type" }

# ══════════════════════════════════════════════════════════════════════
# 15. Samsung Log — short-circuit pe `com.samsung.android.logvideo`
# ══════════════════════════════════════════════════════════════════════
Assert-Contains $PS1_TEXT "com\.samsung\.android\.logvideo" "PS1 Samsung Log tag autoritar"
Assert-Contains $PS1_TEXT "deriva depth-ul din pix_fmt" "PS1 pix_fmt fallback in Get-LogProfile"

# DJI camera_make: fallback `encoder=DJI` (clipuri re-muxed fara djmd/dbgi
# raman recognoscute; paritate cu short-circuit-ul Samsung).
Assert-Contains $PS1_TEXT 'encoder=.*dji' "PS1 encoder=DJI fallback in Get-LogProfile"

# ══════════════════════════════════════════════════════════════════════
# 16. Get-FFprobeValue — csv=p=0 trailing comma fix
#     ffprobe 8.x emite trailing virgula la csv=p=0 single-field queries
#     → polua display + CSV. Switch la default=noprint_wrappers=1:nokey=1.
# ══════════════════════════════════════════════════════════════════════
$gfvMatch = [regex]::Match($PS1_TEXT, '(?ms)function Get-FFprobeValue\b.*?\n\}')
Assert-Eq $true $gfvMatch.Success "PS1 Get-FFprobeValue gasita"
$gfvBody = $gfvMatch.Value
Assert-Contains $gfvBody "default=noprint_wrappers=1:nokey=1" "Get-FFprobeValue foloseste default= format"
# Verifica ffprobe call line — comentariile pot mentiona csv=p=0 in mod legit
$gfvFfprobeLine = ($gfvBody -split "`n" | Where-Object { $_ -match '\bffprobe\b' -and $_ -notmatch '^\s*#' }) -join "`n"
Assert-Eq $false ([bool]($gfvFfprobeLine -match 'csv=p=0')) "Get-FFprobeValue ffprobe call fara csv=p=0"

# ══════════════════════════════════════════════════════════════════════
# 17. Integration smoke (daca ffprobe disponibil) — sample HDR10
# ══════════════════════════════════════════════════════════════════════
$ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
if (-not $ffprobe) {
    $local = Join-Path $PROJECT_ROOT "src\ffprobe.exe"
    if (Test-Path $local) { $env:PATH = "$(Split-Path $local);$env:PATH"; $ffprobe = $local }
}
if ($ffprobe) {
    $samples = Join-Path $PROJECT_ROOT "tests\fixtures\samples"
    if ((Test-Path (Join-Path $samples "hdr10_320p.mkv")) -and (Test-Path (Join-Path $samples "sdr_320p.mp4"))) {
        $tmp = Join-Path $env:TEMP "av_check_v57_test_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Force -Path "$tmp\IN","$tmp\OUT" | Out-Null
        Copy-Item (Join-Path $samples "hdr10_320p.mkv") "$tmp\IN\"
        Copy-Item (Join-Path $samples "sdr_320p.mp4")   "$tmp\IN\"
        $env:AV_INPUT_DIR = "$tmp\IN"
        $env:AV_OUTPUT_DIR = "$tmp\OUT"
        try {
            & $PS1 *>$null
        } catch {}
        $csv = "$tmp\OUT\av_check_report.csv"
        if (Test-Path $csv) {
            $headLine = Get-Content $csv -TotalCount 1
            $headCols = ($headLine -split ',').Count
            Assert-Eq 38 $headCols "integration: CSV header runtime = 38 coloane (incl Container)"
            $hdrRow = Get-Content $csv | Where-Object { $_ -match 'hdr10' } | Select-Object -First 1
            if ($hdrRow) {
                Assert-Contains $hdrRow 'HDR10'  "integration: HDR10 sample detectat"
                Assert-Contains $hdrRow 'bt2020' "integration: ColorPrimaries=bt2020"
                Assert-Contains $hdrRow '1000'   "integration: MaxCLL=1000"
            }
        }
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        Remove-Item Env:AV_INPUT_DIR  -ErrorAction SilentlyContinue
        Remove-Item Env:AV_OUTPUT_DIR -ErrorAction SilentlyContinue
    }
}

Invoke-TestSummary
