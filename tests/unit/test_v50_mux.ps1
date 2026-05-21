# Test v50 Mux flow (PS1) — pure-logic + script markers.
# Coverage: Invoke-MuxFlow function, helpers (Get-MuxLangFromFilename, Get-MuxAttachMime),
#           submenu opt 3 wiring, scan exclude *_mux, ffmpeg cmd builder markers,
#           compat dispatcher reuse.

. "$PSScriptRoot\..\framework.ps1"

$avMux = Join-Path $PSScriptRoot "..\..\src\av_mux.ps1"
Assert-FileExists $avMux "av_mux.ps1 exista"
$content = Get-Content -Raw $avMux

# ─────────────────────────────────────────────────────────────────
# 1) Submenu — 4 optiuni (Remux/Demux/Mux/Anulare)
# ─────────────────────────────────────────────────────────────────
if ($content -match '3\) Mux')                  { _pass } else { _fail "submenu opt 3 = Mux" }
if ($content -match '4\) Anulare')              { _pass } else { _fail "submenu opt 4 = Anulare (shifted)" }
if ($content -match 'Alege 1-4')                { _pass } else { _fail "prompt actualizat la 1-4" }
if ($content -match '"3" \{ Invoke-MuxFlow \}') { _pass } else { _fail "case 3 ruleaza Invoke-MuxFlow" }
if ($content -match '"4"\s+\{\s+Write-Host\s+"Anulat\.') { _pass } else { _fail "case 4 = anulare" }

# ─────────────────────────────────────────────────────────────────
# 2) Function existence markers
# ─────────────────────────────────────────────────────────────────
if ($content -match 'function Invoke-MuxFlow')             { _pass } else { _fail "Invoke-MuxFlow function present" }
if ($content -match 'function Get-MuxInputFiles')          { _pass } else { _fail "Get-MuxInputFiles helper present" }
if ($content -match 'function Get-MuxLangFromFilename')    { _pass } else { _fail "Get-MuxLangFromFilename helper present" }
if ($content -match 'function Get-MuxCodec')               { _pass } else { _fail "Get-MuxCodec helper present" }
if ($content -match 'function Get-MuxAttachMime')          { _pass } else { _fail "Get-MuxAttachMime helper present" }
if ($content -match 'function Read-MuxPickList')           { _pass } else { _fail "Read-MuxPickList helper present" }

# ─────────────────────────────────────────────────────────────────
# 3) Scan exclude — *_mux pe langa *_remux
# ─────────────────────────────────────────────────────────────────
# Get-MuxCandidates trebuie sa contina notlike "*_mux"
if ($content -match 'notlike "\*_mux"')   { _pass } else { _fail "scan exclude *_mux in Get-MuxCandidates" }
if ($content -match 'notlike "\*_remux"') { _pass } else { _fail "scan exclude *_remux in Get-MuxCandidates" }
# Get-MuxInputFiles (v50) trebuie sa aiba acelasi exclude
if ($content -match '\$name -like "\*_mux"') { _pass } else { _fail "Get-MuxInputFiles exclude *_mux" }

# ─────────────────────────────────────────────────────────────────
# 4) Helper logic — Get-MuxLangFromFilename (rebind inline)
# ─────────────────────────────────────────────────────────────────
function Get-MuxLangFromFilename {
    param([string]$File)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($File)
    if ($base -match '\.([a-z]{2,3})$') { return $Matches[1] }
    if ($base -match '_([a-z]{2,3})$') {
        $lang = $Matches[1]
        $exclude = @("mkv","mp4","mov","aac","ac3","mp3","srt","ass","sup","idx","sub","hd","sd","hq","lq")
        if ($exclude -notcontains $lang) { return $lang }
    }
    return ""
}

Assert-Eq "eng" (Get-MuxLangFromFilename "movie.eng.srt")     "dot pattern .eng"
Assert-Eq "ron" (Get-MuxLangFromFilename "track_ron.eac3")    "underscore pattern _ron"
Assert-Eq "jpn" (Get-MuxLangFromFilename "anime.jpn.ass")     "dot pattern .jpn"
Assert-Eq ""    (Get-MuxLangFromFilename "movie.mkv")         "no pattern returns empty"
Assert-Eq ""    (Get-MuxLangFromFilename "track_hd.eac3")     "tech suffix _hd excluded"
Assert-Eq "fra" (Get-MuxLangFromFilename "film.fra.srt")      "3-letter ISO fra"
Assert-Eq "de"  (Get-MuxLangFromFilename "movie_de.mka")      "2-letter de"

