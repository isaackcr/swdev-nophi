[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/NOPHI.Windows.ps1"

Ensure-DockerAccess

function Ensure-Network {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Subnet,
        [Parameter(Mandatory = $true)][string]$Gateway
    )

    $exists = $false
    $recreate = $false

    # Use SilentlyContinue locally so a missing network (non-zero exit) does not
    # trigger a terminating error under $ErrorActionPreference = "Stop".
    $inspectOutput = $null
    $inspectExitCode = 0
    try {
        $inspectOutput = & docker network inspect $Name 2>$null
        $inspectExitCode = $LASTEXITCODE
    } catch {
        $inspectExitCode = 1
    }

    if ($inspectExitCode -eq 0) {
        $exists = $true
        $networkData = $inspectOutput | ConvertFrom-Json
        $currentConfig = $networkData[0].IPAM.Config[0]

        if ($currentConfig.Subnet -ne $Subnet -or $currentConfig.Gateway -ne $Gateway) {
            $recreate = $true
        }
    }

    if ($recreate) {
        & docker network rm $Name | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Fail ("Unable to remove Docker network {0}." -f $Name)
        }
    }

    if ($recreate -or -not $exists) {
        $createArgs = @(
            "network", "create",
            "--driver", "bridge",
            "--subnet", $Subnet,
            "--gateway", $Gateway,
            $Name
        )
        & docker @createArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Fail ("Unable to create Docker network {0}." -f $Name)
        }

        if ($recreate) {
            Write-Host ("Recreated network {0} with {1} ({2})." -f $Name, $Subnet, $Gateway)
        }
        else {
            Write-Host ("Created network {0} with {1} ({2})." -f $Name, $Subnet, $Gateway)
        }

        return
    }

    Write-Host ("Network already configured: {0}" -f $Name)
}

Ensure-Network -Name "cri-dev-net" -Subnet "192.168.240.0/24" -Gateway "192.168.240.1"
Ensure-Network -Name "cri-collab-net" -Subnet "192.168.241.0/24" -Gateway "192.168.241.1"