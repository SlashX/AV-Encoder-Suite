# Test Get-ProfileSchema — recunoaste cheile, returneaza tipul corect.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

Import-AvEncodeFunctions -Names @('Get-ProfileSchema')

# Enum
$schema = Get-ProfileSchema -Key 'ENCODER_NAME'
Assert-Eq 'enum:libx265,libx264,av1,dnxhr,prores,apv,hwenc' $schema 'ENCODER_NAME enum'

# PS1-native ENCODER alias
$schema = Get-ProfileSchema -Key 'ENCODER'
Assert-Match $schema '^enum:' 'ENCODER (PS1) is enum'

# Regex
$schema = Get-ProfileSchema -Key 'CRF_PARAM'
Assert-Match $schema '^regex:' 'CRF_PARAM is regex'
Assert-Contains $schema '[0-9]' 'CRF_PARAM regex contains digits class'

# HW backend
$schema = Get-ProfileSchema -Key 'HW_BACKEND'
Assert-Contains $schema 'nvenc' 'HW_BACKEND knows nvenc'
Assert-Contains $schema 'videotoolbox' 'HW_BACKEND knows videotoolbox'

# EXTENDS
Assert-Eq 'path:' (Get-ProfileSchema -Key 'EXTENDS') 'EXTENDS is path'

# Container
$schema = Get-ProfileSchema -Key 'CONTAINER'
Assert-Contains $schema 'mkv' 'CONTAINER knows mkv'
Assert-Contains $schema 'mp4' 'CONTAINER knows mp4'

# Unknown
Assert-Eq '' (Get-ProfileSchema -Key 'BOGUS_KEY_XYZ') 'unknown returns empty'

Invoke-TestSummary