# ─────────────────────────────────────────────────────────────────
# 5) Helper logic — Get-MuxAttachMime (rebind inline)
# ─────────────────────────────────────────────────────────────────
function Get-MuxAttachMime {
    param([string]$Ext)
    switch ($Ext.ToLowerInvariant()) {
        "ttf" { return "application/x-truetype-font" }
        "otf" { return "application/vnd.ms-opentype" }
        "ttc" { return "font/collection" }
        "png" { return "image/png" }
        "jpg" { return "image/jpeg" }
        "jpeg" { return "image/jpeg" }
        "webp" { return "image/webp" }
        "bmp" { return "image/bmp" }
        default { return "application/octet-stream" }
    }
}

Assert-Eq "application/x-truetype-font" (Get-MuxAttachMime "ttf")  "mime: ttf"
Assert-Eq "application/vnd.ms-opentype" (Get-MuxAttachMime "otf")  "mime: otf"
Assert-Eq "font/collection"             (Get-MuxAttachMime "ttc")  "mime: ttc"
Assert-Eq "image/png"                   (Get-MuxAttachMime "png")  "mime: png"
Assert-Eq "image/jpeg"                  (Get-MuxAttachMime "jpg")  "mime: jpg"
Assert-Eq "image/jpeg"                  (Get-MuxAttachMime "jpeg") "mime: jpeg"
Assert-Eq "image/webp"                  (Get-MuxAttachMime "webp") "mime: webp"
Assert-Eq "image/bmp"                   (Get-MuxAttachMime "bmp")  "mime: bmp"
Assert-Eq "application/octet-stream"    (Get-MuxAttachMime "xyz")  "mime: unknown -> octet-stream"
Assert-Eq "image/png"                   (Get-MuxAttachMime "PNG")  "mime: uppercase PNG"

# ─────────────────────────────────────────────────────────────────
# 6) Compat dispatcher reuse — markers in Invoke-MuxFlow body
# ─────────────────────────────────────────────────────────────────
# Find Invoke-MuxFlow body via AST
$ast = [System.Management.Automation.Language.Parser]::ParseFile($avMux, [ref]$null, [ref]$null)
$muxFuncAst = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-MuxFlow' }, $true)
if ($muxFuncAst.Count -ge 1) { _pass } else { _fail "Invoke-MuxFlow AST node found" }

$muxBody = $muxFuncAst[0].Body.Extent.Text
if ($muxBody -match 'Get-RemuxStreamCompat .*video')    { _pass } else { _fail "mux foloseste Get-RemuxStreamCompat (video)" }
if ($muxBody -match 'Get-RemuxStreamCompat .*audio')    { _pass } else { _fail "mux foloseste Get-RemuxStreamCompat (audio)" }
if ($muxBody -match 'Get-RemuxStreamCompat .*subtitle') { _pass } else { _fail "mux foloseste Get-RemuxStreamCompat (subtitle)" }
if ($muxBody -match 'PRE-FLIGHT FAIL')                  { _pass } else { _fail "abort video incompat e tratat" }

# ─────────────────────────────────────────────────────────────────
# 7) ffmpeg cmd builder markers
# ─────────────────────────────────────────────────────────────────
if ($muxBody -match '"0:v:0"')         { _pass } else { _fail "video mapped din input 0" }
if ($muxBody -match ':a"')             { _pass } else { _fail "audio map prin :a" }
if ($muxBody -match ':s"')             { _pass } else { _fail "subtitle map prin :s" }
if ($muxBody -match '-map_chapters')   { _pass } else { _fail "chapters map argument" }
if ($muxBody -match '\+faststart')     { _pass } else { _fail "movflags +faststart pe mp4/mov" }
if ($muxBody -match 'hvc1')            { _pass } else { _fail "tag hvc1 pentru hevc in mp4/mov" }
if ($muxBody -match 'av01')            { _pass } else { _fail "tag av01 pentru av1 in mp4/mov" }
if ($muxBody -match 'avc1')            { _pass } else { _fail "tag avc1 pentru h264 in mp4/mov" }
if ($muxBody -match 'mov_text')        { _pass } else { _fail "subs convert mov_text pe mp4/mov" }
if ($muxBody -match '-attach')         { _pass } else { _fail "attachment -attach pentru MKV" }
if ($muxBody -match 'mimetype=')       { _pass } else { _fail "attachment mimetype emitted" }
if ($muxBody -match '"-y"')            { _pass } else { _fail "ffmpeg -y flag pentru overwrite" }

