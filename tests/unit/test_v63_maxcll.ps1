# v63 — MaxCLL/MaxFALL masurat (opt-in, Varianta B) + fix extract (mirror al test_v63_maxcll.sh).
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }
$ENC    = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
$COMMON = Get-Content (Join-Path $SRC "av_common.sh") -Raw
$X265   = Get-Content (Join-Path $SRC "av_encoder_x265.sh") -Raw

# ── 1. PS1 — motor + hook + prompt + state + schema + fix extract ──
Assert-Match $ENC 'function Measure-Hdr10Cll'                       "PS1: Measure-Hdr10Cll"
Assert-Match $ENC 'signalstats,metadata=print'                     "PS1: reteta signalstats"
Assert-Match $ENC ([regex]::Escape('hdr10MeasureCll -and -not $realCll')) "PS1: hook masoara doar fara CLL inscris"
Assert-Match $ENC ([regex]::Escape('$script:hdr10StaticSource = "measured-cll"')) "PS1: marker measured-cll"
Assert-Match $ENC 'function Read-Hdr10MeasureChoice'               "PS1: prompt opt-in (Varianta B)"
Assert-Match $ENC ([regex]::Escape('$script:hdr10MeasureCll = $script:hdr10MeasureCllBase')) "PS1: reset per-fisier la baza"
Assert-Match $ENC "'HDR10_MEASURE_CLL'    \{ 'enum:0,1'"           "PS1: schema profil"
Assert-Match $ENC 'frame_side_data=side_data_type,red_x'          "PS1 FIX: extract frame_side_data="
Assert-Eq $false ([bool]($ENC -match 'show_entries frame=side_data_list')) "PS1 FIX: nu mai foloseste frame=side_data_list"

# ── 2. Paritate bash — motor + hooks encodere + fix ──
Assert-Match $COMMON 'measure_hdr10_cll\(\)'                       "bash: measure_hdr10_cll"
Assert-Match $COMMON 'frame_side_data=side_data_type,red_x'       "bash FIX: extract frame_side_data="
Assert-Match $X265   ([regex]::Escape('measure_hdr10_cll "$file"')) "bash x265 hlg_to_hdr10: masoara opt-in"

# ── 3. Functional — fix extract (CLL inscris → probe) + measure (HLG → measured) ──
if ((Get-Command ffmpeg -EA SilentlyContinue) -and (Get-Command ffprobe -EA SilentlyContinue)) {
    Import-AvEncodeFunctions -Names @("Get-Hdr10StaticMetadata","Set-Hdr10StaticDefaults","Measure-Hdr10Cll","Resolve-Hdr10Static")
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("v63cll_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $pq = Join-Path $tmp "pq.mp4"; $hlg = Join-Path $tmp "hlg.mp4"
    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" `
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast `
        -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1):max-cll=831,200:log-level=none" `
        -an $pq 2>$null | Out-Null
    & ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" `
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast `
        -x265-params "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:log-level=none" `
        -an $hlg 2>$null | Out-Null
    if ((Test-Path $pq) -and (Test-Path $hlg)) {
        # FIX extract: CLL inscris → probe + valoare reala
        $script:hdr10MeasureCll = $true; Resolve-Hdr10Static -File $pq | Out-Null
        Assert-Eq "probe" $script:hdr10StaticSource   "functional: CLL inscris citit (extract fix → probe)"
        Assert-Eq "831,200" $script:hdr10MaxCll       "functional: MaxCLL inscris pastrat, NU masurat"
        # measure: HLG fara CLL + flag ON → measured-cll
        $script:hdr10MeasureCll = $true; Resolve-Hdr10Static -File $hlg | Out-Null
        Assert-Eq "measured-cll" $script:hdr10StaticSource "functional: HLG fara CLL → masoara"
        Assert-Eq $true ($script:hdr10MaxCll -match '^\d+,\d+$' -and $script:hdr10MaxCll -ne "1000,400") "functional: MaxCLL masurat ($($script:hdr10MaxCll)) != default"
        # flag OFF → default
        $script:hdr10MeasureCll = $false; Resolve-Hdr10Static -File $hlg | Out-Null
        Assert-Eq "1000,400" $script:hdr10MaxCll      "functional: flag OFF → default 1000,400"
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Invoke-TestSummary
