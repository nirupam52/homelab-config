FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git jq less nodejs npm \
        openssh-server procps python3 python3-pip python3-venv ripgrep unzip \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd \
    && useradd --create-home --uid 10001 --shell /bin/bash agent

COPY sshd_config /etc/ssh/sshd_hermes_config
COPY sandbox-env.sh /etc/profile.d/sandbox-env.sh

USER agent
WORKDIR /home/agent
EXPOSE 2222
ENTRYPOINT ["/usr/sbin/sshd", "-D", "-e", "-f", "/etc/ssh/sshd_hermes_config"]