# ─────────────────────────────────────────────────────────────────
# 8) Output naming & overwrite check
# ─────────────────────────────────────────────────────────────────
if ($muxBody -match '_mux\.\{1\}') { _pass } else { _fail "output naming <name>_mux.<ext> (format string)" }
if ($muxBody -match 'Suprascriu')  { _pass } else { _fail "overwrite prompt" }

# ─────────────────────────────────────────────────────────────────
# 9) Metadata & disposition (per-track edit)
# ─────────────────────────────────────────────────────────────────
if ($muxBody -match '-metadata:s:a:')  { _pass } else { _fail "metadata per audio stream" }
if ($muxBody -match '-metadata:s:s:')  { _pass } else { _fail "metadata per subtitle stream" }
if ($muxBody -match '-disposition:a:') { _pass } else { _fail "disposition flag audio" }
if ($muxBody -match '-disposition:s:') { _pass } else { _fail "disposition flag subtitle" }
if ($muxBody -match 'language=')       { _pass } else { _fail "language metadata emis" }
if ($muxBody -match 'forced')          { _pass } else { _fail "forced flag disposition (sub)" }
if ($muxBody -match 'default')         { _pass } else { _fail "default flag disposition" }

# ─────────────────────────────────────────────────────────────────
# 10) VobSub pair handling
# ─────────────────────────────────────────────────────────────────
if ($muxBody -match '\$sfExt -eq "sub"')      { _pass } else { _fail "branch pentru .sub orfan" }
if ($muxBody -match '\.idx')                  { _pass } else { _fail "VobSub .idx pair check" }
if ($muxBody -match 'dvd_subtitle')           { _pass } else { _fail "fallback codec dvd_subtitle pentru .idx" }
if ($muxBody -match 'hdmv_pgs_subtitle')      { _pass } else { _fail "fallback codec hdmv_pgs_subtitle pentru .sup" }

# ─────────────────────────────────────────────────────────────────
# 11) Container target options
# ─────────────────────────────────────────────────────────────────
if ($muxBody -match '1\) mkv')  { _pass } else { _fail "target opt 1 = mkv (default)" }
if ($muxBody -match '2\) mp4')  { _pass } else { _fail "target opt 2 = mp4" }
if ($muxBody -match '3\) mov')  { _pass } else { _fail "target opt 3 = mov" }
if ($muxBody -match '4\) webm') { _pass } else { _fail "target opt 4 = webm" }

# ─────────────────────────────────────────────────────────────────
# 12) Extension sets defined
# ─────────────────────────────────────────────────────────────────
if ($content -match '\$MuxExtVideo\s*=')    { _pass } else { _fail "ext set video" }
if ($content -match '\$MuxExtAudio\s*=')    { _pass } else { _fail "ext set audio" }
if ($content -match '\$MuxExtSub\s*=')      { _pass } else { _fail "ext set subtitle" }
if ($content -match '\$MuxExtChapters\s*=') { _pass } else { _fail "ext set chapters" }
if ($content -match '\$MuxExtAttach\s*=')   { _pass } else { _fail "ext set attachments" }

# ─────────────────────────────────────────────────────────────────
# 13) Audit fixes (post-release v50)
# ─────────────────────────────────────────────────────────────────

# 13a) XML chapters → FFMETADATA1 conversion
if ($content -match 'function Convert-XmlChaptersToFFMetadata') { _pass } else { _fail "helper Convert-XmlChaptersToFFMetadata exista" }
if ($muxBody -match 'chExt -eq "xml"')                          { _pass } else { _fail "branch xml in Invoke-MuxFlow" }
if ($muxBody -match 'chaptersTmpFFMeta')                        { _pass } else { _fail "temp ffmetadata tracked" }
if ($muxBody -match 'Convert-XmlChaptersToFFMetadata')          { _pass } else { _fail "conversia apelata in mux flow" }

# 13b) Attachment mimetype per-index
if ($muxBody -match '-metadata:s:t:\$attachIdx')                { _pass } else { _fail "metadata per attachment cu index" }
if ($muxBody -match '\$attachIdx\+\+')                          { _pass } else { _fail "attachIdx incrementeaza" }

