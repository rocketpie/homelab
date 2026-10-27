FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Install OpenCode 2 as the vscode user (installs to ~/.opencode/bin).
USER vscode
RUN curl -fsSL https://opencode.ai/v2/install | bash \
&& git config --global --add safe.directory /workspace

# Expose it on the global PATH.
USER root
RUN ln -sf /home/vscode/.opencode/bin/opencode /usr/local/bin/opencode

ENV DEBIAN_FRONTEND=noninteractive

USER root
RUN apt-get update -o Acquire::Retries=2 \
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
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install PowerShell from the Microsoft package repository.
RUN set -eux; \
    . /etc/os-release; \
    url="https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb"; \
    deb=/tmp/packages-microsoft-prod.deb; \
    if ! curl -fsSL \
        --retry 2 \
        --retry-delay 5 \
        --retry-all-errors \
        --connect-timeout 30 \
        --output "$deb" \
        "$url"; then \
        echo "troubleshoot: could not download $url"; \
        printf 'troubleshoot: %-12s mtu=%s\n' eth0 "$(cat /sys/class/net/eth0/mtu 2>/dev/null || echo unknown)"; \
        exit 1; \
    fi; \
    dpkg -i "$deb"; \
    rm -f "$deb"; \
    apt-get update -o Acquire::Retries=3; \
    apt-get install -y --no-install-recommends powershell; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

# Install the Ansible toolchain into the image.
COPY .devcontainer/venv-requirements.txt .devcontainer/collection-requirements.txt /tmp/ansible-bootstrap/
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

