# Test v49 Mux tools (PS1) — pure-logic + ffprobe mock.
# Coverage: Get-RemuxStreamCompat, Get-RemuxPreflight extins,
#           av_mux.ps1 markers (remux + demux), Invoke-HdrDvTools refactor.

. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

Import-AvEncodeFunctions -Names @(
    'Get-RemuxStreamCompat',
    'Get-RemuxStreams',
    'Get-RemuxPreflight',
    'Get-SourceCodec'
)

# ─────────────────────────────────────────────────────────────────
# 1) Get-RemuxStreamCompat — compat matrix
# ─────────────────────────────────────────────────────────────────

# 1a) MKV permisiv
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec hevc -CodecType video -Target mkv) "mkv: hevc video copy"
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec eac3 -CodecType audio -Target mkv) "mkv: eac3 audio copy"
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec hdmv_pgs_subtitle -CodecType subtitle -Target mkv) "mkv: pgs sub copy"
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec ttf -CodecType attachment -Target mkv) "mkv: attach copy"

# 1b) MP4 video
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec hevc -CodecType video -Target mp4) "mp4: hevc copy"
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec h264 -CodecType video -Target mp4) "mp4: h264 copy"
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec av1  -CodecType video -Target mp4) "mp4: av1 copy"
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec vp8  -CodecType video -Target mp4) "mp4: vp8 drop"

# 1c) MP4 audio
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec aac    -CodecType audio -Target mp4) "mp4: aac copy"
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec eac3   -CodecType audio -Target mp4) "mp4: eac3 copy"
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec truehd -CodecType audio -Target mp4) "mp4: truehd drop"
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec dts    -CodecType audio -Target mp4) "mp4: dts drop"

# 1d) MP4 subtitle
Assert-Eq "convert:mov_text" (Get-RemuxStreamCompat -Codec subrip   -CodecType subtitle -Target mp4) "mp4: subrip -> mov_text"
Assert-Eq "convert:mov_text" (Get-RemuxStreamCompat -Codec ass      -CodecType subtitle -Target mp4) "mp4: ass -> mov_text"
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec mov_text -CodecType subtitle -Target mp4) "mp4: mov_text copy"
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec hdmv_pgs_subtitle -CodecType subtitle -Target mp4) "mp4: pgs drop"
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec dvd_subtitle -CodecType subtitle -Target mp4) "mp4: dvd_sub drop"

# 1e) MOV
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec prores -CodecType video -Target mov) "mov: prores copy"
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec eac3   -CodecType audio -Target mov) "mov: eac3 DROP (compat dispatcher)"
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec opus   -CodecType audio -Target mov) "mov: opus drop"

# 1f) WEBM
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec vp9 -CodecType video -Target webm) "webm: vp9 copy"
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec av1 -CodecType video -Target webm) "webm: av1 copy"
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec hevc -CodecType video -Target webm) "webm: hevc DROP"
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec h264 -CodecType video -Target webm) "webm: h264 DROP"
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec opus -CodecType audio -Target webm) "webm: opus copy"
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec vorbis -CodecType audio -Target webm) "webm: vorbis copy"
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec aac    -CodecType audio -Target webm) "webm: aac DROP"
Assert-Eq "copy" (Get-RemuxStreamCompat -Codec webvtt -CodecType subtitle -Target webm) "webm: webvtt copy"
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec subrip -CodecType subtitle -Target webm) "webm: subrip DROP"

# 1g) Attachments — drop pe non-mkv
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec ttf -CodecType attachment -Target mp4) "mp4: attach drop"
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec otf -CodecType attachment -Target mov) "mov: attach drop"
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec ttf -CodecType attachment -Target webm) "webm: attach drop"

# 1h) Necunoscut -> drop
Assert-Eq "drop" (Get-RemuxStreamCompat -Codec fubar123 -CodecType video -Target mp4) "mp4: unknown -> drop"

# ─────────────────────────────────────────────────────────────────
# 2) Get-RemuxPreflight — reguli noi v49
# ─────────────────────────────────────────────────────────────────
$script:_mock_video    = "hevc"
$script:_mock_audios   = ""
$script:_mock_subs     = ""
$script:_mock_attachs  = ""
$script:_mock_tags     = ""

