terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.0"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
    envbuilder = {
      source = "coder/envbuilder"
    }
  }
}

variable "docker_socket" {
  default     = "unix:///var/run/docker.sock"
  description = "(Optional) Docker socket URI"
  type        = string
}

provider "coder" {}
provider "docker" {
  # Defaulting to null if the variable is an empty string lets us have an optional variable without having to set our own default
  host = var.docker_socket != "" ? var.docker_socket : null
}

provider "envbuilder" {}

data "coder_external_auth" "github" {
    id = "primary-github"
}

# GitHub Example (CODER_EXTERNAL_AUTH_0_ID="primary-github")
# makes a GitHub authentication token available at data.coder_external_auth.github.access_token
data "coder_external_auth" "primary-github" {
   id = "primary-github"
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "repo" {
  description  = "Select a repository to automatically clone and start working with a devcontainer."
  display_name = "Repository (auto)"
  mutable      = true
  name         = "repo"
  option {
    name        = "test-greater"
    icon        = "/icon/code.svg"
    description = "The distribution OS"
    value       = "https://github.com/greaterindustries/test-greater"
  }
  option {
    name        = "eng-onboarding"
    icon        = "/icon/code.svg"
    description = "The onboarding repo docs and KB tools"
    value       = "https://github.com/greaterindustries/eng-onboarding"
  }
  order = 1
}

variable "cache_repo" {
  default     = "localhost:5000/cache"
  description = "(Optional) Use a container registry as a cache to speed up builds."
  type        = string
}

variable "insecure_cache_repo" {
  default     = true
  description = "Enable this option if your cache registry does not serve HTTPS."
  type        = bool
}

variable "cache_repo_docker_config_path" {
  default     = ""
  description = "(Optional) Path to a docker config.json containing credentials to the provided cache repo, if required."
  sensitive   = true
  type        = string
}

locals {
  container_name             = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  devcontainer_builder_image = "ghcr.io/coder/envbuilder:latest"
  git_author_name            = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
  git_author_email           = data.coder_workspace_owner.me.email
  repo_url                   = data.coder_parameter.repo.value
  # The envbuilder provider requires a key-value map of environment variables.
  envbuilder_env = {
    # "ENVBUILDER_GIT_URL" : "",
    "ENVBUILDER_GIT_URL" : local.repo_url,
    "ENVBUILDER_GIT_USERNAME" : data.coder_external_auth.primary-github.access_token,
    "ENVBUILDER_GIT_PASSWORD" : "",
    "ENVBUILDER_WORKSPACE_FOLDER" : "/workspaces/test-greater",
    "ENVBUILDER_CACHE_REPO" : var.cache_repo,
    "CODER_AGENT_TOKEN" : coder_agent.main.token,
    # Use the docker gateway if the access URL is 127.0.0.1
    "CODER_AGENT_URL" : replace(data.coder_workspace.me.access_url, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal"),
    # Use the docker gateway if the access URL is 127.0.0.1
    "ENVBUILDER_INIT_SCRIPT" : replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal"),
    # "ENVBUILDER_FALLBACK_IMAGE" : "ghcr.io/coder/envbuilder:latest",
    "ENVBUILDER_DOCKER_CONFIG_BASE64" : try(data.local_sensitive_file.cache_repo_dockerconfigjson[0].content_base64, ""),
    "ENVBUILDER_PUSH_IMAGE" : var.cache_repo == "" ? "" : "true",
    "ENVBUILDER_INSECURE" : "${var.insecure_cache_repo}",
    # Debug environment variables
    "ENVBUILDER_DEBUG" : "true",
    "ENVBUILDER_LOG_LEVEL" : "debug",
  }
  # Convert the above map to the format expected by the docker provider.
  docker_env = [
    for k, v in local.envbuilder_env : "${k}=${v}"
  ]
}

data "local_sensitive_file" "cache_repo_dockerconfigjson" {
  count    = var.cache_repo_docker_config_path == "" ? 0 : 1
  filename = var.cache_repo_docker_config_path
}

resource "docker_image" "devcontainer_builder_image" {
  name         = local.devcontainer_builder_image
  keep_locally = true
}

resource "docker_volume" "workspaces" {
  name = "coder-${data.coder_workspace.me.id}"
  # Protect the volume from being deleted due to changes in attributes.
  lifecycle {
    ignore_changes = all
  }
  # Add labels in Docker to keep track of orphan resources.
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  # This field becomes outdated if the workspace is renamed but can
  # be useful for debugging or cleaning out dangling volumes.
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

# Check for the presence of a prebuilt image in the cache repo
# that we can use instead.
resource "envbuilder_cached_image" "cached" {
  count         = var.cache_repo == "" ? 0 : data.coder_workspace.me.start_count
  builder_image = local.devcontainer_builder_image
  # Required by envbuilder but not used since git-clone module handles cloning
  git_url       = local.repo_url
  cache_repo    = var.cache_repo
  extra_env     = local.envbuilder_env
  insecure      = var.insecure_cache_repo
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = var.cache_repo == "" ? local.devcontainer_builder_image : envbuilder_cached_image.cached.0.image
  # Uses lower() to avoid Docker restriction on container names.
  name = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  # Hostname makes the shell more user friendly: coder@my-workspace:~$
  hostname = data.coder_workspace.me.name
  # Use the environment specified by the envbuilder provider, if available.
  env = var.cache_repo == "" ? local.docker_env : envbuilder_cached_image.cached.0.env
  # Use host network mode for k3s to avoid networking issues
  network_mode = "host"
  # Run with privileged access for k3s
  privileged = true
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
  volumes {
    container_path = "/workspaces"
    volume_name    = docker_volume.workspaces.name
    read_only      = false
  }
  volumes {
    container_path = "/var/run/docker.sock"
    host_path      = "/var/run/docker.sock"
    read_only      = false
  }
  # Add host mounts for k3s
  volumes {
    container_path = "/var/lib/rancher"
    host_path      = "/var/lib/rancher"
    read_only      = false
  }
  volumes {
    container_path = "/var/lib/kubelet"
    host_path      = "/var/lib/kubelet"
    read_only      = false
  }
  volumes {
    container_path = "/var/lib/cni"
    host_path      = "/var/lib/cni"
    read_only      = false
  }
  volumes {
    container_path = "/var/lib/containerd"
    host_path      = "/var/lib/containerd"
    read_only      = false
  }
  volumes {
    container_path = "/run/containerd"
    host_path      = "/run/containerd"
    read_only      = false
  }
  volumes {
    container_path = "/etc/rancher"
    host_path      = "/etc/rancher"
    read_only      = false
  }

  # Add labels in Docker to keep track of orphan resources.
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}

resource "coder_agent" "main" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
  startup_script = <<-EOT
    set -e

    # Fix Docker permissions if needed
    if ! docker ps >/dev/null 2>&1; then
      echo "Fixing Docker permissions..."
      # Check if docker group exists, create if not
      if ! getent group docker >/dev/null 2>&1; then
        sudo groupadd -g 189 docker
      fi
      # Add coder user to docker group
      sudo usermod -aG docker coder
      # Fix socket permissions
      sudo chmod 666 /var/run/docker.sock
      # Activate the new group membership
      newgrp docker
    fi

    # Configure Docker to trust the local registry
    echo "Configuring Docker to trust local registry..."
    if [ ! -f /etc/docker/daemon.json ]; then
      sudo mkdir -p /etc/docker
      sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "insecure-registries": ["localhost:5000"]
}
EOF
      sudo systemctl restart docker
    fi

    # Create necessary devices for k3s
    echo "=== Creating necessary devices for k3s ==="
    sudo mknod /dev/kmsg c 1 11 2>/dev/null || echo "kmsg device already exists"
    sudo chmod 666 /dev/kmsg
    sudo mknod /dev/net/tun c 10 200 2>/dev/null || echo "tun device already exists"
    sudo chmod 666 /dev/net/tun

    # Start containerd for k3s
    echo "=== Starting containerd ==="
    sudo containerd > /tmp/containerd.log 2>&1 &
    sleep 3
    
    # Wait for containerd to be ready
    echo "Waiting for containerd to be ready..."
    timeout 30 bash -c 'until ls /run/containerd/containerd.sock 2>/dev/null; do sleep 1; done' || echo "containerd startup timeout"

    # Start k3s with privileged access
    echo "=== Starting k3s with privileged access ==="
    
    # Create necessary directories
    sudo mkdir -p /var/lib/rancher/k3s
    sudo mkdir -p /var/lib/kubelet
    sudo mkdir -p /var/lib/cni
    sudo mkdir -p /var/lib/containerd
    sudo mkdir -p /run/containerd
    sudo mkdir -p /etc/rancher
    
    # Set proper permissions
    sudo chown -R coder:coder /var/lib/rancher
    sudo chown -R coder:coder /var/lib/kubelet
    sudo chown -R coder:coder /var/lib/cni
    sudo chown -R coder:coder /var/lib/containerd
    sudo chown -R coder:coder /run/containerd
    sudo chown -R coder:coder /etc/rancher
    
    # Start k3s with containerd
    sudo k3s server \
      --snapshotter native \
      --write-kubeconfig-mode 644 \
      --write-kubeconfig ~/.kube/config \
      --container-runtime-endpoint=unix:///run/containerd/containerd.sock \
      --kubelet-arg="container-runtime-endpoint=unix:///run/containerd/containerd.sock" \
      --kubelet-arg="log-flush-frequency=5s" \
      > /tmp/k3s.log 2>&1 &
    
    # Wait for k3s to be ready
    echo "Waiting for k3s to be ready..."
    timeout 120 bash -c 'until kubectl get nodes 2>/dev/null; do sleep 5; done' || echo "k3s startup timeout"
    
    # Test kubectl access
    echo "Testing kubectl access..."
    kubectl get nodes || echo "kubectl access failed"

    echo "=== Debugging workspace structure ==="
    echo "Contents of /workspaces/:"
    ls -la /workspaces/
    echo ""
    echo "Contents of /workspaces/test-greater/ (if it exists):"
    ls -la /workspaces/test-greater/ 2>/dev/null || echo "Directory does not exist"
    echo ""
    echo "Looking for .devcontainer in /workspaces/test-greater/:"
    find /workspaces/test-greater/ -name ".devcontainer" -type d 2>/dev/null || echo "No .devcontainer directory found"

    # Debug Docker socket permissions
    echo "=== Docker Socket Debugging ==="
    echo "Docker socket permissions:"
    ls -la /var/run/docker.sock 2>/dev/null || echo "Docker socket not found"
    echo ""
    echo "Current user and groups:"
    id
    echo ""
    echo "Docker daemon status:"
    sudo systemctl status docker 2>/dev/null || echo "Docker daemon not running via systemctl"
    echo ""
    echo "Testing Docker access:"
    docker ps 2>&1 || echo "Docker access failed"

    # Add any commands that should be executed at workspace startup (e.g install requirements, start a program, etc) here
  EOT
  dir            = "/workspaces/test-greater"

  # These environment variables allow you to make Git commits right away after creating a
  # workspace. Note that they take precedence over configuration defined in ~/.gitconfig!
  # You can remove this block if you'd prefer to configure Git manually or using
  # dotfiles. (see docs/dotfiles.md)
  env = {
    GIT_AUTHOR_NAME     = local.git_author_name
    GIT_AUTHOR_EMAIL    = local.git_author_email
    GIT_COMMITTER_NAME  = local.git_author_name
    GIT_COMMITTER_EMAIL = local.git_author_email

  }

  # The following metadata blocks are optional. They are used to display
  # information about your workspace in the dashboard. You can remove them
  # if you don't want to display any information.
  # For basic resources, you can use the `coder stat` command.
  # If you need more control, you can write your own script.
  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $HOME"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    # get load avg scaled by number of cores
    script   = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval = 60
    timeout  = 1
  }

  metadata {
    display_name = "Swap Usage (Host)"
    key          = "7_swap_host"
    script       = <<EOT
      free -b | awk '/^Swap/ { printf("%.1f/%.1f", $3/1024.0/1024.0/1024.0, $2/1024.0/1024.0/1024.0) }'
    EOT
    interval     = 10
    timeout      = 1
  }
}

# See https://registry.coder.com/modules/coder/code-server
module "code-server" {
  count  = data.coder_workspace.me.start_count
  source = "registry.coder.com/coder/code-server/coder"

  # This ensures that the latest non-breaking version of the module gets downloaded, you can also pin the module version to prevent breaking changes in production.
  version = "~> 1.0"

  agent_id = coder_agent.main.id
  order    = 1
}

# See https://registry.coder.com/modules/coder/cursor
module "cursor" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/cursor/coder"
  version  = "1.2.0"
  agent_id = coder_agent.main.id
  folder   = "/workspaces/${replace(local.repo_url, "https://github.com/greaterindustries/", "")}"
}

resource "coder_metadata" "container_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = coder_agent.main.id
  item {
    key   = "workspace image"
    value = var.cache_repo == "" ? local.devcontainer_builder_image : envbuilder_cached_image.cached.0.image
  }
  item {
    key   = "git url"
    value = local.repo_url
  }
  item {
    key   = "cache repo"
    value = var.cache_repo == "" ? "not enabled" : var.cache_repo
  }
}