[CmdletBinding()]
param(
    [string]$Container,
    [string]$DnsServer = "172.19.20.19",
    [string[]]$AllowIp = @("172.19.21.28"),
    [string[]]$BlockedTarget = @("172.19.20.19", "172.19.149.1"),
    [int]$Timeout = 4
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/NOPHI.Windows.ps1"

Ensure-DockerAccess

if ($Timeout -lt 1) {
    Fail "Timeout must be a positive integer."
}

if (-not $Container) {
    $candidates = Get-RunningNophiContainersForCurrentUser
    if (-not $candidates -or $candidates.Count -eq 0) {
        Fail ("No running NOPHI container found for user '{0}'. Pass -Container NAME." -f (Get-SafeUserName))
    }

    if ($candidates.Count -gt 1) {
        $list = ($candidates | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
        Fail ("Multiple running NOPHI containers found for the current user:`n{0}`nPass -Container NAME to choose one." -f $list)
    }

    $Container = $candidates[0]
}

& docker container inspect $Container *> $null
if ($LASTEXITCODE -ne 0) {
    Fail ("Container not found: {0}" -f $Container)
}

$runningState = (& docker inspect -f "{{.State.Running}}" $Container).Trim()
if ($LASTEXITCODE -ne 0 -or $runningState -ne "true") {
    Fail ("Container is not running: {0}" -f $Container)
}

function Invoke-InContainer {
    param([Parameter(Mandatory = $true)][string]$Command)

    $output = & docker exec $Container bash -lc $Command 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output | Out-String).TrimEnd()
    }
}

$internetHost = "1.1.1.1"
$internetPort = 443
$dnsPort = 53
$blockedPort = 443
$script:testsFailed = 0
$script:testIndex = 0
$script:totalTests = 2 + $AllowIp.Count + $BlockedTarget.Count

function Write-TestHeader {
    param([Parameter(Mandatory = $true)][string]$Description)

    $script:testIndex += 1
    Write-Host ("[{0}/{1}] {2}" -f $script:testIndex, $script:totalTests, $Description)
}

function Write-TestResult {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Details
    )

    Write-Host ("  {0}" -f $Status)
    if ($Details) {
        foreach ($line in ($Details -split "`r?`n")) {
            if ($line) {
                Write-Host ("  {0}" -f $line)
            }
        }
    }
    Write-Host ""
}

function Run-ExpectSuccess {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Command
    )

    Write-TestHeader -Description $Description
    $result = Invoke-InContainer -Command $Command

    if ($result.ExitCode -eq 0) {
        Write-TestResult -Status "PASS" -Details $result.Output
    }
    else {
        $script:testsFailed += 1
        Write-TestResult -Status "FAIL (expected success)" -Details $result.Output
    }
}

function Run-ExpectTcpReachable {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Command
    )

    Write-TestHeader -Description $Description
    $result = Invoke-InContainer -Command $Command

    if ($result.ExitCode -eq 0) {
        Write-TestResult -Status "PASS" -Details $result.Output
    }
    elseif ($result.Output -match "Connection refused") {
        Write-TestResult -Status "PASS (reachable, connection refused)" -Details $result.Output
    }
    else {
        $script:testsFailed += 1
        Write-TestResult -Status "FAIL (expected TCP reachability)" -Details $result.Output
    }
}

function Run-ExpectFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Command
    )

    Write-TestHeader -Description $Description
    $result = Invoke-InContainer -Command $Command

    if ($result.ExitCode -eq 0) {
        $script:testsFailed += 1
        Write-TestResult -Status "FAIL (expected block/failure)" -Details $result.Output
    }
    else {
        Write-TestResult -Status "PASS (blocked as expected)" -Details $result.Output
    }
}

Write-Host ("Running egress tests from container: {0}" -f $Container)
Write-Host ("Timeout per probe: {0}s" -f $Timeout)
Write-Host ""

Run-ExpectSuccess -Description ("Internet TCP egress to {0}:{1}" -f $internetHost, $internetPort) -Command ("nc -z -w {0} {1} {2}" -f $Timeout, $internetHost, $internetPort)
Run-ExpectSuccess -Description ("Allowed DNS TCP egress to {0}:{1}" -f $DnsServer, $dnsPort) -Command ("nc -z -w {0} {1} {2}" -f $Timeout, $DnsServer, $dnsPort)

foreach ($allowTarget in $AllowIp) {
    Run-ExpectTcpReachable -Description ("Allowed TCP connectivity to {0}:{1}" -f $allowTarget, $blockedPort) -Command ("nc -z -v -w {0} {1} {2}" -f $Timeout, $allowTarget, $blockedPort)
}

foreach ($blocked in $BlockedTarget) {
    Run-ExpectFailure -Description ("Blocked egress to {0}:{1}" -f $blocked, $blockedPort) -Command ("nc -z -w {0} {1} {2}" -f $Timeout, $blocked, $blockedPort)
}

if ($script:testsFailed -gt 0) {
    Write-Host ("Egress test run complete: {0} test(s) failed." -f $script:testsFailed)
    exit 1
}

Write-Host "Egress test run complete: all tests passed."
