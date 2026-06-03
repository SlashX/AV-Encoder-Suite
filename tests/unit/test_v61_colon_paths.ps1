# v61: fix Windows drive-colon in parametri `:`-separati ai encoderului
# (x265 dhdr10-info / svtav1 hdr10plus-json / stats=). Pe Windows calea absoluta
# (C:\...) sparge string-ul `:`-separat → ffmpeg hard-fail. Fix: nume gol + ffmpeg
# rulat cu CWD pe directorul fisierului. Fix exclusiv PS1 (bash e colon-free).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$PROJECT_ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$ENCODE_PS1 = Join-Path $PROJECT_ROOT "src\av_encode.ps1"
$BURNIN_PS1 = Join-Path $PROJECT_ROOT "src\av_burnin.ps1"
$ENCODE_TXT = Get-Content $ENCODE_PS1 -Raw
$BURNIN_TXT = Get-Content $BURNIN_PS1 -Raw
$SRC = Join-Path $PROJECT_ROOT "src"

# ── 1. AST parse + functie noua definita ───────────────────────────
$astErrs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ENCODE_PS1, [ref]$null, [ref]$astErrs)
Assert-Eq 0 $astErrs.Count "av_encode.ps1 AST parse fara erori"
$found = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-InlineParamName' }, $true)
Assert-Eq $true ($found -ne $null) "AST: Get-InlineParamName definita"

# ── 2. Import functii + test functional ────────────────────────────
Import-AvEncodeFunctions -Names @('Get-InlineParamName','Ensure-TempDir','Initialize-2PassState','Clear-2PassState') | Out-Null

$testTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("v61t_" + [guid]::NewGuid().ToString('N'))
$script:AV_TEMP_DIR = $testTmp

# Get-InlineParamName: returneaza NUME GOL (colon-free) + seteaza workdir = parent
$script:ffmpegWorkDir = ""
$name = Get-InlineParamName 'C:\Users\foo\AppData\Local\Temp\hp_123.json'
Assert-Eq 'hp_123.json' $name "Get-InlineParamName returneaza leaf-ul (nume gol)"
Assert-NotContains $name ':' "numele gol NU contine ':' (chiar din cale C:\)"
Assert-NotContains $name '\' "numele gol NU contine '\'"
Assert-Eq 'C:\Users\foo\AppData\Local\Temp' $script:ffmpegWorkDir "workdir = directorul parinte"
Assert-Eq '' (Get-InlineParamName '') "cale goala → token gol"

# Initialize-2PassState: statsBase nume gol, statsFile sub AV_TEMP_DIR, workdir setat
$script:ffmpegWorkDir = ""
Initialize-2PassState "C:\some path\My Video.mkv"
Assert-NotContains $script:statsBase '\' "statsBase NU contine '\' (nume gol)"
Assert-NotContains $script:statsBase '/' "statsBase NU contine '/'"
Assert-NotContains $script:statsBase ':' "statsBase NU contine ':'"
Assert-Match $script:statsBase '\.passlog$' "statsBase se termina in .passlog"
Assert-Eq $testTmp (Split-Path -Parent $script:statsFile) "statsFile sub AV_TEMP_DIR"
Assert-Eq $testTmp $script:ffmpegWorkDir "ffmpegWorkDir = AV_TEMP_DIR (2-pass)"
Assert-Eq $true $script:use2Pass "use2Pass = true"

# Clear-2PassState: reseteaza stats DAR pastreaza AV_TEMP_DIR (partajat, nu subdir)
New-Item -ItemType Directory -Force -Path $testTmp | Out-Null
Set-Content -Path $script:statsFile -Value "x" -Encoding ASCII
Set-Content -Path ($script:statsFile + ".cutree") -Value "y" -Encoding ASCII
Clear-2PassState
Assert-Eq '' $script:statsFile "statsFile resetat"
Assert-Eq '' $script:statsBase "statsBase resetat"
Assert-DirExists $testTmp "Clear-2PassState NU sterge AV_TEMP_DIR (partajat)"
Remove-Item $testTmp -Recurse -Force -ErrorAction SilentlyContinue

