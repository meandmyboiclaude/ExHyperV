#!/bin/bash
# @Name: Fedora-44-Official
# @Description: GPU-PV deployment script for Fedora 44 (also works on Fedora 41+)
# @Author: ExHyperV Community
# @Version: 1.0.0

set -e

# ==========================================================
# 0. Helper Functions
# ==========================================================
# Update /etc/environment variable (idempotent)
update_env() {
    local key=$1
    local val=$2
    sudo sed -i "/^$key=/d" /etc/environment
    sudo sed -i "/^export $key=/d" /etc/environment
    echo "$key=$val" | sudo tee -a /etc/environment > /dev/null
}

# Retry mechanism
retry_cmd() {
    local n=1
    local max=5
    local delay=5
    while true; do
        if "$@"; then
            break
        else
            if [[ $n -lt $max ]]; then
                echo " -> [WARNING] Command failed, retrying in $delay seconds (attempt $n of $max): $*"
                sleep $delay
                ((n++))
            else
                echo " -> [ERROR] Max retries reached ($max), command failed: $*"
                return 1
            fi
        fi
    done
}

# ==========================================================
# 1. Initialization & Parameter Parsing
# ==========================================================
ACTION=${1:-"deploy"}
ENABLE_GRAPHICS=${2:-"true"}
PROXY_URL=${3:-""}

# --- Architecture detection ---
MACHINE_ARCH=$(uname -m)
case "$MACHINE_ARCH" in
    x86_64)
        ARCH_DIR="x64"
        ;;
    aarch64|arm64)
        ARCH_DIR="arm64"
        ;;
    *)
        echo "[ERROR] Unsupported architecture: $MACHINE_ARCH"
        exit 1
        ;;
esac
echo "[+] Detected architecture: $MACHINE_ARCH (Using repo dir: $ARCH_DIR)"

DEPLOY_DIR="$(dirname $(realpath $0))"
LIB_DIR="$DEPLOY_DIR/lib"
# Remote repository base URLs for patches and libraries
PATCH_BASE_URL="https://raw.githubusercontent.com/Justsenger/ExHyperV/main/src/Linux/script/patches"
GITHUB_LIB_URL="https://raw.githubusercontent.com/Justsenger/ExHyperV/main/src/Linux/lib/$ARCH_DIR"

if [ -n "$PROXY_URL" ]; then
    export http_proxy="$PROXY_URL"
    export https_proxy="$PROXY_URL"
    echo "[+] Using proxy: $PROXY_URL"
fi

# ==========================================================
# Uninstall Support
# ==========================================================
if [ "$ACTION" == "uninstall" ]; then
    echo "[STEP: Uninstalling GPU-PV components...]"

    # Stop and disable the late-load service
    sudo systemctl stop load-dxg-late.service 2>/dev/null || true
    sudo systemctl disable load-dxg-late.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/load-dxg-late.service
    sudo rm -f /usr/local/bin/load_dxg_driver.sh
    sudo systemctl daemon-reload

    # Unload module
    sudo modprobe -r dxgkrnl 2>/dev/null || true

    # Remove DKMS module
    if dkms status | grep -q "dxgkrnl"; then
        DKMS_VER=$(dkms status | grep dxgkrnl | head -1 | awk -F'[,/ ]' '{print $2}' | xargs)
        sudo dkms remove dxgkrnl/"$DKMS_VER" --all 2>/dev/null || true
        sudo rm -rf /usr/src/dxgkrnl-"$DKMS_VER"
    fi

    # Remove blacklist and module load configs
    sudo rm -f /etc/modprobe.d/blacklist-dxgkrnl.conf
    sudo rm -f /etc/modules-load.d/vgem.conf

    # Remove WSL libraries
    sudo rm -rf /usr/lib/wsl
    sudo rm -f /etc/ld.so.conf.d/ld.wsl.conf
    sudo ldconfig

    # Remove MOK key (user must manually delete from firmware)
    if [ -f /var/lib/dxgkrnl-mok/MOK.der ]; then
        echo " -> MOK key found at /var/lib/dxgkrnl-mok/. To fully remove Secure Boot enrollment,"
        echo "    run: sudo mokutil --delete /var/lib/dxgkrnl-mok/MOK.der"
        echo "    then reboot and confirm deletion in the MOK Manager."
    fi

    # Clean environment variables
    sudo sed -i '/^GALLIUM_DRIVERS=/d' /etc/environment
    sudo sed -i '/^DRI_PRIME=/d' /etc/environment
    sudo sed -i '/^LIBVA_DRIVER_NAME=/d' /etc/environment
    sudo sed -i '/^VK_ICD_FILENAMES=/d' /etc/environment

    # Rebuild initramfs
    echo " -> Rebuilding initramfs..."
    sudo dracut --force

    echo "[STATUS: SUCCESS]"
    echo " -> GPU-PV components have been uninstalled. A reboot is recommended."
    exit 0