function Global:ffprobe {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments=$true)]$RemainingArgs)
    $argStr = ($RemainingArgs -join ' ')
    if ($argStr -match 'select_streams v:0')  { $script:_mock_video;   return }
    if ($argStr -match 'select_streams a')    { $script:_mock_audios;  return }
    if ($argStr -match 'select_streams s')    { $script:_mock_subs;    return }
    if ($argStr -match 'select_streams t')    { $script:_mock_attachs; return }
    if ($argStr -match 'codec_tag_string')    { $script:_mock_tags;    return }
    if ($argStr -match 'show_chapters')       { ''; return }
    return ""
}

$tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ('av_test_v49_'+[guid]::NewGuid().ToString('N')+'.mp4')
"fake" | Set-Content -LiteralPath $tmpFile

try {
    # 2a) WEBM + hevc -> FAIL
    $script:_mock_video = "hevc"; $script:_mock_audios = ""; $script:_mock_subs = ""; $script:_mock_attachs = ""
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "webm"
    Assert-Eq 2 $r.level "webm+hevc -> level 2 FAIL"
    Assert-Match (($r.notes -join ' ')) "WEBM" "note mentions WEBM"

    # 2b) WEBM + vp9 + aac -> level 1
    $script:_mock_video = "vp9"; $script:_mock_audios = "aac"
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "webm"
    Assert-Eq 1 $r.level "webm+vp9+aac -> level 1"

    # 2c) WEBM + av1 + opus -> level 0
    $script:_mock_video = "av1"; $script:_mock_audios = "opus"
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "webm"
    Assert-Eq 0 $r.level "webm+av1+opus -> level 0"

    # 2d) MP4 + truehd -> level 1
    $script:_mock_video = "hevc"; $script:_mock_audios = "truehd"; $script:_mock_subs = ""; $script:_mock_attachs = ""
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mp4"
    Assert-Eq 1 $r.level "mp4+truehd -> level 1"
    Assert-Match (($r.notes -join ' ')) "TrueHD" "note mentions TrueHD"

    # 2e) MP4 + PGS -> level 1
    $script:_mock_video = "hevc"; $script:_mock_audios = "aac"; $script:_mock_subs = "hdmv_pgs_subtitle"
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mp4"
    Assert-Eq 1 $r.level "mp4+pgs -> level 1"
    Assert-Match (($r.notes -join ' ')) "bitmap" "note mentions bitmap"

    # 2f) MP4 + attachments -> level 1
    $script:_mock_video = "hevc"; $script:_mock_audios = "aac"; $script:_mock_subs = ""; $script:_mock_attachs = "10"
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mp4"
    Assert-Eq 1 $r.level "mp4+attach -> level 1"
    Assert-Match (($r.notes -join ' ')) "atasament" "note mentions atasament"

    # 2g) MKV permisiv ramane permisiv chiar cu streams ostile
    $script:_mock_video = "hevc"; $script:_mock_audios = "truehd"; $script:_mock_subs = "hdmv_pgs_subtitle"; $script:_mock_attachs = "20"
    $r = Get-RemuxPreflight -File $tmpFile -TargetContainer "mkv"
    Assert-Eq 0 $r.level "mkv permisiv chiar cu hostile streams"
}
finally {
    Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
    Remove-Item Function:ffprobe -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
# 3) av_mux.ps1 — markers + structura (rename v49 av_remux → av_mux)
# ─────────────────────────────────────────────────────────────────
$avMux = Join-Path $PSScriptRoot "..\..\src\av_mux.ps1"
Assert-FileExists $avMux "av_mux.ps1 exista"
$content = Get-Content -Raw $avMux

# Input/output list
if ($content -match 'SupportedInputExt\s*=\s*@\("mkv","webm","mp4","m4v","mov","ts","m2ts","mts","vob","mxf"\)') { _pass } else { _fail "Input list completa: mkv/webm/mp4/m4v/mov/ts/m2ts/mts/vob/mxf" }
if ($content -match 'SupportedOutputExt\s*=\s*@\("mkv","mp4","mov","webm"\)') { _pass } else { _fail "Output list: mkv/mp4/mov/webm" }

# Functii cheie remux
if ($content -match 'function Show-RemuxStreamSelection') { _pass } else { _fail "Show-RemuxStreamSelection function present" }
if ($content -match 'function Invoke-RemuxFile')          { _pass } else { _fail "Invoke-RemuxFile function present" }
if ($content -match 'function ConvertFrom-Selection')     { _pass } else { _fail "ConvertFrom-Selection helper present" }
if ($content -match 'Get-RemuxStreamCompat')              { _pass } else { _fail "Get-RemuxStreamCompat invocat" }

# Output naming _remux
if ($content -match '_remux\.') { _pass } else { _fail "Output naming _remux.<ext>" }

# Map flags per-rel
if ($content -match '0:v:\$r') { _pass } else { _fail "video stream mapping per-rel" }
if ($content -match '0:a:\$r') { _pass } else { _fail "audio stream mapping per-rel" }

# Batch summary
if ($content -match 'REMUX BATCH SUMMARY') { _pass } else { _fail "batch summary header" }

# v49: Submenu + demux flow markers
if ($content -match 'MUX TOOLS')                     { _pass } else { _fail "submenu MUX TOOLS prezent" }
if ($content -match 'function Invoke-RemuxFlow')     { _pass } else { _fail "Invoke-RemuxFlow wrapper prezent" }
if ($content -match 'function Invoke-DemuxFlow')     { _pass } else { _fail "Invoke-DemuxFlow function prezent" }
if ($content -match 'function Show-DemuxStreamSelection') { _pass } else { _fail "Show-DemuxStreamSelection prezent" }
if ($content -match 'function Invoke-DemuxFile')     { _pass } else { _fail "Invoke-DemuxFile prezent" }
if ($content -match 'function Get-DemuxSubtitleExt') { _pass } else { _fail "Get-DemuxSubtitleExt helper prezent" }
if ($content -match 'function Get-DemuxCoverExt')    { _pass } else { _fail "Get-DemuxCoverExt helper prezent" }
if ($content -match 'function Get-DemuxSpecialStreams') { _pass } else { _fail "Get-DemuxSpecialStreams prezent" }
if ($content -match 'function New-ChaptersXml')      { _pass } else { _fail "New-ChaptersXml generator prezent" }
if ($content -match '_chapters\.xml')                { _pass } else { _fail "chapters output naming" }
if ($content -match '_attach')                       { _pass } else { _fail "attach folder output" }
if ($content -match '_data')                         { _pass } else { _fail "data folder output" }

# ─────────────────────────────────────────────────────────────────
# 3b) Demux helpers — pure logic (subtitle/cover ext mapping)
# Redefinim local (mirror al definitiilor din av_mux.ps1)
# ─────────────────────────────────────────────────────────────────
function Get-DemuxSubtitleExt {
    param([string]$Codec)
    switch ($Codec.ToLowerInvariant()) {
        "subrip"            { return "srt" }
        "srt"               { return "srt" }
        "ass"               { return "ass" }
        "ssa"               { return "ass" }
        "webvtt"            { return "vtt" }
        "hdmv_pgs_subtitle" { return "sup" }
        "dvd_subtitle"      { return "sub" }
        "mov_text"          { return "srt" }
        "tx3g"              { return "srt" }
        default             { return "bin" }
    }
}
function Get-DemuxCoverExt {
    param([string]$Codec)
    switch ($Codec.ToLowerInvariant()) {
        "mjpeg" { return "jpg" }
        "jpeg"  { return "jpg" }
        "png"   { return "png" }
        "webp"  { return "webp" }
        "bmp"   { return "bmp" }
        default { return "img" }
    }
}

Assert-Eq "srt" (Get-DemuxSubtitleExt -Codec "subrip")            "demux ext: subrip -> srt"
Assert-Eq "srt" (Get-DemuxSubtitleExt -Codec "SRT")               "demux ext: SRT (case-insensitive) -> srt"
Assert-Eq "ass" (Get-DemuxSubtitleExt -Codec "ass")               "demux ext: ass -> ass"
Assert-Eq "ass" (Get-DemuxSubtitleExt -Codec "ssa")               "demux ext: ssa -> ass"
Assert-Eq "vtt" (Get-DemuxSubtitleExt -Codec "webvtt")            "demux ext: webvtt -> vtt"
Assert-Eq "sup" (Get-DemuxSubtitleExt -Codec "hdmv_pgs_subtitle") "demux ext: PGS -> sup"
Assert-Eq "sub" (Get-DemuxSubtitleExt -Codec "dvd_subtitle")      "demux ext: VobSub -> sub"
Assert-Eq "srt" (Get-DemuxSubtitleExt -Codec "mov_text")          "demux ext: mov_text -> srt (convert)"
Assert-Eq "srt" (Get-DemuxSubtitleExt -Codec "tx3g")              "demux ext: tx3g -> srt (convert)"
Assert-Eq "bin" (Get-DemuxSubtitleExt -Codec "fubar")             "demux ext: unknown -> bin"

Assert-Eq "jpg"  (Get-DemuxCoverExt -Codec "mjpeg") "cover ext: mjpeg -> jpg"
Assert-Eq "jpg"  (Get-DemuxCoverExt -Codec "jpeg")  "cover ext: jpeg -> jpg"
Assert-Eq "png"  (Get-DemuxCoverExt -Codec "png")   "cover ext: png -> png"
Assert-Eq "webp" (Get-DemuxCoverExt -Codec "webp")  "cover ext: webp -> webp"
Assert-Eq "img"  (Get-DemuxCoverExt -Codec "fubar") "cover ext: unknown -> img"

# ─────────────────────────────────────────────────────────────────
# 4) ConvertFrom-Selection — sintaxa selectie (importa local)
# ─────────────────────────────────────────────────────────────────
function ConvertFrom-Selection {
    param([string]$Text, [int]$Max)
    $clean = ($Text -replace '\s', '')
    if ([string]::IsNullOrEmpty($clean) -or $clean -match '^(?i)all$') {
        if ($Max -le 0) { return @() }
        return @(0..($Max-1))
    }
    if ($clean -match '^(?i)none$') { return @() }
    $out = New-Object System.Collections.Generic.List[int]
    foreach ($p in ($clean -split ',')) {
        if ($p -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            for ($i = $a-1; $i -le $b-1; $i++) {
                if ($i -ge 0 -and $i -lt $Max) { $out.Add($i) | Out-Null }
            }
        } elseif ($p -match '^\d+$') {
            $i = [int]$p - 1
            if ($i -ge 0 -and $i -lt $Max) { $out.Add($i) | Out-Null }
        } else {
            return $null
        }
    }
    return ,@($out)
}

$r = ConvertFrom-Selection -Text "ALL" -Max 3
Assert-Eq 3 $r.Count "parse: ALL -> 3 items"
Assert-Eq 0 $r[0] "parse: ALL[0]=0"
Assert-Eq 2 $r[2] "parse: ALL[2]=2"

$r = ConvertFrom-Selection -Text "" -Max 3
Assert-Eq 3 $r.Count "parse: empty -> ALL (3 items)"

$r = ConvertFrom-Selection -Text "NONE" -Max 3
Assert-Eq 0 $r.Count "parse: NONE -> 0 items"

$r = ConvertFrom-Selection -Text "1,3" -Max 5
Assert-Eq 2 $r.Count "parse: 1,3 -> 2 items"
Assert-Eq 0 $r[0] "parse: 1,3 [0]=0"
Assert-Eq 2 $r[1] "parse: 1,3 [1]=2"

$r = ConvertFrom-Selection -Text "1-3" -Max 5
Assert-Eq 3 $r.Count "parse: 1-3 -> 3 items"

$r = ConvertFrom-Selection -Text "1,3-4" -Max 5
Assert-Eq 3 $r.Count "parse: 1,3-4 -> 3 items"

$r = ConvertFrom-Selection -Text "99" -Max 3
Assert-Eq 0 $r.Count "parse: 99 (out of range) -> 0 items"

$r = ConvertFrom-Selection -Text "abc" -Max 3
if ($null -eq $r) { _pass } else { _fail "parse: invalid -> null" }

# ─────────────────────────────────────────────────────────────────
# 5) Invoke-HdrDvTools refactor — submeniu fara Remux + dispatch av_mux
# ─────────────────────────────────────────────────────────────────
$avEncode = Join-Path $PSScriptRoot "..\..\src\av_encode.ps1"
Assert-FileExists $avEncode "av_encode.ps1 exista"
$encContent = Get-Content -Raw $avEncode

# Invoke-RemuxContainer trebuie sa fie sters (UI flow vechi)
if ($encContent -match 'function Invoke-RemuxContainer') { _fail "Invoke-RemuxContainer (UI vechi) trebuie sters" } else { _pass }

# Invoke-HdrDvTools cu 7 optiuni (v56: extins de la 4 la 7; "Alege 1-7" e unic in fisier)
if ($encContent -match 'Alege 1-7') { _pass } else { _fail "Invoke-HdrDvTools cu prompt 1-7 (v56)" }
# Nota redirect catre Mux tools (av_mux)
if ($encContent -match 'optiunea 7|Mux tools') { _pass } else { _fail "redirect note pentru Mux tools" }

# Main menu cu 10 optiuni si dispatch av_mux.ps1
if ($encContent -match '10-Iesire') { _pass } else { _fail "Main menu 10-Iesire" }
if ($encContent -match 'av_mux\.ps1') { _pass } else { _fail "Main menu dispatch av_mux.ps1" }

# Invoke-Remux (worker) pastrat pentru back-compat
if ($encContent -match 'function Invoke-Remux\b') { _pass } else { _fail "Invoke-Remux worker pastrat" }
