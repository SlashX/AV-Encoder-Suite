# v78 — pastrarea metadata-ului nativ DJI (djmd GPS) prin GRAFT MP4Box. PS1 mirror.
#   A) telemetrie strip "pastreaza GPS nativ"  B) flux encode re-graft GPS.
#   Source-level + paritate + FUNCTIONAL real pe Windows (MP4Box + sample DJI).
. "$PSScriptRoot\..\framework.ps1"

$src     = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src'
$common  = Get-Content (Join-Path $src 'av_common.sh')    -Raw
$launch  = Get-Content (Join-Path $src 'av_launcher.sh')  -Raw
$telSh   = Get-Content (Join-Path $src 'av_telemetry.sh') -Raw
$telPs   = Get-Content (Join-Path $src 'av_telemetry.ps1') -Raw
$encPs   = Get-Content (Join-Path $src 'av_encode.ps1')   -Raw

function AssertHas($text, $needle, $msg) { Assert-Eq $true ($text.Contains($needle)) $msg }

# ── 1. Helperi bash (av_common.sh) ───────────────────────────────────
AssertHas $common '_dji_native_meta_ids()'          "av_common: _dji_native_meta_ids"
AssertHas $common '_dji_has_native_meta()'          "av_common: _dji_has_native_meta"
AssertHas $common '_dji_graft_native_meta()'        "av_common: _dji_graft_native_meta"
AssertHas $common '_dji_preserve_meta_postencode()' "av_common: orchestrator B"
AssertHas $common '_dji_preserve_meta_postencode "$file" "$output"' "av_common: hook in run_encode_loop"

# ── 2. Helperi PS1 (av_encode.ps1 — B) ───────────────────────────────
AssertHas $encPs 'function Get-DjiNativeMetaIds'           "PS1 av_encode: Get-DjiNativeMetaIds"
AssertHas $encPs 'function Test-DjiNativeMeta'             "PS1 av_encode: Test-DjiNativeMeta"
AssertHas $encPs 'function Add-DjiNativeMeta'              "PS1 av_encode: Add-DjiNativeMeta"
AssertHas $encPs 'function Invoke-DjiPreserveMetaPostEncode' "PS1 av_encode: orchestrator B"
AssertHas $encPs 'Invoke-DjiPreserveMetaPostEncode -Source $f.FullName -Output $outFile' "PS1 av_encode: apel hook B"
# si pe stream-copy (Invoke-StreamCopy) — paritate cu re-encode (djmd se pierde la copy)
AssertHas $encPs 'Invoke-DjiPreserveMetaPostEncode -Source $fileInfo.FullName -Output $outFile' "PS1 Invoke-StreamCopy: re-grefeaza djmd si pe stream-copy"
# si pe audio-only (av_encoder_audio.sh bash + PS1 menu 2); NU pe trim/concat (video editat)
$audSh = Get-Content (Join-Path $src 'av_encoder_audio.sh') -Raw
AssertHas $audSh '_dji_preserve_meta_postencode "$file" "$output"' "av_encoder_audio.sh: graft pe audio-only"
Assert-Eq 3 ([regex]::Matches($encPs, 'Invoke-DjiPreserveMetaPostEncode -Source').Count) "PS1 av_encode: 3 call-site graft (run-loop + stream-copy + audio-only)"

# ── 3. A — meniu telemetrie (bash + PS1): optiunea 3 + cancel = 4 ─────
AssertHas $telSh 'Pastreaza GPS nativ (djmd)'     "av_telemetry.sh: optiunea 3"
AssertHas $telSh 'Alege 1-4 [implicit: 1]'        "av_telemetry.sh: prompt 1-4"
AssertHas $telPs 'Pastreaza GPS nativ (djmd)'     "av_telemetry.ps1: optiunea 3"
AssertHas $telPs 'Alege 1-4 [implicit: 1]'        "av_telemetry.ps1: prompt 1-4"
AssertHas $telPs 'function Add-DjiNativeMeta'     "av_telemetry.ps1: copie Add-DjiNativeMeta"
AssertHas $telPs 'Add-DjiNativeMeta -Original $f.FullName -Output $outClean' "av_telemetry.ps1: mode 3 graft"

