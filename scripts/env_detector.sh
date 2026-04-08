#!/bin/bash
# =============================================================================
# scripts/env_detector.sh
# Diagnostic engine for host environment detection
#
# Precisely detects GPU availability, hardware architecture, container toolkits,
# and display server configurations (X11/Wayland). Results are output in
# KEY=VALUE format for Makefile integration.
# =============================================================================

# Load logging utility
source "$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh" 2>/dev/null || true
LOG_PREFIX="[Env Detector]"

# 1. Identify GPU hardware and container toolkit compatibility
HAS_NVIDIA="false"
HAS_TOOLKIT="false"
HAS_DRI="false"

if command -v nvidia-smi >/dev/null 2>&1; then
    HAS_NVIDIA="true"
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if docker info 2>/dev/null | grep -iq "Runtimes: .*nvidia"; then
        HAS_TOOLKIT="true"
    fi
else
    log_warn "Docker daemon is not running or not accessible. GPU toolkit detection skipped."
fi

# Detect /dev/dri existence (Used for Intel/AMD resource allocation and auto-mount selection)
if [ -d /dev/dri ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
    HAS_DRI="true"
fi

# 2. Determine host CPU architecture for binary compatibility
RAW_ARCH=$(uname -m)
case "${RAW_ARCH}" in
    x86_64)  HOST_ARCH="amd64" ;;
    aarch64) HOST_ARCH="arm64" ;;
    armv8*)  HOST_ARCH="arm64" ;;
    *)       HOST_ARCH="unknown" ;;
esac

# 3. Detect Display Protocols and Establish Secure Cache Paths
# Ensure a valid cache directory exists, defaulting to .docker_cache within the workspace
if [ -z "${DOCKER_DEV_CACHE_DIR}" ]; then
    HOST_CACHE_DIR="${WORKSPACE_PATH:-$(pwd)}/.docker_cache"
else
    HOST_CACHE_DIR="${DOCKER_DEV_CACHE_DIR}"
fi
mkdir -p "${HOST_CACHE_DIR}"

DISPLAY_TYPE="X11"
HOST_XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}"
HOST_WAYLAND_DISPLAY="${WAYLAND_DISPLAY}"
# Sudo support: Accurately locate the X11 authority file by referencing the real home directory of the SUDO_USER.
if [ -n "${SUDO_USER}" ]; then
    ORIGINAL_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
    HOST_HOME="${ORIGINAL_HOME}"
    HOST_XAUTHORITY="${XAUTHORITY:-${ORIGINAL_HOME}/.Xauthority}"
else
    HOST_HOME="${HOME}"
    HOST_XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
fi

if [ -n "$WAYLAND_DISPLAY" ]; then
    DISPLAY_TYPE="Wayland"
    # Verify actual socket file existence and normalize path
    if [ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]; then
        HOST_WAYLAND_DISPLAY="${WAYLAND_DISPLAY}"
    elif [ -S "/run/user/$(id -u)/${WAYLAND_DISPLAY}" ]; then
        HOST_XDG_RUNTIME_DIR="/run/user/$(id -u)"
    fi
fi

if [ -z "${HOST_XDG_RUNTIME_DIR}" ] || [ ! -d "${HOST_XDG_RUNTIME_DIR}" ]; then
    mkdir -p "${HOST_CACHE_DIR}/dummy_xdg_runtime"
    HOST_XDG_RUNTIME_DIR="${HOST_CACHE_DIR}/dummy_xdg_runtime"
fi

# Detect the X11 Unix socket directory with automatic fallback creation
if [ -d /tmp/.X11-unix ]; then
    HOST_X11_DIR="/tmp/.X11-unix"
else
    # Create a virtual path for environments without X11 or in special cases
    mkdir -p "${HOST_CACHE_DIR}/dummy_x11_unix"
    HOST_X11_DIR="${HOST_CACHE_DIR}/dummy_x11_unix"
fi

# 4. Host File Dummy Mapping (Ensuring stability for Headless or SSOT environments)
if [ -d "${HOST_HOME}/.ssh" ]; then
    HOST_SSH_DIR="${HOST_HOME}/.ssh"
else
    mkdir -p "${HOST_CACHE_DIR}/dummy_ssh"
    HOST_SSH_DIR="${HOST_CACHE_DIR}/dummy_ssh"
fi

if [ -f "${HOST_HOME}/.gitconfig" ]; then
    HOST_GITCONFIG="${HOST_HOME}/.gitconfig"
else
    touch "${HOST_CACHE_DIR}/dummy_gitconfig"
    HOST_GITCONFIG="${HOST_CACHE_DIR}/dummy_gitconfig"
fi

if [ ! -f "${HOST_XAUTHORITY}" ]; then
    touch "${HOST_CACHE_DIR}/dummy_xauthority"
    HOST_XAUTHORITY="${HOST_CACHE_DIR}/dummy_xauthority"
fi

# Validate that path variables do not contain spaces to prevent Makefile parsing issues
for _path_var in HOST_HOME HOST_CACHE_DIR HOST_X11_DIR HOST_SSH_DIR HOST_GITCONFIG HOST_XAUTHORITY; do
    _val=$(eval echo '$'"$_path_var")
    if echo "$_val" | grep -q ' '; then
        log_warn "$_path_var contains spaces ('$_val'). This may cause Makefile eval issues."
    fi
done

# 5. Output results in KEY=VALUE format for Makefile or environment injection
echo "HAS_NVIDIA=${HAS_NVIDIA}"
echo "HAS_TOOLKIT=${HAS_TOOLKIT}"
echo "HAS_DRI=${HAS_DRI}"
echo "HOST_ARCH=${HOST_ARCH}"
echo "DISPLAY_TYPE=${DISPLAY_TYPE}"
echo "HOST_XDG_RUNTIME_DIR=${HOST_XDG_RUNTIME_DIR}"
echo "HOST_WAYLAND_DISPLAY=${HOST_WAYLAND_DISPLAY}"
echo "HOST_XAUTHORITY=${HOST_XAUTHORITY}"
echo "HOST_HOME=${HOST_HOME}"
echo "HOST_CACHE_DIR=${HOST_CACHE_DIR}"
echo "HOST_X11_DIR=${HOST_X11_DIR}"
echo "HOST_GITCONFIG=${HOST_GITCONFIG}"
echo "HOST_SSH_DIR=${HOST_SSH_DIR}"
