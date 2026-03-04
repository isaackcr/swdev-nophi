# NOPHI-dev

Docker-based development environment for NOPHI with:
- Ubuntu and optional CUDA base images
- Per-user dev container startup/removal scripts
- Shared host data directory setup
- Dedicated Docker bridge network setup
- Docker network egress filtering via `iptables`, prevents access to internal networks but Internet is allowed.

## Getting Started as a Developer (After server has already been setup)

The purpose of this project is to provide a sandboxed container for software development with AI coding tools that must not access PHI.

**NEVER** place PHI in either host-mounted path or copy it to your container:
- `${HOME}/NOPHI-home` (your personal persistent workspace, created for you)
- `/srv/NOPHI-data` (shared data directory, created for you)

Network boundary: these containers cannot access internal hosts or internal network resources. They can reach external Internet endpoints and other containers attached to `cri-collab-net`.

**NEVER** allow PHI to be accessed by these containers or transferred over any network path, including SSH.

Assumptions:
- [Docker](https://docs.docker.com/engine/install/ubuntu/) is installed and usable by your user.
- All of the installation steps at the bottom of this document were completed by an admin already.
- Your own `${HOME}/.ssh/authorized_keys` already exists.

1. Clone this Git repo.

```bash
git clone <repo-url>
```

2. Move into the cloned repository.

```bash
cd NOPHI-dev
```

3. Start your container (CPU or GPU).

CPU:

```bash
./start-NOPHI-dev.sh
```

CUDA (Use CUDA mode only if the server has NVIDIA GPUs, Docker GPU runtime support is configured, and the CUDA image is available):

```bash
./start-NOPHI-dev.sh --cuda
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
  - `${HOME}/.ssh/authorized_keys -> /home/${USER}/.ssh/authorized_keys` (required, read-only)
    Used for SSH access to the container user account.
- SSH port is derived as `40000 + $(id -u)`

4. Stop/remove your container when needed.

CPU:

```bash
./remove-NOPHI-dev.sh
```

CUDA:

```bash
./remove-NOPHI-dev.sh --cuda
```

---

## Server Prep/Installation

Use this section for first-time host setup.

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

Optional collaboration network:

```bash
./create-docker-networks.sh --collab
```

Defaults used:
- `cri-dev-net`: `192.168.240.0/24`, gateway `192.168.240.1`
- `cri-collab-net`: `192.168.241.0/24`, gateway `192.168.241.1` (optional)

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

8. Build the container image.

CPU image:

```bash
./build-NOPHI-dev.sh
```

CUDA image:

```bash
./build-NOPHI-dev.sh --cuda
```

Custom tag:

```bash
./build-NOPHI-dev.sh --tag my-image:latest
```

## Script Reference

- `build-NOPHI-dev.sh`
  - Builds CPU or CUDA image from `Dockerfile`
- `start-NOPHI-dev.sh`
  - Starts per-user container on `cri-dev-net`
- `remove-NOPHI-dev.sh`
  - Removes per-user CPU/CUDA container
- `create-shared-data-dir.sh`
  - Prepares `/srv/NOPHI-data` and `cri-shared` membership
- `create-docker-networks.sh`
  - Ensures Docker bridge networks with fixed `192.168.x.x` subnets
- `configure-docker-egress-filtering.sh`
  - Applies per-network Docker egress policy in `DOCKER-USER`
- `setup-nvidia-container-toolkit.sh`
  - Installs/configures NVIDIA Container Toolkit so Docker can run CUDA containers with `--gpus all`
