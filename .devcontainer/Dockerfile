FROM --platform=linux/amd64 mcr.microsoft.com/devcontainers/base:ubuntu

# Set shell with pipefail for safer pipe operations
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install basic system dependencies (cached layer)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    libc6 \
    libc6-dev \
    build-essential \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Add Python PPA and install Python 3.12
RUN add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Create Python symlinks
RUN ln -s /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/python3.12 /usr/bin/python3

# Create or modify coder user
RUN if id -u coder > /dev/null 2>&1; then \
        echo "User coder already exists, modifying..."; \
        usermod -aG sudo coder; \
    else \
        if id -u 1000 > /dev/null 2>&1; then \
            echo "UID 1000 exists, creating coder with different UID..."; \
            useradd --create-home --shell=/bin/bash --groups=sudo coder; \
        else \
            echo "Creating coder user with UID 1000..."; \
            useradd --create-home --shell=/bin/bash --groups=sudo --uid=1000 coder; \
        fi; \
    fi \
    && echo "coder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/nopasswd \
    && chmod 440 /etc/sudoers.d/nopasswd \
    && chown -R coder:coder /home/coder

# Install Just directly
RUN curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin

# Install Bazelisk (as bazel command)
RUN curl -LO https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64 \
    && chmod +x bazelisk-linux-amd64 \
    && mv bazelisk-linux-amd64 /usr/local/bin/bazel

# Install Google Cloud CLI in shared location
RUN curl -sSL https://sdk.cloud.google.com > /tmp/install-gcloud.sh \
    && chmod +x /tmp/install-gcloud.sh \
    && CLOUDSDK_INSTALL_DIR=/opt /tmp/install-gcloud.sh --disable-prompts \
    && rm /tmp/install-gcloud.sh \
    && chmod -R 755 /opt/google-cloud-sdk \
    && echo "source /opt/google-cloud-sdk/path.bash.inc" >> /etc/bash.bashrc \
    && echo "source /opt/google-cloud-sdk/completion.bash.inc" >> /etc/bash.bashrc

# Add gcloud to PATH for all users
ENV PATH="/opt/google-cloud-sdk/bin:${PATH}"

# Install containerd for k3s
RUN apt-get update && apt-get install -y --no-install-recommends \
    containerd \
    && rm -rf /var/lib/apt/lists/*

# Configure containerd
RUN mkdir -p /etc/containerd \
    && containerd config default > /etc/containerd/config.toml \
    && sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Install k3s
RUN curl -sfL https://get.k3s.io | sh -

# Install Temporal CLI
RUN curl -sSf https://temporal.download/cli.sh | sh \
    && mv /root/.temporalio/bin/temporal /usr/local/bin/temporal

# Install kubectl
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
    && rm kubectl

# Install kubectx and kubens
RUN git clone https://github.com/ahmetb/kubectx /opt/kubectx \
    && ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx \
    && ln -s /opt/kubectx/kubens /usr/local/bin/kubens \
    && chmod +x /opt/kubectx/kubectx /opt/kubectx/kubens

# Install Skaffold
RUN curl -Lo skaffold https://storage.googleapis.com/skaffold/releases/latest/skaffold-linux-amd64 \
    && install skaffold /usr/local/bin/ \
    && rm skaffold

# Install Helm
RUN curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install Coder agent
RUN curl -fsSL https://coder.com/install.sh | sh -s -- --method=standalone --prefix=/usr/local

# Install Docker CLI
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker.io \
    && rm -rf /var/lib/apt/lists/*

# Create necessary directories and set permissions for k3s
RUN mkdir -p /var/lib/rancher/k3s \
    && mkdir -p /var/lib/kubelet \
    && mkdir -p /var/lib/cni \
    && mkdir -p /var/lib/containerd \
    && mkdir -p /run/containerd \
    && mkdir -p /dev/kmsg \
    && chmod 666 /dev/kmsg

# Verify installations (run as root before switching users)
RUN bazel version && \
    gcloud version && \
    temporal --version && \
    docker --version && \
    kubectl version --client && \
    kubectx --help && \
    kubens --help && \
    skaffold version && \
    helm version && \
    just --version

# Set up gcloud for coder user
RUN echo "source /opt/google-cloud-sdk/path.bash.inc" >> /home/coder/.bashrc \
    && echo "source /opt/google-cloud-sdk/completion.bash.inc" >> /home/coder/.bashrc \
    && chown -R coder:coder /home/coder

# Add coder to docker group with proper GID for Docker socket access
# Use GID 189 to match the host's systemd-journal group that owns the Docker socket
# Alternative: Use the same name as the host group for better portability
RUN groupadd -f -g 189 docker && usermod -aG docker coder

# RUN mkdir -p /workspaces && chown -R coder:coder /workspaces

# Switch to coder user
USER coder
WORKDIR /workspaces