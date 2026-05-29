# Test v44 helpers C+D+E (PS1): Convert-RpuProfile + Get-RemuxPreflight
# ffprobe e mockuit ca functie shell pentru Get-RemuxPreflight.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

Import-AvEncodeFunctions -Names @(
    'Get-SourceCodec',
    'Get-ToolForExtract',
    'Get-ToolForInject',
    'Get-DvRpu',
    'Convert-RpuProfile',
    'Get-RawVideo',
    'Get-RemuxPreflight',
    'Invoke-Remux'
)

# ─────────────────────────────────────────────────────────────────
# Mock ffprobe — function override (PS1 prefera functii peste binary
# pentru `& ffprobe ...` cand exista in scope).
# ─────────────────────────────────────────────────────────────────
$script:_mock_audio = "aac"
$script:_mock_sub   = ""
$script:_mock_tags  = ""
$script:_mock_video = "hevc"   # v57: mockable pentru AV1+MOV preflight test

function Global:ffprobe {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments=$true)]$RemainingArgs)
    $argStr = ($RemainingArgs -join ' ')
    # v49: Get-RemuxPreflight foloseste select_streams a/s/t (toate stream-urile),
    # nu :0 (primul). Mock raspunde la ambele forme pentru back-compat.
    if ($argStr -match 'select_streams v:0') { $script:_mock_video; return }
    if ($argStr -match 'select_streams a')   { $script:_mock_audio; return }
    if ($argStr -match 'select_streams s')   { $script:_mock_sub;   return }
    if ($argStr -match 'select_streams t')   { ''; return }
    if ($argStr -match 'codec_tag_string')   { $script:_mock_tags;  return }
    if ($argStr -match 'show_chapters')      { ''; return }
    return ""
}

$tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ('av_test_hdv_'+[guid]::NewGuid().ToString('N')+'.mp4')
"fake" | Set-Content -LiteralPath $tmpFile