fi

# ==========================================================
# 2. Dependencies
# Fedora uses dnf. Packages: gcc gcc-c++ make instead of build-essential.
# kernel-devel instead of linux-headers. openssl + mokutil for Secure Boot.
# elfutils-devel provides libelf needed by some kernel module builds.
# ==========================================================
echo "[STEP: Installing basic dependencies...]"
sudo dnf install -y git curl dkms wget gcc gcc-c++ make kernel-devel \
    unzip aria2 openssl mokutil elfutils-devel

# ==========================================================
# 3. Kernel Header Check
# Fedora: kernel-devel-$(uname -r)
# CachyOS kernels from COPR: kernel-cachyos-devel-$(uname -r)
# ==========================================================
echo "[STEP: Checking Kernel Headers...]"
TARGET_KERNEL_VERSION=$(uname -r)

if [ ! -e "/lib/modules/$TARGET_KERNEL_VERSION/build" ]; then
    echo " -> Kernel headers not found for $TARGET_KERNEL_VERSION. Attempting installation..."

    HEADERS_INSTALLED=false

    # Try CachyOS kernel headers first if running a CachyOS kernel
    if echo "$TARGET_KERNEL_VERSION" | grep -qi "cachyos"; then
        echo " -> Detected CachyOS kernel, trying kernel-cachyos-devel..."
        if sudo dnf install -y "kernel-cachyos-devel-$TARGET_KERNEL_VERSION" 2>/dev/null; then
            HEADERS_INSTALLED=true
        else
            echo " -> kernel-cachyos-devel not found, trying kernel-cachyos-devel (unversioned)..."
            if sudo dnf install -y kernel-cachyos-devel 2>/dev/null; then
                HEADERS_INSTALLED=true
            fi
        fi
    fi

    # Try standard Fedora kernel-devel
    if [ "$HEADERS_INSTALLED" = false ]; then
        if sudo dnf install -y "kernel-devel-$TARGET_KERNEL_VERSION" 2>/dev/null; then
            HEADERS_INSTALLED=true
        else
            echo " -> Exact version not available. Installing latest kernel-devel..."
            if sudo dnf install -y kernel-devel; then
                HEADERS_INSTALLED=true
                # Check if we now have headers for current kernel
                if [ ! -e "/lib/modules/$TARGET_KERNEL_VERSION/build" ]; then
                    echo " -> [WARNING] Installed kernel-devel does not match running kernel $TARGET_KERNEL_VERSION."
                    echo " -> You may need to reboot into the matching kernel."
                    echo "[STATUS: REBOOT_REQUIRED]"
                    exit 0
                fi
            fi
        fi
    fi

    if [ "$HEADERS_INSTALLED" = false ]; then
        echo " -> [ERROR] Could not install kernel headers for $TARGET_KERNEL_VERSION"
        exit 1
    fi
fi

# Final check
if [ ! -e "/lib/modules/$TARGET_KERNEL_VERSION/build" ]; then
    echo " -> [ERROR] Kernel headers still not found at /lib/modules/$TARGET_KERNEL_VERSION/build"
    echo " -> Please install the correct kernel-devel package for your kernel."
    exit 1
fi
echo " -> Kernel headers found for $TARGET_KERNEL_VERSION"

