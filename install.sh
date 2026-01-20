#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPO="thomas/claude-code-isolated"
BINARY_NAME="cci"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${VERSION:-latest}"
COLIMA_VM_NAME="cci"
COLIMA_CPU="${COLIMA_CPU:-4}"
COLIMA_MEMORY="${COLIMA_MEMORY:-8}"
COLIMA_DISK="${COLIMA_DISK:-60}"

# Detect OS and architecture
detect_platform() {
    local os
    local arch

    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Linux*)
            OS="linux"
            PLATFORM="linux"
            ;;
        Darwin*)
            OS="darwin"
            PLATFORM="macos"
            ;;
        *)
            echo -e "${RED}✗ Unsupported OS: $os${NC}"
            exit 1
            ;;
    esac

    case "$arch" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            echo -e "${RED}✗ Unsupported architecture: $arch${NC}"
            exit 1
            ;;
    esac

    echo -e "${BLUE}→ Detected platform: ${OS}/${ARCH}${NC}"
}

# ============================================================================
# Linux-specific functions
# ============================================================================

# Check if Incus is installed (Linux)
check_incus_linux() {
    echo -e "${BLUE}→ Checking Incus installation...${NC}"

    if ! command -v incus &> /dev/null; then
        echo -e "${YELLOW}⚠ Incus not found${NC}"
        echo ""
        echo "  claude-code-isolated requires Incus to be installed."
        echo "  Install Incus: https://linuxcontainers.org/incus/docs/main/installing/"
        echo ""
        echo "  Quick install (Ubuntu/Debian):"
        echo "    sudo apt update"
        echo "    sudo apt install -y incus"
        echo "    sudo incus admin init --auto"
        echo "    sudo usermod -aG incus-admin \$USER"
        echo ""
        read -p "Continue installation anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo -e "${GREEN}✓ Incus found: $(incus version)${NC}"
    fi
}

# Check if user is in incus-admin group (Linux)
check_group_linux() {
    if groups | grep -q incus-admin; then
        echo -e "${GREEN}✓ User is in incus-admin group${NC}"
    else
        echo -e "${YELLOW}⚠ User is not in incus-admin group${NC}"
        echo ""
        echo "  You need to be in the incus-admin group to use claude-code-isolated."
        echo "  Run: sudo usermod -aG incus-admin \$USER"
        echo "  Then log out and back in for changes to take effect."
        echo ""
    fi
}

# Set up ZFS storage (Linux)
setup_zfs_storage() {
    echo ""
    echo -e "${BLUE}→ Setting up fast storage (ZFS)...${NC}"

    if command -v zfs &> /dev/null; then
        echo -e "${GREEN}✓ ZFS already installed${NC}"
    else
        echo -e "${BLUE}→ Installing ZFS...${NC}"
        if sudo apt-get install -y zfsutils-linux 2>&1 | grep -q "E:"; then
            echo -e "${YELLOW}⚠ ZFS installation failed (may not be available for your kernel)${NC}"
            echo -e "${YELLOW}  Containers will use default storage (slower but functional)${NC}"
            return 1
        fi
        echo -e "${GREEN}✓ ZFS installed${NC}"
    fi

    if incus storage list --format=csv 2>/dev/null | grep -q "^zfs-pool,"; then
        echo -e "${GREEN}✓ ZFS storage pool already configured${NC}"
        return 0
    fi

    echo -e "${BLUE}→ Creating ZFS storage pool (50GiB)...${NC}"
    if sudo incus storage create zfs-pool zfs size=50GiB 2>&1; then
        echo -e "${GREEN}✓ ZFS storage pool created${NC}"

        echo -e "${BLUE}→ Configuring default profile to use ZFS...${NC}"
        if incus profile device set default root pool=zfs-pool 2>&1; then
            echo -e "${GREEN}✓ Default profile configured for ZFS${NC}"
            echo -e "${GREEN}✓ Containers will now start instantly (~50ms vs 5-10s)${NC}"
        else
            echo -e "${YELLOW}⚠ Failed to configure default profile${NC}"
            echo -e "  ${BLUE}incus profile device set default root pool=zfs-pool${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ ZFS storage pool creation failed${NC}"
        echo -e "${YELLOW}  Containers will use default storage (slower but functional)${NC}"
        return 1
    fi
}

# ============================================================================
# macOS-specific functions (Colima)
# ============================================================================

