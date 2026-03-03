#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./create-docker-networks.sh [--collab]

Ensures Docker bridge networks exist with non-172.x subnets:
  cri-dev-net    192.168.240.0/24 (gateway 192.168.240.1)
  cri-collab-net 192.168.241.0/24 (gateway 192.168.241.1, optional with --collab)
EOF
}

CREATE_COLLAB=false
while (($# > 0)); do
  case "$1" in
    --collab)
      CREATE_COLLAB=true
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

ensure_network() {
  local name="$1"
  local subnet="$2"
  local gateway="$3"
  local exists=false
  local recreate=false

  if docker network inspect "${name}" >/dev/null 2>&1; then
    exists=true
    local current_subnet
    local current_gateway
    current_subnet="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "${name}")"
    current_gateway="$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "${name}")"
    if [[ "${current_subnet}" != "${subnet}" || "${current_gateway}" != "${gateway}" ]]; then
      recreate=true
    fi
  fi

  if [[ "${recreate}" == "true" ]]; then
    docker network rm "${name}" >/dev/null
    docker network create \
      --driver bridge \
      --subnet "${subnet}" \
      --gateway "${gateway}" \
      "${name}" >/dev/null
    echo "Recreated network ${name} with ${subnet} (${gateway})."
    return
  fi

  if [[ "${exists}" == "false" ]]; then
    docker network create \
      --driver bridge \
      --subnet "${subnet}" \
      --gateway "${gateway}" \
      "${name}" >/dev/null
    echo "Created network ${name} with ${subnet} (${gateway})."
    return
  fi

  echo "Network already configured: ${name}"
}

ensure_network "cri-dev-net" "192.168.240.0/24" "192.168.240.1"

if [[ "${CREATE_COLLAB}" == "true" ]]; then
  ensure_network "cri-collab-net" "192.168.241.0/24" "192.168.241.1"
fi
