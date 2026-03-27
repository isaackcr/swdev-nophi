Set-StrictMode -Version Latest

$script:WindowsRoot = $PSScriptRoot
$script:RepoRoot = Split-Path -Parent $script:WindowsRoot

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)

    throw $Message
}

function Get-RepoRoot {
    return $script:RepoRoot
}

function Get-WindowsScriptsRoot {
    return $script:WindowsRoot
}

function Get-CurrentUserName {
    if ($env:USERNAME) {
        return $env:USERNAME
    }

    return [Environment]::UserName
}

function Get-SafeUserName {
    $safeUser = (Get-CurrentUserName).ToLowerInvariant() -replace '[^a-z0-9_-]', '-'
    $safeUser = $safeUser.Trim('-')

    if (-not $safeUser) {
        return "devuser"
    }

    return $safeUser
}

function Get-ComputerNameSafe {
    if ($env:COMPUTERNAME) {
        $hostName = $env:COMPUTERNAME
    }
    else {
        $hostName = [System.Net.Dns]::GetHostName()
    }

    $safeHost = $hostName.ToLowerInvariant() -replace '[^a-z0-9_.-]', '-'
    $safeHost = $safeHost.Trim('-')

    if (-not $safeHost) {
        return "host"
    }

    return $safeHost
}

function Get-CurrentUserSid {
    return ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
}

function Get-PortOffset {
    $sidBytes = [System.Text.Encoding]::UTF8.GetBytes((Get-CurrentUserSid))
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hashBytes = $sha256.ComputeHash($sidBytes)
    }
    finally {
        $sha256.Dispose()
    }

    return [int]([BitConverter]::ToUInt32($hashBytes, 0) % 10000)
}

function Get-SshPort {
    return 40000 + (Get-PortOffset)
}

function Get-ForwardPort {
    return 50000 + (Get-PortOffset)
}

function Get-DefaultSharedDir {
    return Join-Path $env:USERPROFILE "NOPHI-shared"
}

function Get-DefaultHomeDir {
    return Join-Path $env:USERPROFILE ("NOPHI-home-{0}" -f (Get-ComputerNameSafe))
}

function Get-AuthorizedKeysPath {
    return Join-Path (Join-Path $env:USERPROFILE ".ssh") "authorized_keys"
}

function Ensure-DockerAccess {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Fail "docker command not found. Install Docker Desktop first."
    }

    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Fail "Docker is installed but not usable right now. Ensure Docker Desktop is running, then retry."
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Ensure-AuthorizedKeys {
    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    $authKeys = Join-Path $sshDir "authorized_keys"
    $createdAuthKeys = $false

    Ensure-Directory -Path $sshDir

    if (-not (Test-Path -LiteralPath $authKeys)) {
        New-Item -ItemType File -Path $authKeys -Force | Out-Null
        $createdAuthKeys = $true
    }

    return [pscustomobject]@{
        Path = $authKeys
        Created = $createdAuthKeys
        Empty = ((Get-Item -LiteralPath $authKeys).Length -eq 0)
    }
}

function Test-HostSupportsCuda {
    $nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    }

    if (-not $nvidiaSmi) {
        return $false
    }

    # docker run prints to stderr when pulling/checking the image, which triggers
    # a terminating error under $ErrorActionPreference = "Stop". Wrap in try/catch.
    try {
        & docker run --rm --gpus all nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04 nvidia-smi *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Get-ContainerName {
    param([Parameter(Mandatory = $true)][ValidateSet("cpu", "cuda")][string]$Mode)

    $userName = Get-SafeUserName
    $hostName = Get-ComputerNameSafe

    if ($Mode -eq "cuda") {
        return "{0}-NOPHI-{1}-cuda" -f $userName, $hostName
    }

    return "{0}-NOPHI-{1}" -f $userName, $hostName
}

function Resolve-RunMode {
    param([Parameter(Mandatory = $true)][ValidateSet("auto", "cpu", "cuda")][string]$RequestedMode)

    if ($RequestedMode -eq "cpu") {
        return "cpu"
    }

    if (Test-HostSupportsCuda) {
        return "cuda"
    }

    if ($RequestedMode -eq "cuda") {
        Write-Warning "CUDA mode requested but unavailable. Continuing in CPU mode."
    }

    return "cpu"
}

function Get-ImageTagForMode {
    param([Parameter(Mandatory = $true)][ValidateSet("cpu", "cuda")][string]$Mode)

    if ($Mode -eq "cuda") {
        return "nophi-dev-cuda:cuda12.6.3"
    }

    return "nophi-dev:ubuntu24.04"
}

function Get-BuildHintForMode {
    param([Parameter(Mandatory = $true)][ValidateSet("cpu", "cuda")][string]$Mode)

    if ($Mode -eq "cuda") {
        return ".\windows\build-NOPHI-dev.ps1 -Cuda"
    }

    return ".\windows\build-NOPHI-dev.ps1 -Cpu"
}

function Ensure-ImageExists {
    param([Parameter(Mandatory = $true)][string]$ImageTag)

    & docker image inspect $ImageTag *> $null
    if ($LASTEXITCODE -ne 0) {
        $mode = if ($ImageTag -like "*cuda*") { "cuda" } else { "cpu" }
        Fail ("Missing Docker image {0}. Build it first with: {1}" -f $ImageTag, (Get-BuildHintForMode -Mode $mode))
    }
}

function Ensure-NetworkExists {
    param([Parameter(Mandatory = $true)][string]$NetworkName)

    & docker network inspect $NetworkName *> $null
    if ($LASTEXITCODE -ne 0) {
        Fail ("Missing Docker network {0}. Create it first with .\windows\create-docker-networks.ps1." -f $NetworkName)
    }
}

function Get-RunningNophiContainersForCurrentUser {
    $ownerLabel = Get-SafeUserName
    $names = & docker ps --filter "label=owner=$ownerLabel" --format "{{.Names}}"
    if ($LASTEXITCODE -ne 0) {
        Fail "Unable to query running containers."
    }

    return @($names | Where-Object { $_ -and $_ -match "-NOPHI-" })
}

function Test-PortAvailable {
    param([Parameter(Mandatory = $true)][int]$Port)

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)

    try {
        $listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $listener) {
            $listener.Stop()
        }
    }
}

function Ensure-PortAvailable {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($Port -lt 1 -or $Port -gt 65535) {
        Fail ("Derived port {0} is invalid for {1}." -f $Port, $Description)
    }

    if (-not (Test-PortAvailable -Port $Port)) {
        Fail ("Port {0} for {1} is already in use on this host." -f $Port, $Description)
    }
}