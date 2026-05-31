# v59 Mux audit — PS1 mirror
# - csv=p=0 multi-field TrimEnd(',') (HDR sources)
# - Demux attach dedup
# - Chapters XML validation cu LastChapterParseError
. "$PSScriptRoot\..\framework.ps1"

$PROJECT_ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$MUX_PS1   = Join-Path $PROJECT_ROOT "src\av_mux.ps1"
$MUX_TXT   = Get-Content $MUX_PS1 -Raw

# ── AST parse OK ────────────────────────────────────────────────
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($MUX_PS1, [ref]$null, [ref]$errs)
Assert-Eq 0 $errs.Count "av_mux.ps1 AST parse fara erori"

# ── 1. csv TrimEnd(',') markers ─────────────────────────────────
# Folosim .Contains() pentru a evita escape pe [] (interpretate ca char class in -clike)
Assert-Eq $true ($MUX_TXT.Contains('$parts[5].TrimEnd(')) "Get-RemuxStreams video: TrimEnd pe title"
Assert-Eq $true ($MUX_TXT.Contains('$parts[4].TrimEnd(')) "Get-RemuxStreams audio: TrimEnd pe title"
Assert-Eq $true ($MUX_TXT.Contains('$parts[3].TrimEnd(')) "Get-RemuxStreams subtitle: TrimEnd pe title"
Assert-Eq $true ($MUX_TXT.Contains('$parts[2].TrimEnd(')) "Get-RemuxStreams attachment: TrimEnd pe title"
Assert-Eq $true ($MUX_TXT.Contains('$parts[2].Trim().TrimEnd(')) "Get-DemuxSpecialStreams: cover disp TrimEnd"
Assert-Eq $true ($MUX_TXT.Contains('$parts[1].Trim().TrimEnd(')) "Get-DemuxSpecialStreams: data tag TrimEnd"

# ── 2. Functional test pe TrimEnd ───────────────────────────────
Assert-Eq "0"     "0,".TrimEnd(',')    "TrimEnd: '0,' -> '0'"
Assert-Eq "1"     "1,".TrimEnd(',')    "TrimEnd: '1,' (cover art HDR file) -> '1'"
Assert-Eq "Title" "Title".TrimEnd(',') "TrimEnd: 'Title' (no comma) -> 'Title' unchanged"
Assert-Eq "Title" "Title,".TrimEnd(',') "TrimEnd: 'Title,' -> 'Title'"

# ── 3. Demux attach dedup ───────────────────────────────────────
Assert-Contains $MUX_TXT 'Get-SanitizedFilename -Text $rawName' "Demux attach: sanitize name"
Assert-Contains $MUX_TXT 'do {' "Demux attach: do-while dedup loop"
Assert-Contains $MUX_TXT '-dump_attachment:t:$t $target' "Demux attach: path explicit (nu CWD-based)"
# Verifica ca NU mai e Set-Location patternul vechi
$cwdPattern = ([regex]'Set-Location -LiteralPath \$attachDir').Matches($MUX_TXT).Count
Assert-Eq 0 $cwdPattern "Demux attach: vechiul Set-Location CWD pattern eliminat"

# ── 4. Chapters XML validation strict ───────────────────────────
Assert-Contains $MUX_TXT '$script:LastChapterParseError' "Convert-XmlChaptersToFFMetadata: error var"
Assert-Contains $MUX_TXT '"fisier inexistent"' "validation: fisier inexistent"
Assert-Contains $MUX_TXT '"XML gol"' "validation: XML gol"
Assert-Contains $MUX_TXT '"niciun <ChapterAtom> in XML"' "validation: no atom"
Assert-Contains $MUX_TXT '"ChapterAtom prezent dar fara' "validation: no valid TS"
Assert-Contains $MUX_TXT 'XML malformat' "validation: parse exception"

# Caller propaga motiv
Assert-Contains $MUX_TXT 'Motiv: $($script:LastChapterParseError)' "Caller: afiseaza motiv user-facing"

# ── 5. Functional test pe Convert-XmlChaptersToFFMetadata ───────
# Extract function via AST
$astTokens = $null; $astErrs = $null
$muxAst = [System.Management.Automation.Language.Parser]::ParseFile($MUX_PS1, [ref]$astTokens, [ref]$astErrs)
$fnAst = $muxAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Convert-XmlChaptersToFFMetadata' }, $true)
Assert-Eq $true ($fnAst -ne $null) "AST: Convert-XmlChaptersToFFMetadata gasita"

