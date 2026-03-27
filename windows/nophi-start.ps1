[CmdletBinding()]
param(
    [ValidateSet("auto", "cpu", "cuda")]
    [string]$Mode = "auto",
    [string]$SharedDir
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/NOPHI.Windows.ps1"

Ensure-DockerAccess

$userName = Get-SafeUserName
$sshPort = Get-SshPort
$forwardPort = Get-ForwardPort
$runMode = Resolve-RunMode -RequestedMode $Mode
$containerName = Get-ContainerName -Mode $runMode
$imageTag = Get-ImageTagForMode -Mode $runMode
$sharedPath = if ($SharedDir) { $SharedDir } else { Get-DefaultSharedDir }
$homePath = Get-DefaultHomeDir
$authorizedKeys = Ensure-AuthorizedKeys
$networkName = "cri-dev-net"

if (-not (Test-Path -LiteralPath $sharedPath -PathType Container)) {
    Fail ("Missing {0}. Create it first with .\windows\create-shared-data-dir.ps1." -f $sharedPath)
}

Ensure-Directory -Path $homePath
Ensure-ImageExists -ImageTag $imageTag
Ensure-NetworkExists -NetworkName $networkName
Ensure-PortAvailable -Port $sshPort -Description "SSH access"
Ensure-PortAvailable -Port $forwardPort -Description "forwarded container port 3879"

$legacyNames = @(
    (Get-ContainerName -Mode "cpu"),
    (Get-ContainerName -Mode "cuda"),
    ("{0}-NOPHI-dev" -f $userName),
    ("{0}-NOPHI-dev-cuda" -f $userName)
)

foreach ($legacyName in $legacyNames | Select-Object -Unique) {
    & docker rm -f $legacyName *> $null
}

$dockerArgs = @(
    "run", "-d",
    "--name", $containerName,
    "--hostname", $containerName,
    "--restart", "unless-stopped",
    "--network", $networkName,
    "-p", ("{0}:22" -f $sshPort),
    "-p", ("{0}:3879" -f $forwardPort),
    "-e", ("USERNAME={0}" -f $userName),
    "-e", "USER_UID=1000",
    "-e", "USER_GID=1000",
    "-v", ("{0}:/home/{1}" -f $homePath, $userName),
    "-v", ("{0}:/srv/NOPHI-shared" -f $sharedPath),
    "-v", ("{0}:/home/{1}/.ssh/authorized_keys:ro" -f $authorizedKeys.Path, $userName),
    "--label", ("owner={0}" -f $userName)
)

if ($runMode -eq "cuda") {
    $dockerArgs += @("--gpus", "all")
}

$dockerArgs += $imageTag

& docker @dockerArgs | Out-Null
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host ("Container started: {0}" -f $containerName)
if ($authorizedKeys.Empty) {
    Write-Host ("Populate {0} with a public key before connecting." -f $authorizedKeys.Path)
}
Write-Host ("SSH with: ssh -p {0} {1}@localhost" -f $sshPort, $userName)
Write-Host ("Forwarded container port 3879 is available on host port {0}." -f $forwardPort)
if ($Mode -eq "cuda" -and $runMode -ne "cuda") {
    Write-Host "CUDA request was treated as a no-op on this host; CPU container was started."
}