# ── 4. Schema + save flow (paritate bash<->PS1) ──────────────────────
AssertHas $common 'DJI_PRESERVE_META)    echo "enum:,auto,on,off"'  "schema bash"
AssertHas $encPs  "'DJI_PRESERVE_META'    { 'enum:,auto,on,off'"    "schema PS1"
AssertHas $launch 'DJI_PRESERVE_META="${DJI_PRESERVE_META:-}"'      "save flow bash"
AssertHas $encPs  'DJI_PRESERVE_META=$(if ($env:DJI_PRESERVE_META)' "save flow PS1"

# ── 5. Policy auto/on/off + bypass non-interactiv (PS1) ──────────────
AssertHas $encPs 'if ($policy -eq "off") { return }'    "PS1: off → no-op"
AssertHas $encPs 'IsInputRedirected'                    "PS1: detectie non-interactiv (auto → ON)"

# ── 6. Nume FARA literalul "mp4box" (paritate santinela no_hardcoded_tools) ──
$mp4boxNamed = [regex]::Matches($encPs, 'function\s+[A-Za-z-]*[Mm]p4[Bb]ox[A-Za-z-]*').Count
Assert-Eq 0 $mp4boxNamed "PS1 av_encode: nicio functie cu mp4box in nume"
# unealta via env (NU hardcodat la call-site)
AssertHas $encPs '$env:AV_TOOL_MP4BOX'  "PS1: unealta via `$env:AV_TOOL_MP4BOX"

# ── 7. FUNCTIONAL: graft real pe sample DJI (Windows + MP4Box) ───────
$ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
if (-not $ffprobe) { $env:PATH = "$src;$env:PATH" }
$mux = if ($env:AV_TOOL_MP4BOX) { $env:AV_TOOL_MP4BOX } else { "mp4box" }
$dji = Get-ChildItem (Join-Path $src 'DJI_*.MP4') -ErrorAction SilentlyContinue | Select-Object -First 1
if ((Get-Command ffprobe -ErrorAction SilentlyContinue) -and (Get-Command $mux -ErrorAction SilentlyContinue) -and $dji) {
    # extrage cele 3 functii REALE din av_telemetry.ps1 (AST)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'av_telemetry.ps1'), [ref]$null, [ref]$null)
    foreach ($fn in @('Get-DjiNativeMetaIds','Test-DjiNativeMeta','Add-DjiNativeMeta')) {
        $f = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn}, $true) | Select-Object -First 1
        Invoke-Expression $f.Extent.Text
    }
    Assert-Eq $true (Test-DjiNativeMeta $dji.FullName) "FUNCTIONAL: Test-DjiNativeMeta=true pe DJI"
    $ids = @(Get-DjiNativeMetaIds $dji.FullName)
    Assert-Eq 1 $ids.Count "FUNCTIONAL: 1 ID (djmd DOAR)"

    $g = [guid]::NewGuid().ToString('N').Substring(0,8)
    $base = Join-Path $env:TEMP "djiP_$g.mp4"
    & ffmpeg -v error -y -i $dji.FullName -map 0:v:0 -map "0:a?" -c copy -dn $base 2>$null | Out-Null
    $r = Add-DjiNativeMeta -Original $dji.FullName -Output $base
    Assert-Eq $true $r "FUNCTIONAL: Add-DjiNativeMeta rc=true"
    $djmd = @(& ffprobe -v error -select_streams d -show_entries stream=codec_tag_string -of default=noprint_wrappers=1:nokey=1 $base 2>$null | Where-Object { "$_".Trim() -eq 'djmd' })
    Assert-Eq $true ($djmd.Count -ge 1) "FUNCTIONAL: djmd prezent dupa graft"
    # negativ: non-DJI refuzat
    $nod = Join-Path $env:TEMP "nodji_$g.mp4"
    & ffmpeg -v error -y -f lavfi -i "testsrc=d=1:s=64x64" -c:v libx264 $nod 2>$null | Out-Null
    Assert-Eq $false (Test-DjiNativeMeta $nod) "FUNCTIONAL: Test-DjiNativeMeta=false pe non-DJI"
    Assert-Eq $false (Add-DjiNativeMeta -Original $nod -Output $base) "FUNCTIONAL: graft refuzat pe non-DJI"
    Remove-Item $base,$nod -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "  NOTA: ffprobe/MP4Box/sample DJI absent — sar functionalul (source-level acopera)" -ForegroundColor DarkGray
}

Invoke-TestSummary
