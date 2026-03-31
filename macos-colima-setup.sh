#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./macos-colima-setup.sh [options]

Bootstraps Colima for NOPHI on macOS Tahoe+ and then runs ./macos-docker-setup.sh
with the same options.

This wrapper:
  - verifies the host is macOS Tahoe+ (macOS 26+)
  - installs missing Homebrew packages for Colima Docker workflows
  - starts the Colima Linux container runtime if needed
  - waits for Docker to become ready
  - delegates shared-dir, network, build, command install, and egress setup to
    ./macos-docker-setup.sh

Examples:
  ./macos-colima-setup.sh
  ./macos-colima-setup.sh --no-build
  ./macos-colima-setup.sh --uninstall

All other options are passed through to ./macos-docker-setup.sh.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_SETUP_SCRIPT="${SCRIPT_DIR}/macos-docker-setup.sh"
DOCKER_WAIT_SECONDS=120
DOCKER_WAIT_INTERVAL_SECONDS=2

fail() {
  echo "Error: $*" >&2
  exit 1
}

ensure_delegate_script() {
  if [[ ! -x "${DOCKER_SETUP_SCRIPT}" ]]; then
    fail "Missing delegate script ${DOCKER_SETUP_SCRIPT}."
  fi
}

ensure_macos_tahoe_or_newer() {
  local os_name=""
  local macos_version=""
  local macos_major=""

  os_name="$(uname -s)"
  if [[ "${os_name}" != "Darwin" ]]; then
    fail "This script only supports macOS."
  fi

  macos_version="$(sw_vers -productVersion 2>/dev/null || true)"
  macos_major="${macos_version%%.*}"

  if [[ -z "${macos_major}" ]]; then
    fail "Unable to determine macOS version."
  fi

  if ! [[ "${macos_major}" =~ ^[0-9]+$ ]]; then
    fail "Unexpected macOS version string: ${macos_version}"
  fi

  if (( macos_major < 26 )); then
    fail "macOS Tahoe+ required. Found ${macos_version}."
  fi
}

ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    return
  fi

  fail "Homebrew is required. Install Homebrew first, then rerun this script."
}

install_colima_prereqs_if_needed() {
  local missing_tools=()
  local tool_name=""

  for tool_name in colima docker limactl; do
    if ! command -v "${tool_name}" >/dev/null 2>&1; then
      missing_tools+=("${tool_name}")
    fi
  done

  if ((${#missing_tools[@]} == 0)); then
    return
  fi

  echo "Installing missing Colima prerequisites with Homebrew..."
  brew install colima docker lima
}

ensure_colima_context() {
  if docker context inspect colima >/dev/null 2>&1; then
    docker context use colima >/dev/null
  fi
}

colima_running() {
  local status_output=""

  if ! command -v colima >/dev/null 2>&1; then
    return 1
  fi

  status_output="$(colima status 2>/dev/null || true)"
  printf '%s\n' "${status_output}" | grep -qiE '(^|[[:space:]])running([[:space:]]|$)'
}

start_colima_if_needed() {
  if colima_running; then
    echo "Colima is already running."
    ensure_colima_context
    return
  fi

  echo "Starting Colima..."
  colima start
  ensure_colima_context
}

wait_for_docker() {
  local max_attempts=0
  local attempt=1

  max_attempts=$((DOCKER_WAIT_SECONDS / DOCKER_WAIT_INTERVAL_SECONDS))
  if (( max_attempts < 1 )); then
    max_attempts=1
  fi

  while (( attempt <= max_attempts )); do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep "${DOCKER_WAIT_INTERVAL_SECONDS}"
    attempt=$((attempt + 1))
  done

  return 1
}

if (($# > 0)); then
  for arg in "$@"; do
    case "${arg}" in
      -h|--help)
        usage
        exit 0
        ;;
    esac
  done
fi

if [[ "${EUID}" -eq 0 ]]; then
  fail "Run this script as your regular macOS user."
fi

ensure_delegate_script
ensure_macos_tahoe_or_newer
ensure_homebrew
install_colima_prereqs_if_needed
start_colima_if_needed

if ! wait_for_docker; then
  fail "Docker did not become ready after starting Colima."
fi

exec "${DOCKER_SETUP_SCRIPT}" "$@"
