#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./macos-docker-setup.sh [options]

Sets up NOPHI Docker workflows for macOS 14+ (OrbStack, Docker Desktop, or Colima Linux containers), single-user mode:
  - prepares ~/NOPHI-shared for the current user
  - ensures Docker networks exist (cri-dev-net + cri-collab-net)
  - builds CPU image only (no CUDA path on macOS)
  - installs nophi-start and nophi-remove into ~/.local/bin by default
  - applies Linux-equivalent egress filtering to cri-dev-net inside the macOS Docker VM
  - installs a per-user LaunchAgent that re-applies egress rules on Docker socket changes

Options:
  --network-name NAME         Protected Docker network (default: cri-dev-net)
  --dns-server IP             Allowed DNS resolver for protected network (default: 172.19.20.19)
  --allow-ip IP               Allowed destination IP even within blocked subnets (repeatable)
  --allow-ips-csv CSV         Comma-separated allowed destination IPs (internal helper option)
  --block-subnet CIDR         Blocked destination subnet (repeatable)
  --block-subnets-csv CSV     Comma-separated blocked subnets (internal helper option)
  --helper-image TAG          Helper image for VM firewall apply (default: nophi-egress-helper:ubuntu24.04)
  --install-prefix DIR        Command install prefix (default: ~/.local/bin)
  --shared-dir DIR            Shared host directory mounted to /srv/NOPHI-shared (default: ~/NOPHI-shared)
  --no-build                  Skip CPU image build
  --no-install-commands       Skip installing nophi-start / nophi-remove
  --no-launch-agent           Skip installing LaunchAgent persistence
  --egress-only               Apply egress rules only (used by LaunchAgent)
  --uninstall                 Remove all macOS network settings created by this script
  -h, --help                  Show this help
EOF
}

DOCKER_NETWORK_NAME="cri-dev-net"
DNS_SERVER="172.19.20.19"
ALLOW_SPECIFIC_IPS=("172.19.21.28")
BLOCK_SUBNETS=("172.19.20.0/23" "172.19.149.0/26")
FIREWALL_HELPER_IMAGE="nophi-egress-helper:ubuntu24.04"
INSTALL_PREFIX="${HOME}/.local/bin"
SHARED_DIR="${HOME}/NOPHI-shared"

RUN_EGRESS_ONLY=false
BUILD_CPU_IMAGE=true
INSTALL_COMMANDS=true
INSTALL_LAUNCH_AGENT=true
EGRESS_WAIT_SECONDS=120
EGRESS_WAIT_INTERVAL_SECONDS=2
RUN_UNINSTALL=false

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
    --allow-ips-csv)
      if (($# < 2)); then
        echo "Error: --allow-ips-csv requires a value."
        usage
        exit 1
      fi
      ALLOW_SPECIFIC_IPS=()
      IFS=',' read -r -a parsed_allow_ips <<< "$2"
      for allow_ip in "${parsed_allow_ips[@]}"; do
        if [[ -n "${allow_ip}" ]]; then
          ALLOW_SPECIFIC_IPS+=("${allow_ip}")
        fi
      done
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
    --block-subnets-csv)
      if (($# < 2)); then
        echo "Error: --block-subnets-csv requires a value."
        usage
        exit 1
      fi
      BLOCK_SUBNETS=()
      IFS=',' read -r -a parsed_subnets <<< "$2"
      for subnet in "${parsed_subnets[@]}"; do
        if [[ -n "${subnet}" ]]; then
          BLOCK_SUBNETS+=("${subnet}")
        fi
      done
      shift 2
      ;;
    --helper-image)
      if (($# < 2)); then
        echo "Error: --helper-image requires a value."
        usage
        exit 1
      fi
      FIREWALL_HELPER_IMAGE="$2"
      shift 2
      ;;
    --install-prefix)
      if (($# < 2)); then
        echo "Error: --install-prefix requires a value."
        usage
        exit 1
      fi
      INSTALL_PREFIX="$2"
      shift 2
      ;;
    --shared-dir)
      if (($# < 2)); then
        echo "Error: --shared-dir requires a value."
        usage
        exit 1
      fi
      SHARED_DIR="$2"
      shift 2
      ;;
    --no-build)
      BUILD_CPU_IMAGE=false
      shift
      ;;
    --no-install-commands)
      INSTALL_COMMANDS=false
      shift
      ;;
    --no-launch-agent)
      INSTALL_LAUNCH_AGENT=false
      shift
      ;;
    --egress-only)
      RUN_EGRESS_ONLY=true
      shift
      ;;
    --uninstall)
      RUN_UNINSTALL=true
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

fail() {
  echo "Error: $*" >&2
  exit 1
}

resolve_shell_rc_file() {
  local shell_name=""

  shell_name="$(basename "${SHELL:-}")"

  case "${shell_name}" in
    zsh)
      printf '%s\n' "${HOME}/.zshrc"
      ;;
    bash)
      printf '%s\n' "${HOME}/.bash_profile"
      ;;
    *)
      printf '%s\n' "${HOME}/.zshrc"
      ;;
  esac
}