# Check if Homebrew is installed (macOS)
check_homebrew() {
    if ! command -v brew &> /dev/null; then
        echo -e "${RED}✗ Homebrew not found${NC}"
        echo ""
        echo "  Homebrew is required for macOS installation."
        echo "  Install Homebrew: https://brew.sh/"
        echo ""
        echo "  Run this command:"
        echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        echo ""
        exit 1
    fi
    echo -e "${GREEN}✓ Homebrew found${NC}"
}

# Check and install Colima (macOS)
check_colima() {
    echo -e "${BLUE}→ Checking Colima installation...${NC}"

    if ! command -v colima &> /dev/null; then
        echo -e "${YELLOW}⚠ Colima not found, installing...${NC}"
        brew install colima
        echo -e "${GREEN}✓ Colima installed${NC}"
    else
        echo -e "${GREEN}✓ Colima found: $(colima version | head -1)${NC}"
    fi

    # Also need lima for VM management
    if ! command -v limactl &> /dev/null; then
        echo -e "${YELLOW}⚠ Lima not found, installing...${NC}"
        brew install lima
        echo -e "${GREEN}✓ Lima installed${NC}"
    fi
}

# Check if cci Colima VM exists and is running
check_colima_vm() {
    if colima list 2>/dev/null | grep -q "^${COLIMA_VM_NAME}.*Running"; then
        echo -e "${GREEN}✓ Colima VM '${COLIMA_VM_NAME}' is running${NC}"
        return 0
    elif colima list 2>/dev/null | grep -q "^${COLIMA_VM_NAME}"; then
        echo -e "${YELLOW}⚠ Colima VM '${COLIMA_VM_NAME}' exists but is not running${NC}"
        return 1
    else
        echo -e "${YELLOW}⚠ Colima VM '${COLIMA_VM_NAME}' does not exist${NC}"
        return 2
    fi
}

# Create and configure Colima VM with Incus (macOS)
setup_colima_vm() {
    echo ""
    echo -e "${BLUE}→ Setting up Colima VM with Incus...${NC}"
    echo ""
    echo "  This will create a Linux VM with the following resources:"
    echo "    - CPUs: ${COLIMA_CPU}"
    echo "    - Memory: ${COLIMA_MEMORY} GB"
    echo "    - Disk: ${COLIMA_DISK} GB"
    echo ""
    echo "  You can customize these with environment variables:"
    echo "    COLIMA_CPU=4 COLIMA_MEMORY=8 COLIMA_DISK=60 ./install.sh"
    echo ""

    read -p "Continue with VM creation? [Y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}⚠ Skipping VM creation${NC}"
        echo "  You can create it later with: cci-colima-setup"
        return 1
    fi

    # Start Colima with Ubuntu and enough resources for Incus
    echo -e "${BLUE}→ Creating Colima VM '${COLIMA_VM_NAME}'...${NC}"

    colima start "${COLIMA_VM_NAME}" \
        --cpu "${COLIMA_CPU}" \
        --memory "${COLIMA_MEMORY}" \
        --disk "${COLIMA_DISK}" \
        --vm-type vz \
        --vz-rosetta \
        --mount-type virtiofs \
        --network-address

    echo -e "${GREEN}✓ Colima VM created${NC}"

    # Install Incus in the VM
    echo -e "${BLUE}→ Installing Incus in VM...${NC}"

    colima ssh "${COLIMA_VM_NAME}" -- bash -c '
        set -e

        # Update and install dependencies
        sudo apt-get update -qq
        sudo apt-get install -y -qq curl gpg

        # Add Incus repository (Zabbly)
        sudo mkdir -p /etc/apt/keyrings/
        sudo curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc

        cat <<EOF | sudo tee /etc/apt/sources.list.d/zabbly-incus-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo ${VERSION_CODENAME})
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF

        # Install Incus
        sudo apt-get update -qq
        sudo apt-get install -y -qq incus

        # Initialize Incus
        sudo incus admin init --auto

        # Add user to incus-admin group
        sudo usermod -aG incus-admin $USER

        echo "Incus installed successfully"
    '

    echo -e "${GREEN}✓ Incus installed in VM${NC}"

    # Configure socket forwarding
    setup_incus_socket_forward

    echo -e "${GREEN}✓ Colima VM setup complete${NC}"
}

