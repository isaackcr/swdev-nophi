#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install-nophi-commands.sh [--prefix DIR]

Installs global command aliases for NOPHI container lifecycle scripts:
  start-nophi  -> start-NOPHI-dev.sh
  remove-nophi -> remove-NOPHI-dev.sh

Default install prefix: /usr/local/bin
EOF
}

PREFIX="/usr/local/bin"
while (($# > 0)); do
  case "$1" in
    --prefix)
      if (($# < 2)); then
        echo "Error: --prefix requires a directory path."
        exit 1
      fi
      PREFIX="$2"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_SRC="${SCRIPT_DIR}/start-NOPHI-dev.sh"
REMOVE_SRC="${SCRIPT_DIR}/remove-NOPHI-dev.sh"

if [[ ! -f "${START_SRC}" ]]; then
  echo "Error: missing source script ${START_SRC}"
  exit 1
fi

if [[ ! -f "${REMOVE_SRC}" ]]; then
  echo "Error: missing source script ${REMOVE_SRC}"
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
else
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: sudo is required to install into ${PREFIX}."
    exit 1
  fi
  SUDO=(sudo)
fi

"${SUDO[@]}" install -d -m 755 "${PREFIX}"
"${SUDO[@]}" install -m 755 "${START_SRC}" "${PREFIX}/start-nophi"
"${SUDO[@]}" install -m 755 "${REMOVE_SRC}" "${PREFIX}/remove-nophi"

echo "Installed commands:"
echo "  ${PREFIX}/start-nophi"
echo "  ${PREFIX}/remove-nophi"
