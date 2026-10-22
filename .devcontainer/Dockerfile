FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install OpenCode 2 as the vscode user (installs to ~/.opencode/bin).
USER vscode
RUN curl -fsSL https://opencode.ai/v2/install | bash \
&& git config --global --add safe.directory /workspace

# Expose it on the global PATH.
USER root
RUN ln -sf /home/vscode/.opencode/bin/opencode /usr/local/bin/opencode

ENV DEBIAN_FRONTEND=noninteractive

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        python3 \
        python3-pip \
        python3-venv \
        sshpass \
        wget \
        xorriso \
    && . /etc/os-release \
    && wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm -f /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install the Ansible toolchain into the image. The repo-local .venv and
# .collections directories are only needed by the legacy WSL workflow.
COPY venv-requirements.txt collection-requirements.txt /tmp/ansible-bootstrap/
RUN python3 -m venv /opt/ansible/venv \
    && /opt/ansible/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/ansible/venv/bin/pip install --no-cache-dir -r /tmp/ansible-bootstrap/venv-requirements.txt \
    && mkdir -p /opt/ansible/collections \
    && /opt/ansible/venv/bin/ansible-galaxy collection install -p /opt/ansible/collections $(cat /tmp/ansible-bootstrap/collection-requirements.txt) \
    && chown -R vscode:vscode /opt/ansible \
    && rm -rf /tmp/ansible-bootstrap

ENV PATH="/opt/ansible/venv/bin:${PATH}"
ENV ANSIBLE_COLLECTIONS_PATH="/opt/ansible/collections"
ENV ANSIBLE_PYTHON="/opt/ansible/venv/bin/python"

