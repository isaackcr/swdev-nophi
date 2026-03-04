#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./build-NOPHI-dev.sh [--cpu] [--cuda] [--tag IMAGE_TAG]

Builds Docker images from Dockerfile:
  CPU image:  nophi-dev:ubuntu24.04
  CUDA image: nophi-dev-cuda:cuda12.6.3

Default behavior (no flags): build both CPU and CUDA images.

Options:
  --cpu            Build only CPU image (or include CPU image when combined with --cuda)
  --cuda           Build only CUDA image (or include CUDA image when combined with --cpu)
  --tag IMAGE_TAG  Override image tag (valid only when building exactly one image)

Examples:
  ./build-NOPHI-dev.sh
  ./build-NOPHI-dev.sh --cpu
  ./build-NOPHI-dev.sh --cuda
  ./build-NOPHI-dev.sh --cpu --cuda
  ./build-NOPHI-dev.sh --cpu --tag my-cpu-image:latest
  ./build-NOPHI-dev.sh --cuda --tag my-image:latest
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CPU_BASE_IMAGE="ubuntu:24.04"
CPU_IMAGE_TAG="nophi-dev:ubuntu24.04"
CUDA_BASE_IMAGE="nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04"
CUDA_IMAGE_TAG="nophi-dev-cuda:cuda12.6.3"

BUILD_CPU=true
BUILD_CUDA=true
EXPLICIT_TARGET=false
TAG_OVERRIDE=""

host_supports_cuda() {
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

while (($# > 0)); do
  case "$1" in
    --cpu)
      if [[ "${EXPLICIT_TARGET}" == "false" ]]; then
        BUILD_CPU=false
        BUILD_CUDA=false
        EXPLICIT_TARGET=true
      fi
      BUILD_CPU=true
      shift
      ;;
    --cuda)
      if [[ "${EXPLICIT_TARGET}" == "false" ]]; then
        BUILD_CPU=false
        BUILD_CUDA=false
        EXPLICIT_TARGET=true
      fi
      BUILD_CUDA=true
      shift
      ;;
    --tag)
      if (($# < 2)); then
        echo "Error: --tag requires a value."
        usage
        exit 1
      fi
      TAG_OVERRIDE="$2"
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

if [[ "${BUILD_CUDA}" == "true" ]] && ! host_supports_cuda; then
  echo "Notice: No NVIDIA GPUs detected on this host. Skipping CUDA image build."
  BUILD_CUDA=false
fi

if [[ -n "${TAG_OVERRIDE}" ]]; then
  if [[ "${BUILD_CPU}" == "true" && "${BUILD_CUDA}" == "true" ]]; then
    echo "Error: --tag can only be used with --cpu or --cuda (single-image build)."
    usage
    exit 1
  fi

  if [[ "${BUILD_CPU}" == "true" ]]; then
    CPU_IMAGE_TAG="${TAG_OVERRIDE}"
  else
    CUDA_IMAGE_TAG="${TAG_OVERRIDE}"
  fi
fi

if [[ "${BUILD_CPU}" == "true" ]]; then
  docker build \
    --build-arg "BASE_IMAGE=${CPU_BASE_IMAGE}" \
    --tag "${CPU_IMAGE_TAG}" \
    --file "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}"
  echo "Built CPU image '${CPU_IMAGE_TAG}' with base image '${CPU_BASE_IMAGE}'."
fi

if [[ "${BUILD_CUDA}" == "true" ]]; then
  docker build \
    --build-arg "BASE_IMAGE=${CUDA_BASE_IMAGE}" \
    --tag "${CUDA_IMAGE_TAG}" \
    --file "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}"
  echo "Built CUDA image '${CUDA_IMAGE_TAG}' with base image '${CUDA_BASE_IMAGE}'."
fi

if [[ "${BUILD_CPU}" != "true" && "${BUILD_CUDA}" != "true" ]]; then
  echo "No images were built."
fi
