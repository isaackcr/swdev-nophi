#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./test-nophi-egress.sh [--container NAME] [--dns-server IP] [--allow-ip IP]... [--blocked-target IP]... [--timeout SECONDS]

Runs egress network tests from inside a running NOPHI container and reports each result in order.

Defaults:
  container:      auto-detect running NOPHI container for current user
  internet test:  1.1.1.1:443 (must be reachable)
  DNS test:       172.19.20.19:53/TCP (must be reachable)
  allow tests:    172.19.21.28:443 (must be reachable)
  blocked tests:  172.19.20.19:443 and 172.19.149.1:443 (must be blocked)
  timeout:        4 seconds

Examples:
  ./test-nophi-egress.sh
  ./test-nophi-egress.sh --container isaac-NOPHI-myhost
  ./test-nophi-egress.sh --allow-ip 172.19.21.29 --allow-ip 172.19.21.30
  ./test-nophi-egress.sh --blocked-target 10.42.0.10 --blocked-target 172.19.30.10
EOF
}

CONTAINER_NAME=""
DNS_SERVER="172.19.20.19"
ALLOW_IPS=("172.19.21.28")
BLOCKED_TARGETS=("172.19.20.19" "172.19.149.1")
TIMEOUT_SECONDS=4
INTERNET_HOST="1.1.1.1"
INTERNET_PORT=443
DNS_PORT=53
BLOCKED_PORT=443

while (($# > 0)); do
  case "$1" in
    --container)
      if (($# < 2)); then
        echo "Error: --container requires a value."
        usage
        exit 1
      fi
      CONTAINER_NAME="$2"
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
    --blocked-target)
      if (($# < 2)); then
        echo "Error: --blocked-target requires a value."
        usage
        exit 1
      fi
      BLOCKED_TARGETS+=("$2")
      shift 2
      ;;
    --allow-ip)
      if (($# < 2)); then
        echo "Error: --allow-ip requires a value."
        usage
        exit 1
      fi
      ALLOW_IPS+=("$2")
      shift 2
      ;;
    --timeout)
      if (($# < 2)); then
        echo "Error: --timeout requires a value."
        usage
        exit 1
      fi
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "${CONTAINER_NAME}" ]]; then
        CONTAINER_NAME="$1"
        shift
      else
        echo "Error: unknown argument '$1'."
        usage
        exit 1
      fi
      ;;
  esac
done

fail() {
  echo "Error: $*" >&2
  exit 1
}

trim_lines() {
  sed '/^$/d'
}

ensure_tools() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "docker command not found."
  fi
  if ! docker info >/dev/null 2>&1; then
    fail "Docker is not running or not accessible."
  fi
  if ! [[ "${TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || (( TIMEOUT_SECONDS < 1 )); then
    fail "Timeout must be a positive integer."
  fi
}

resolve_default_container() {
  local user_name=""
  local candidates=""
  local count=0

  if [[ -n "${CONTAINER_NAME}" ]]; then
    return
  fi

  user_name="${USER:-$(id -un)}"
  candidates="$(docker ps --filter "label=owner=${user_name}" --format '{{.Names}}' | grep -- '-NOPHI-' || true)"
  candidates="$(printf '%s\n' "${candidates}" | trim_lines || true)"

  if [[ -z "${candidates}" ]]; then
    fail "No running NOPHI container found for user '${user_name}'. Pass --container NAME."
  fi

  count="$(printf '%s\n' "${candidates}" | awk 'END {print NR+0}')"
  if (( count > 1 )); then
    echo "Error: multiple running NOPHI containers found for user '${user_name}':" >&2
    printf '%s\n' "${candidates}" | sed 's/^/  - /' >&2
    fail "Pass --container NAME to choose one."
  fi

  CONTAINER_NAME="$(printf '%s\n' "${candidates}" | head -n 1)"
}

ensure_container_running() {
  local running=""
  if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    fail "Container not found: ${CONTAINER_NAME}"
  fi
  running="$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}")"
  if [[ "${running}" != "true" ]]; then
    fail "Container is not running: ${CONTAINER_NAME}"
  fi
}

run_in_container() {
  local cmd="$1"
  docker exec "${CONTAINER_NAME}" bash -lc "${cmd}"
}

TEST_INDEX=0
FAILED=0
TOTAL_TESTS=0

print_test_header() {
  local description="$1"
  TEST_INDEX=$((TEST_INDEX + 1))
  echo "[${TEST_INDEX}/${TOTAL_TESTS}] ${description}"
}

print_test_result() {
  local status="$1"
  local details="$2"
  echo "  ${status}"
  if [[ -n "${details}" ]]; then
    printf '%s\n' "${details}" | sed 's/^/  /'
  fi
  echo
}

run_expect_success() {
  local description="$1"
  local cmd="$2"
  local output=""

  print_test_header "${description}"
  if output="$(run_in_container "${cmd}" 2>&1)"; then
    print_test_result "PASS" "${output}"
  else
    FAILED=$((FAILED + 1))
    print_test_result "FAIL (expected success)" "${output}"
  fi
}

run_expect_tcp_reachable() {
  local description="$1"
  local cmd="$2"
  local output=""

  print_test_header "${description}"
  if output="$(run_in_container "${cmd}" 2>&1)"; then
    print_test_result "PASS" "${output}"
  elif printf '%s' "${output}" | grep -qi "Connection refused"; then
    print_test_result "PASS (reachable, connection refused)" "${output}"
  else
    FAILED=$((FAILED + 1))
    print_test_result "FAIL (expected TCP reachability)" "${output}"
  fi
}

run_expect_failure() {
  local description="$1"
  local cmd="$2"
  local output=""

  print_test_header "${description}"
  if output="$(run_in_container "${cmd}" 2>&1)"; then
    FAILED=$((FAILED + 1))
    print_test_result "FAIL (expected block/failure)" "${output}"
  else
    print_test_result "PASS (blocked as expected)" "${output}"
  fi
}

ensure_tools
resolve_default_container
ensure_container_running

TOTAL_TESTS=$((2 + ${#ALLOW_IPS[@]} + ${#BLOCKED_TARGETS[@]}))

echo "Running egress tests from container: ${CONTAINER_NAME}"
echo "Timeout per probe: ${TIMEOUT_SECONDS}s"
echo

run_expect_success \
  "Internet TCP egress to ${INTERNET_HOST}:${INTERNET_PORT}" \
  "nc -z -w ${TIMEOUT_SECONDS} ${INTERNET_HOST} ${INTERNET_PORT}"

run_expect_success \
  "Allowed DNS TCP egress to ${DNS_SERVER}:${DNS_PORT}" \
  "nc -z -w ${TIMEOUT_SECONDS} ${DNS_SERVER} ${DNS_PORT}"

for allow_ip in "${ALLOW_IPS[@]}"; do
  run_expect_tcp_reachable \
    "Allowed egress to ${allow_ip}:${BLOCKED_PORT}" \
    "nc -z -w ${TIMEOUT_SECONDS} ${allow_ip} ${BLOCKED_PORT}"
done

for target in "${BLOCKED_TARGETS[@]}"; do
  run_expect_failure \
    "Blocked egress to ${target}:${BLOCKED_PORT}" \
    "nc -z -w ${TIMEOUT_SECONDS} ${target} ${BLOCKED_PORT}"
done

if (( FAILED > 0 )); then
  echo "Egress test run complete: ${FAILED} test(s) failed."
  exit 1
fi

echo "Egress test run complete: all tests passed."