shell_path_for_display() {
  local path_value="$1"

  case "${path_value}" in
    "${HOME}")
      printf '%s\n' '$HOME'
      ;;
    "${HOME}"/*)
      printf '%s\n' "\$HOME/${path_value#"${HOME}/"}"
      ;;
    *)
      printf '%s\n' "${path_value}"
      ;;
  esac
}

dedupe_block_subnets() {
  local deduped=()
  local seen=""
  local subnet=""

  for subnet in "${BLOCK_SUBNETS[@]}"; do
    if [[ -z "${subnet}" ]]; then
      continue
    fi
    case ",${seen}," in
      *",${subnet},"*)
        continue
        ;;
      *)
        deduped+=("${subnet}")
        if [[ -z "${seen}" ]]; then
          seen="${subnet}"
        else
          seen="${seen},${subnet}"
        fi
        ;;
    esac
  done

  BLOCK_SUBNETS=("${deduped[@]}")
}

dedupe_allow_specific_ips() {
  local deduped=()
  local seen=""
  local allow_ip=""

  for allow_ip in "${ALLOW_SPECIFIC_IPS[@]}"; do
    if [[ -z "${allow_ip}" ]]; then
      continue
    fi
    case ",${seen}," in
      *",${allow_ip},"*)
        continue
        ;;
      *)
        deduped+=("${allow_ip}")
        if [[ -z "${seen}" ]]; then
          seen="${allow_ip}"
        else
          seen="${seen},${allow_ip}"
        fi
        ;;
    esac
  done

  ALLOW_SPECIFIC_IPS=("${deduped[@]}")
}

join_allow_specific_ips_csv() {
  local csv=""
  local allow_ip=""

  for allow_ip in "${ALLOW_SPECIFIC_IPS[@]}"; do
    if [[ -z "${csv}" ]]; then
      csv="${allow_ip}"
    else
      csv="${csv},${allow_ip}"
    fi
  done

  printf '%s' "${csv}"
}

join_block_subnets_csv() {
  local csv=""
  local subnet=""

  for subnet in "${BLOCK_SUBNETS[@]}"; do
    if [[ -z "${csv}" ]]; then
      csv="${subnet}"
    else
      csv="${csv},${subnet}"
    fi
  done

  printf '%s' "${csv}"
}

stable_chain_name() {
  local network_name="$1"
  local chain_hash=""

  if command -v shasum >/dev/null 2>&1; then
    chain_hash="$(printf '%s' "${network_name}" | shasum -a 256 | awk '{print $1}')"
  else
    chain_hash="$(printf '%s' "${network_name}" | cksum | awk '{print $1}')"
  fi

  printf 'DNET-%s' "${chain_hash:0:12}"
}

docker_ready() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

egress_prereqs_ready() {
  docker_ready \
    && docker network inspect "${DOCKER_NETWORK_NAME}" >/dev/null 2>&1 \
    && docker image inspect "${FIREWALL_HELPER_IMAGE}" >/dev/null 2>&1
}

wait_for_egress_prereqs() {
  local max_attempts=0
  local attempt=1

  max_attempts=$((EGRESS_WAIT_SECONDS / EGRESS_WAIT_INTERVAL_SECONDS))
  if (( max_attempts < 1 )); then
    max_attempts=1
  fi

  while (( attempt <= max_attempts )); do
    if egress_prereqs_ready; then
      return 0
    fi
    sleep "${EGRESS_WAIT_INTERVAL_SECONDS}"
    attempt=$((attempt + 1))
  done

  return 1
}

ensure_macos_14_or_newer() {
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

  if (( macos_major < 14 )); then
    fail "macOS 14+ required. Found ${macos_version}."
  fi
}

ensure_supported_macos_docker_engine() {
  local os_type=""
  local operating_system=""
  local current_context=""
  local docker_host=""

  if ! command -v docker >/dev/null 2>&1; then
    fail "docker command not found. Install Docker Desktop, OrbStack, or Colima first."
  fi

  if ! docker info >/dev/null 2>&1; then
    fail "Docker is not running. Start Docker Desktop, OrbStack, or Colima and retry."
  fi

  os_type="$(docker info --format '{{.OSType}}' 2>/dev/null || true)"
  operating_system="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
  current_context="$(docker context show 2>/dev/null || true)"
  docker_host="$(docker context inspect "${current_context}" --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || true)"

  if [[ "${os_type}" != "linux" ]]; then
    fail "Docker must be running Linux containers. Current OSType is '${os_type}'."
  fi

  if [[ "${operating_system}" == *"Docker Desktop"* ]]; then
    echo "Detected engine: Docker Desktop"
    return
  fi

  if [[ "${operating_system}" == *"OrbStack"* ]]; then
    echo "Detected engine: OrbStack"
    return
  fi

  if [[ "${operating_system}" == *"Colima"* ]]; then
    echo "Detected engine: Colima"
    return
  fi

  if [[ "${docker_host}" == *".orbstack/run/docker.sock"* ]]; then
    echo "Detected engine: OrbStack (${docker_host})"
    return
  fi

  if [[ "${docker_host}" == *".docker/run/docker.sock"* ]]; then
    echo "Detected engine: Docker Desktop (${docker_host})"
    return
  fi

  if [[ "${docker_host}" == *".colima/"* ]]; then
    echo "Detected engine: Colima (${docker_host})"
    return
  fi

  echo "Warning: unrecognized macOS Docker engine (OperatingSystem='${operating_system}', context='${current_context}', host='${docker_host}')."
  echo "Continuing because Linux container mode is active."
}

ensure_shared_dir() {
  echo "Preparing shared data directory at ${SHARED_DIR}..."
  mkdir -p "${SHARED_DIR}"
  chmod 700 "${SHARED_DIR}" || true

  if [[ ! -r "${SHARED_DIR}" || ! -w "${SHARED_DIR}" || ! -x "${SHARED_DIR}" ]]; then
    fail "No read/write/execute access to ${SHARED_DIR}."
  fi
}

ensure_firewall_helper_image() {
  if docker image inspect "${FIREWALL_HELPER_IMAGE}" >/dev/null 2>&1; then
    return
  fi

  echo "Building firewall helper image '${FIREWALL_HELPER_IMAGE}'..."
  docker build --tag "${FIREWALL_HELPER_IMAGE}" --file - "${SCRIPT_DIR}" <<'EOF'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends iptables util-linux \
 && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["/usr/bin/nsenter","-t","1","-n","/bin/bash","-lc"]
EOF
}

apply_egress_rules() {
  local print_rules="$1"
  local network_id=""
  local network_iface=""
  local chain_name=""
  local allow_ips_csv=""
  local block_csv=""
  local show_rules="0"

  if ! docker network inspect "${DOCKER_NETWORK_NAME}" >/dev/null 2>&1; then
    if [[ "${RUN_EGRESS_ONLY}" == "true" ]]; then
      return 0
    fi
    fail "Docker network '${DOCKER_NETWORK_NAME}' not found. Run ./create-docker-networks.sh first."
  fi

  network_id="$(docker network inspect -f '{{.Id}}' "${DOCKER_NETWORK_NAME}")"
  network_iface="br-${network_id:0:12}"
  chain_name="$(stable_chain_name "${DOCKER_NETWORK_NAME}")"
  allow_ips_csv="$(join_allow_specific_ips_csv)"
  block_csv="$(join_block_subnets_csv)"

  if [[ "${print_rules}" == "true" ]]; then
    show_rules="1"
  fi

  docker run --rm --privileged --pid=host \
    -e NETWORK_IFACE="${network_iface}" \
    -e CHAIN_NAME="${chain_name}" \
    -e DNS_SERVER="${DNS_SERVER}" \
    -e ALLOW_IPS_CSV="${allow_ips_csv}" \
    -e BLOCK_SUBNETS_CSV="${block_csv}" \
    -e SHOW_RULES="${show_rules}" \
    "${FIREWALL_HELPER_IMAGE}" '
set -euo pipefail

iptables -nL DOCKER-USER >/dev/null 2>&1 || iptables -N DOCKER-USER
iptables -nL "${CHAIN_NAME}" >/dev/null 2>&1 || iptables -N "${CHAIN_NAME}"
iptables -F "${CHAIN_NAME}"

# Remove every existing jump to this chain, regardless of interface, then add one correct jump.
while iptables -S DOCKER-USER | grep -F -- "-j ${CHAIN_NAME}" >/dev/null 2>&1; do
  delete_rule="$(iptables -S DOCKER-USER | grep -F -- "-j ${CHAIN_NAME}" | head -n 1)"
  delete_rule="${delete_rule/-A /-D }"
  iptables ${delete_rule}
done

# Remove DNET rules in DOCKER-USER that point to missing bridge interfaces.
while IFS= read -r docker_user_rule; do
  case "${docker_user_rule}" in
    -A\ DOCKER-USER\ *-j\ DNET-*)
      iface="$(printf "%s\n" "${docker_user_rule}" | sed -n "s/.* -i \\([^ ]*\\) .*/\\1/p")"
      if [[ -n "${iface}" ]] && ! ip link show dev "${iface}" >/dev/null 2>&1; then
        delete_rule="${docker_user_rule/-A /-D }"
        iptables ${delete_rule}
      fi
      ;;
  esac
