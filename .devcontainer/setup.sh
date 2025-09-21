#!/bin/bash
set -e

echo "🚀 Setting up development environment..."

# Install Homebrew
echo "📦 Installing Homebrew..."
export NONINTERACTIVE=1
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Configure Homebrew for the coder user
echo "⚙️  Configuring Homebrew environment..."
echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >>/home/coder/.bashrc
echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >>/home/coder/.profile

# Activate Homebrew environment
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# Install packages
echo "📚 Installing development packages..."
/home/linuxbrew/.linuxbrew/bin/brew install node pnpm just buf

# Setup default .zshrc
echo "⚙️  Setting up default .zshrc..."
if [[ ! -f /home/coder/.zshrc ]]; then
    cp /workspaces/chaski/.devcontainer/.zshrc /home/coder/.zshrc
    echo "✅ Default .zshrc copied to /home/coder/.zshrc"
else
    echo "ℹ️  .zshrc already exists, skipping..."
fi

# Setup Bazel remote build configuration
echo "⚙️  Setting up Bazel remote build configuration..."
if [[ -d "/workspaces/chaski" ]]; then
    echo "build --config=remote" >/workspaces/chaski/user.bazelrc
    echo "✅ Created /workspaces/chaski/user.bazelrc with remote build config"
else
    echo "ℹ️  Chaski repository not found, skipping Bazel config..."
fi

# update /workspaces to be writable by coder user
echo "🔧 Updating /workspaces permissions..."
sudo chown coder:coder /workspaces

echo "✅ Development environment setup complete!"
