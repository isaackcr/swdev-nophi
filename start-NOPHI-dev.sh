#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./start-NOPHI-dev.sh [--cpu|--cuda]

Starts the NOPHI dev container:
  default mode: auto (CUDA if available, otherwise CPU)
  --cpu: force CPU mode
  --cuda: prefer CUDA mode (falls back to CPU if unavailable)
EOF
}

REQUEST_MODE="auto"
while (($# > 0)); do
  case "$1" in
    --cpu)
      if [[ "${REQUEST_MODE}" == "cuda" ]]; then
        echo "Error: --cpu and --cuda cannot be used together."
        usage
        exit 1
      fi
      REQUEST_MODE="cpu"
      shift
      ;;
    --cuda)
      if [[ "${REQUEST_MODE}" == "cpu" ]]; then
        echo "Error: --cpu and --cuda cannot be used together."
        usage
        exit 1
      fi
      REQUEST_MODE="cuda"
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

USER_NAME="${USER:-$(id -un)}"
UID_NUM="$(id -u)"
GID_NUM="$(id -g)"
PORT="$((40000 + UID_NUM))"
NAME=""
IMAGE=""
IMAGE_BUILD_HINT=""
NOPHI_HOME="${HOME}/NOPHI-home"
SHARED="/srv/NOPHI-data"
DEV_NET_NAME="cri-dev-net"
DOCKER_GPU_ARGS=()
RUN_MODE="cpu"

fail() {
  echo "Error: $*" >&2
  exit 1
}

ensure_docker_access() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "docker command not found. Install Docker first."
  fi

  if docker info >/dev/null 2>&1; then
    return
  fi

  if id -nG "${USER_NAME}" 2>/dev/null | tr ' ' '\n' | grep -Fxq "docker"; then
    fail "Docker is installed but not usable right now. Ensure the Docker daemon is running, then retry."
  fi

  fail "User ${USER_NAME} does not have Docker access. Run: sudo usermod -aG docker ${USER_NAME}, then log out and back in."
}

ensure_authorized_keys() {
  local ssh_dir="${HOME}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  mkdir -p "${ssh_dir}" || fail "Unable to create ${ssh_dir}."
  chmod 700 "${ssh_dir}" || fail "Unable to set permissions on ${ssh_dir}."

  if [[ ! -f "${auth_keys}" ]]; then
    touch "${auth_keys}" || fail "Unable to create ${auth_keys}."
    echo "Created ${auth_keys}."
  fi

  chmod 600 "${auth_keys}" || fail "Unable to set permissions on ${auth_keys}."

  if [[ ! -s "${auth_keys}" ]]; then
    echo "Warning: ${auth_keys} is empty. Add your public SSH key before connecting to the container." >&2
  fi
}

ensure_shared_access() {
  if [[ ! -d "${SHARED}" ]]; then
    fail "Missing ${SHARED}. Run ./create-shared-data-dir.sh once with sudo access."
  fi

  if [[ ! -r "${SHARED}" || ! -w "${SHARED}" || ! -x "${SHARED}" ]]; then
    fail "No read/write/execute access to ${SHARED}. Ask an admin to grant access."
  fi
}

ensure_image_exists() {
  if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    fail "Missing Docker image ${IMAGE}. Build it first with: ${IMAGE_BUILD_HINT}"
  fi
}

cuda_mode_available() {
  command -v nvidia-smi >/dev/null 2>&1 \
    && nvidia-smi -L >/dev/null 2>&1 \
    && docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'
}

configure_mode() {
  if [[ "$1" == "cuda" ]]; then
    NAME="${USER_NAME}-NOPHI-${HOSTNAME}-cuda"
    IMAGE="nophi-dev-cuda:cuda12.6.3"
    IMAGE_BUILD_HINT="./build-NOPHI-dev.sh --cuda"
    DOCKER_GPU_ARGS=(--gpus all)
  else
    NAME="${USER_NAME}-NOPHI-${HOSTNAME}"
    IMAGE="nophi-dev:ubuntu24.04"
    IMAGE_BUILD_HINT="./build-NOPHI-dev.sh --cpu"
    DOCKER_GPU_ARGS=()
  fi
}

resolve_mode() {
  if [[ "${REQUEST_MODE}" == "cpu" ]]; then
    RUN_MODE="cpu"
    return
  fi

  if cuda_mode_available; then
    RUN_MODE="cuda"
    return
  fi

  if [[ "${REQUEST_MODE}" == "cuda" ]]; then
    echo "Warning: CUDA mode requested but unavailable. Continuing in CPU mode."
  fi
  RUN_MODE="cpu"
}

ensure_dev_network() {
  if ! docker network inspect "${DEV_NET_NAME}" >/dev/null 2>&1; then
    fail "Missing Docker network ${DEV_NET_NAME}. It must be created during server setup (run ./create-docker-networks.sh as an admin)."
  fi
}

if (( PORT > 65535 )); then
  fail "Derived port ${PORT} is invalid for UID ${UID_NUM}."
fi

mkdir -p "${NOPHI_HOME}"

ensure_docker_access
resolve_mode
configure_mode "${RUN_MODE}"
ensure_authorized_keys
ensure_shared_access
ensure_image_exists
ensure_dev_network

docker rm -f "${USER_NAME}-NOPHI-${HOSTNAME}" >/dev/null 2>&1 || true
docker rm -f "${USER_NAME}-NOPHI-${HOSTNAME}-cuda" >/dev/null 2>&1 || true
docker rm -f "${USER_NAME}-NOPHI-dev" >/dev/null 2>&1 || true
docker rm -f "${USER_NAME}-NOPHI-dev-cuda" >/dev/null 2>&1 || true

docker run -d \
  --name "${NAME}" \
  --hostname "${NAME}" \
  --restart unless-stopped \
  "${DOCKER_GPU_ARGS[@]}" \
  --network "${DEV_NET_NAME}" \
  -p "${PORT}:22" \
  -e USERNAME="${USER_NAME}" \
  -e USER_UID="${UID_NUM}" \
  -e USER_GID="${GID_NUM}" \
  -v "${NOPHI_HOME}:/home/${USER_NAME}" \
  -v "${SHARED}:/data" \
  -v "${HOME}/.ssh/authorized_keys:/home/${USER_NAME}/.ssh/authorized_keys:ro" \
  --label owner="${USER_NAME}" \
  "${IMAGE}" >/dev/null

echo "Container started: ${NAME}"
echo "SSH with: ssh -p ${PORT} ${USER_NAME}@$(hostname)"
if [[ "${REQUEST_MODE}" == "cuda" && "${RUN_MODE}" != "cuda" ]]; then
  echo "CUDA request was treated as a no-op on this host; CPU container was started."
fi
