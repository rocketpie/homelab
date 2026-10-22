FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install OpenCode 2 as the vscode user (installs to ~/.opencode/bin).
USER vscode
RUN curl -fsSL https://opencode.ai/v2/install | bash

# Expose it on the global PATH.
USER root
RUN ln -sf /home/vscode/.opencode/bin/opencode /usr/local/bin/opencode
