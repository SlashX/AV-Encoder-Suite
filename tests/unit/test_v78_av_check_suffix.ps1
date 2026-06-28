# v78 — av_check output-suffix recognition: _dv81 (static) + _rpu<mode> (dinamic, regex). PS1 mirror.
#   Invariant: fiecare sufix produs de suita e recunoscut de chain-stripping-ul av_check
#   ("COMPARATIE INPUT vs OUTPUT" leaga output-ul de sursa) + paritate bash<->PS1.
. "$PSScriptRoot\..\framework.ps1"

$src   = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src'
$shSrc = Get-Content (Join-Path $src 'av_check.sh') -Raw
$psSrc = Get-Content (Join-Path $src 'av_check.ps1') -Raw

# Helper: substring LITERAL (.Contains evita interpretarea -clike/-cmatch a [ ] $ \ )
function AssertHas($text, $needle, $msg) { Assert-Eq $true ($text.Contains($needle)) $msg }

# ── 1. _dv81 (STATIC) recunoscut in ambele liste literale ─────────────
AssertHas $shSrc '_dvhybrid _dv81'     "av_check.sh: _dv81 in lista de sufixe"
AssertHas $psSrc '"_dvhybrid","_dv81"' "av_check.ps1: _dv81 in lista de sufixe"

# ── 2. _rpu<mode> (DINAMIC) — regex strip in ambele ───────────────────
AssertHas $shSrc '_rpu[0-9]+$' "av_check.sh: regex _rpu<mode> dinamic"
AssertHas $psSrc '_rpu\d+$'    "av_check.ps1: regex _rpu<mode> dinamic"

# ── 3. PARITATE: aceleasi sufixe literale bash <-> PS1 ────────────────
$shBlock = [regex]::Match($shSrc, '(?s)for suffix in(.*?); do').Groups[1].Value
$shSet   = ([regex]::Matches($shBlock, '_[a-z0-9]+') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ' '
$psBlock = [regex]::Match($psSrc, '(?s)foreach \(\$sfx in @\((.*?)\)\) \{').Groups[1].Value
$psSet   = ([regex]::Matches($psBlock, '_[a-z0-9]+') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ' '
Assert-Eq $shSet $psSet "paritate: liste literale identice bash<->PS1"
AssertHas $shSet "_dv81" "setul de paritate contine _dv81"

# ── 4. COMPLETITUDINE: fiecare encoder_get_suffix e recunoscut ────────
Get-ChildItem (Join-Path $src 'av_encoder_*.sh') | ForEach-Object {
    $m = [regex]::Match((Get-Content $_.FullName -Raw), 'encoder_get_suffix\(\) \{ echo "(_[a-z0-9]+)"')
    if ($m.Success) {
        $sfx = $m.Groups[1].Value
        AssertHas $shSrc $sfx              "av_check.sh recunoaste encoder $sfx ($($_.Name))"
        AssertHas $psSrc ('"' + $sfx + '"') "av_check.ps1 recunoaste encoder $sfx ($($_.Name))"
    }
}

# ── 5. COMPLETITUDINE: sufixele uneltelor (paritate explicita) ────────
foreach ($sfx in @("_audio","_remux","_mux","_telem","_hud","_subs","_preview","_nodv","_nohdr10plus","_dvhybrid","_dv81")) {
    AssertHas $shSrc $sfx               "av_check.sh recunoaste tool $sfx"
    AssertHas $psSrc ('"' + $sfx + '"') "av_check.ps1 recunoaste tool $sfx"
}

# ── 6. FUNCTIONAL: replica logica de strip av_check.ps1 (lista reala) ──
function Strip-Name($n) {
    $b = [System.IO.Path]::GetFileNameWithoutExtension($n)
    foreach ($s in @("_x265","_x264","_av1","_dnxhr","_prores","_apv","_audio","_hwenc","_remux","_mux","_telem","_hud","_subs","_preview","_nodv","_nohdr10plus","_dvhybrid","_dv81")) {
        $b = $b -replace [regex]::Escape($s),""
    }
    $b = $b -replace '_rpu\d+$',''
    return $b
}
Assert-Eq "movie"   (Strip-Name "movie_dv81.mkv")      "_dv81 -> base"
Assert-Eq "movie"   (Strip-Name "movie_rpu2.mkv")      "_rpu2 -> base"
Assert-Eq "movie"   (Strip-Name "movie_rpu5.mov")      "_rpu5 -> base"
Assert-Eq "clip"    (Strip-Name "clip_rpu3_telem.mp4") "_rpu3_telem compus -> base"
Assert-Eq "movie"   (Strip-Name "movie.mkv")           "fara sufix -> neschimbat"
Assert-Eq "holiday" (Strip-Name "holiday_av1.mp4")     "_av1 fara fals-match _rpu"

Invoke-TestSummary