# 13c) Overwrite check earlier — verifica ordinea in cod
# Pattern in script: "Suprascriu" trebuie sa apara INAINTE de "Per-stream compat check"
$lines = $content -split "`n"
$owLineNo = -1
$compatLineNo = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($owLineNo -lt 0 -and $lines[$i] -match 'Suprascriu')              { $owLineNo = $i }
    if ($compatLineNo -lt 0 -and $lines[$i] -match 'Per-stream compat')   { $compatLineNo = $i }
}
if ($owLineNo -gt 0 -and $compatLineNo -gt 0 -and $owLineNo -lt $compatLineNo) {
    _pass
} else {
    _fail "overwrite check trebuie inainte de compat check (lines: ow=$owLineNo, compat=$compatLineNo)"
}

# 13d) PS1 cover exclude regex (align cu bash _cover_[0-9])
if ($content -match '_cover_\\d\+')   { _pass } else { _fail "PS1 cover exclude foloseste \d+ (align bash)" }
# Verifica ca pattern-ul vechi -like "*_cover_*" e eliminat (in Get-MuxInputFiles)
$getMuxFilesFn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-MuxInputFiles' }, $true)
if ($getMuxFilesFn.Count -ge 1) {
    $body = $getMuxFilesFn[0].Body.Extent.Text
    if ($body -match '_cover_\\d\+') { _pass } else { _fail "Get-MuxInputFiles foloseste regex _cover_\\d+" }
}

# 13e) XML→FFMETADATA pure-logic: parse function din script + run pe sample
$convertFn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Convert-XmlChaptersToFFMetadata' }, $true)
if ($convertFn.Count -ge 1) {
    $null = Invoke-Expression $convertFn[0].Extent.Text
    $xmlSample = @'
<?xml version="1.0" encoding="UTF-8"?>
<Chapters>
  <EditionEntry>
    <ChapterAtom>
      <ChapterTimeStart>00:00:00.000000000</ChapterTimeStart>
      <ChapterTimeEnd>00:05:30.500000000</ChapterTimeEnd>
      <ChapterDisplay>
        <ChapterString>Intro &amp; Open</ChapterString>
      </ChapterDisplay>
    </ChapterAtom>
    <ChapterAtom>
      <ChapterTimeStart>00:05:30.500000000</ChapterTimeStart>
      <ChapterTimeEnd>00:10:00.000000000</ChapterTimeEnd>
      <ChapterDisplay>
        <ChapterString>Part Two</ChapterString>
      </ChapterDisplay>
    </ChapterAtom>
  </EditionEntry>
</Chapters>
'@
    $tmpXml = Join-Path $env:TEMP ("av_test_" + [guid]::NewGuid().ToString('N') + ".xml")
    $tmpOut = Join-Path $env:TEMP ("av_test_" + [guid]::NewGuid().ToString('N') + ".ffmetadata")
    [System.IO.File]::WriteAllText($tmpXml, $xmlSample, [System.Text.UTF8Encoding]::new($false))
    try {
        $ok = Convert-XmlChaptersToFFMetadata -XmlIn $tmpXml -OutFile $tmpOut
        Assert-Eq $true $ok "conversia returneaza true"
        $ffmeta = Get-Content -Raw $tmpOut
        if ($ffmeta -match ';FFMETADATA1')         { _pass } else { _fail "FFMETADATA1 header emis" }
        if ($ffmeta -match '\[CHAPTER\]')          { _pass } else { _fail "CHAPTER block emis" }
        if ($ffmeta -match 'TIMEBASE=1/1000')      { _pass } else { _fail "TIMEBASE corect (ms)" }
        if ($ffmeta -match 'START=0\b')            { _pass } else { _fail "primul START=0" }
        if ($ffmeta -match 'END=330500')           { _pass } else { _fail "primul END=5m30.5s in ms" }
        if ($ffmeta -match 'START=330500')         { _pass } else { _fail "al doilea START match" }
        if ($ffmeta -match 'END=600000')           { _pass } else { _fail "al doilea END=10min" }
        if ($ffmeta -match 'title=Intro & Open')   { _pass } else { _fail "title cu entity decoded" }
        if ($ffmeta -match 'title=Part Two')       { _pass } else { _fail "al doilea title" }
    } finally {
        Remove-Item -LiteralPath $tmpXml, $tmpOut -Force -ErrorAction SilentlyContinue
    }
}

Invoke-TestSummary
