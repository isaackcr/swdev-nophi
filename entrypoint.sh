#!/usr/bin/env bash
set -euo pipefail

USERNAME="${USERNAME:-devuser}"
USER_UID="${USER_UID:-1000}"
USER_GID="${USER_GID:-1000}"

# Create group if the numeric GID does not already exist
if ! getent group "${USER_GID}" >/dev/null 2>&1; then
  groupadd -g "${USER_GID}" "${USERNAME}"
fi

# Create user if missing
if ! id -u "${USERNAME}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -u "${USER_UID}" -g "${USER_GID}" "${USERNAME}"
  usermod -aG sudo "${USERNAME}"
  echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
  chmod 0440 "/etc/sudoers.d/${USERNAME}"
fi

HOME_DIR="/home/${USERNAME}"
SSH_DIR="${HOME_DIR}/.ssh"
BASHRC="${HOME_DIR}/.bashrc"
PROFILE="${HOME_DIR}/.profile"

# Fix home ownership and permissions
mkdir -p "${HOME_DIR}"
chown "${USER_UID}:${USER_GID}" "${HOME_DIR}"
chmod 755 "${HOME_DIR}"

# Ensure .ssh exists with safe perms
mkdir -p "${SSH_DIR}"
chown "${USER_UID}:${USER_GID}" "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

# If authorized_keys is mounted in, keep perms sane
if [[ -f "${SSH_DIR}/authorized_keys" ]]; then
  chmod 600 "${SSH_DIR}/authorized_keys" || true
  chown "${USER_UID}:${USER_GID}" "${SSH_DIR}/authorized_keys" || true
fi

# Make bashrc exist
touch "${BASHRC}"
chown "${USER_UID}:${USER_GID}" "${BASHRC}"

# Ensure login shells source .bashrc (mounted homes may not include default skel files)
touch "${PROFILE}"
if ! grep -q 'Load .bashrc for interactive bash shells' "${PROFILE}"; then
  cat >> "${PROFILE}" <<'EOF'

# Load .bashrc for interactive bash shells
if [ -n "${BASH_VERSION:-}" ] && [ -f "${HOME}/.bashrc" ]; then
  . "${HOME}/.bashrc"
fi
EOF
fi
chown "${USER_UID}:${USER_GID}" "${PROFILE}"

# TERM compatibility for remote clients
if ! grep -q 'TERM compatibility for remote clients' "${BASHRC}"; then
  cat >> "${BASHRC}" <<'EOF'

# TERM compatibility for remote clients
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  case "$TERM" in
    xterm-ghostty|ghostty|unknown)
      export TERM=xterm-256color
      ;;
  esac
fi
EOF
fi

chown "${USER_UID}:${USER_GID}" "${BASHRC}"

# TERM fallback for shells that do not load user dotfiles
cat > /etc/profile.d/zz-term-compat.sh <<'EOF'
if [ -n "${SSH_CONNECTION:-}" ] && [ -t 1 ]; then
  case "${TERM:-}" in
    xterm-ghostty|ghostty|unknown)
      export TERM=xterm-256color
      ;;
  esac
fi
EOF
chmod 0644 /etc/profile.d/zz-term-compat.sh

# For interactive SSH shells, start in the user's home directory.
cat > /etc/profile.d/zz-home-default-dir.sh <<'EOF'
if [[ -n "${SSH_CONNECTION:-}" && -t 1 && -n "${HOME:-}" && -d "${HOME}" ]]; then
  cd "${HOME}" 2>/dev/null || true
fi
EOF
chmod 0644 /etc/profile.d/zz-home-default-dir.sh

# SSH config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

if grep -q '^#\?UsePAM ' /etc/ssh/sshd_config; then
  sed -i 's/^#\?UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config
else
  echo 'UsePAM yes' >> /etc/ssh/sshd_config
fi

if grep -q '^AllowUsers ' /etc/ssh/sshd_config; then
  sed -i "s/^AllowUsers .*/AllowUsers ${USERNAME}/" /etc/ssh/sshd_config
else
  echo "AllowUsers ${USERNAME}" >> /etc/ssh/sshd_config
fi

exec /usr/sbin/sshd -D