# ==========================================================
# 4. dxgkrnl Module Compilation & Verification (Core Logic)
# This section is distro-agnostic (same DKMS flow as Ubuntu).
# Downloads lightweight pre-extracted source, rebuilds kernel tree
# structure, applies patches, builds via DKMS.
# ==========================================================
if lsmod | grep -q "dxgkrnl" || dkms status | grep -q "dxgkrnl"; then
    echo " -> dxgkrnl is already installed or loaded."
else
    echo "[STEP: Preparing Source & Patching...]"
    # Determine kernel major version to select branch (5.15 or 6.6)
    KERNEL_MAJOR=$(echo $TARGET_KERNEL_VERSION | cut -d. -f1)
    KERNEL_MINOR=$(echo $TARGET_KERNEL_VERSION | cut -d. -f2)

    if [[ "$KERNEL_MAJOR" -eq 6 && "$KERNEL_MINOR" -ge 6 ]] || [[ "$KERNEL_MAJOR" -gt 6 ]]; then
        TARGET_BRANCH="linux-msft-wsl-6.6.y"
    else
        TARGET_BRANCH="linux-msft-wsl-5.15.y"
    fi

    # Clean old workspace
    rm -rf /tmp/dxg-src /tmp/kernel_src.tar.gz /tmp/extract-tmp

    # Download lightweight kernel source
    PKG="dxgkrnl-${TARGET_BRANCH#linux-msft-wsl-}"
    PKG="${PKG%.y}-patched"
    echo " -> Downloading Lightweight Kernel Source using Aria2..."
    ZIP_URL="https://raw.githubusercontent.com/Justsenger/ExHyperV/kernel-assets/$PKG.tar.gz"

    retry_cmd aria2c -x 4 -s 4 --dir=/tmp --out=kernel_src.tar.gz "$ZIP_URL" --allow-overwrite

    # Rebuild directory structure for patch -p1 compatibility
    echo " -> Recreating Kernel Tree Structure..."
    mkdir -p /tmp/extract-tmp
    tar -xzf /tmp/kernel_src.tar.gz -C /tmp/extract-tmp --strip-components=1

    mkdir -p /tmp/dxg-src/drivers/hv/dxgkrnl
    mv /tmp/extract-tmp/include /tmp/dxg-src/include
    cp -r /tmp/extract-tmp/* /tmp/dxg-src/drivers/hv/dxgkrnl/

    cd /tmp/dxg-src
    VERSION="custom"

    # Patch application function
    apply_patch() {
        local patch_url=$1
        local patch_file=$(basename "$patch_url")
        retry_cmd curl -fsSL --retry 3 "$patch_url" -o "$patch_file"
        patch -p1 < "$patch_file"
    }

    echo "[STEP: Patching Kernel Source...]"
    apply_patch "$PATCH_BASE_URL/linux-msft-wsl-5.15.y/0001-Add-a-gpu-pv-support.patch"

    if [ "$TARGET_BRANCH" == "linux-msft-wsl-5.15.y" ]; then
        apply_patch "$PATCH_BASE_URL/linux-msft-wsl-5.15.y/0002-Add-a-multiple-kernel-version-support.patch"
        apply_patch "$PATCH_BASE_URL/linux-msft-wsl-5.15.y/0003-Fix-gpadl-has-incomplete-type-error.patch"
    else
        # 6.6 branch fix
        retry_cmd curl -fsSL --retry 3 "$PATCH_BASE_URL/linux-msft-wsl-6.6.y/0002-Fix-eventfd_signal.patch" -o patch_6.6.patch
        patch -p1 --ignore-whitespace < patch_6.6.patch
    fi

    echo "[STEP: Compiling and Installing DXG Module...]"
    # Copy patched source to /usr/src for DKMS
    sudo cp -r ./drivers/hv/dxgkrnl /usr/src/dxgkrnl-$VERSION
    sudo cp -r ./include /usr/src/dxgkrnl-$VERSION/include
    DXGMODULE_FILE="/usr/src/dxgkrnl-$VERSION/dxgmodule.c"

    # Auto-fix for kernel 6.8+ eventfd API change
    if grep -q "eventfd_signal.*struct eventfd_ctx.*__u64" /lib/modules/$TARGET_KERNEL_VERSION/build/include/linux/eventfd.h 2>/dev/null; then
        sed -i 's/eventfd_signal(event->cpu_event);/eventfd_signal(event->cpu_event, 1);/g' "$DXGMODULE_FILE"
    fi

    # Configure standalone Makefile
    echo "Configuring Makefile..."
    sudo sed -i 's/\$(CONFIG_DXGKRNL)/m/' /usr/src/dxgkrnl-$VERSION/Makefile
    echo "EXTRA_CFLAGS=-I\$(PWD)/include -D_MAIN_KERNEL_" | sudo tee -a /usr/src/dxgkrnl-$VERSION/Makefile

    # Generate DKMS configuration
    sudo tee /usr/src/dxgkrnl-$VERSION/dkms.conf > /dev/null <<EOF
PACKAGE_NAME="dxgkrnl"
PACKAGE_VERSION="$VERSION"
BUILT_MODULE_NAME="dxgkrnl"
DEST_MODULE_LOCATION="/kernel/drivers/hv/dxgkrnl/"
AUTOINSTALL="yes"
EOF

    # DKMS build flow
    sudo dkms add dxgkrnl/$VERSION
    sudo dkms build dxgkrnl/$VERSION
    sudo dkms install dxgkrnl/$VERSION --force
fi

# ==========================================================
# 4b. Secure Boot / MOK Signing
# Fedora enforces Secure Boot strictly. If enabled, the dxgkrnl
# module must be signed with a Machine Owner Key (MOK) enrolled
# in the firmware, or modprobe will refuse to load it.
# ==========================================================
echo "[STEP: Checking Secure Boot status...]"
SB_ENABLED=false
if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
    SB_ENABLED=true
    echo " -> Secure Boot is ENABLED. Module signing is required."
fi

if [ "$SB_ENABLED" = true ]; then
    MOK_DIR="/var/lib/dxgkrnl-mok"
    MOK_PRIV="$MOK_DIR/MOK.priv"
    MOK_DER="$MOK_DIR/MOK.der"

    if [ ! -f "$MOK_PRIV" ] || [ ! -f "$MOK_DER" ]; then
        echo "[STEP: Generating MOK key pair for module signing...]"
        sudo mkdir -p "$MOK_DIR"
        sudo openssl req -new -x509 -newkey rsa:2048 -keyout "$MOK_PRIV" \
            -outform DER -out "$MOK_DER" -nodes -days 36500 \
            -subj "/CN=dxgkrnl-module-signing-key/" 2>/dev/null
        sudo chmod 600 "$MOK_PRIV"
        sudo chmod 644 "$MOK_DER"
        echo " -> MOK key pair generated at $MOK_DIR"
    else
        echo " -> MOK key pair already exists at $MOK_DIR"
    fi

    # Find the compiled module to sign
    DXGKRNL_KO=$(find /lib/modules/$TARGET_KERNEL_VERSION -name "dxgkrnl.ko*" 2>/dev/null | head -1)
    if [ -n "$DXGKRNL_KO" ]; then
        # Handle compressed modules (.ko.xz, .ko.zst, .ko.gz)
        DXGKRNL_KO_PLAIN="$DXGKRNL_KO"
        COMPRESSED=false
        case "$DXGKRNL_KO" in
            *.xz)
                sudo xz -d "$DXGKRNL_KO"
                DXGKRNL_KO_PLAIN="${DXGKRNL_KO%.xz}"
                COMPRESSED=true
                ;;
            *.zst)
                sudo zstd -d --rm "$DXGKRNL_KO"
                DXGKRNL_KO_PLAIN="${DXGKRNL_KO%.zst}"
                COMPRESSED=true
                ;;
            *.gz)
                sudo gzip -d "$DXGKRNL_KO"
                DXGKRNL_KO_PLAIN="${DXGKRNL_KO%.gz}"
                COMPRESSED=true
                ;;
        esac

        echo " -> Signing dxgkrnl module: $DXGKRNL_KO_PLAIN"
        SIGN_FILE="/lib/modules/$TARGET_KERNEL_VERSION/build/scripts/sign-file"
        if [ -x "$SIGN_FILE" ]; then
            sudo "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$DXGKRNL_KO_PLAIN"
            echo " -> Module signed successfully."
        else
            # Fallback: use kmodsign if available
            if command -v kmodsign &>/dev/null; then
                sudo kmodsign sha256 "$MOK_PRIV" "$MOK_DER" "$DXGKRNL_KO_PLAIN"
                echo " -> Module signed successfully (via kmodsign)."
            else
                echo " -> [WARNING] Could not find sign-file or kmodsign. Module may not load with Secure Boot."
            fi
        fi

        # Re-compress if it was compressed
        if [ "$COMPRESSED" = true ]; then
            case "$DXGKRNL_KO" in
                *.xz)  sudo xz "$DXGKRNL_KO_PLAIN" ;;
                *.zst) sudo zstd --rm "$DXGKRNL_KO_PLAIN" ;;
                *.gz)  sudo gzip "$DXGKRNL_KO_PLAIN" ;;
            esac
        fi
    else
        echo " -> [WARNING] dxgkrnl.ko not found in /lib/modules/$TARGET_KERNEL_VERSION"
    fi

    # Check if MOK is already enrolled
    if ! mokutil --test-key "$MOK_DER" 2>/dev/null | grep -qi "already enrolled"; then
        echo ""
        echo " ========================================================"
        echo " IMPORTANT: MOK key must be enrolled in firmware."
        echo " Run the following command, set a one-time password,"
        echo " then REBOOT and select 'Enroll MOK' in the blue screen:"
        echo ""
        echo "   sudo mokutil --import $MOK_DER"
        echo ""
        echo " After enrollment, re-run this script or manually load:"
        echo "   sudo modprobe dxgkrnl"
        echo " ========================================================"
        echo ""
        # Attempt automatic import (will prompt for password)
        sudo mokutil --import "$MOK_DER" || true
    else
        echo " -> MOK key is already enrolled."
    fi
fi

echo "[STEP: Testing module load...]"
if ! sudo modprobe dxgkrnl; then
    if [ "$SB_ENABLED" = true ]; then
        echo " -> [WARNING] dxgkrnl could not be loaded. This is likely because the MOK key"
        echo "    has not yet been enrolled. Reboot to complete MOK enrollment, then the module"
        echo "    will load automatically via the load-dxg-late service."
    else
        echo " -> [WARNING] dxgkrnl could not be loaded. Check dmesg for details."
    fi
fi

# ==========================================================
# 5. Graphics Stack Configuration
# Fedora 41+ ships modern Mesa in the base repos (Mesa 25.x).
# No PPA needed. Just install the relevant driver packages.
# ==========================================================
if [ "$ENABLE_GRAPHICS" == "true" ]; then
    echo "[STEP: Configuring Graphics Stack...]"
    sudo dnf install -y \
        mesa-dri-drivers \
        mesa-vulkan-drivers \
        mesa-va-drivers \
        vulkan-loader \
        vulkan-tools \
        mesa-libGL \
        mesa-libEGL
fi

# ==========================================================
# 6. System Configuration & WSL Library Deployment
# Deploy D3D12/DXCore userspace libraries to the WSL standard
# path so that 3D applications can load them.
# ==========================================================
echo "[STEP: Deploying WSL Core Libraries...]"
LIBS=("libd3d12.so" "libd3d12core.so" "libdxcore.so")
mkdir -p "$LIB_DIR"
for lib in "${LIBS[@]}"; do
    if [ ! -f "$LIB_DIR/$lib" ]; then
        echo " -> $lib not found locally, downloading for $ARCH_DIR..."
        if ! retry_cmd aria2c -x 4 -s 4 --dir="$LIB_DIR" --out="$lib" "$GITHUB_LIB_URL/$lib" --allow-overwrite; then
            echo " -> [ERROR] Failed to download $lib from $GITHUB_LIB_URL/$lib"
            exit 1
        fi
    fi
done

if [ -f "$LIB_DIR/nvidia-smi" ]; then
    echo "[+] Found nvidia-smi uploaded from host, deploying to /usr/bin..."
    sudo cp "$LIB_DIR/nvidia-smi" /usr/bin/nvidia-smi
    sudo chmod 755 /usr/bin/nvidia-smi
fi

sudo mkdir -p /usr/lib/wsl/drivers /usr/lib/wsl/lib
sudo rm -rf /usr/lib/wsl/drivers/* /usr/lib/wsl/lib/*
if [ -d "$DEPLOY_DIR/drivers" ]; then
    sudo cp -r "$DEPLOY_DIR/drivers"/* /usr/lib/wsl/drivers/
fi
sudo cp -a "$LIB_DIR"/*.so* /usr/lib/wsl/lib/
# Capital-D symlink: some Mesa code paths look for libD3D12Core.so
sudo ln -sf /usr/lib/wsl/lib/libd3d12core.so /usr/lib/wsl/lib/libD3D12Core.so
sudo chmod -R 0555 /usr/lib/wsl
sudo chown -R root:root /usr/lib/wsl
echo "/usr/lib/wsl/lib" | sudo tee /etc/ld.so.conf.d/ld.wsl.conf > /dev/null
sudo ldconfig

# ==========================================================
# 6b. SELinux Context for WSL Libraries
# Fedora runs SELinux in enforcing mode by default. Without
# correct labels, libraries under /usr/lib/wsl/ will be
# blocked from loading.
# ==========================================================
echo "[STEP: Setting SELinux contexts for WSL libraries...]"
if command -v semanage &>/dev/null; then
    # Set the file context to lib_t for shared libraries
    sudo semanage fcontext -a -t lib_t "/usr/lib/wsl/lib(/.*)?" 2>/dev/null || \
        sudo semanage fcontext -m -t lib_t "/usr/lib/wsl/lib(/.*)?" 2>/dev/null || true
    sudo semanage fcontext -a -t lib_t "/usr/lib/wsl/drivers(/.*)?" 2>/dev/null || \
        sudo semanage fcontext -m -t lib_t "/usr/lib/wsl/drivers(/.*)?" 2>/dev/null || true
else
    echo " -> [NOTE] semanage not found. Installing policycoreutils-python-utils..."
    sudo dnf install -y policycoreutils-python-utils || true
    if command -v semanage &>/dev/null; then
        sudo semanage fcontext -a -t lib_t "/usr/lib/wsl/lib(/.*)?" 2>/dev/null || \
            sudo semanage fcontext -m -t lib_t "/usr/lib/wsl/lib(/.*)?" 2>/dev/null || true
        sudo semanage fcontext -a -t lib_t "/usr/lib/wsl/drivers(/.*)?" 2>/dev/null || \
            sudo semanage fcontext -m -t lib_t "/usr/lib/wsl/drivers(/.*)?" 2>/dev/null || true
    fi
fi
sudo restorecon -Rv /usr/lib/wsl/ || true

# ==========================================================
# 7. Kernel Module Late-Load Strategy
# ==========================================================
echo "[STEP: Configuring Kernel Modules Strategy (vgem & dxgkrnl)...]"

# 1. Configure vgem auto-load
echo "vgem" | sudo tee /etc/modules-load.d/vgem.conf > /dev/null
sudo modprobe vgem || true

# 2. Blacklist dxgkrnl to prevent boot-time conflicts
echo "blacklist dxgkrnl" | sudo tee /etc/modprobe.d/blacklist-dxgkrnl.conf > /dev/null

# 3. Rebuild initramfs with dracut (Fedora equivalent of update-initramfs)
echo " -> Rebuilding initramfs with dracut..."
sudo dracut --force

# 4. Create late-load script
echo " -> Creating late-load script..."
sudo tee /usr/local/bin/load_dxg_driver.sh > /dev/null << 'EOF'
#!/bin/bash
modprobe dxgkrnl
if [ -e /dev/dxg ]; then
    chmod 666 /dev/dxg
fi
EOF
sudo chmod +x /usr/local/bin/load_dxg_driver.sh

sudo systemctl stop load-dxg-late.service 2>/dev/null || true
sudo systemctl disable load-dxg-late.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/load-dxg-late.service

sudo tee /etc/systemd/system/load-dxg-late.service > /dev/null << 'EOF'
[Unit]
Description=Late load dxgkrnl
After=graphical.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/load_dxg_driver.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

sudo systemctl daemon-reload
sudo systemctl unmask load-dxg-late.service
sudo systemctl enable load-dxg-late.service
sudo systemctl start load-dxg-late.service

# ==========================================================
# 8. Environment Variables & Permissions
# ==========================================================
if [ "$ENABLE_GRAPHICS" == "true" ]; then
    echo "[STEP: Finalizing environment variables...]"
    # Gallium D3D12 backend configuration
    update_env "GALLIUM_DRIVERS" "d3d12"
    update_env "DRI_PRIME" "1"
    update_env "LIBVA_DRIVER_NAME" "d3d12"
    # Vulkan ICD for dozen (D3D12-based Vulkan)
    update_env "VK_ICD_FILENAMES" "/usr/share/vulkan/icd.d/dzn_icd.x86_64.json"

    if ! grep -q "GALLIUM_DRIVERS=d3d12" ~/.bashrc; then
        cat >> ~/.bashrc <<EOF
# GPU-PV Configuration
export GALLIUM_DRIVERS=d3d12
export DRI_PRIME=1
export LIBVA_DRIVER_NAME=d3d12
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/dzn_icd.x86_64.json
EOF
    fi

    # Grant current user render permissions
    sudo usermod -a -G video,render $USER

    # Hyper-V virtual GPU is usually card1, but many programs expect card0
    echo " -> Fix permissions and symlinks for /dev/dri..."
    sudo chmod 666 /dev/dri/* || true
    if [ -e /dev/dri/card1 ]; then
        sudo ln -sf /dev/dri/card1 /dev/dri/card0
    fi
fi

# ==========================================================
# 9. Verification
# ==========================================================
echo "[STEP: Verifying deployment...]"
echo ""
VERIFY_PASS=true

# Check /dev/dxg
if [ -e /dev/dxg ]; then
    echo " [OK] /dev/dxg exists"
else
    echo " [--] /dev/dxg not found (may appear after reboot/MOK enrollment)"
    VERIFY_PASS=false
fi

# Check module loaded
if lsmod | grep -q dxgkrnl; then
    echo " [OK] dxgkrnl module is loaded"
else
    echo " [--] dxgkrnl module is not loaded (may load after reboot/MOK enrollment)"
    VERIFY_PASS=false
fi

# Check DKMS status
if dkms status | grep -q dxgkrnl; then
    echo " [OK] dxgkrnl registered in DKMS"
else
    echo " [--] dxgkrnl not found in DKMS"
    VERIFY_PASS=false
fi

# Check systemd service
if systemctl is-enabled load-dxg-late.service &>/dev/null; then
    echo " [OK] load-dxg-late.service is enabled"
else
    echo " [--] load-dxg-late.service is not enabled"
    VERIFY_PASS=false
fi

# Check WSL libraries
if [ -f /usr/lib/wsl/lib/libd3d12.so ]; then
    echo " [OK] WSL libraries deployed to /usr/lib/wsl/lib/"
else
    echo " [--] WSL libraries not found"
    VERIFY_PASS=false
fi

# Check SELinux context
if command -v ls &>/dev/null && ls -Z /usr/lib/wsl/lib/ 2>/dev/null | grep -q "lib_t"; then
    echo " [OK] SELinux context set correctly (lib_t)"
else
    echo " [--] SELinux context may not be set correctly"
fi

echo ""
if [ "$VERIFY_PASS" = false ] && [ "$SB_ENABLED" = true ]; then
    echo " -> Some checks did not pass. If Secure Boot MOK enrollment is pending,"
    echo "    reboot to complete enrollment, then verify with: sudo modprobe dxgkrnl"
fi

# ==========================================================
# 10. Cleanup & Exit
# ==========================================================
echo "[STEP: Cleaning up deployment files...]"
cd /
sudo rm -rf "$DEPLOY_DIR"

if [ "$SB_ENABLED" = true ] && ! lsmod | grep -q dxgkrnl; then
    echo "[STATUS: REBOOT_REQUIRED]"
    echo " -> Reboot required to complete MOK enrollment and load dxgkrnl."
else
    echo "[STATUS: SUCCESS]"
fi
