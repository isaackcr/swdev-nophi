[CmdletBinding()]
param(
    [switch]$NoVerify
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/NOPHI.Windows.ps1"

Ensure-DockerAccess

$nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if (-not $nvidiaSmi) {
    $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
}

if (-not $nvidiaSmi) {
    Fail "nvidia-smi was not found. Install NVIDIA Windows drivers with WSL/Docker support first."
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Fail "wsl.exe was not found. Install WSL 2 first."
}

$wslOutput = & wsl.exe -l -v 2>$null
if ($LASTEXITCODE -ne 0) {
    Fail "Unable to query WSL distributions. Ensure WSL 2 is installed and working."
}

Write-Host "Detected NVIDIA driver tooling and WSL."
Write-Host "On Windows, Docker Desktop provides the GPU runtime integration. No Linux package installation was performed."

if (-not $NoVerify) {
    Write-Host "Verifying GPU access from Docker..."
    & docker run --rm --gpus all nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04 nvidia-smi
    if ($LASTEXITCODE -ne 0) {
        Fail "Docker GPU verification failed."
    }
}

Write-Host "Windows GPU readiness check complete."