done < <(iptables -S DOCKER-USER)

iptables -I DOCKER-USER 1 -i "${NETWORK_IFACE}" -j "${CHAIN_NAME}"

# Remove orphaned DNET chains with no remaining jump references.
for stale_chain in $(iptables -S | sed -n "s/^-N \\(DNET-[^ ]*\\)$/\\1/p"); do
  if [[ "${stale_chain}" == "${CHAIN_NAME}" ]]; then
    continue
  fi
  if iptables -S | grep -F -- "-j ${stale_chain}" >/dev/null 2>&1; then
    continue
  fi
  iptables -F "${stale_chain}" || true
  iptables -X "${stale_chain}" || true
done

iptables -A "${CHAIN_NAME}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A "${CHAIN_NAME}" -d "${DNS_SERVER}" -p udp --dport 53 -j ACCEPT
iptables -A "${CHAIN_NAME}" -d "${DNS_SERVER}" -p tcp --dport 53 -j ACCEPT

IFS="," read -r -a allow_ips <<< "${ALLOW_IPS_CSV}"
for allow_ip in "${allow_ips[@]}"; do
  [[ -n "${allow_ip}" ]] || continue
  iptables -A "${CHAIN_NAME}" -d "${allow_ip}" -j ACCEPT
done

IFS="," read -r -a subnets <<< "${BLOCK_SUBNETS_CSV}"
for subnet in "${subnets[@]}"; do
  [[ -n "${subnet}" ]] || continue
  iptables -A "${CHAIN_NAME}" -d "${subnet}" -j REJECT --reject-with icmp-port-unreachable
