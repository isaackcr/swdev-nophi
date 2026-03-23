ARG BASE_IMAGE=ubuntu:24.04
ARG INSTALL_NVTOP=false
FROM ${BASE_IMAGE}
ARG INSTALL_NVTOP

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    if [ "${INSTALL_NVTOP}" = "true" ]; then \
      if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        sed -i '/^Components:/ { /multiverse/! s/$/ multiverse/ }' /etc/apt/sources.list.d/ubuntu.sources; \
      elif [ -f /etc/apt/sources.list ]; then \
        sed -i '/^[[:space:]]*deb .*ubuntu/ { / multiverse/! s/$/ multiverse/ }' /etc/apt/sources.list; \
      fi; \
    fi; \
    apt-get update; \
    packages="openssh-server sudo git gh curl wget vim nano tmux htop iputils-ping netcat-openbsd build-essential ca-certificates python3 python3-pip python3-venv"; \
    if [ "${INSTALL_NVTOP}" = "true" ]; then \
      if ! apt-cache show nvtop >/dev/null 2>&1; then \
        echo "ERROR: nvtop is not available in the configured Ubuntu apt repositories."; \
        exit 1; \
      fi; \
      packages="${packages} nvtop"; \
    fi; \
    apt-get install -y ${packages}; \
    rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && install -m 0755 /root/.local/bin/uv /usr/local/bin/uv \
 && if [ -x /root/.local/bin/uvx ]; then install -m 0755 /root/.local/bin/uvx /usr/local/bin/uvx; fi

RUN mkdir -p /var/run/sshd /srv/NOPHI-shared
EXPOSE 22

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
