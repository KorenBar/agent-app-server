FROM mcr.microsoft.com/playwright:v1.61.0-noble

ENV DEBIAN_FRONTEND=noninteractive
ENV CODEX_HOME=/home/agent/.codex
ENV NPM_CONFIG_PREFIX=/home/agent/.npm-global
ENV PATH=/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/home/agent/.npm-global/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        dnsutils \
        fd-find \
        ffmpeg \
        file \
        fontconfig \
        fonts-noto-color-emoji \
        fonts-noto-core \
        g++ \
        gnupg \
        git \
        imagemagick \
        iproute2 \
        iputils-ping \
        jq \
        less \
        lsof \
        make \
        nano \
        netcat-openbsd \
        net-tools \
        openssh-client \
        openssh-server \
        pipx \
        pkg-config \
        poppler-utils \
        procps \
        psmisc \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        rsync \
        shellcheck \
        socat \
        sudo \
        supervisor \
        tmux \
        tree \
        tini \
        unzip \
        vim-tiny \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*

RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && . /etc/os-release \
    && printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        containerd.io \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Install image-owned tools outside mounted user npm volumes.
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && NPM_CONFIG_PREFIX=/usr/local npm install -g \
        @openai/codex \
        @playwright/test@1.61.0 \
        codexapp \
        playwright@1.61.0 \
    && cd /usr/local/lib/node_modules/codexapp \
    && NPM_CONFIG_PREFIX=/usr/local npm install node-pty@^1.1.0 --include=optional \
    && npm cache clean --force

RUN if getent group agent >/dev/null; then \
        groupmod -g 1001 agent; \
    elif getent group 1001 >/dev/null; then \
        groupmod -n agent "$(getent group 1001 | cut -d: -f1)"; \
    else \
        groupadd -g 1001 agent; \
    fi \
    && if id -u agent >/dev/null 2>&1; then \
        usermod -u 1001 -g agent -d /home/agent -s /bin/bash agent; \
    elif getent passwd 1001 >/dev/null; then \
        usermod -l agent -d /home/agent -m -g agent -s /bin/bash "$(getent passwd 1001 | cut -d: -f1)"; \
    else \
        useradd -m -d /home/agent -s /bin/bash -u 1001 -g agent agent; \
    fi \
    && (getent group docker >/dev/null || groupadd docker) \
    && usermod -aG docker agent \
    && install -d -m 0755 /workspace /run/sshd /etc/ssh/persistent /opt/agent-app/ssh /var/lib/docker \
    && install -d -m 0700 -o agent -g agent /home/agent/.ssh /home/agent/.codex \
    && install -d -m 0755 -o agent -g agent /home/agent/Documents /home/agent/.local /home/agent/.npm-global \
    && chown agent:agent /home/agent /workspace

COPY entrypoint.sh /usr/local/bin/agent-app-entrypoint
COPY nginx-vhost-init.sh /usr/local/bin/agent-app-nginx-vhost

RUN sed -i 's/\r$//' /usr/local/bin/agent-app-entrypoint /usr/local/bin/agent-app-nginx-vhost \
    && chmod +x /usr/local/bin/agent-app-entrypoint /usr/local/bin/agent-app-nginx-vhost

WORKDIR /workspace

EXPOSE 22 5900

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/agent-app-entrypoint"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
