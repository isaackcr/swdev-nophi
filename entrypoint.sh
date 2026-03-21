#!/usr/bin/env bash
set -euo pipefail

USERNAME="${USERNAME:-devuser}"
USER_UID="${USER_UID:-1000}"
USER_GID="${USER_GID:-1000}"
SHARED_GID="${SHARED_GID:-}"

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

if [[ -n "${SHARED_GID}" ]]; then
  if [[ ! "${SHARED_GID}" =~ ^[0-9]+$ ]]; then
    echo "Invalid SHARED_GID: ${SHARED_GID}" >&2
    exit 1
  fi

  SHARED_GROUP_NAME="$(getent group "${SHARED_GID}" | cut -d: -f1)"
  if [[ -z "${SHARED_GROUP_NAME}" ]]; then
    SHARED_GROUP_NAME="nophi-shared-${SHARED_GID}"
    groupadd -g "${SHARED_GID}" "${SHARED_GROUP_NAME}"
  fi

  if [[ -n "${SHARED_GROUP_NAME}" ]]; then
    usermod -aG "${SHARED_GROUP_NAME}" "${USERNAME}"
  fi
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

# Ensure user-level tools installed into ~/.local/bin are on PATH
if ! grep -q 'NOPHI local bin PATH' "${PROFILE}"; then
  cat >> "${PROFILE}" <<'EOF'

# NOPHI local bin PATH
if [ -d "${HOME}/.local/bin" ]; then
  export PATH="${HOME}/.local/bin:${PATH}"
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

# Rich interactive shell defaults for container users
if ! grep -q 'NOPHI rich interactive shell defaults' "${BASHRC}"; then
  cat >> "${BASHRC}" <<'EOF'

# NOPHI rich interactive shell defaults
if [[ $- == *i* ]]; then
  # Keep history useful across many SSH sessions
  shopt -s histappend checkwinsize cmdhist
  HISTSIZE=5000
  HISTFILESIZE=10000

  # Enable bash completion when available
  if [[ -r /etc/bash_completion ]]; then
    . /etc/bash_completion
  fi

  # Better completion and prompt coloring via readline
  bind 'set colored-stats on' 2>/dev/null || true
  bind 'set colored-completion-prefix on' 2>/dev/null || true
  bind 'set show-all-if-ambiguous on' 2>/dev/null || true
  bind 'set completion-ignore-case on' 2>/dev/null || true

  # Baseline color aliases
  if command -v dircolors >/dev/null 2>&1; then
    eval "$(dircolors -b)"
  fi
  alias ls='ls --color=auto'
  alias grep='grep --color=auto'
  alias egrep='egrep --color=auto'
  alias fgrep='fgrep --color=auto'

  # Git prompt support (branch + dirty state) if available
  if [[ -r /usr/lib/git-core/git-sh-prompt ]]; then
    . /usr/lib/git-core/git-sh-prompt
  elif [[ -r /etc/bash_completion.d/git-prompt ]]; then
    . /etc/bash_completion.d/git-prompt
  fi
  export GIT_PS1_SHOWDIRTYSTATE=1
  export GIT_PS1_SHOWSTASHSTATE=1
  export GIT_PS1_SHOWUNTRACKEDFILES=1
  export GIT_PS1_SHOWUPSTREAM=auto

  # Colorful prompt; includes git branch when git prompt helper is available
  if declare -F __git_ps1 >/dev/null 2>&1; then
    PS1='\[\e[38;5;39m\]\u@\h\[\e[0m\]:\[\e[38;5;214m\]\w\[\e[0m\]$(__git_ps1 " \[\e[38;5;141m\](%s)\[\e[0m\]") \[\e[38;5;46m\]\$\[\e[0m\] '
  else
    PS1='\[\e[38;5;39m\]\u@\h\[\e[0m\]:\[\e[38;5;214m\]\w\[\e[0m\] \[\e[38;5;46m\]\$\[\e[0m\] '
  fi
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