# ── 3. Regression la nivel de sursa (av_encode.ps1) ────────────────
Assert-Contains    $ENCODE_TXT 'dhdr10-info=$(Get-InlineParamName'  "x265 inline foloseste Get-InlineParamName"
Assert-Contains    $ENCODE_TXT 'hdr10plus-json=$(Get-InlineParamName' "AV1 inline foloseste Get-InlineParamName"
Assert-NotContains $ENCODE_TXT 'dhdr10-info=${hdr10PlusJson}'       "x265 main: NU mai foloseste calea absoluta directa"
Assert-NotContains $ENCODE_TXT 'dhdr10-info=${hdr10pJson}'          "x265 pipeline: NU mai foloseste calea absoluta directa"
Assert-Contains    $ENCODE_TXT 'stats=$($script:statsBase)'         "2-pass stats foloseste nume gol (statsBase)"
Assert-NotContains $ENCODE_TXT 'stats=$($script:statsFile)'         "2-pass NU mai pune statsFile absolut in param"
Assert-NotContains $ENCODE_TXT 'incompatibil cu x265-params'        "pipeline x265: guard de degradare eliminat"
Assert-NotContains $ENCODE_TXT 'incompatibil cu svtav1-params'      "pipeline svtav1: guard de degradare eliminat"
Assert-Contains    $ENCODE_TXT '-RedirectStandardError $errFile @wd' "Start-Process main injecteaza @wd (WorkingDirectory)"

# ── 3b. Filtergraph: vidstab .trf nume gol (drive-colon in -vf sparge filtergraph) ─
# La vidstab nici escape-ul `\:` nu merge → singura solutie e nume gol + Push-Location.
Assert-Contains    $ENCODE_TXT 'result=$trfBare'  "vidstab detect: result= foloseste nume gol"
Assert-Contains    $ENCODE_TXT 'input=${trfBare}' "vidstab transform: input= foloseste nume gol"
Assert-NotContains $ENCODE_TXT 'result=$trfFile'  "vidstab: NU mai foloseste calea absoluta in filtru"
# lut3d: drive-colon escaped la toate sursele LUT (verificare functionala in integration).
# Source-grep robust: secventa de escape colon `,'\:'` exista (LOG/HLG/creative + tc).
$lutColonEsc = ([regex]::Matches($ENCODE_TXT, [regex]::Escape(",'\:'"))).Count
Assert-Eq $true ($lutColonEsc -ge 4) "lut3d: drive-colon escape prezent la >=4 site-uri (LOG/HLG/creative/tc), gasit $lutColonEsc"

# ── 4. Regression la nivel de sursa (av_burnin.ps1) ────────────────
Assert-Contains    $BURNIN_TXT 'function Invoke-BurninEncode'             "burn-in: wrapper Invoke-BurninEncode definit"
Assert-Contains    $BURNIN_TXT 'hdr10plus-json=$(Split-Path -Leaf $json)' "burn-in: svtav1-params foloseste nume gol"
Assert-NotContains $BURNIN_TXT 'hdr10plus-json=$jsonEsc'                  "burn-in: NU mai foloseste jsonEsc (\\→/ nu scotea ':')"
Assert-Contains    $BURNIN_TXT '$script:BurninWorkDir = Split-Path -Parent $json' "burn-in: seteaza BurninWorkDir"

# ── 5. Integration — extract HDR10+ real + encode colon-safe ───────
$ff = Join-Path $SRC 'ffmpeg.exe';   if (-not (Test-Path $ff)) { $ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source }
$fp = Join-Path $SRC 'ffprobe.exe';  if (-not (Test-Path $fp)) { $fp = (Get-Command ffprobe -ErrorAction SilentlyContinue).Source }
$hp = Join-Path $SRC 'hdr10plus_tool.exe'; if (-not (Test-Path $hp)) { $hp = (Get-Command hdr10plus_tool -ErrorAction SilentlyContinue).Source }
$sample = Join-Path $SRC 'Upload_S02E01_HDR10Plus_40s_HEVC.mp4'

