[CmdletBinding()]
param(
    [string]$SharedDir = $(Join-Path $env:USERPROFILE "NOPHI-shared")
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/NOPHI.Windows.ps1"

$created = $false

if (-not (Test-Path -LiteralPath $SharedDir)) {
    New-Item -ItemType Directory -Path $SharedDir -Force | Out-Null
    $created = $true
}

if ($created) {
    Write-Host ("Created directory: {0}" -f $SharedDir)
}
else {
    Write-Host "Shared directory access is already configured."
}
