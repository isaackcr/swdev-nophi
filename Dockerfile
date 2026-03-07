ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    openssh-server sudo git gh curl wget vim nano tmux htop iputils-ping netcat-openbsd \
    build-essential ca-certificates python3 python3-pip python3-venv \
 && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && install -m 0755 /root/.local/bin/uv /usr/local/bin/uv \
 && if [ -x /root/.local/bin/uvx ]; then install -m 0755 /root/.local/bin/uvx /usr/local/bin/uvx; fi

RUN mkdir -p /var/run/sshd /workspace /data
EXPOSE 22

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
