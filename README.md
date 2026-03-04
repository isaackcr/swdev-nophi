# NOPHI-dev

Docker-based development environment for NOPHI with:
- Ubuntu and optional CUDA base images
- Per-user dev container startup/removal scripts
- Shared host data directory setup
- Dedicated Docker bridge network setup
- Docker network egress filtering via `iptables`, prevents access to internal networks but Internet is allowed.

## Getting Started as a Developer (After server has already been set up)

The purpose of this project is to provide a sandboxed container for software development with AI coding tools that must not access PHI.

**NEVER** place PHI in either host-mounted path or copy it to your container:
- `${HOME}/NOPHI-home` (your personal persistent workspace, created for you)
- `/srv/NOPHI-data` (shared data directory, created for you)

Network boundary: these containers cannot access internal hosts or internal network resources. They can reach external Internet endpoints and other containers attached to `cri-collab-net`.

**NEVER** allow PHI to be accessed by these containers or transferred over any network path, including SSH.

Assumptions:
- [Docker](https://docs.docker.com/engine/install/ubuntu/) is installed and usable by your user.
- All of the installation steps at the bottom of this document were completed by an admin already.
- `nophi-start` and `nophi-remove` were installed by an admin and are on your `PATH`.
- Docker network `cri-dev-net` was created during server setup.
- Your public key is in `${HOME}/.ssh/authorized_keys` for SSH access (the file is auto-created if missing, but you still need to add a key).

1. Start your container.

Auto-select mode (uses CUDA when available, otherwise CPU):

```bash
nophi-start
```

Force CPU mode:

```bash
nophi-start --cpu
```

Prefer CUDA mode (falls back to CPU if CUDA is unavailable):

```bash
nophi-start --cuda
```

Startup behavior:
- Container name:
  - CPU: `${USER}-NOPHI-dev`
  - CUDA: `${USER}-NOPHI-dev-cuda`
- Mounts:
  - `${HOME}/NOPHI-home -> /home/${USER}`
    Personal, persistent workspace (auto-created if missing). Use this for cloning repos and development work. Data here persists across container restarts/removals. NEVER store PHI data here.
  - `/srv/NOPHI-data -> /data`
    Shared NOPHI data directory (created during server setup). NEVER store PHI data here.
  - `${HOME}/.ssh/authorized_keys -> /home/${USER}/.ssh/authorized_keys` (read-only)
    Used for SSH access to the container user account. The host file is auto-created if missing.
- SSH port is derived as `40000 + $(id -u)`

2. Stop/remove your container.

Auto-select target (prefers CUDA target when available, otherwise CPU; if that container does not exist, it tries the other target):

```bash
nophi-remove
```

Force CPU target:

```bash
nophi-remove --cpu
```

Prefer CUDA target (falls back to CPU if CUDA is unavailable):

```bash
nophi-remove --cuda
```

---

## Server Prep/Installation

Use this section for first-time host setup by an admin.

1. Clone this Git repo.

```bash
git clone <repo-url>
```

2. Move into the cloned repository.

```bash
cd NOPHI-dev
```

3. Configure the shared data directory (requires sudo).

```bash
./create-shared-data-dir.sh
```

What this does:
- Ensures Linux group `cri-shared` exists
- Ensures `/srv/NOPHI-data` exists
- Applies group ownership/permissions (`2775`)
- Adds your user to `cri-shared` if needed

If your user was newly added to `cri-shared`, log out and back in before continuing.

4. Create Docker bridge networks.

```bash
./create-docker-networks.sh
```

This creates both networks:
- `cri-dev-net`: `192.168.240.0/24`, gateway `192.168.240.1`
- `cri-collab-net`: `192.168.241.0/24`, gateway `192.168.241.1`

5. Optional (CUDA only): Configure NVIDIA Container Toolkit on the host (requires sudo).

```bash
./setup-nvidia-container-toolkit.sh
```

If your host already supports `docker run --gpus all ...`, you can skip this step.

6. Optional: Configure Docker egress filtering for `cri-dev-net` (requires sudo).

```bash
./configure-docker-egress-filtering.sh
```

Default egress policy:
- Applies only to containers attached to `cri-dev-net`
- Allows established/related return traffic
- Allows same-network container-to-container traffic
- Allows DNS to `172.19.20.19` on TCP/UDP 53
- Blocks internal subnets with `REJECT --reject-with icmp-port-unreachable`:
  - `172.19.20.0/23`
  - `172.19.149.0/26`
- Allows all other egress

Add more blocked networks as needed:

```bash
./configure-docker-egress-filtering.sh \
  --block-subnet 172.19.30.0/24 \
  --block-subnet 10.42.0.0/16
```

7. If UFW is enabled on the host, allow inbound SSH port range for remote clients.

```bash
sudo ufw allow from 172.19.149.0/24 to any port 42000:43000 proto tcp
sudo ufw allow from 172.19.20.0/24 to any port 42000:43000 proto tcp
sudo ufw status numbered
```

Without these rules, SSH from another client may be blocked even when the container is running.

8. Build container images.

Build both CPU and CUDA images (default):

```bash
./build-NOPHI-dev.sh
```

Build CPU image only:

```bash
./build-NOPHI-dev.sh --cpu
```

Build CUDA image only (if the server has NVIDIA GPUs and developers will use CUDA):

```bash
./build-NOPHI-dev.sh --cuda
```

On non-GPU servers, CUDA build paths are treated as no-ops and skipped.

Custom tag (single-image build only):

```bash
./build-NOPHI-dev.sh --cpu --tag my-image:latest
```

9. Install global developer commands (requires sudo).

```bash
./install-nophi-commands.sh
```

Custom install prefix:

```bash
./install-nophi-commands.sh --prefix /opt/nophi/bin
```

If you use a custom prefix, ensure it is on each developer's `PATH`.

This installs:
- `nophi-start`
- `nophi-remove`

10. Ensure each developer account can run containers and access shared data.

For each developer user:
- Add to `docker` group
- Add to `cri-shared` group
- Ensure `~/.ssh/authorized_keys` contains their public SSH key

Example:

```bash
sudo usermod -aG docker,cri-shared <username>
```

Users added to new groups must log out and back in.

## Script Reference

- `build-NOPHI-dev.sh`
  - Builds CPU and CUDA images by default, or selected image(s) with `--cpu` / `--cuda`
- `start-NOPHI-dev.sh`
  - Starts per-user container on `cri-dev-net` with auto CPU/CUDA selection (`--cpu` / `--cuda` supported)
- `remove-NOPHI-dev.sh`
  - Removes per-user container with auto CPU/CUDA target selection (`--cpu` / `--cuda` supported)
- `create-shared-data-dir.sh`
  - Prepares `/srv/NOPHI-data` and `cri-shared` membership
- `create-docker-networks.sh`
  - Ensures Docker bridge networks with fixed `192.168.x.x` subnets
- `configure-docker-egress-filtering.sh`
  - Applies per-network Docker egress policy in `DOCKER-USER`
- `setup-nvidia-container-toolkit.sh`
  - Installs/configures NVIDIA Container Toolkit so Docker can run CUDA containers with `--gpus all`
- `install-nophi-commands.sh`
  - Installs `nophi-start` and `nophi-remove` into `/usr/local/bin` (or a custom prefix)
