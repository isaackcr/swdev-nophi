[CmdletBinding()]
param(
    [switch]$Cpu,
    [switch]$Cuda,
    [string]$Tag
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/NOPHI.Windows.ps1"

Ensure-DockerAccess

$scriptRoot = Get-RepoRoot
$cpuBaseImage = "ubuntu:24.04"
$cpuImageTag = "nophi-dev:ubuntu24.04"
$cudaBaseImage = "nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04"
$cudaImageTag = "nophi-dev-cuda:cuda12.6.3"

$buildCpu = $true
$buildCuda = $true

if ($Cpu -or $Cuda) {
    $buildCpu = $Cpu.IsPresent
    $buildCuda = $Cuda.IsPresent
}

if ($buildCuda -and -not (Test-HostSupportsCuda)) {
    Write-Host "Notice: No NVIDIA GPU support detected on this host. Skipping CUDA image build."
    $buildCuda = $false
}

if ($Tag) {
    if ($buildCpu -and $buildCuda) {
        Fail "--Tag can only be used when building exactly one image."
    }

    if ($buildCpu) {
        $cpuImageTag = $Tag
    }
    else {
        $cudaImageTag = $Tag
    }
}

if ($buildCpu) {
    $cpuArgs = @(
        "build",
        "--build-arg", "BASE_IMAGE=$cpuBaseImage",
        "--build-arg", "INSTALL_NVTOP=false",
        "--tag", $cpuImageTag,
        "--file", (Join-Path $scriptRoot "Dockerfile"),
        $scriptRoot
    )
    & docker @cpuArgs
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    Write-Host ("Built CPU image '{0}' with base image '{1}'." -f $cpuImageTag, $cpuBaseImage)
}

if ($buildCuda) {
    $cudaArgs = @(
        "build",
        "--build-arg", "BASE_IMAGE=$cudaBaseImage",
        "--build-arg", "INSTALL_NVTOP=true",
        "--tag", $cudaImageTag,
        "--file", (Join-Path $scriptRoot "Dockerfile"),
        $scriptRoot
    )
    & docker @cudaArgs
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    Write-Host ("Built CUDA image '{0}' with base image '{1}'." -f $cudaImageTag, $cudaBaseImage)
}

if (-not $buildCpu -and -not $buildCuda) {
    Write-Host "No images were built."
}
