# Windows Port

This directory contains a Windows-native PowerShell port of the NOPHI host scripts for Docker Desktop with the WSL 2 backend.

These scripts run from Windows PowerShell and talk to Docker directly. They do not shell out to the Linux `.sh` scripts.

## Prerequisites

1. Install Docker Desktop for Windows.
2. Enable Linux containers and the WSL 2 backend in Docker Desktop.
3. Install WSL 2.
4. If you need CUDA, install current NVIDIA Windows drivers with WSL/Docker support.
5. Clone this repository onto a Windows-accessible path such as `%USERPROFILE%\src\NOPHI-dev`.

## Script Map

- `install-NOPHI-dev.ps1`
  Windows setup helper that runs:
  - `create-shared-data-dir.ps1`
  - `create-docker-networks.ps1`
  - `build-NOPHI-dev.ps1`
  - `install-nophi-commands.ps1`

- `create-shared-data-dir.ps1`
  Creates the default shared directory at `%USERPROFILE%\NOPHI-shared`.

- `create-docker-networks.ps1`
  Creates `cri-dev-net` and `cri-collab-net` with the same subnets as Linux.

- `build-NOPHI-dev.ps1`
  Builds the CPU and optional CUDA images.

- `nophi-start.ps1`
  Starts the NOPHI container from Windows.

- `nophi-remove.ps1`
  Removes the NOPHI container from Windows.

- `install-nophi-commands.ps1`
  Installs `nophi-start.cmd` and `nophi-remove.cmd` into a Windows bin directory.

- `test-nophi-egress.ps1`
  Runs the same container-side `nc` connectivity checks from Windows.

- `setup-nvidia-container-toolkit.ps1`
  Windows-specific GPU readiness check for Docker Desktop. It verifies prerequisites instead of installing Linux packages.

- `configure-docker-egress-filtering.ps1`
  Explicit fail-closed script. Per-network `iptables` enforcement from the Linux host does not have a supported equivalent on Docker Desktop for Windows.

## Security Note

The Linux egress policy in this repository depends on host-level `iptables` rules attached to a Docker bridge interface. Docker Desktop on Windows does not expose a supported per-network equivalent.

Because this is a HIPAA-regulated environment, the Windows port does not pretend that boundary exists. The Windows egress configuration script fails closed and tells you to use a Linux host or another externally enforced network control if you need the same guarantee.

## Examples

Initial setup:

```powershell
.\windows\install-NOPHI-dev.ps1
```

CPU-only build during setup:

```powershell
.\windows\install-NOPHI-dev.ps1 -Cpu
```

Start a container:

```powershell
.\windows\nophi-start.ps1
```

Prefer CUDA mode:

```powershell
.\windows\nophi-start.ps1 -Mode cuda
```

Install convenience commands:

```powershell
.\windows\install-nophi-commands.ps1
```

Test current egress behavior from the running container:

```powershell
.\windows\test-nophi-egress.ps1
```

## Installed Paths

Default Windows host paths:

- Home workspace: `%USERPROFILE%\NOPHI-home-%COMPUTERNAME%`
- Shared directory: `%USERPROFILE%\NOPHI-shared`
- SSH public keys: `%USERPROFILE%\.ssh\authorized_keys`

## PATH Note

`install-nophi-commands.ps1` installs `.cmd` shims into `%LOCALAPPDATA%\NOPHI\bin` by default. Add that directory to your Windows `PATH` if you want to run `nophi-start` and `nophi-remove` directly.
