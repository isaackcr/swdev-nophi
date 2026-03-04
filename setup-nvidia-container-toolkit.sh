#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./setup-nvidia-container-toolkit.sh [--no-verify]

Installs and configures NVIDIA Container Toolkit for Docker on Ubuntu/Debian.
This is required to run CUDA containers with `docker run --gpus all`.

Options:
  --no-verify   Skip post-setup GPU container verification step.
EOF
}

VERIFY=true
while (($# > 0)); do
  case "$1" in
    --no-verify)
      VERIFY=false
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

if [[ ! -r /etc/os-release ]]; then
  echo "Error: unable to detect OS (missing /etc/os-release)."
  exit 1
fi

. /etc/os-release
if [[ "${ID}" != "ubuntu" && "${ID}" != "debian" ]]; then
  echo "Error: this script currently supports Ubuntu/Debian only."
  echo "Detected OS: ${ID:-unknown} ${VERSION_ID:-unknown}"
  exit 1
fi

echo "Preparing NVIDIA Container Toolkit setup..."
sudo -v

echo "Installing prerequisites..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

KEYRING_PATH="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
LIST_PATH="/etc/apt/sources.list.d/nvidia-container-toolkit.list"

echo "Configuring NVIDIA package repository..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor \
  | sudo tee "${KEYRING_PATH}" >/dev/null

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
  | sudo tee "${LIST_PATH}" >/dev/null

echo "Installing nvidia-container-toolkit..."
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

echo "Configuring Docker runtime..."
sudo nvidia-ctk runtime configure --runtime=docker

echo "Restarting Docker..."
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^docker\.service'; then
  sudo systemctl restart docker
elif command -v service >/dev/null 2>&1; then
  sudo service docker restart
else
  echo "Warning: could not detect service manager to restart Docker automatically."
  echo "Please restart Docker manually before running CUDA containers."
fi

if [[ "${VERIFY}" == "true" ]]; then
  echo "Verifying GPU access from Docker..."
  docker run --rm --gpus all nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04 nvidia-smi
fi

echo "NVIDIA Container Toolkit setup complete."
