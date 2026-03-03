# NOPHI-dev

Docker-based development environment for NOPHI with:
- Ubuntu and optional CUDA base images
- Per-user dev container startup/removal scripts
- Shared host data directory setup
- Dedicated Docker bridge network setup
- Optional Docker egress filtering via `iptables`

## Installation

Assumption: Docker is already installed and usable by your user.

1. Move into this directory.

```bash
cd /path/to/NOPHI-dev
```

2. Configure the shared data directory (requires sudo).

```bash
./create-shared-data-dir.sh
```

What this does:
- Ensures Linux group `cri-shared` exists
- Ensures `/srv/NOPHI-data` exists
- Applies group ownership/permissions (`2775`)
- Adds your user to `cri-shared` if needed

If your user was newly added to `cri-shared`, log out and back in before continuing.

3. Create Docker bridge networks.

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

4. Optional: Configure Docker egress filtering for `cri-dev-net` (requires sudo).

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

5. Build the container image.

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

## Run

Start CPU container:

```bash
./start-NOPHI-dev.sh
```

Start CUDA container:

```bash
./start-NOPHI-dev.sh --cuda
```

Startup behavior:
- Container name:
  - CPU: `${USER}-NOPHI-dev`
  - CUDA: `${USER}-NOPHI-dev-cuda`
- Docker image:
  - CPU: `NOPHI-dev:ubuntu24.04`
  - CUDA: `NOPHI-dev-cuda:cuda12.6.3`
- Mounts:
  - `${HOME}/NOPHI-workspace -> /workspace`
  - `/srv/NOPHI-data -> /data`
  - `${HOME}/.ssh/authorized_keys` (required) -> container user `~/.ssh/authorized_keys`
- SSH port is derived as `20000 + $(id -u)`
- If `cri-dev-net` is missing, it is auto-created by `start-NOPHI-dev.sh`
- `--gpus all` is applied only in `--cuda` mode

## Stop/Remove

Remove CPU container:

```bash
./remove-NOPHI-dev
```

Remove CUDA container:

```bash
./remove-NOPHI-dev --cuda
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
