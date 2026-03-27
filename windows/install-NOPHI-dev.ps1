[CmdletBinding()]
param(
    [switch]$Cpu,
    [switch]$Cuda,
    [string]$Tag,
    [string]$Prefix,
    [switch]$NoBuild,
    [switch]$NoInstallCommands
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/NOPHI.Windows.ps1"

& (Join-Path $PSScriptRoot "create-shared-data-dir.ps1")
& (Join-Path $PSScriptRoot "create-docker-networks.ps1")

if (-not $NoBuild) {
    $buildArgs = @()
    if ($Cpu) {
        $buildArgs += "-Cpu"
    }
    if ($Cuda) {
        $buildArgs += "-Cuda"
    }
    if ($Tag) {
        $buildArgs += @("-Tag", $Tag)
    }

    & (Join-Path $PSScriptRoot "build-NOPHI-dev.ps1") @buildArgs
}

if (-not $NoInstallCommands) {
    $installArgs = @()
    if ($Prefix) {
        $installArgs += @("-Prefix", $Prefix)
    }

    & (Join-Path $PSScriptRoot "install-nophi-commands.ps1") @installArgs
}
