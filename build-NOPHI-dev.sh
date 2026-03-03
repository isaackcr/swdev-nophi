#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./build-NOPHI-dev.sh [--cuda] [--tag IMAGE_TAG]

Builds Docker image from Dockerfile using:
  default base image: ubuntu:24.04
  CUDA base image:    nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04 (with --cuda)

Examples:
  ./build-NOPHI-dev.sh
  ./build-NOPHI-dev.sh --cuda
  ./build-NOPHI-dev.sh --cuda --tag my-image:latest
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE="ubuntu:24.04"
IMAGE_TAG="NOPHI-dev:ubuntu24.04"

while (($# > 0)); do
  case "$1" in
    --cuda)
      BASE_IMAGE="nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04"
      IMAGE_TAG="NOPHI-dev-cuda:cuda12.6.3"
      shift
      ;;
    --tag)
      if (($# < 2)); then
        echo "Error: --tag requires a value."
        usage
        exit 1
      fi
      IMAGE_TAG="$2"
      shift 2
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

docker build \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --tag "${IMAGE_TAG}" \
  --file "${SCRIPT_DIR}/Dockerfile" \
  "${SCRIPT_DIR}"

echo "Built image '${IMAGE_TAG}' with base image '${BASE_IMAGE}'."
