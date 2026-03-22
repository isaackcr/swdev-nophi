#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./configure-docker-egress-filtering.sh [--network-name NAME] [--dns-server IP] [--allow-ip IP]... [--block-subnet CIDR]... [--no-install] [--no-save]

Configures Docker egress filtering for one Docker network only:
  - allows Internet egress
  - allows explicitly approved destination IPs even when they fall inside blocked subnets
  - blocks access to one or more internal subnets
  - allows same-network container-to-container traffic
  - allows DNS to approved resolver

Defaults:
  Docker network:  cri-dev-net
  DNS resolver:    172.19.20.19
  allowed IPs:     172.19.21.28
  blocked subnets: 172.19.20.0/23, 172.19.149.0/26

Notes:
  - Repeat --allow-ip to add more single-IP exceptions.
  - Repeat --block-subnet to add more subnets.
  - Every blocked subnet uses REJECT --reject-with icmp-port-unreachable.
EOF
}

DOCKER_NETWORK_NAME="cri-dev-net"
DNS_SERVER="172.19.20.19"
ALLOW_SPECIFIC_IPS=("172.19.21.28")
BLOCK_SUBNETS=("172.19.20.0/23" "172.19.149.0/26")
INSTALL_PERSISTENCE=true
SAVE_RULES=true

while (($# > 0)); do
  case "$1" in
    --network-name)
      if (($# < 2)); then
        echo "Error: --network-name requires a value."
        usage
        exit 1
      fi
      DOCKER_NETWORK_NAME="$2"
      shift 2
      ;;
    --dns-server)
      if (($# < 2)); then
        echo "Error: --dns-server requires a value."
        usage
        exit 1
      fi
      DNS_SERVER="$2"
      shift 2
      ;;
    --allow-ip)
      if (($# < 2)); then
        echo "Error: --allow-ip requires a value."
        usage
        exit 1
      fi
      ALLOW_SPECIFIC_IPS+=("$2")
      shift 2
      ;;
    --block-subnet)
      if (($# < 2)); then
        echo "Error: --block-subnet requires a value."
        usage
        exit 1
      fi
      BLOCK_SUBNETS+=("$2")
      shift 2
      ;;
    --no-install)
      INSTALL_PERSISTENCE=false
      shift
      ;;
    --no-save)
      SAVE_RULES=false
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

echo "Preparing Docker egress filtering rules..."
sudo -v

if ! docker network inspect "${DOCKER_NETWORK_NAME}" >/dev/null 2>&1; then
  echo "Error: Docker network '${DOCKER_NETWORK_NAME}' not found."
  echo "Run ./create-docker-networks.sh first, or pass --network-name with an existing network."
  exit 1
fi

NETWORK_ID="$(docker network inspect -f '{{.Id}}' "${DOCKER_NETWORK_NAME}")"
NETWORK_IFACE="br-${NETWORK_ID:0:12}"
CHAIN_NAME="DNET-${NETWORK_ID:0:12}"

if [[ "${INSTALL_PERSISTENCE}" == "true" ]]; then
  if dpkg-query -W -f='${Status}' iptables-persistent 2>/dev/null | grep -q "install ok installed"; then
    echo "iptables-persistent already installed."
  else
    echo "Installing iptables-persistent..."
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
  fi
fi

# Ensure DOCKER-USER exists even on hosts where Docker has not created it yet.
if ! sudo iptables -nL DOCKER-USER >/dev/null 2>&1; then
  sudo iptables -N DOCKER-USER
fi

# Ensure the per-network chain exists and is reset.
if ! sudo iptables -nL "${CHAIN_NAME}" >/dev/null 2>&1; then
  sudo iptables -N "${CHAIN_NAME}"
fi
sudo iptables -F "${CHAIN_NAME}"

# Keep exactly one jump for this network's bridge interface.
while sudo iptables -C DOCKER-USER -i "${NETWORK_IFACE}" -j "${CHAIN_NAME}" >/dev/null 2>&1; do
  sudo iptables -D DOCKER-USER -i "${NETWORK_IFACE}" -j "${CHAIN_NAME}"
done
sudo iptables -I DOCKER-USER 1 -i "${NETWORK_IFACE}" -j "${CHAIN_NAME}"

# Policy for traffic originating from this specific Docker network.
sudo iptables -A "${CHAIN_NAME}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A "${CHAIN_NAME}" -i "${NETWORK_IFACE}" -o "${NETWORK_IFACE}" -j ACCEPT
sudo iptables -A "${CHAIN_NAME}" -d "${DNS_SERVER}" -p udp --dport 53 -j ACCEPT
sudo iptables -A "${CHAIN_NAME}" -d "${DNS_SERVER}" -p tcp --dport 53 -j ACCEPT

# Allow specific destination IPs before broader subnet rejects.
declare -A seen_allow_ip=()
for allow_ip in "${ALLOW_SPECIFIC_IPS[@]}"; do
  if [[ -n "${seen_allow_ip[${allow_ip}]:-}" ]]; then
    continue
  fi
  seen_allow_ip["${allow_ip}"]=1
  sudo iptables -A "${CHAIN_NAME}" -d "${allow_ip}" -j ACCEPT
done

# Deduplicate blocked subnets while preserving order.
declare -A seen_subnet=()
for subnet in "${BLOCK_SUBNETS[@]}"; do
  if [[ -n "${seen_subnet[${subnet}]:-}" ]]; then
    continue
  fi
  seen_subnet["${subnet}"]=1
  sudo iptables -A "${CHAIN_NAME}" -d "${subnet}" -j REJECT --reject-with icmp-port-unreachable
done

sudo iptables -A "${CHAIN_NAME}" -j ACCEPT

echo
echo "DOCKER-USER rules:"
sudo iptables -L DOCKER-USER -n -v --line-numbers
echo
echo "${CHAIN_NAME} rules (network=${DOCKER_NETWORK_NAME}, iface=${NETWORK_IFACE}):"
sudo iptables -L "${CHAIN_NAME}" -n -v --line-numbers

if [[ "${SAVE_RULES}" == "true" ]]; then
  if command -v netfilter-persistent >/dev/null 2>&1; then
    echo
    echo "Saving rules with netfilter-persistent..."
    sudo netfilter-persistent save
  else
    echo
    echo "Warning: netfilter-persistent not found; rules are active but not persisted."
  fi
fi

echo
echo "Docker egress filtering configured for ${DOCKER_NETWORK_NAME} (${NETWORK_IFACE})."
