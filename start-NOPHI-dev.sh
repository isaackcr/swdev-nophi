#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./start-NOPHI-dev [--cuda]

Starts the NOPHI dev container:
  default image: NOPHI-dev:ubuntu24.04
  CUDA image:    NOPHI-dev-cuda:cuda12.6.3 (with --cuda)
EOF
}

USE_CUDA=false
while (($# > 0)); do
  case "$1" in
    --cuda)
      USE_CUDA=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'."
      usage
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UID_NUM="$(id -u)"
GID_NUM="$(id -g)"
PORT="$((20000 + UID_NUM))"
NAME="${USER}-NOPHI-dev"
IMAGE="NOPHI-dev:ubuntu24.04"
WORKSPACE="${HOME}/NOPHI-workspace"
SHARED="/srv/NOPHI-data"
DOCKER_GPU_ARGS=()

if [[ "${USE_CUDA}" == "true" ]]; then
  NAME="${USER}-NOPHI-dev-cuda"
  IMAGE="NOPHI-dev-cuda:cuda12.6.3"
  DOCKER_GPU_ARGS=(--gpus all)
fi

if (( PORT > 65535 )); then
  echo "Derived port ${PORT} is invalid for UID ${UID_NUM}."
  exit 1
fi

mkdir -p "${WORKSPACE}"

if [[ ! -f "${HOME}/.ssh/authorized_keys" ]]; then
  echo "Missing ${HOME}/.ssh/authorized_keys on cri-gpu."
  exit 1
fi

if [[ ! -d "${SHARED}" ]]; then
  echo "Missing ${SHARED}. Run ./create-shared-data-dir.sh once with sudo access."
  exit 1
fi

if ! docker network inspect cri-dev-net >/dev/null 2>&1; then
  echo "Creating missing Docker network: cri-dev-net"
  bash "${SCRIPT_DIR}/create-docker-networks.sh"
fi

docker rm -f "${NAME}" >/dev/null 2>&1 || true

docker run -d \
  --name "${NAME}" \
  --hostname "${NAME}" \
  --restart unless-stopped \
  "${DOCKER_GPU_ARGS[@]}" \
  --network cri-dev-net \
  -p "${PORT}:22" \
  -e USERNAME="${USER}" \
  -e USER_UID="${UID_NUM}" \
  -e USER_GID="${GID_NUM}" \
  -v "${WORKSPACE}:/workspace" \
  -v "${SHARED}:/data" \
  -v "${HOME}/.ssh/authorized_keys:/home/${USER}/.ssh/authorized_keys:ro" \
  --label owner="${USER}" \
  "${IMAGE}" >/dev/null

echo "Container started: ${NAME}"
echo "SSH with: ssh -p ${PORT} ${USER}@${HOSTNAME}"