# Set up Incus socket forwarding from VM to host (macOS)
setup_incus_socket_forward() {
    echo -e "${BLUE}→ Configuring Incus socket forwarding...${NC}"

    local socket_dir="$HOME/.cci"
    local socket_path="$socket_dir/incus.sock"

    mkdir -p "$socket_dir"

    # Get VM IP
    local vm_ip
    vm_ip=$(colima ssh "${COLIMA_VM_NAME}" -- hostname -I | awk '{print $1}')

    # Create wrapper script for cci to use
    cat > "$socket_dir/incus-proxy.sh" << EOF
#!/bin/bash
# Forward Incus commands to Colima VM
colima ssh ${COLIMA_VM_NAME} -- incus "\$@"
EOF
    chmod +x "$socket_dir/incus-proxy.sh"

    # Create environment setup script
    cat > "$socket_dir/env.sh" << EOF
# Source this file to use cci with Colima
# Usage: source ~/.cci/env.sh

export CCI_COLIMA_VM="${COLIMA_VM_NAME}"
export CCI_INCUS_REMOTE="colima"

# Alias incus to use Colima VM
alias incus='colima ssh ${COLIMA_VM_NAME} -- incus'

echo "CCI environment configured for Colima VM: ${COLIMA_VM_NAME}"
EOF

    echo -e "${GREEN}✓ Socket forwarding configured${NC}"
    echo ""
    echo "  To use cci, first source the environment:"
    echo "    ${BLUE}source ~/.cci/env.sh${NC}"
}

# Start Colima VM if not running (macOS)
start_colima_vm() {
    echo -e "${BLUE}→ Starting Colima VM '${COLIMA_VM_NAME}'...${NC}"
    colima start "${COLIMA_VM_NAME}"
    echo -e "${GREEN}✓ Colima VM started${NC}"
}

# Install cci-colima helper script (macOS)
install_colima_helper() {
    echo -e "${BLUE}→ Installing cci-colima helper...${NC}"

    local helper_script="${INSTALL_DIR}/cci-colima"

    local helper_content='#!/usr/bin/env bash
set -euo pipefail

COLIMA_VM_NAME="${CCI_COLIMA_VM:-cci}"

usage() {
    echo "cci-colima - Manage Colima VM for claude-code-isolated"
    echo ""
    echo "Usage: cci-colima <command>"
    echo ""
    echo "Commands:"
    echo "  start     Start the Colima VM"
    echo "  stop      Stop the Colima VM"
    echo "  restart   Restart the Colima VM"
    echo "  status    Show VM status"
    echo "  ssh       SSH into the VM"
    echo "  incus     Run incus command in VM"
    echo "  setup     Create/recreate the VM"
    echo ""
}

case "${1:-}" in
    start)
        colima start "$COLIMA_VM_NAME"
        ;;
    stop)
        colima stop "$COLIMA_VM_NAME"
        ;;
    restart)
        colima restart "$COLIMA_VM_NAME"
        ;;
    status)
        colima status "$COLIMA_VM_NAME"
        ;;
    ssh)
        shift
        colima ssh "$COLIMA_VM_NAME" -- "${@:-bash}"
        ;;
    incus)
        shift
        colima ssh "$COLIMA_VM_NAME" -- incus "$@"
        ;;
    setup)
        echo "Re-running setup..."
        curl -fsSL "https://raw.githubusercontent.com/'"${REPO}"'/master/install.sh" | bash
        ;;
    *)
        usage
        ;;
esac
'

    if [ -w "$INSTALL_DIR" ]; then
        echo "$helper_content" > "$helper_script"
        chmod +x "$helper_script"
    else
        echo "$helper_content" | sudo tee "$helper_script" > /dev/null
        sudo chmod +x "$helper_script"
    fi

    echo -e "${GREEN}✓ cci-colima helper installed${NC}"
}

# ============================================================================
# Common functions
# ============================================================================

# Download binary from GitHub releases
download_binary() {
    local download_url
    local tmp_dir
    local binary_path
    local download_os

    echo -e "${BLUE}→ Downloading claude-code-isolated...${NC}"

    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" EXIT

    # For macOS, we still download the linux binary (runs in Colima VM)
    # But we also need a macOS wrapper
    if [ "$PLATFORM" = "macos" ]; then
        download_os="linux"
    else
        download_os="$OS"
    fi

    if [ "$VERSION" = "latest" ]; then
        download_url="https://github.com/${REPO}/releases/latest/download/cci-${download_os}-${ARCH}"
    else
        download_url="https://github.com/${REPO}/releases/download/${VERSION}/cci-${download_os}-${ARCH}"
    fi

    binary_path="${tmp_dir}/${BINARY_NAME}"

    if command -v curl &> /dev/null; then
        curl -fsSL "$download_url" -o "$binary_path"
    elif command -v wget &> /dev/null; then
        wget -q -O "$binary_path" "$download_url"
    else
        echo -e "${RED}✗ Neither curl nor wget found${NC}"
        exit 1
    fi

    chmod +x "$binary_path"

    echo -e "${BLUE}→ Installing to ${INSTALL_DIR}...${NC}"

    if [ "$PLATFORM" = "macos" ]; then
        # On macOS, install binary to VM and create wrapper
        install_binary_macos "$binary_path"
    else
        # On Linux, install directly
        if [ -w "$INSTALL_DIR" ]; then
            cp "$binary_path" "${INSTALL_DIR}/${BINARY_NAME}"
            ln -sf "${INSTALL_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/claude-code-isolated"
        else
            sudo cp "$binary_path" "${INSTALL_DIR}/${BINARY_NAME}"
            sudo ln -sf "${INSTALL_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/claude-code-isolated"
        fi
    fi

    echo -e "${GREEN}✓ Installed to ${INSTALL_DIR}/${BINARY_NAME}${NC}"
}

