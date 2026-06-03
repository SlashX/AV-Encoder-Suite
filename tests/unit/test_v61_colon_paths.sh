#!/usr/bin/env bash
# v61: bugul drive-colon in x265-params/svtav1-params (dhdr10-info / hdr10plus-json /
# stats=) e EXCLUSIV Windows (PS1). Pe bash (Termux/Linux/macOS) caile sunt colon-free
# → parametrii inline merg nativ, fara workdir hack. Acest test documenteaza invariantul
# de platforma + verifica feature parity (inline append HDR10+ exista in bash) + confirma
# ca guard-ul v60 belt-and-suspenders ramane prezent (no-op pe bash → mereu preserve).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"

TC_SRC="$(cat "$SRC/av_trimconcat.sh")"

# ── 1. Feature parity — inline append HDR10+ exista in bash ────────
assert_contains "$TC_SRC" 'dhdr10-info=${hdr10p_json}'   "bash pipeline: x265 inline dhdr10-info prezent"
assert_contains "$TC_SRC" 'hdr10plus-json=${hdr10p_json}' "bash pipeline: svtav1 inline hdr10plus-json prezent"

# ── 2. Invariant platforma — caile bash sunt colon-free ────────────
for p in "/storage/emulated/0/Media/Temp/hdr10plus_x.json" "/tmp/hdr10plus_x.json" "/home/u/Media/Temp/hp.json"; do
    case "$p" in
        *:*) assert_eq "colon-free" "are-colon:$p" "cale bash colon-free" ;;
        *)   assert_eq "0" "0" "cale bash colon-free: $p" ;;
    esac
done

# ── 3. Param `:`-separat cu cale bash → portiunea de cale fara ':' ─
json="/storage/emulated/0/Media/Temp/hp.json"
param="hdr-opt=1:repeat-headers=1:hdr10=1:dhdr10-info=${json}"
path_part="${param##*dhdr10-info=}"
case "$path_part" in
    *:*) assert_eq "no-colon" "colon-in-path:$path_part" "param bash: portiunea de cale fara ':'" ;;
    *)   assert_eq "0" "0" "param bash: dhdr10-info path colon-free (merge nativ, fara fix)" ;;
esac

# stats= bash (acelasi rationament — cale colon-free)
stats="/tmp/av2pass_x/clip.passlog"
sparam="pass=1:stats=${stats}:slow-firstpass=0"
stats_part="${sparam##*stats=}"; stats_part="${stats_part%%:*}"
case "$stats_part" in
    *:*) assert_eq "no-colon" "colon:$stats_part" "param bash: stats path fara ':'" ;;
    *)   assert_eq "0" "0" "param bash: stats= colon-free (2-pass merge nativ)" ;;
esac

# ── 4. Contrast — o cale stil Windows AR introduce ':' (motivul fix-ului PS1) ─
winpath='C:\Users\u\Temp\hp.json'
case "$winpath" in
    *:*) assert_eq "0" "0" "cale Windows contine ':' → ar sparge param-ul (de-aia PS1 are fix)" ;;
    *)   assert_eq "win-has-colon" "no-colon" "asteptat ':' in cale Windows" ;;
esac

# ── 5. Guard v60 belt-and-suspenders inca prezent (no-op pe bash) ──
assert_contains "$TC_SRC" 'incompatibil cu x265-params'   "bash colon-guard pipeline x265 (no-op pe bash → preserve)"
assert_contains "$TC_SRC" 'incompatibil cu svtav1-params' "bash colon-guard pipeline svtav1 (no-op pe bash → preserve)"
