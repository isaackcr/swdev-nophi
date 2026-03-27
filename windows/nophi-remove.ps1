[CmdletBinding()]
param(
    [ValidateSet("auto", "cpu", "cuda")]
    [string]$Mode = "auto"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/NOPHI.Windows.ps1"

Ensure-DockerAccess

$targetMode = Resolve-RunMode -RequestedMode $Mode
$name = Get-ContainerName -Mode $targetMode

function Test-ContainerExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    $containerNames = & docker ps -a --format "{{.Names}}"
    return ($LASTEXITCODE -eq 0 -and ($containerNames | Where-Object { $_ -eq $Name }))
}

if (Test-ContainerExists -Name $name) {
    & docker rm -f $name | Out-Null
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    Write-Host ("Container removed: {0}" -f $name)
}
elseif ($Mode -eq "auto") {
    $altMode = if ($targetMode -eq "cpu") { "cuda" } else { "cpu" }
    $altName = Get-ContainerName -Mode $altMode

    if (Test-ContainerExists -Name $altName) {
        & docker rm -f $altName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
        Write-Host ("Container removed: {0}" -f $altName)
        Write-Host ("Auto-selected target was {0}, but no matching container existed." -f $targetMode)
    }
    else {
        Write-Host ("Container not found: {0}" -f $name)
    }
}
else {
    Write-Host ("Container not found: {0}" -f $name)
}