# Install binary on macOS (copies to VM and creates wrapper)
install_binary_macos() {
    local binary_path="$1"

    # Copy binary to VM
    echo -e "${BLUE}→ Copying binary to Colima VM...${NC}"
    colima ssh "${COLIMA_VM_NAME}" -- mkdir -p /home/$USER/.local/bin

    # Use cat to transfer the binary
    cat "$binary_path" | colima ssh "${COLIMA_VM_NAME}" -- "cat > /home/\$USER/.local/bin/cci && chmod +x /home/\$USER/.local/bin/cci"

    # Create symlink in VM
    colima ssh "${COLIMA_VM_NAME}" -- "sudo ln -sf /home/\$USER/.local/bin/cci /usr/local/bin/cci"
    colima ssh "${COLIMA_VM_NAME}" -- "sudo ln -sf /home/\$USER/.local/bin/cci /usr/local/bin/claude-code-isolated"

    # Create wrapper script on macOS host
    echo -e "${BLUE}→ Creating macOS wrapper script...${NC}"

    local wrapper_content='#!/usr/bin/env bash
# cci wrapper for macOS - executes in Colima VM
COLIMA_VM_NAME="${CCI_COLIMA_VM:-cci}"

# Check if VM is running
if ! colima list 2>/dev/null | grep -q "^${COLIMA_VM_NAME}.*Running"; then
    echo "Error: Colima VM '\''${COLIMA_VM_NAME}'\'' is not running"
    echo "Start it with: cci-colima start"
    exit 1
fi

# Get current working directory relative to home
CWD="$(pwd)"
HOME_DIR="$HOME"

# Map macOS path to VM path
if [[ "$CWD" == "$HOME_DIR"* ]]; then
    VM_CWD="/home/$USER${CWD#$HOME_DIR}"
else
    VM_CWD="$CWD"
fi

# Execute cci in VM with proper working directory
exec colima ssh "$COLIMA_VM_NAME" -- "cd \"$VM_CWD\" 2>/dev/null || cd ~; cci $*"
'

    if [ -w "$INSTALL_DIR" ]; then
        echo "$wrapper_content" > "${INSTALL_DIR}/${BINARY_NAME}"
        chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
        ln -sf "${INSTALL_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/claude-code-isolated"
    else
        echo "$wrapper_content" | sudo tee "${INSTALL_DIR}/${BINARY_NAME}" > /dev/null
        sudo chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
        sudo ln -sf "${INSTALL_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/claude-code-isolated"
    fi
}

# Build from source
build_from_source() {
    local tmp_dir

    echo -e "${BLUE}→ Building from source...${NC}"

    if ! command -v go &> /dev/null; then
        echo -e "${RED}✗ Go not found${NC}"
        echo "  Install Go: https://go.dev/doc/install"
        exit 1
    fi

    echo -e "${BLUE}→ Go version: $(go version)${NC}"

    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" EXIT

    echo -e "${BLUE}→ Cloning repository...${NC}"
    git clone --depth 1 "https://github.com/${REPO}.git" "$tmp_dir"

    cd "$tmp_dir"
    echo -e "${BLUE}→ Building binary...${NC}"

    if [ "$PLATFORM" = "macos" ]; then
        # Cross-compile for Linux (runs in Colima VM)
        GOOS=linux GOARCH="${ARCH}" make build
        install_binary_macos "./cci"
    else
        make build
        echo -e "${BLUE}→ Installing to ${INSTALL_DIR}...${NC}"
        if [ -w "$INSTALL_DIR" ]; then
            make install
        else
            sudo make install
        fi
    fi

    echo -e "${GREEN}✓ Built and installed${NC}"
}

