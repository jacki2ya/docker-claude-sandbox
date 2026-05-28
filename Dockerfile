FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        git \
        jq \
        ripgrep \
        fd-find \
        python3 \
        python3-pip \
        python3-venv \
        python3-yaml \
        build-essential \
        less \
        vim-tiny \
        nano \
        procps \
        iproute2 \
        gnupg \
        sudo \
        locales \
        openssh-client \
        age \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s "$(command -v fdfind)" /usr/local/bin/fd

RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code

# Terraform via HashiCorp's official APT repo (multi-arch: amd64 + arm64)
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg \
        | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com bookworm main" \
        > /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends terraform \
    && rm -rf /var/lib/apt/lists/*

# SOPS — pinned binary release from getsops/sops (multi-arch: amd64 + arm64)
ARG SOPS_VERSION=3.9.4
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL -o /usr/local/bin/sops \
        "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${arch}" \
    && chmod +x /usr/local/bin/sops

ARG USERNAME=claude
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID --create-home --shell /bin/bash $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY bin/claude-statusline /usr/local/bin/claude-statusline
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/claude-statusline

# Baked under ~/.claude/ as siblings of the runtime bind-mount
# (~/.claude/projects/-workspace). --chown lets the entrypoint's
# non-recursive ownership reclaim skip them.
COPY --chown=$USER_UID:$USER_GID image/claude-home-settings.json /home/$USERNAME/.claude/settings.json
COPY --chown=$USER_UID:$USER_GID image/claude-home-CLAUDE.md     /home/$USERNAME/.claude/CLAUDE.md

USER $USERNAME
WORKDIR /workspace

ENV DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