done

# Allow container-to-container traffic only after block rules so blocked subnets still win.
iptables -A "${CHAIN_NAME}" -i "${NETWORK_IFACE}" -o "${NETWORK_IFACE}" -j ACCEPT

iptables -A "${CHAIN_NAME}" -j ACCEPT

if [[ "${SHOW_RULES}" == "1" ]]; then
  echo
  echo "DOCKER-USER rules:"
  iptables -L DOCKER-USER -n -v --line-numbers
  echo
  echo "${CHAIN_NAME} rules (iface=${NETWORK_IFACE}):"
  iptables -L "${CHAIN_NAME}" -n -v --line-numbers
fi
'
}

install_commands_locally() {
  mkdir -p "${INSTALL_PREFIX}"
  rm -f "${INSTALL_PREFIX}/nophi-start"

  cat > "${INSTALL_PREFIX}/nophi-start" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ -z "\${TZ:-}" ]]; then
  resolved_tz=""
  localtime_target=""

  if command -v realpath >/dev/null 2>&1; then
    localtime_target="\$(realpath /etc/localtime 2>/dev/null || true)"
  fi

  if [[ -z "\${localtime_target}" ]] && command -v readlink >/dev/null 2>&1; then
    localtime_target="\$(readlink /etc/localtime 2>/dev/null || true)"
  fi

  case "\${localtime_target}" in
    /usr/share/zoneinfo/*)
      resolved_tz="\${localtime_target#/usr/share/zoneinfo/}"
      ;;
    /private/usr/share/zoneinfo/*)
      resolved_tz="\${localtime_target#/private/usr/share/zoneinfo/}"
      ;;
    /var/db/timezone/zoneinfo/*)
      resolved_tz="\${localtime_target#/var/db/timezone/zoneinfo/}"
      ;;
    /private/var/db/timezone/zoneinfo/*)
      resolved_tz="\${localtime_target#/private/var/db/timezone/zoneinfo/}"
      ;;
  esac

  if [[ -z "\${resolved_tz}" && -L /var/db/timezone/localtime ]]; then
    localtime_target="\$(readlink /var/db/timezone/localtime 2>/dev/null || true)"
    case "\${localtime_target}" in
      /var/db/timezone/zoneinfo/*)
        resolved_tz="\${localtime_target#/var/db/timezone/zoneinfo/}"
        ;;
      /private/var/db/timezone/zoneinfo/*)
        resolved_tz="\${localtime_target#/private/var/db/timezone/zoneinfo/}"
        ;;
    esac
  fi

  if [[ -z "\${resolved_tz}" ]] && command -v systemsetup >/dev/null 2>&1; then
    resolved_tz="\$(systemsetup -gettimezone 2>/dev/null | awk -F': ' 'NF > 1 {print \$2}')"
  fi

  if [[ -n "\${resolved_tz}" ]]; then
    export TZ="\${resolved_tz}"
  fi
fi

exec "${SCRIPT_DIR}/start-NOPHI-dev.sh" "\$@"
EOF
  chmod 755 "${INSTALL_PREFIX}/nophi-start"
  ln -sf "${SCRIPT_DIR}/remove-NOPHI-dev.sh" "${INSTALL_PREFIX}/nophi-remove"
  echo "Installed command links:"
  echo "  ${INSTALL_PREFIX}/nophi-start"
  echo "  ${INSTALL_PREFIX}/nophi-remove"
}

install_egress_launch_agent() {
  local launch_label="com.nophi.docker-egress"
  local launch_path="${HOME}/Library/LaunchAgents/${launch_label}.plist"
  local log_path="${HOME}/Library/Logs/nophi-docker-egress.log"
  local allow_ips_csv=""
  local block_csv=""
  local uid_num=""

  allow_ips_csv="$(join_allow_specific_ips_csv)"
  block_csv="$(join_block_subnets_csv)"
  uid_num="$(id -u)"

  mkdir -p "${HOME}/Library/LaunchAgents"
  mkdir -p "${HOME}/Library/Logs"

  cat > "${launch_path}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${launch_label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPT_PATH}</string>
    <string>--egress-only</string>
    <string>--network-name</string>
    <string>${DOCKER_NETWORK_NAME}</string>
    <string>--dns-server</string>
    <string>${DNS_SERVER}</string>
    <string>--allow-ips-csv</string>
    <string>${allow_ips_csv}</string>
    <string>--block-subnets-csv</string>
    <string>${block_csv}</string>
    <string>--helper-image</string>
    <string>${FIREWALL_HELPER_IMAGE}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>WatchPaths</key>
  <array>
    <string>/var/run/docker.sock</string>
    <string>${HOME}/.docker/run/docker.sock</string>
    <string>${HOME}/.orbstack/run/docker.sock</string>
    <string>${HOME}/.colima/default/docker.sock</string>
  </array>
  <key>StandardOutPath</key>
  <string>${log_path}</string>
  <key>StandardErrorPath</key>
  <string>${log_path}</string>
</dict>
</plist>
EOF

  plutil -lint "${launch_path}" >/dev/null

  launchctl bootout "gui/${uid_num}" "${launch_path}" >/dev/null 2>&1 || true
  if ! launchctl bootstrap "gui/${uid_num}" "${launch_path}" >/dev/null 2>&1; then
    launchctl unload "${launch_path}" >/dev/null 2>&1 || true
    launchctl load "${launch_path}" >/dev/null 2>&1 || fail "Unable to load LaunchAgent ${launch_path}."
  fi
  launchctl kickstart -k "gui/${uid_num}/${launch_label}" >/dev/null 2>&1 || true

  echo "Installed LaunchAgent for egress persistence: ${launch_path}"
}

remove_egress_launch_agent() {
  local launch_label="com.nophi.docker-egress"
  local launch_path="${HOME}/Library/LaunchAgents/${launch_label}.plist"
  local log_path="${HOME}/Library/Logs/nophi-docker-egress.log"
  local uid_num=""

  uid_num="$(id -u)"

  launchctl bootout "gui/${uid_num}" "${launch_path}" >/dev/null 2>&1 || true
  launchctl unload "${launch_path}" >/dev/null 2>&1 || true
  rm -f "${launch_path}"
  rm -f "${log_path}"

  echo "Removed LaunchAgent: ${launch_path}"
}

remove_egress_firewall_settings() {
  echo "Removing macOS Docker VM egress firewall settings..."

  docker run --rm --privileged --pid=host \
    "${FIREWALL_HELPER_IMAGE}" '
set -euo pipefail

if ! iptables -nL DOCKER-USER >/dev/null 2>&1; then
  exit 0
fi

# Remove every script-managed jump from DOCKER-USER.
while IFS= read -r docker_user_rule; do
  case "${docker_user_rule}" in
    -A\ DOCKER-USER\ *-j\ DNET-*)
      delete_rule="${docker_user_rule/-A /-D }"
      iptables ${delete_rule} || true
      ;;
  esac
done < <(iptables -S DOCKER-USER)

# Remove every script-managed chain.
for managed_chain in $(iptables -S | sed -n "s/^-N \\(DNET-[^ ]*\\)$/\\1/p"); do
  iptables -F "${managed_chain}" || true
  iptables -X "${managed_chain}" || true
done
'
}

remove_managed_networks() {
  local network_name=""
  local failed=false
  local attached=""

  for network_name in "cri-dev-net" "cri-collab-net"; do
    if ! docker network inspect "${network_name}" >/dev/null 2>&1; then
      continue
    fi

    if docker network rm "${network_name}" >/dev/null 2>&1; then
      echo "Removed Docker network: ${network_name}"
      continue
    fi

    attached="$(docker network inspect -f '{{range $id, $c := .Containers}}{{println $c.Name}}{{end}}' "${network_name}" 2>/dev/null | sed '/^$/d' | tr '\n' ' ')"
    echo "Warning: unable to remove Docker network '${network_name}'."
    if [[ -n "${attached}" ]]; then
      echo "  Attached containers: ${attached}"
    fi
    failed=true
  done

  if [[ "${failed}" == "true" ]]; then
    fail "One or more managed networks could not be removed because they are still in use."
  fi
}

run_uninstall() {
  remove_egress_launch_agent

  if ! command -v docker >/dev/null 2>&1; then
    fail "docker command not found. Start Docker Desktop, OrbStack, or Colima and rerun uninstall to remove firewall and network settings."
  fi

  if ! docker info >/dev/null 2>&1; then
    fail "Docker is not running. Start Docker Desktop, OrbStack, or Colima and rerun uninstall."
  fi

  ensure_supported_macos_docker_engine
  ensure_firewall_helper_image
  remove_egress_firewall_settings
  remove_managed_networks

  echo
  echo "macOS network uninstall completed."
}

dedupe_block_subnets
dedupe_allow_specific_ips

if [[ "${RUN_EGRESS_ONLY}" == "true" ]]; then
  if ! wait_for_egress_prereqs; then
    echo "Egress-only run skipped: prerequisites were not ready within ${EGRESS_WAIT_SECONDS}s." >&2
    exit 0
  fi
  apply_egress_rules "false"
  exit 0
fi

if [[ "${EUID}" -eq 0 ]]; then
  fail "Run this script as your regular macOS user."
fi

ensure_macos_14_or_newer

if [[ "${RUN_UNINSTALL}" == "true" ]]; then
  run_uninstall
  exit 0
fi

ensure_supported_macos_docker_engine

ensure_shared_dir

echo "Ensuring Docker networks..."
"${SCRIPT_DIR}/create-docker-networks.sh"

if [[ "${BUILD_CPU_IMAGE}" == "true" ]]; then
  echo "Building CPU image..."
  "${SCRIPT_DIR}/build-NOPHI-dev.sh" --cpu
fi

if [[ "${INSTALL_COMMANDS}" == "true" ]]; then
  install_commands_locally
fi

ensure_firewall_helper_image

echo "Applying Docker egress filtering for '${DOCKER_NETWORK_NAME}'..."
apply_egress_rules "true"

if [[ "${INSTALL_LAUNCH_AGENT}" == "true" ]]; then
  install_egress_launch_agent
fi

echo
echo "macOS Docker setup completed."
echo "Shared data directory: ${SHARED_DIR}"
echo "Protected network: ${DOCKER_NETWORK_NAME}"
echo "Blocked subnets: $(join_block_subnets_csv)"
echo "DNS allowlist target: ${DNS_SERVER}"
echo "Allowed destination IP exceptions: $(join_allow_specific_ips_csv)"
echo
SHELL_RC_FILE="$(resolve_shell_rc_file)"
DISPLAY_INSTALL_PREFIX="$(shell_path_for_display "${INSTALL_PREFIX}")"
DISPLAY_SHELL_RC_FILE="$(shell_path_for_display "${SHELL_RC_FILE}")"
echo "To add '${INSTALL_PREFIX}' to your PATH for future shells, run:"
echo "  echo 'export PATH=\"${DISPLAY_INSTALL_PREFIX}:\$PATH\"' >> \"${DISPLAY_SHELL_RC_FILE}\""
echo "  source \"${DISPLAY_SHELL_RC_FILE}\""