# Post-install setup (Linux)
post_install_linux() {
    setup_zfs_storage

    echo ""
    echo -e "${GREEN}✓ Installation complete!${NC}"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Build the CCI image:"
    echo "     ${BLUE}cci build${NC}"
    echo ""
    echo "  2. Start your first session:"
    echo "     ${BLUE}cci shell${NC}"
    echo ""
    echo "  3. View available commands:"
    echo "     ${BLUE}cci --help${NC}"
    echo ""

    if ! groups | grep -q incus-admin; then
        echo -e "${YELLOW}⚠ Remember to add yourself to incus-admin group:${NC}"
        echo "   ${BLUE}sudo usermod -aG incus-admin \$USER${NC}"
        echo "   Then log out and back in."
        echo ""
    fi

    echo "Documentation: https://github.com/${REPO}"
    echo ""
}

# Post-install setup (macOS)
post_install_macos() {
    echo ""
    echo -e "${GREEN}✓ Installation complete!${NC}"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Make sure the Colima VM is running:"
    echo "     ${BLUE}cci-colima status${NC}"
    echo ""
    echo "  2. Build the CCI image (in VM):"
    echo "     ${BLUE}cci build${NC}"
    echo ""
    echo "  3. Start your first session:"
    echo "     ${BLUE}cci shell${NC}"
    echo ""
    echo "  4. View available commands:"
    echo "     ${BLUE}cci --help${NC}"
    echo ""
    echo "Useful Colima commands:"
    echo "  ${BLUE}cci-colima start${NC}   - Start the VM"
    echo "  ${BLUE}cci-colima stop${NC}    - Stop the VM"
    echo "  ${BLUE}cci-colima ssh${NC}     - SSH into the VM"
    echo "  ${BLUE}cci-colima incus${NC}   - Run incus commands"
    echo ""
    echo "Documentation: https://github.com/${REPO}"
    echo ""
}

# Main installation for Linux
install_linux() {
    check_incus_linux
    check_group_linux

    echo ""
    echo "Installation method:"
    echo "  1. Download pre-built binary (fastest)"
    echo "  2. Build from source"
    echo ""

    if curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" &> /dev/null; then
        read -p "Choose [1/2] (default: 1): " -n 1 -r
        echo ""

        case $REPLY in
            2)
                build_from_source
                ;;
            *)
                download_binary
                ;;
        esac
    else
        echo -e "${YELLOW}⚠ No pre-built binaries available, building from source...${NC}"
        build_from_source
    fi

    post_install_linux
}

# Main installation for macOS
install_macos() {
    echo ""
    echo -e "${BLUE}macOS Installation${NC}"
    echo ""
    echo "  claude-code-isolated uses Incus containers which require Linux."
    echo "  On macOS, we use Colima to run a Linux VM with Incus installed."
    echo ""

    check_homebrew
    check_colima

    # Check VM status
    local vm_status
    if check_colima_vm; then
        vm_status=0
    else
        vm_status=$?
    fi

    case $vm_status in
        0)
            # VM running, continue with binary install
            echo ""
            ;;
        1)
            # VM exists but not running
            read -p "Start the VM? [Y/n] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                start_colima_vm
            fi
            ;;
        2)
            # VM doesn't exist
            setup_colima_vm
            ;;
    esac

    # Install helper script
    install_colima_helper

    # Install binary
    echo ""
    echo "Installation method:"
    echo "  1. Download pre-built binary (fastest)"
    echo "  2. Build from source"
    echo ""

    if curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" &> /dev/null; then
        read -p "Choose [1/2] (default: 1): " -n 1 -r
        echo ""

        case $REPLY in
            2)
                build_from_source
                ;;
            *)
                download_binary
                ;;
        esac
    else
        echo -e "${YELLOW}⚠ No pre-built binaries available, building from source...${NC}"
        build_from_source
    fi

    post_install_macos
}

# Main installation
main() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}  claude-code-isolated (cci) installer${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo ""

    detect_platform

    case "$PLATFORM" in
        linux)
            install_linux
            ;;
        macos)
            install_macos
            ;;
        *)
            echo -e "${RED}✗ Unsupported platform: $PLATFORM${NC}"
            exit 1
            ;;
    esac
}

# Handle errors
error_handler() {
    echo ""
    echo -e "${RED}✗ Installation failed${NC}"
    echo ""
    echo "If you need help:"
    echo "  - Check the documentation: https://github.com/${REPO}"
    echo "  - File an issue: https://github.com/${REPO}/issues"
    exit 1
}

trap error_handler ERR

# Run main
main "$@"
