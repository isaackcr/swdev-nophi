#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./remove-NOPHI-dev.sh [--cuda]

Removes the NOPHI dev container:
  default name: ${USER}-NOPHI-dev
  CUDA name:    ${USER}-NOPHI-dev-cuda (with --cuda)
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

NAME="${USER}-NOPHI-dev"
if [[ "${USE_CUDA}" == "true" ]]; then
  NAME="${USER}-NOPHI-dev-cuda"
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${NAME}"; then
  docker rm -f "${NAME}" >/dev/null
  echo "Container removed: ${NAME}"
else
  echo "Container not found: ${NAME}"
fi
