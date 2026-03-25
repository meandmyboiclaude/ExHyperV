#!/bin/bash
# @Name: CachyOS-Official
# @Description: GPU-PV deployment script for CachyOS (Arch-based, pacman/yay, Clang-built kernels)
# @Author: ExHyperV Community
# @Version: 1.0.0

set -e

# ==========================================================
# 0. Helper Functions
# ==========================================================
update_env() {
    local key=$1
    local val=$2
    sudo sed -i "/^$key=/d" /etc/environment
    sudo sed -i "/^export $key=/d" /etc/environment
    echo "$key=$val" | sudo tee -a /etc/environment > /dev/null
}

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

    sudo systemctl stop load-dxg-late.service 2>/dev/null || true
    sudo systemctl disable load-dxg-late.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/load-dxg-late.service
    sudo rm -f /usr/local/bin/load_dxg_driver.sh
    sudo systemctl daemon-reload

    sudo modprobe -r dxgkrnl 2>/dev/null || true

    # Remove module from all installed kernels
    for moddir in /usr/lib/modules/*/extra; do
        sudo rm -f "$moddir/dxgkrnl.ko" "$moddir/dxgkrnl.ko.zst" 2>/dev/null
    done
    sudo depmod -a

    sudo rm -f /etc/modprobe.d/blacklist-dxgkrnl.conf
    sudo rm -f /etc/modules-load.d/vgem.conf

    sudo rm -rf /usr/lib/wsl
    sudo rm -f /etc/ld.so.conf.d/ld.wsl.conf
    sudo ldconfig

    sudo sed -i '/^GALLIUM_DRIVERS=/d' /etc/environment
    sudo sed -i '/^DRI_PRIME=/d' /etc/environment
    sudo sed -i '/^LIBVA_DRIVER_NAME=/d' /etc/environment
    sudo sed -i '/^VK_ICD_FILENAMES=/d' /etc/environment

    echo "[STATUS: SUCCESS]"
    echo " -> GPU-PV components have been uninstalled. A reboot is recommended."
    exit 0
fi

# ==========================================================
# 2. Dependencies
# CachyOS/Arch uses pacman. clang+lld required for CachyOS
# kernels which are Clang-built.
# ==========================================================
echo "[STEP: Installing basic dependencies...]"
sudo pacman -S --noconfirm --needed \
    git curl wget gcc clang lld make unzip aria2 \
    openssl linux-api-headers

# ==========================================================
# 3. Kernel Header Check
# CachyOS kernels: linux-cachyos-headers, linux-cachyos-rc-headers, etc.
# Module build dir: /usr/lib/modules/$(uname -r)/build
# ==========================================================
echo "[STEP: Checking Kernel Headers...]"
TARGET_KERNEL_VERSION=$(uname -r)

if [ ! -e "/usr/lib/modules/$TARGET_KERNEL_VERSION/build" ]; then
    echo " -> Kernel headers not found for $TARGET_KERNEL_VERSION. Attempting installation..."

    HEADERS_INSTALLED=false

    # Detect which kernel package is installed and install matching headers
    if echo "$TARGET_KERNEL_VERSION" | grep -qi "cachyos-rc"; then
        echo " -> Detected CachyOS RC kernel, installing linux-cachyos-rc-headers..."
        sudo pacman -S --noconfirm linux-cachyos-rc-headers && HEADERS_INSTALLED=true
    elif echo "$TARGET_KERNEL_VERSION" | grep -qi "cachyos-lts"; then
        echo " -> Detected CachyOS LTS kernel, installing linux-cachyos-lts-headers..."
        sudo pacman -S --noconfirm linux-cachyos-lts-headers && HEADERS_INSTALLED=true
    elif echo "$TARGET_KERNEL_VERSION" | grep -qi "cachyos"; then
        echo " -> Detected CachyOS kernel, installing linux-cachyos-headers..."
        sudo pacman -S --noconfirm linux-cachyos-headers && HEADERS_INSTALLED=true
    else
        echo " -> Trying generic linux-headers..."
        sudo pacman -S --noconfirm linux-headers && HEADERS_INSTALLED=true
    fi

    if [ "$HEADERS_INSTALLED" = false ]; then
        echo " -> [ERROR] Could not install kernel headers for $TARGET_KERNEL_VERSION"
        exit 1
    fi
fi

# Final check (Arch uses /usr/lib/modules, not /lib/modules)
BUILD_DIR="/usr/lib/modules/$TARGET_KERNEL_VERSION/build"
if [ ! -e "$BUILD_DIR" ]; then
    # Fallback: check /lib/modules symlink
    BUILD_DIR="/lib/modules/$TARGET_KERNEL_VERSION/build"
    if [ ! -e "$BUILD_DIR" ]; then
        echo " -> [ERROR] Kernel headers still not found for $TARGET_KERNEL_VERSION"
        exit 1
    fi
fi
echo " -> Kernel headers found for $TARGET_KERNEL_VERSION"

# ==========================================================
# 3b. Detect compiler used to build kernel
# CachyOS kernels are Clang-built; building with GCC will fail.
# ==========================================================
KERNEL_CC="gcc"
KERNEL_LD="ld"
if grep -q "clang" /proc/version 2>/dev/null; then
    KERNEL_CC="clang"
    KERNEL_LD="ld.lld"
    echo " -> Kernel built with Clang — will use CC=clang LD=ld.lld"
else
    echo " -> Kernel built with GCC — will use CC=gcc"
fi

# ==========================================================
# 4. dxgkrnl Module Compilation (no DKMS — direct build)
# CachyOS doesn't use DKMS by default. We build the module
# directly and install to /usr/lib/modules/*/extra/.
# ==========================================================
if lsmod | grep -q "dxgkrnl"; then
    echo " -> dxgkrnl is already loaded."
