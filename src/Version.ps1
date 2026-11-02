# Product metadata is embedded by the build; development loads the same version.json.
function Get-SjcVersionInfo {
    $embedded=Get-Variable -Scope Script -Name SjcEmbeddedVersion -ValueOnly -ErrorAction SilentlyContinue
    if($embedded){return $embedded}
    $path=Join-Path (Split-Path -Parent $PSScriptRoot) 'version.json'
    $value=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)|ConvertFrom-Json
    if($value.version -notmatch '^\d+\.\d+\.\d+$' -or $value.fileVersion -ne ($value.version+'.0') -or $value.planSchemaVersion -ne 1){throw 'Invalid product version metadata.'}
    $script:SjcEmbeddedVersion=$value
    return $value
}
function Get-SjcVersion { return [string](Get-SjcVersionInfo).version }
function Get-SjcPlanSchemaVersion { return [int](Get-SjcVersionInfo).planSchemaVersion }
