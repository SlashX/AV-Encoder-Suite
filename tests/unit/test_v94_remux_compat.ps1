# v94 (O12) — matricea de compatibilitate Remux, testata pe copia VIE.
#
# Cele 33 de aserţiuni de mai jos stateau in test_v49_mux.ps1 si erau importate prin
# `Import-AvEncodeFunctions`, care citeste HARDCODAT din src/av_encode.ps1 — deci testau o
# copie MOARTA: `Get-RemuxStreamCompat` si `Get-RemuxStreams` sunt definite si acolo, dar
# NIMIC din av_encode.ps1 nu le cheama. Codul care ruleaza efectiv la Remux/Mux e in
# av_mux.ps1 (6, respectiv 2 apeluri).
#
# Cele doua copii au DRIFTAT, iar cea moarta e cu doua versiuni in urma:
#   v59 — `TrimEnd(',')` pe title (trailing comma din `csv=p=0` pe surse HDR)  -> LIPSESTE
#   v88 — dedupe IAMF (`$seenIdx` + gate numeric pe idx)                       -> LIPSESTE
# Pe `Get-RemuxStreamCompat` divergenta e doar de formatare (logica identica — verificat:
# toate cele 17 cazuri de referinta dau acelasi rezultat pe ambele copii).
#
# Aici se importa EXPLICIT din av_mux.ps1 (`-Path`), deci aserţiunile valideaza codul care
# se executa. Secţiunea 2 documenteaza copiile moarte: cand se face curatenia (se sterg cele
# 2 functii din av_encode.ps1), aserţiunile de acolo pica si spun exact ce sa scoti.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
$MUX  = Join-Path $SRC 'av_mux.ps1'
$ENC  = Join-Path $SRC 'av_encode.ps1'

# copia VIE — cea folosita de fluxurile Remux/Mux
Import-AvEncodeFunctions -Names @('Get-RemuxStreamCompat') -Path $MUX

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
# 2) Copiile MOARTE din av_encode.ps1 (O12) — stare documentata, nu bug
# ─────────────────────────────────────────────────────────────────
# Cand se sterg cele 2 functii din av_encode.ps1, aserţiunile de mai jos pica.
# Semnalul e INTENTIONAT: scoate si aceasta secţiune odata cu ele.
$encTxt = Get-Content $ENC -Raw
$muxTxt = Get-Content $MUX -Raw

foreach ($fn in 'Get-RemuxStreamCompat', 'Get-RemuxStreams') {
    Assert-Eq $true ([regex]::IsMatch($encTxt, "(?m)^function\s+$fn")) `
        "O12: $fn inca definit in av_encode.ps1 (de sters la curatenie)"
    # „mort" = zero apeluri in acel fisier (scadem definitia din numaratoare)
    $encUses = ([regex]::Matches($encTxt, "(?<![A-Za-z0-9_-])$fn(?![A-Za-z0-9_-])")).Count - 1
    Assert-Eq 0 $encUses "O12: $fn e MORT in av_encode.ps1 (zero apeluri acolo)"
    # ...si VIU in av_mux.ps1
    $muxUses = ([regex]::Matches($muxTxt, "(?<![A-Za-z0-9_-])$fn(?![A-Za-z0-9_-])")).Count - 1
    Assert-Nonzero $muxUses "O12: $fn e VIU in av_mux.ps1 (are apeluri)"
}

# Driftul concret: fixurile v59 si v88 sunt DOAR in copia vie
Assert-Eq $true  ($muxTxt.Contains('$parts[5].TrimEnd(')) "O12: fixul v59 (TrimEnd pe title) e in copia vie"
Assert-Eq $false ($encTxt.Contains('$parts[5].TrimEnd(')) "O12: fixul v59 LIPSESTE din copia moarta"
Assert-Eq $true  ($muxTxt.Contains('$seenIdx.ContainsKey($idx)')) "O12: fixul v88 (dedupe IAMF) e in copia vie"
Assert-Eq $false ($encTxt.Contains('$seenIdx.ContainsKey($idx)')) "O12: fixul v88 LIPSESTE din copia moarta"

Invoke-TestSummary