if ($ff -and $fp -and $hp -and (Test-Path $ff) -and (Test-Path $fp) -and (Test-Path $hp) -and (Test-Path $sample)) {
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("v61i_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        # Extract HDR10+ JSON in $work (drive-colon path)
        $raw = Join-Path $work 'raw.hevc'
        & $ff -y -v error -i $sample -c:v copy -bsf:v hevc_mp4toannexb -f hevc $raw 2>$null | Out-Null
        $json = Join-Path $work 'hp.json'
        & $hp extract -i $raw -o $json 2>$null | Out-Null
        Assert-FileExists $json "integration: HDR10+ JSON extras"

        # Encode colon-safe: nume gol + -WorkingDirectory (mecanismul main-flow)
        $bare = Split-Path -Leaf $json
        $p = "hdr-opt=1:repeat-headers=1:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:dhdr10-info=$bare"
        $out = Join-Path $work 'out.mp4'
        $err = Join-Path $work 'err.txt'
        $args = @('-y','-v','error','-t','2','-i',$sample,'-an','-c:v','libx265','-preset','ultrafast','-pix_fmt','yuv420p10le','-x265-params',$p,$out)
        $proc = Start-Process $ff -ArgumentList $args -NoNewWindow -PassThru -Wait -WorkingDirectory $work -RedirectStandardError $err
        Assert-Zero $proc.ExitCode "integration: encode colon-safe exit 0 (nume gol + WorkingDirectory)"
        Assert-FileExists $out "integration: output creat"

        # Verify HDR10+ dinamic pastrat
        $sd = & $fp -hide_banner -loglevel error -select_streams v:0 -read_intervals "%+#3" `
            -show_frames -show_entries frame_side_data=side_data_type -of default=nw=1:nk=1 $out 2>$null
        $sdStr = ($sd | Where-Object { $_ }) -join '|'
        Assert-Match $sdStr '2094' "integration: HDR10+ SMPTE2094-40 pastrat in output"

        # Control: calea ABSOLUTA (cu ':') trebuie sa pice (dovada bugului)
        $pAbs = "hdr-opt=1:repeat-headers=1:hdr10=1:dhdr10-info=$json"
        $outA = Join-Path $work 'outabs.mp4'
        $procA = Start-Process $ff -ArgumentList @('-y','-v','error','-t','2','-i',$sample,'-an','-c:v','libx265','-preset','ultrafast','-pix_fmt','yuv420p10le','-x265-params',$pAbs,$outA) -NoNewWindow -PassThru -Wait -RedirectStandardError (Join-Path $work 'errA.txt')
        Assert-Nonzero $procA.ExitCode "integration: calea absoluta cu ':' pica (bugul reprodus)"
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "  (integration HDR10+ sarit — ffmpeg/ffprobe/hdr10plus_tool/sample lipsesc)" -ForegroundColor DarkGray
}

# ── 6. Integration filtergraph — lut3d escaped + vidstab nume gol ───
if ($ff -and (Test-Path $ff)) {
    $w2 = Join-Path ([System.IO.Path]::GetTempPath()) ("v61f_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $w2 | Out-Null
    try {
        # lut3d: cale C:\ cu drive-colon escaped (C\:/) merge; raw C:/ pica
        $cube = Join-Path $w2 'id.cube'
        @('LUT_3D_SIZE 2','0 0 0','1 0 0','0 1 0','1 1 0','0 0 1','1 0 1','0 1 1','1 1 1') | Set-Content $cube -Encoding ASCII
        $escPath = ($cube -replace '\\','/') -replace ':','\:'
        $pL = Start-Process $ff -ArgumentList @('-y','-v','error','-f','lavfi','-i','testsrc=size=320x240:rate=25:duration=1','-vf',"lut3d='$escPath',format=yuv420p",'-f','null','NUL') -NoNewWindow -PassThru -Wait -RedirectStandardError (Join-Path $w2 'l.txt')
        Assert-Zero $pL.ExitCode "integration lut3d: cale C\:/ escaped → exit 0"
        $rawPath = ($cube -replace '\\','/')
        $pLbad = Start-Process $ff -ArgumentList @('-y','-v','error','-f','lavfi','-i','testsrc=size=320x240:rate=25:duration=1','-vf',"lut3d='$rawPath',format=yuv420p",'-f','null','NUL') -NoNewWindow -PassThru -Wait -RedirectStandardError (Join-Path $w2 'lb.txt')
        Assert-Nonzero $pLbad.ExitCode "integration lut3d: cale C:/ neescapata pica (bugul reprodus)"

        # vidstab: detect cu nume gol + WorkingDirectory (skip daca lipseste libvidstab)
        if (& $ff -hide_banner -filters 2>$null | Select-String 'vidstabdetect' -Quiet) {
            $trf = Join-Path $w2 'shaky.trf'; $bare2 = Split-Path -Leaf $trf
            $pV = Start-Process $ff -ArgumentList @('-y','-v','error','-f','lavfi','-i','testsrc=size=320x240:rate=25:duration=2','-vf',"vidstabdetect=result=$bare2",'-f','null','NUL') -NoNewWindow -PassThru -Wait -WorkingDirectory $w2 -RedirectStandardError (Join-Path $w2 'v.txt')
            Assert-Zero $pV.ExitCode "integration vidstab: nume gol + WorkingDirectory → exit 0"
            Assert-FileExists $trf "integration vidstab: .trf scris in workdir"
        } else {
            Write-Host "  (vidstab integration sarit — build fara libvidstab)" -ForegroundColor DarkGray
        }
    } finally { Remove-Item $w2 -Recurse -Force -ErrorAction SilentlyContinue }
}

Invoke-TestSummary