try {
    # ─────────────────────────────────────────────────────────────
    # 1) Get-RemuxPreflight — toate regulile
    # ─────────────────────────────────────────────────────────────

    # 1a) aac + mp4 -> level 0
    $script:_mock_audio = "aac"; $script:_mock_sub = ""; $script:_mock_tags = ""
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mp4"
    Assert-Eq 0 $r.level "aac+mp4 -> level 0"
    Assert-Eq 0 $r.notes.Count "aac+mp4: 0 notes"

    # 1b) eac3 + mov -> level 2
    $script:_mock_audio = "eac3"
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mov"
    Assert-Eq 2 $r.level "eac3+mov -> level 2"
    if ($r.notes.Count -gt 0) { _pass } else { _fail "eac3+mov: should have notes" }
    $joined = $r.notes -join ' '
    Assert-Match $joined "E-AC3" "note mentions E-AC3"

    # 1c) eac3 + mp4 -> level 0 (E-AC3 e ok in mp4)
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mp4"
    Assert-Eq 0 $r.level "eac3+mp4 -> level 0 (no problem)"

    # 1d) subrip + mp4 -> level 1
    $script:_mock_audio = "aac"; $script:_mock_sub = "subrip"
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mp4"
    Assert-Eq 1 $r.level "subrip+mp4 -> level 1"
    Assert-Match ($r.notes -join ' ') "mov_text" "note mentions mov_text conversion"

    # 1e) ass + mov -> level 1
    $script:_mock_sub = "ass"
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mov"
    Assert-Eq 1 $r.level "ass+mov -> level 1"

    # 1f) djmd codec_tag + mp4 -> level 1
    $script:_mock_audio = "aac"; $script:_mock_sub = ""; $script:_mock_tags = "djmd"
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mp4"
    Assert-Eq 1 $r.level "djmd+mp4 -> level 1"
    Assert-Match ($r.notes -join ' ') "DJI" "note mentions DJI"

    # 1g) eac3 + srt + mov -> level 2 (max wins)
    $script:_mock_audio = "eac3"; $script:_mock_sub = "subrip"; $script:_mock_tags = ""
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mov"
    Assert-Eq 2 $r.level "eac3+srt+mov -> level 2"
    if ($r.notes.Count -ge 2) { _pass } else { _fail "expected >=2 notes" }

    # v57 — AV1 + MOV preflight (ffmpeg refuza)
    $script:_mock_audio = "aac"; $script:_mock_sub = ""; $script:_mock_tags = ""; $script:_mock_video = "av1"
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mov"
    Assert-Eq 2 $r.level "av1+mov -> level 2 (ffmpeg refuza)"
    Assert-Match ($r.notes -join ' ') "AV1" "note mentions AV1"

    # v57 — AV1 + MP4 OK
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mp4"
    Assert-Eq 0 $r.level "av1+mp4 -> level 0 (compatible)"

    # v57 — AV1 + MKV OK
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mkv"
    Assert-Eq 0 $r.level "av1+mkv -> level 0"

    $script:_mock_video = "hevc"   # reset

    # 1h) MKV permisiv
    $script:_mock_audio = "eac3"; $script:_mock_sub = "ass"; $script:_mock_tags = "djmd"
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mkv"
    Assert-Eq 0 $r.level "mkv permisiv -> level 0"
    Assert-Eq 0 $r.notes.Count "mkv: 0 notes"

    # 1i) Container necunoscut -> level 2
    $script:_mock_audio = "aac"; $script:_mock_sub = ""; $script:_mock_tags = ""
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "bogus"
    Assert-Eq 2 $r.level "bogus container -> level 2"

    # 1j) Case-insensitive (MOV uppercase)
    $script:_mock_audio = "eac3"
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "MOV"
    Assert-Eq 2 $r.level "MOV uppercase -> same as mov"

    # ─────────────────────────────────────────────────────────────
    # 2) Convert-RpuProfile — failure paths
    # ─────────────────────────────────────────────────────────────
    $r = Convert-RpuProfile -RpuIn "C:\nonexistent\rpu.bin" -RpuOut $tmpFile -Mode 2 -TargetCodec hevc
    Assert-Eq $false $r "convert: missing rpu_in -> false"

    # 3) Function existence
    foreach ($n in 'Get-DvRpu','Convert-RpuProfile','Get-RawVideo','Get-RemuxPreflight','Invoke-Remux') {
        $g = Get-Command $n -ErrorAction SilentlyContinue
        if ($g) { _pass } else { _fail "$n missing" }
    }

    # ─────────────────────────────────────────────────────────────
    # 4) Invoke-Remux — args building (audit fix B1)
    #    Mock ffmpeg ca sa capturam argumentele.
    # ─────────────────────────────────────────────────────────────
    $script:_capturedArgs = ""
    function Global:ffmpeg {
        [CmdletBinding()]
        param([Parameter(ValueFromRemainingArguments=$true)]$RemainingArgs)
        $script:_capturedArgs = ($RemainingArgs -join ' ')
        # Simulam succes: scriem un fisier dummy non-empty (ultimul arg = output)
        $last = $RemainingArgs[-1]
        "ok" | Set-Content -LiteralPath $last
        $global:LASTEXITCODE = 0
    }
    $outDummy = Join-Path ([System.IO.Path]::GetTempPath()) ('av_test_remux_'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        # 4a) target=mkv → NU contine "mov_text"; foloseste -c:s copy
        $script:_mock_tags = ""
        Invoke-Remux -InputFile $tmpFile -OutputFile $outDummy -TargetContainer "mkv" | Out-Null
        if ($script:_capturedArgs -match 'mov_text') { _fail "mkv must NOT use mov_text (got: $($script:_capturedArgs))" } else { _pass }
        if ($script:_capturedArgs -match '-c:s copy') { _pass } else { _fail "mkv must use '-c:s copy' (got: $($script:_capturedArgs))" }

        # 4b) target=mp4 + source HEVC → mov_text + tag:v hvc1
        Remove-Item -LiteralPath $outDummy -Force -ErrorAction SilentlyContinue
        Invoke-Remux -InputFile $tmpFile -OutputFile $outDummy -TargetContainer "mp4" | Out-Null
        if ($script:_capturedArgs -match 'mov_text') { _pass } else { _fail "mp4 must use mov_text (got: $($script:_capturedArgs))" }
        if ($script:_capturedArgs -match '-tag:v hvc1') { _pass } else { _fail "mp4 + hevc must use -tag:v hvc1 (got: $($script:_capturedArgs))" }
        if ($script:_capturedArgs -match '\+faststart') { _pass } else { _fail "mp4 must use +faststart (got: $($script:_capturedArgs))" }

        # 4c) target=mov + source HEVC → mov_text + hvc1
        Remove-Item -LiteralPath $outDummy -Force -ErrorAction SilentlyContinue
        Invoke-Remux -InputFile $tmpFile -OutputFile $outDummy -TargetContainer "mov" | Out-Null
        if ($script:_capturedArgs -match 'mov_text') { _pass } else { _fail "mov must use mov_text (got: $($script:_capturedArgs))" }
    }
    finally {
        Remove-Item -LiteralPath $outDummy -Force -ErrorAction SilentlyContinue
        Remove-Item Function:ffmpeg -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
    Remove-Item Function:ffprobe -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
# v57: refactor av_hdr_dv flows — helper Invoke-HdvCombineWithOriginal
# elimina duplicarea celor 4 ffmpeg combine site-uri din PS1.
# ─────────────────────────────────────────────────────────────────
$PROJECT_ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$PS1_SCRIPT = Join-Path $PROJECT_ROOT "src\av_encode.ps1"
$PS1_TEXT   = Get-Content $PS1_SCRIPT -Raw

# Helper definit o singura data
$helperDefs = ([regex]::Matches($PS1_TEXT, 'function Invoke-HdvCombineWithOriginal\b')).Count
Assert-Eq 1 $helperDefs "Invoke-HdvCombineWithOriginal definit exact o data"

# 4 call-site-uri (cele 4 flow-uri)
$helperCalls = ([regex]::Matches($PS1_TEXT, '\$ok\s*=\s*Invoke-HdvCombineWithOriginal\b')).Count
Assert-Eq 4 $helperCalls "4 call-site-uri Invoke-HdvCombineWithOriginal"

# Zero `-map 0:v:0 -map 1:a?` direct in flows hdr_dv (toate trec prin helper)
# Verifica pe blocul Invoke-(TransformRpu|Hdr10PlusToDv|RemoveDv|RemoveHdr10Plus)
$flowBlock = [regex]::Match($PS1_TEXT, '(?ms)function Invoke-TransformRpu\b.*?function Invoke-PlotDvMetadata\b').Value
$directCombine = ([regex]::Matches($flowBlock, '"-map","0:v:0","-map","1:a\?"')).Count
Assert-Eq 0 $directCombine "zero ffmpeg combine direct in flows (toate trec prin helper)"

# v57: Get-SourceCodec NU mai foloseste csv=p=0 (trailing comma bug — `av1,`)
$gscMatch = [regex]::Match($PS1_TEXT, '(?ms)function Get-SourceCodec\b.*?\n\}')
Assert-Eq $true $gscMatch.Success "Get-SourceCodec gasita"
$gscBody = $gscMatch.Value
Assert-Contains $gscBody "default=noprint_wrappers=1:nokey=1" "Get-SourceCodec foloseste default= format"
$gscFfprobeLine = ($gscBody -split "`n" | Where-Object { $_ -match 'ffprobe' -and $_ -notmatch '^\s*#' }) -join "`n"
Assert-Eq $false ([bool]($gscFfprobeLine -match 'csv=p=0')) "Get-SourceCodec ffprobe call fara csv=p=0"

# v57: hybrid + transform_rpu PS1 seteaza codec_tag (hvc1/av01) pe MP4/MOV/M4V
$hybridBlock = [regex]::Match($PS1_TEXT, '(?ms)function Invoke-Hdr10PlusToDv\b.*?\n\}').Value
Assert-Eq $true ([bool]($hybridBlock -match '"-tag:v","(hvc1|av01)"')) "Invoke-Hdr10PlusToDv seteaza -tag:v hvc1/av01"
$transformBlock = [regex]::Match($PS1_TEXT, '(?ms)function Invoke-TransformRpu\b.*?\n\}').Value
Assert-Eq $true ([bool]($transformBlock -match '"-tag:v","(hvc1|av01)"')) "Invoke-TransformRpu seteaza -tag:v hvc1/av01"

Invoke-TestSummary
