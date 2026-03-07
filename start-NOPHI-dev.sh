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

resolve_effective_user() {
  if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
    return
  fi

  if [[ -n "${USER:-}" ]]; then
    echo "${USER}"
    return
  fi

  id -un
}

resolve_user_home() {
  local user_name="$1"

  if command -v getent >/dev/null 2>&1; then
    getent passwd "${user_name}" | cut -d: -f6
    return
  fi

  if command -v dscl >/dev/null 2>&1; then
    dscl . -read "/Users/${user_name}" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
    return
  fi

  printf '%s\n' "${HOME}"
}

USER_NAME="$(resolve_effective_user)"
if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" && "${SUDO_USER:-}" == "${USER_NAME}" ]]; then
  UID_NUM="${SUDO_UID}"
else
  UID_NUM="$(id -u "${USER_NAME}")"
fi
if [[ "${EUID}" -eq 0 && -n "${SUDO_GID:-}" && "${SUDO_USER:-}" == "${USER_NAME}" ]]; then
  GID_NUM="${SUDO_GID}"
else
  GID_NUM="$(id -g "${USER_NAME}")"
fi
USER_HOME="$(resolve_user_home "${USER_NAME}")"
OS_NAME="$(uname -s)"
PORT="$((40000 + UID_NUM))"
NAME=""
IMAGE=""
IMAGE_BUILD_HINT=""
NOPHI_HOME="${USER_HOME}/NOPHI-home"
if [[ "$(uname -s)" == "Darwin" ]]; then
  DEFAULT_SHARED="${USER_HOME}/NOPHI-data"
else
  DEFAULT_SHARED="/srv/NOPHI-data"
fi
SHARED="${NOPHI_SHARED_DIR:-${DEFAULT_SHARED}}"
DEV_NET_NAME="cri-dev-net"
DOCKER_GPU_ARGS=()
RUN_MODE="cpu"
AUTHORIZED_KEYS_EMPTY=0

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
  local ssh_dir="${USER_HOME}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  mkdir -p "${ssh_dir}" || fail "Unable to create ${ssh_dir}."
  if [[ "${EUID}" -eq 0 ]]; then
    chown "${UID_NUM}:${GID_NUM}" "${ssh_dir}" || fail "Unable to set ownership on ${ssh_dir}."
  fi
  chmod 700 "${ssh_dir}" || fail "Unable to set permissions on ${ssh_dir}."

  if [[ ! -f "${auth_keys}" ]]; then
    (umask 077 && : > "${auth_keys}") || fail "Unable to create ${auth_keys}."
    echo "Created ${auth_keys}."
  fi

  if [[ "${EUID}" -eq 0 ]]; then
    chown "${UID_NUM}:${GID_NUM}" "${auth_keys}" || fail "Unable to set ownership on ${auth_keys}."
  fi
  chmod 600 "${auth_keys}" || fail "Unable to set permissions on ${auth_keys}."

  if [[ ! -s "${auth_keys}" ]]; then
    AUTHORIZED_KEYS_EMPTY=1
  fi
}

ensure_shared_access() {
  if [[ ! -d "${SHARED}" ]]; then
    fail "Missing ${SHARED}. Create it first (macOS: ./macos-docker-setup.sh, Linux: ./create-shared-data-dir.sh)."
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

DOCKER_RUN_CMD=(
  docker run -d
  --name "${NAME}"
  --hostname "${NAME}"
  --restart unless-stopped
)

if [[ "${RUN_MODE}" == "cuda" ]]; then
  DOCKER_RUN_CMD+=("${DOCKER_GPU_ARGS[@]}")
fi

DOCKER_RUN_CMD+=(
  --network "${DEV_NET_NAME}"
  -p "${PORT}:22"
  -e USERNAME="${USER_NAME}"
  -e USER_UID="${UID_NUM}"
  -e USER_GID="${GID_NUM}"
  -v "${NOPHI_HOME}:/home/${USER_NAME}"
  -v "${SHARED}:/data"
  -v "${USER_HOME}/.ssh/authorized_keys:/home/${USER_NAME}/.ssh/authorized_keys:ro"
  --label owner="${USER_NAME}"
  "${IMAGE}"
)

"${DOCKER_RUN_CMD[@]}" >/dev/null

echo "Container started: ${NAME}"
if (( AUTHORIZED_KEYS_EMPTY )); then
  echo "Populate ${USER_HOME}/.ssh/authorized_keys with a public key from the server you will SSH from before connecting."
fi
if [[ "${OS_NAME}" == "Darwin" ]]; then
  echo "SSH with: ssh -p ${PORT} ${USER_NAME}@localhost"
  echo "Note: local hostname may not resolve on macOS; use localhost for this connection."
else
  echo "SSH with: ssh -p ${PORT} ${USER_NAME}@$(hostname)"
fi
if [[ "${REQUEST_MODE}" == "cuda" && "${RUN_MODE}" != "cuda" ]]; then
  echo "CUDA request was treated as a no-op on this host; CPU container was started."
fi
