[CmdletBinding()]
param(
    [string]$Prefix = $(Join-Path $env:LOCALAPPDATA "NOPHI\bin")
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/NOPHI.Windows.ps1"

$startSrc = Join-Path $PSScriptRoot "nophi-start.ps1"
$removeSrc = Join-Path $PSScriptRoot "nophi-remove.ps1"

if (-not (Test-Path -LiteralPath $startSrc)) {
    Fail ("Missing source script {0}" -f $startSrc)
}

if (-not (Test-Path -LiteralPath $removeSrc)) {
    Fail ("Missing source script {0}" -f $removeSrc)
}

New-Item -ItemType Directory -Path $Prefix -Force | Out-Null

$startShim = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$startSrc" %*
"@

$removeShim = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$removeSrc" %*
"@

Set-Content -LiteralPath (Join-Path $Prefix "nophi-start.cmd") -Value $startShim -NoNewline
Set-Content -LiteralPath (Join-Path $Prefix "nophi-remove.cmd") -Value $removeShim -NoNewline

Write-Host "Installed commands:"
Write-Host ("  {0}" -f (Join-Path $Prefix "nophi-start.cmd"))
Write-Host ("  {0}" -f (Join-Path $Prefix "nophi-remove.cmd"))
