#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./create-docker-networks.sh

Ensures Docker bridge networks exist with non-172.x subnets:
  cri-dev-net    192.168.240.0/24 (gateway 192.168.240.1)
  cri-collab-net 192.168.241.0/24 (gateway 192.168.241.1)

Override defaults with environment variables when needed:
  CRI_DEV_SUBNET, CRI_DEV_GATEWAY, CRI_COLLAB_SUBNET, CRI_COLLAB_GATEWAY
If a subnet overlaps existing address space, the script tries fallback ranges.
EOF
}

if (($# > 0)); then
  case "$1" in
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
fi

fail() {
  echo "Error: $*" >&2
  exit 1
}

overlap_error() {
  [[ "$1" == *"invalid pool request: Pool overlaps with other one on this address space"* ]]
}

create_network() {
  local name="$1"
  local subnet="$2"
  local gateway="$3"
  local output

  if output="$(
    docker network create \
      --driver bridge \
      --subnet "${subnet}" \
      --gateway "${gateway}" \
      "${name}" 2>&1
  )"; then
    return
  fi

  if overlap_error "${output}"; then
    return 2
  fi

  echo "${output}" >&2
  return 1
}

fallback_pairs_for_network() {
  case "$1" in
    cri-dev-net)
      cat <<'EOF'
10.250.0.0/24|10.250.0.1
10.251.0.0/24|10.251.0.1
192.168.242.0/24|192.168.242.1
EOF
      ;;
    cri-collab-net)
      cat <<'EOF'
10.250.1.0/24|10.250.1.1
10.251.1.0/24|10.251.1.1
192.168.243.0/24|192.168.243.1
EOF
      ;;
  esac
}

create_network_with_fallback() {
  local name="$1"
  local subnet="$2"
  local gateway="$3"
  local try_subnet="$subnet"
  local try_gateway="$gateway"
  local rc=0

  if create_network "${name}" "${try_subnet}" "${try_gateway}"; then
    echo "${try_subnet}|${try_gateway}"
    return
  fi

  rc=$?
  if [[ ${rc} -ne 2 ]]; then
    fail "Failed creating ${name} with ${try_subnet} (${try_gateway})."
  fi

  while IFS='|' read -r try_subnet try_gateway; do
    if [[ -z "${try_subnet}" || -z "${try_gateway}" ]]; then
      continue
    fi

    if [[ "${try_subnet}" == "${subnet}" && "${try_gateway}" == "${gateway}" ]]; then
      continue
    fi

    echo "Warning: ${name} subnet ${subnet} overlaps existing address space. Trying ${try_subnet} (${try_gateway})." >&2
    if create_network "${name}" "${try_subnet}" "${try_gateway}"; then
      echo "${try_subnet}|${try_gateway}"
      return
    fi

    rc=$?
    if [[ ${rc} -ne 2 ]]; then
      fail "Failed creating ${name} with ${try_subnet} (${try_gateway})."
    fi
  done < <(fallback_pairs_for_network "${name}")

  fail "Network ${name} overlaps existing address space for all attempted subnets. Retry with explicit overrides, for example: CRI_DEV_SUBNET=10.252.0.0/24 CRI_DEV_GATEWAY=10.252.0.1 CRI_COLLAB_SUBNET=10.252.1.0/24 CRI_COLLAB_GATEWAY=10.252.1.1 ./create-docker-networks.sh"
}

DEV_SUBNET="${CRI_DEV_SUBNET:-192.168.240.0/24}"
DEV_GATEWAY="${CRI_DEV_GATEWAY:-192.168.240.1}"
COLLAB_SUBNET="${CRI_COLLAB_SUBNET:-192.168.241.0/24}"
COLLAB_GATEWAY="${CRI_COLLAB_GATEWAY:-192.168.241.1}"

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
    local created_pair
    docker network rm "${name}" >/dev/null
    created_pair="$(create_network_with_fallback "${name}" "${subnet}" "${gateway}")"
    echo "Recreated network ${name} with ${created_pair%%|*} (${created_pair##*|})."
    return
  fi

  if [[ "${exists}" == "false" ]]; then
    local created_pair
    created_pair="$(create_network_with_fallback "${name}" "${subnet}" "${gateway}")"
    echo "Created network ${name} with ${created_pair%%|*} (${created_pair##*|})."
    return
  fi

  echo "Network already configured: ${name}"
}

ensure_network "cri-dev-net" "${DEV_SUBNET}" "${DEV_GATEWAY}"
ensure_network "cri-collab-net" "${COLLAB_SUBNET}" "${COLLAB_GATEWAY}"
