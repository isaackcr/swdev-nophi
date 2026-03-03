#!/usr/bin/env bash
set -euo pipefail

SHARED_DIR="/srv/NOPHI-data"
SHARED_GROUP="cri-shared"
TARGET_USER="${USER}"
GROUP_CREATED=false
DIR_CREATED=false
USER_ADDED=false

if ! getent group "${SHARED_GROUP}" >/dev/null; then
  GROUP_CREATED=true
fi

if [[ ! -d "${SHARED_DIR}" ]]; then
  DIR_CREATED=true
fi

sudo groupadd -f "${SHARED_GROUP}"
sudo mkdir -p "${SHARED_DIR}"
sudo chgrp -R "${SHARED_GROUP}" "${SHARED_DIR}"
sudo chmod -R 2775 "${SHARED_DIR}"

if ! getent group "${SHARED_GROUP}" | awk -F: -v user="${TARGET_USER}" '
  {
    n = split($4, members, ",")
    for (i = 1; i <= n; i++) {
      if (members[i] == user) {
        found = 1
      }
    }
  }
  END { exit found ? 0 : 1 }
'; then
  sudo usermod -aG "${SHARED_GROUP}" "${TARGET_USER}"
  USER_ADDED=true
fi

if [[ "${GROUP_CREATED}" == "true" ]]; then
  echo "Created group: ${SHARED_GROUP}"
fi

if [[ "${DIR_CREATED}" == "true" ]]; then
  echo "Created directory: ${SHARED_DIR}"
fi

if [[ "${USER_ADDED}" == "true" ]]; then
  echo "Added ${TARGET_USER} to ${SHARED_GROUP}; log out and back in to use new group membership."
fi

if [[ "${GROUP_CREATED}" == "false" && "${DIR_CREATED}" == "false" && "${USER_ADDED}" == "false" ]]; then
  echo "Shared directory access is already configured."
fi
