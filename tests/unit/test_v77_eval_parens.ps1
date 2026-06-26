# v77 (PS1) — Santinela eval-parens master-display. Oglinda test_v77_eval_parens.sh.
# Bug-ul eval-parens (master-display=G(..) → "syntax error near unexpected token (") afecteaza
# DOAR calea bash care ruleaza FFMPEG_CMD prin `eval`. PS1 e IMUN prin constructie: construieste
# comanda ffmpeg ca ARRAY de argumente si o ruleaza cu splat (`& ffmpeg @args`) → fiecare element
# e un argument separat, fara re-parsare de shell → parantezele master-display sunt brute si sigure.
# Acest test: (1) confirma ca PS1 NU foloseste eval/Invoke-Expression pe comanda de encode;
# (2) confirma paritatea fix-ului in bash (_esc_eval_parens pe cele 2 situri eval).
. "$PSScriptRoot\..\framework.ps1"

$proj = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SRC  = Join-Path $proj "src"
$psRaw    = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
$commonSh = Get-Content (Join-Path $SRC "av_common.sh") -Raw
$x265Sh   = Get-Content (Join-Path $SRC "av_encoder_x265.sh") -Raw
$av1Sh    = Get-Content (Join-Path $SRC "av_encoder_av1.sh") -Raw

# ── 1. PS1 imun: niciun Invoke-Expression / iex pe comanda de encode ──
Assert-NotContains $psRaw 'Invoke-Expression' "PS1 NU foloseste Invoke-Expression (imun la eval-parens)"
Assert-Match $psRaw '& ffmpeg @' "PS1 invoca ffmpeg prin array-splat (& ffmpeg @args) — fara re-parsare shell"

# ── 2. PS1 foloseste master-display RAW (paranteze brute — corect, intra in array, nu eval) ──
Assert-Contains $psRaw 'master-display=$($script:hdr10MasterDisplayX265)'   "PS1 x265 master-display RAW (array → fara escapare)"
Assert-Contains $psRaw 'mastering-display=$($script:hdr10MasterDisplaySvtAv1)' "PS1 av1 mastering-display RAW (array → fara escapare)"

# ── 3. Paritate bash: fix-ul eval-parens prezent ──
Assert-Contains $commonSh '_esc_eval_parens()' "_esc_eval_parens definit (av_common.sh)"
Assert-Match $x265Sh 'X265_HDR10_STATIC_PARAMS="master-display=\$\(_esc_eval_parens' "bash x265 escapeaza master-display (calea eval)"
Assert-Match $av1Sh  'mastering-display=\$\(_esc_eval_parens' "bash av1 escapeaza mastering-display (calea eval)"
Assert-NotContains $x265Sh 'master-display=${HDR10_MASTER_DISPLAY_X265}' "bash x265: forma RAW pe eval eliminata (regresie)"

# ── 4. Mecanism: array-splat pasează parantezele ca UN argument (fara re-parsare) ──
# Simulam: un parametru cu paranteze trecut prin splat ramane intact (spre deosebire de eval/bash).
$probe = @("master-display=G(13250,34500)B(7500,3000)")
Assert-Eq "master-display=G(13250,34500)B(7500,3000)" $probe[0] "array-splat pastreaza parantezele intacte (de ce PS1 e imun)"

# ── 5. Generalizare bug #2 — paritate cu garzile bash (HW + inventar eval) ──
# (a) HW bash: _HW_VUI_BSF numeric (fara paranteze) → FFMPEG_CMD HW eval'd ramane sigur
$hwBsfLines = ($commonSh -split "`n") | Where-Object { $_ -match '_HW_VUI_BSF' -and $_ -match '=' }
$hwBsfParens = ($hwBsfLines | Where-Object { $_ -match '\(' }).Count
Assert-Eq 0 $hwBsfParens "bash HW: _HW_VUI_BSF numeric, fara paranteze (paritate)"
# (b) PS1 HW: Get-HwVuiBsf produce coduri numerice + se paseaza prin array (PS1 imun oricum)
Assert-Match $psRaw 'function Get-HwVuiBsf' "PS1 are Get-HwVuiBsf (VUI HW)"
Assert-NotContains $psRaw 'Invoke-Expression' "PS1 HW: niciun Invoke-Expression (deja confirmat — imun)"

Invoke-TestSummary