else
    echo "[STEP: Preparing Source & Patching...]"
    KERNEL_MAJOR=$(echo $TARGET_KERNEL_VERSION | cut -d. -f1)
    KERNEL_MINOR=$(echo $TARGET_KERNEL_VERSION | cut -d. -f2)

    if [[ "$KERNEL_MAJOR" -eq 6 && "$KERNEL_MINOR" -ge 6 ]] || [[ "$KERNEL_MAJOR" -gt 6 ]]; then
        TARGET_BRANCH="linux-msft-wsl-6.6.y"
    else
        TARGET_BRANCH="linux-msft-wsl-5.15.y"
    fi

    rm -rf /tmp/dxg-src /tmp/kernel_src.tar.gz /tmp/extract-tmp

    PKG="dxgkrnl-${TARGET_BRANCH#linux-msft-wsl-}"
    PKG="${PKG%.y}-patched"
    echo " -> Downloading Lightweight Kernel Source using Aria2..."
    ZIP_URL="https://raw.githubusercontent.com/Justsenger/ExHyperV/kernel-assets/$PKG.tar.gz"

    retry_cmd aria2c -x 4 -s 4 --dir=/tmp --out=kernel_src.tar.gz "$ZIP_URL" --allow-overwrite

    echo " -> Recreating Kernel Tree Structure..."
    mkdir -p /tmp/extract-tmp
    tar -xzf /tmp/kernel_src.tar.gz -C /tmp/extract-tmp --strip-components=1

    mkdir -p /tmp/dxg-src/drivers/hv/dxgkrnl
    mv /tmp/extract-tmp/include /tmp/dxg-src/include
    cp -r /tmp/extract-tmp/* /tmp/dxg-src/drivers/hv/dxgkrnl/

    cd /tmp/dxg-src

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
        retry_cmd curl -fsSL --retry 3 "$PATCH_BASE_URL/linux-msft-wsl-6.6.y/0002-Fix-eventfd_signal.patch" -o patch_6.6.patch
        patch -p1 --ignore-whitespace < patch_6.6.patch
    fi

    echo "[STEP: Compiling DXG Module...]"
    SRC_DIR="/tmp/dxg-src/drivers/hv/dxgkrnl"
    DXGMODULE_FILE="$SRC_DIR/dxgmodule.c"

    # Auto-fix for kernel 6.8+ eventfd API change
    if grep -q "eventfd_signal.*struct eventfd_ctx.*__u64" "$BUILD_DIR/include/linux/eventfd.h" 2>/dev/null; then
        sed -i 's/eventfd_signal(event->cpu_event);/eventfd_signal(event->cpu_event, 1);/g' "$DXGMODULE_FILE"
    fi

    # Configure standalone Makefile
    sed -i 's/$(CONFIG_DXGKRNL)/m/' "$SRC_DIR/Makefile"
    echo "EXTRA_CFLAGS=-I\$(PWD)/include -D_MAIN_KERNEL_ -Wno-empty-body" >> "$SRC_DIR/Makefile"

    # Build with detected compiler
    make -C "$BUILD_DIR" M="$SRC_DIR" CC=$KERNEL_CC LD=$KERNEL_LD modules

    echo "[STEP: Installing DXG Module...]"
    sudo mkdir -p "/usr/lib/modules/$TARGET_KERNEL_VERSION/extra"
    sudo cp "$SRC_DIR/dxgkrnl.ko" "/usr/lib/modules/$TARGET_KERNEL_VERSION/extra/"
    sudo depmod -a "$TARGET_KERNEL_VERSION"
    echo " -> dxgkrnl.ko installed for $TARGET_KERNEL_VERSION"
fi

# ==========================================================
# 4b. Secure Boot Check
# CachyOS can run with or without Secure Boot.
# ==========================================================
echo "[STEP: Checking Secure Boot status...]"
SB_ENABLED=false
if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
    SB_ENABLED=true
    echo " -> Secure Boot is ENABLED. Module signing may be required."

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
    fi

    DXGKRNL_KO=$(find /usr/lib/modules/$TARGET_KERNEL_VERSION -name "dxgkrnl.ko*" 2>/dev/null | head -1)
    if [ -n "$DXGKRNL_KO" ]; then
        DXGKRNL_KO_PLAIN="$DXGKRNL_KO"
        case "$DXGKRNL_KO" in
            *.zst) sudo zstd -d --rm "$DXGKRNL_KO"; DXGKRNL_KO_PLAIN="${DXGKRNL_KO%.zst}" ;;
            *.xz)  sudo xz -d "$DXGKRNL_KO"; DXGKRNL_KO_PLAIN="${DXGKRNL_KO%.xz}" ;;
            *.gz)  sudo gzip -d "$DXGKRNL_KO"; DXGKRNL_KO_PLAIN="${DXGKRNL_KO%.gz}" ;;
        esac

        SIGN_FILE="$BUILD_DIR/scripts/sign-file"
        if [ -x "$SIGN_FILE" ]; then
            sudo "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$DXGKRNL_KO_PLAIN"
            echo " -> Module signed successfully."
        fi
    fi

    if ! mokutil --test-key "$MOK_DER" 2>/dev/null | grep -qi "already enrolled"; then
        echo ""
        echo " ========================================================"
        echo " IMPORTANT: MOK key must be enrolled in firmware."
        echo "   sudo mokutil --import $MOK_DER"
        echo " Then reboot and select 'Enroll MOK'."
        echo " ========================================================"
        sudo mokutil --import "$MOK_DER" || true
    fi
else
    echo " -> Secure Boot is DISABLED or mokutil not available. No signing needed."
fi

echo "[STEP: Testing module load...]"
if ! sudo modprobe dxgkrnl; then
    if [ "$SB_ENABLED" = true ]; then
        echo " -> [WARNING] dxgkrnl could not be loaded. Complete MOK enrollment after reboot."
    else
        echo " -> [WARNING] dxgkrnl could not be loaded. Check dmesg for details."
    fi
fi

# ==========================================================
# 5. Graphics Stack Configuration
# CachyOS/Arch: mesa, vulkan-tools from official repos.
# ==========================================================
if [ "$ENABLE_GRAPHICS" == "true" ]; then
    echo "[STEP: Configuring Graphics Stack...]"
    sudo pacman -S --noconfirm --needed \
        mesa \
        vulkan-icd-loader \
        vulkan-tools \
        lib32-mesa \
        lib32-vulkan-icd-loader \
        2>/dev/null || true
fi

# ==========================================================
# 6. System Configuration & WSL Library Deployment
# ==========================================================
echo "[STEP: Deploying WSL Core Libraries...]"
LIBS=("libd3d12.so" "libd3d12core.so" "libdxcore.so")
mkdir -p "$LIB_DIR"
for lib in "${LIBS[@]}"; do
    if [ ! -f "$LIB_DIR/$lib" ]; then
        echo " -> $lib not found locally, downloading for $ARCH_DIR..."
        if ! retry_cmd aria2c -x 4 -s 4 --dir="$LIB_DIR" --out="$lib" "$GITHUB_LIB_URL/$lib" --allow-overwrite; then
            echo " -> [ERROR] Failed to download $lib"
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
sudo ln -sf /usr/lib/wsl/lib/libd3d12core.so /usr/lib/wsl/lib/libD3D12Core.so
sudo chmod -R 0555 /usr/lib/wsl
sudo chown -R root:root /usr/lib/wsl
echo "/usr/lib/wsl/lib" | sudo tee /etc/ld.so.conf.d/ld.wsl.conf > /dev/null
sudo ldconfig 2>/dev/null || true

# ==========================================================
# 7. Kernel Module Late-Load Strategy
# CachyOS uses mkinitcpio, not dracut.
# ==========================================================
echo "[STEP: Configuring Kernel Modules Strategy (vgem & dxgkrnl)...]"

echo "vgem" | sudo tee /etc/modules-load.d/vgem.conf > /dev/null
sudo modprobe vgem || true

echo "blacklist dxgkrnl" | sudo tee /etc/modprobe.d/blacklist-dxgkrnl.conf > /dev/null

# Rebuild initramfs with mkinitcpio (all installed kernels)
echo " -> Rebuilding initramfs with mkinitcpio..."
sudo mkinitcpio -P 2>/dev/null || true

# Create late-load script
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
    update_env "GALLIUM_DRIVERS" "d3d12"
    update_env "DRI_PRIME" "1"
    update_env "LIBVA_DRIVER_NAME" "d3d12"
    update_env "VK_ICD_FILENAMES" "/usr/share/vulkan/icd.d/dzn_icd.x86_64.json"

    # Add to shell configs (bash + zsh)
    for rcfile in ~/.bashrc ~/.zshrc; do
        if [ -f "$rcfile" ] && ! grep -q "GALLIUM_DRIVERS=d3d12" "$rcfile"; then
            cat >> "$rcfile" <<RCEOF
# GPU-PV Configuration
export GALLIUM_DRIVERS=d3d12
export DRI_PRIME=1
export LIBVA_DRIVER_NAME=d3d12
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/dzn_icd.x86_64.json
RCEOF
        fi
    done

    sudo usermod -a -G video,render $USER

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

if [ -e /dev/dxg ]; then
    echo " [OK] /dev/dxg exists"
else
    echo " [--] /dev/dxg not found (may appear after reboot)"
    VERIFY_PASS=false
fi

if lsmod | grep -q dxgkrnl; then
    echo " [OK] dxgkrnl module is loaded"
else
    echo " [--] dxgkrnl module is not loaded"
    VERIFY_PASS=false
fi

if [ -f "/usr/lib/modules/$TARGET_KERNEL_VERSION/extra/dxgkrnl.ko" ]; then
    echo " [OK] dxgkrnl.ko installed in modules/extra"
else
    echo " [--] dxgkrnl.ko not found in modules/extra"
    VERIFY_PASS=false
fi

if systemctl is-enabled load-dxg-late.service &>/dev/null; then
    echo " [OK] load-dxg-late.service is enabled"
else
    echo " [--] load-dxg-late.service is not enabled"
    VERIFY_PASS=false
fi

if [ -f /usr/lib/wsl/lib/libd3d12.so ]; then
    echo " [OK] WSL libraries deployed to /usr/lib/wsl/lib/"
else
    echo " [--] WSL libraries not found"
    VERIFY_PASS=false
fi

echo ""

# ==========================================================
# 10. Cleanup & Exit
# ==========================================================
echo "[STEP: Cleaning up deployment files...]"
cd /
sudo rm -rf "$DEPLOY_DIR"

echo "[STATUS: SUCCESS]"
