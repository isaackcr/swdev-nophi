[CmdletBinding()]
param(
    [string]$NetworkName = "cri-dev-net",
    [string]$DnsServer = "172.19.20.19",
    [string[]]$AllowIp = @("172.19.21.28"),
    [string[]]$BlockSubnet = @("172.19.20.0/23", "172.19.149.0/26")
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/NOPHI.Windows.ps1"

Ensure-DockerAccess

$message = @"
This Windows port fails closed by design.

The Linux version of configure-docker-egress-filtering relies on host-level iptables rules attached to a Docker bridge interface. Docker Desktop on Windows with the WSL 2 backend does not expose a supported per-network equivalent that this repository can configure safely.

Requested network: $NetworkName
Requested DNS server: $DnsServer
Requested allow IPs: $($AllowIp -join ", ")
Requested blocked subnets: $($BlockSubnet -join ", ")

Use a Linux Docker host for enforced per-network egress filtering, or enforce an equivalent boundary outside Docker Desktop before using this environment for regulated workflows.
"@

Fail $message
