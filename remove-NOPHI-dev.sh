#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./remove-NOPHI-dev.sh [--cpu|--cuda]

Removes the NOPHI dev container:
  default mode: auto (CUDA if available, otherwise CPU)
  --cpu: remove CPU container
  --cuda: remove CUDA container if available, otherwise falls back to CPU
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
TARGET_MODE="cpu"

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

cuda_mode_available() {
  command -v nvidia-smi >/dev/null 2>&1 \
    && nvidia-smi -L >/dev/null 2>&1 \
    && docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'
}

container_name_for_mode() {
  if [[ "$1" == "cuda" ]]; then
    echo "${USER_NAME}-NOPHI-dev-cuda"
  else
    echo "${USER_NAME}-NOPHI-dev"
  fi
}

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "$1"
}

resolve_mode() {
  if [[ "${REQUEST_MODE}" == "cpu" ]]; then
    TARGET_MODE="cpu"
    return
  fi

  if cuda_mode_available; then
    TARGET_MODE="cuda"
    return
  fi

  if [[ "${REQUEST_MODE}" == "cuda" ]]; then
    echo "Warning: CUDA mode requested but unavailable. Continuing in CPU mode."
  fi
  TARGET_MODE="cpu"
}

ensure_docker_access
resolve_mode

NAME="$(container_name_for_mode "${TARGET_MODE}")"

if container_exists "${NAME}"; then
  docker rm -f "${NAME}" >/dev/null
  echo "Container removed: ${NAME}"
elif [[ "${REQUEST_MODE}" == "auto" ]]; then
  ALT_MODE="cpu"
  if [[ "${TARGET_MODE}" == "cpu" ]]; then
    ALT_MODE="cuda"
  fi
  ALT_NAME="$(container_name_for_mode "${ALT_MODE}")"
  if container_exists "${ALT_NAME}"; then
    docker rm -f "${ALT_NAME}" >/dev/null
    echo "Container removed: ${ALT_NAME}"
    echo "Auto-selected target was ${TARGET_MODE}, but no matching container existed."
  else
    echo "Container not found: ${NAME}"
  fi
else
  echo "Container not found: ${NAME}"
fi