if ($fnAst) {
    Set-Item function:Global:Convert-XmlChaptersToFFMetadata $fnAst.Body.GetScriptBlock()

    $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "av_mux_test_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        # 5a) Fisier inexistent
        $rc = Convert-XmlChaptersToFFMetadata -XmlIn (Join-Path $tmp "nope.xml") -OutFile (Join-Path $tmp "out.ffmeta")
        Assert-Eq $false $rc "fisier inexistent: false"
        Assert-Eq "fisier inexistent" $script:LastChapterParseError "fisier inexistent: motiv corect"

        # 5b) Fisier gol
        Set-Content -Path (Join-Path $tmp "empty.xml") -Value "" -NoNewline
        $rc = Convert-XmlChaptersToFFMetadata -XmlIn (Join-Path $tmp "empty.xml") -OutFile (Join-Path $tmp "out.ffmeta")
        Assert-Eq $false $rc "fisier gol: false"
        Assert-Eq "XML gol" $script:LastChapterParseError "fisier gol: motiv corect"

        # 5c) XML malformat
        Set-Content -Path (Join-Path $tmp "bad.xml") -Value "<not-closed>"
        $rc = Convert-XmlChaptersToFFMetadata -XmlIn (Join-Path $tmp "bad.xml") -OutFile (Join-Path $tmp "out.ffmeta")
        Assert-Eq $false $rc "XML malformat: false"
        Assert-Contains $script:LastChapterParseError "XML malformat" "XML malformat: motiv corect"

        # 5d) XML cu Chapters dar fara ChapterAtom
        Set-Content -Path (Join-Path $tmp "no_atom.xml") -Value '<?xml version="1.0"?><Chapters><EditionEntry/></Chapters>'
        $rc = Convert-XmlChaptersToFFMetadata -XmlIn (Join-Path $tmp "no_atom.xml") -OutFile (Join-Path $tmp "out.ffmeta")
        Assert-Eq $false $rc "no atom: false"
        Assert-Contains $script:LastChapterParseError "niciun <ChapterAtom>" "no atom: motiv corect"

        # 5e) XML valid
        $validXml = @'
<?xml version="1.0"?>
<Chapters>
  <EditionEntry>
    <ChapterAtom>
      <ChapterTimeStart>00:00:00.000000000</ChapterTimeStart>
      <ChapterTimeEnd>00:00:10.500000000</ChapterTimeEnd>
      <ChapterDisplay>
        <ChapterString>Intro</ChapterString>
        <ChapterLanguage>eng</ChapterLanguage>
      </ChapterDisplay>
    </ChapterAtom>
    <ChapterAtom>
      <ChapterTimeStart>00:00:10.500000000</ChapterTimeStart>
      <ChapterTimeEnd>00:00:25.000000000</ChapterTimeEnd>
      <ChapterDisplay>
        <ChapterString>Scene 1</ChapterString>
        <ChapterLanguage>eng</ChapterLanguage>
      </ChapterDisplay>
    </ChapterAtom>
  </EditionEntry>
</Chapters>
'@
        Set-Content -Path (Join-Path $tmp "valid.xml") -Value $validXml
        $outFile = Join-Path $tmp "valid.ffmeta"
        $rc = Convert-XmlChaptersToFFMetadata -XmlIn (Join-Path $tmp "valid.xml") -OutFile $outFile
        Assert-Eq $true $rc "XML valid: true"
        Assert-Eq $true (Test-Path $outFile) "output produs"
        $content = Get-Content $outFile -Raw
        Assert-Contains $content "[CHAPTER]" "valid: contine [CHAPTER]"
        Assert-Contains $content "title=Intro" "valid: titlu Intro emis"
        Assert-Contains $content "TIMEBASE=1/1000" "valid: TIMEBASE corect"
        Assert-Contains $content "START=0" "valid: START 0 ms"
        Assert-Contains $content "END=10500" "valid: END 10500 ms"
        Assert-Contains $content "title=Scene 1" "valid: titlu Scene 1 emis"
        $nChapters = ([regex]'\[CHAPTER\]').Matches($content).Count
        Assert-Eq 2 $nChapters "valid: 2 [CHAPTER] blocks emise"

        # 5f) XML cu ChapterAtom dar fara timestamp-uri valide
        $noTsXml = @'
<?xml version="1.0"?>
<Chapters>
  <EditionEntry>
    <ChapterAtom>
      <ChapterDisplay><ChapterString>Bad</ChapterString></ChapterDisplay>
    </ChapterAtom>
  </EditionEntry>
</Chapters>
'@
        Set-Content -Path (Join-Path $tmp "no_ts.xml") -Value $noTsXml
        $rc = Convert-XmlChaptersToFFMetadata -XmlIn (Join-Path $tmp "no_ts.xml") -OutFile (Join-Path $tmp "out.ffmeta")
        Assert-Eq $false $rc "atom fara TS: false"
        Assert-Contains $script:LastChapterParseError "fara ChapterTimeStart" "atom fara TS: motiv corect"
    } finally {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ── 6. v59 post-audit: Get-MuxCodec switch la default= (fix tip v57) ──
$muxCodecFn = $muxAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-MuxCodec' }, $true)
Assert-Eq $true ($muxCodecFn -ne $null) "AST: Get-MuxCodec gasita"
$muxCodecText = $muxCodecFn.Extent.Text
Assert-Eq $true ($muxCodecText.Contains('default=noprint_wrappers=1:nokey=1')) "Get-MuxCodec: foloseste default= (v59 audit)"
Assert-Eq $true (-not $muxCodecText.Contains('csv=p=0')) "Get-MuxCodec: nu mai foloseste csv=p=0"

# ── 7. v59 post-audit: namespace XML XPath (local-name()) ──
Assert-Eq $true ($MUX_TXT.Contains("local-name()='ChapterAtom'")) "Convert-XmlChaptersToFFMetadata: XPath local-name pentru namespace"
Assert-Eq $true ($MUX_TXT.Contains("local-name()='ChapterDisplay'")) "Convert-XmlChaptersToFFMetadata: ChapterDisplay namespace-agnostic"

# Functional test pentru namespace XML — testeaza efectiv ca XPath functioneaza
$tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "v59_ns_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $nsXml = '<?xml version="1.0"?><Chapters xmlns="http://www.matroska.org/chapters"><EditionEntry><ChapterAtom><ChapterTimeStart>00:00:00.000000000</ChapterTimeStart><ChapterTimeEnd>00:00:10.000000000</ChapterTimeEnd><ChapterDisplay><ChapterString>NSChap</ChapterString></ChapterDisplay></ChapterAtom></EditionEntry></Chapters>'
    Set-Content -Path (Join-Path $tmp "ns.xml") -Value $nsXml
    $rcNs = Convert-XmlChaptersToFFMetadata -XmlIn (Join-Path $tmp "ns.xml") -OutFile (Join-Path $tmp "ns.ffmeta")
    Assert-Eq $true $rcNs "namespace XML: rc=true (XPath namespace-agnostic functioneaza)"
    if ($rcNs) {
        $content = Get-Content (Join-Path $tmp "ns.ffmeta") -Raw
        Assert-Contains $content "title=NSChap" "namespace XML: titlu extras corect"
        Assert-Contains $content "START=0" "namespace XML: START parsed"
        Assert-Contains $content "END=10000" "namespace XML: END parsed"
    }
} finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ── 8. Integration smoke pe HDR10+ HEVC sample (skip if missing) ─
$sample = Join-Path $PROJECT_ROOT "src\Upload_S02E01_HDR10Plus_40s_HEVC.mp4"
if ((Get-Command "ffprobe" -ErrorAction SilentlyContinue) -and (Test-Path $sample)) {
    $remuxFn = $muxAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-RemuxStreams' }, $true)
    if ($remuxFn) {
        Set-Item function:Global:Get-RemuxStreams $remuxFn.Body.GetScriptBlock()
        $streams = Get-RemuxStreams -File $sample
        Assert-Eq 1 $streams.Video.Count "integration HDR10+: 1 video stream"
        Assert-Eq 1 $streams.Audio.Count "integration HDR10+: 1 audio stream"
        # Title-urile NU trebuie sa aiba trailing comma
        foreach ($v in $streams.Video) {
            $hasComma = $v.Title -match ',$'
            Assert-Eq $false $hasComma "integration video title fara trailing comma: '$($v.Title)'"
        }
    }
}

Invoke-TestSummary
