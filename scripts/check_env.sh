#!/bin/bash
# =============================================================================
# scripts/check_env.sh — host detection (Linux, macOS, WSL2, GPU, display) as
# key=value output. Every key here is consumed by docker-compose*.yml, and
# check [host-detect-contract] asserts none goes missing.
# =============================================================================
set -euo pipefail

# The path SSOT, for devkit_env_value. Sourced like every other script here; it
# defines no HOST_* name this detector emits.
source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || { echo "  [ERROR] Cannot load config/util_paths.sh (broken checkout?)" >&2; exit 1; }
devkit_require "util_logging.sh"
LOG_PREFIX="[Env Detect]"

OUTPUT_MODE="${1:-env}"

usage() {
    cat <<'EOF'
Usage: check_env.sh [--makefile]

Detect host integration settings (GPU, display, paths, ids) and print them.

Options:
  --makefile  Print Makefile-compatible 'KEY := value' assignments.
  -h, --help  Show this help.
EOF
}

# Fail loudly on a typo: falling back to shell-assignment output would make the
# Makefile cache a file full of lines make cannot parse.
case "$OUTPUT_MODE" in
    env|--makefile) ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown option: $OUTPUT_MODE"; usage >&2; exit 2 ;;
esac

emit_env() {
    local key="$1"
    local value="$2"
    if [ "$OUTPUT_MODE" = "--makefile" ]; then
        # Escape make metacharacters: '#' truncates the line, '$' re-expands,
        # a newline injects a make line. env mode is %q-safe already.
        value="${value//$'\n'/ }"
        value="${value//\$/\$\$}"
        value="${value//#/\\#}"
        printf '%s := %s\n' "$key" "$value"
    else
        printf '%s=%q\n' "$key" "$value"
    fi
}

# 1. Host Architecture, macOS & WSL Detection
HOST_ARCH="amd64"
case "$(uname -m)" in
    aarch64|arm64) HOST_ARCH="arm64" ;;
esac

IS_WSL="false"
IS_MACOS="false"

if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    IS_MACOS="true"
elif grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL="true"
fi

# 2. GPU Detection (NVIDIA / DRI)
# macOS is skipped entirely: Docker Desktop runs a Linux VM with no CUDA/DRI
# passthrough, so every macOS host resolves to cpu (LLVMpipe).
HAS_NVIDIA="false"
HAS_TOOLKIT="false"
HAS_DRI="false"

if [ "$IS_MACOS" = "false" ]; then
    if command -v nvidia-smi >/dev/null 2>&1; then
        HAS_NVIDIA="true"
        if command -v docker >/dev/null 2>&1 && docker info 2>/dev/null | grep -qi nvidia; then
            HAS_TOOLKIT="true"
        fi
    fi

    if [ -d /dev/dri ] && compgen -G "/dev/dri/renderD*" >/dev/null; then
        HAS_DRI="true"
    elif [ "$IS_WSL" = "true" ] && [ -e "/dev/dxg" ]; then
        HAS_DRI="true"
    fi
fi

# 3. Path, User & Cache Setup
HOST_WORKSPACE_PATH="${HOST_WORKSPACE_PATH:-$(pwd)}"
WORKSPACE_PATH="${WORKSPACE_PATH:-/workspace}"
# Under sudo, bind the invoking user's HOME and ids, not root's. macOS has no
# getent, hence the fallbacks; each is `|| true` so a missing tool degrades.
if [ -n "${SUDO_USER:-}" ]; then
    if command -v getent >/dev/null 2>&1; then
        HOST_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    elif command -v dscl >/dev/null 2>&1; then
        HOST_HOME="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
    else
        HOST_HOME="$(awk -F: -v u="$SUDO_USER" '$1==u{print $6}' /etc/passwd 2>/dev/null || true)"
    fi
    HOST_UID="${SUDO_UID:-}"
    HOST_GID="${SUDO_GID:-}"
fi
HOST_HOME="${HOST_HOME:-${HOME:-/root}}"
HOST_UID="${HOST_UID:-$(id -u)}"
HOST_GID="${HOST_GID:-$(id -g)}"
# DOCKER_DEV_CACHE_DIR relocates the ccache/uv/apt cache (e.g. to a shared disk).
# Rejected outright when it would alias the workspace itself: `make clean-cache`
# deletes this directory recursively.
HOST_CACHE_DIR="${HOST_WORKSPACE_PATH}/.docker_cache"
if [ -n "${DOCKER_DEV_CACHE_DIR:-}" ]; then
    _cache_root="${DOCKER_DEV_CACHE_DIR%/}"
    case "$DOCKER_DEV_CACHE_DIR" in
        /*) ;;
        *)  log_error "DOCKER_DEV_CACHE_DIR must be an absolute path: ${DOCKER_DEV_CACHE_DIR}"; exit 2 ;;
    esac
    if [ -z "$_cache_root" ] || [ "$_cache_root" = "${HOST_WORKSPACE_PATH%/}" ]; then
        log_error "DOCKER_DEV_CACHE_DIR must not be '/' or the workspace root."
        exit 2
    fi
    HOST_CACHE_DIR="$_cache_root"
fi
# Placeholders need this directory: emitting a nonexistent path lets Docker
# recreate it root-owned. Fatal for --makefile (compose consumes them),
# warn-only otherwise — the SIF path only reads ROS/GPU facts.
if ! mkdir -p "$HOST_CACHE_DIR" 2>/dev/null; then
    if [ "$OUTPUT_MODE" = "--makefile" ]; then
        log_error "Cannot create the cache directory: ${HOST_CACHE_DIR}"
        exit 2
    fi
    log_warn "Cannot create ${HOST_CACHE_DIR}; placeholder mounts unavailable."
fi

# placeholder <name> [--file] — a stand-in for an absent host resource. Docker
# creates a missing mount source as root, breaking the later real mount.
placeholder() {
    local path="${HOST_CACHE_DIR}/dummy_$1"
    if [ "${2:-}" = "--file" ]; then
        [ -f "$path" ] || : > "$path" 2>/dev/null || true
    else
        mkdir -p "$path" 2>/dev/null || true
    fi
    printf '%s' "$path"
}

# 4. Device passthrough mounts (compose 'devices:' entries → host:container)
if [ -d /dev/dri ]; then
    HOST_DRI_MOUNT="/dev/dri:/dev/dri"
else
    HOST_DRI_MOUNT="/dev/null:/dev/null"
fi
if [ -e /dev/dxg ]; then
    HOST_DXG_MOUNT="/dev/dxg:/dev/dxg"
else
    HOST_DXG_MOUNT="/dev/null:/dev/null"
fi
# WSL2 ships libcuda/libd3d12 under /usr/lib/wsl — without this mount the
# container loses GPU acceleration entirely on WSL2.
if [ "$IS_WSL" = "true" ] && [ -d /usr/lib/wsl ]; then
    WSL_LIB_DIR_MOUNT="/usr/lib/wsl"
else
    WSL_LIB_DIR_MOUNT="$(placeholder wsl_lib)"
fi

# 5. Display, Authentication & Session Sockets
DISPLAY_TYPE="X11"
if [ "$IS_MACOS" = "true" ]; then
    case "${DISPLAY:-}" in
        ""|/private/*|/tmp/*) HOST_DISPLAY="host.docker.internal:0" ;;
        *) HOST_DISPLAY="$DISPLAY" ;;
    esac
else
    HOST_DISPLAY="${DISPLAY:-:0}"
fi

HOST_WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}"
HOST_XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"

# WSLg publishes its own X11 socket dir, Wayland socket and runtime dir.
if [ "$IS_WSL" = "true" ] && [ -d /mnt/wslg/runtime-dir ]; then
    HOST_XDG_RUNTIME_DIR="/mnt/wslg/runtime-dir"
    HOST_WAYLAND_DISPLAY="${HOST_WAYLAND_DISPLAY:-wayland-0}"
fi

if [ -n "$HOST_WAYLAND_DISPLAY" ]; then
    DISPLAY_TYPE="Wayland"
    # Point at whichever runtime dir actually holds the compositor socket.
    if [ ! -S "${HOST_XDG_RUNTIME_DIR}/${HOST_WAYLAND_DISPLAY}" ] \
       && [ -S "/run/user/${HOST_UID}/${HOST_WAYLAND_DISPLAY}" ]; then
        HOST_XDG_RUNTIME_DIR="/run/user/${HOST_UID}"
    fi
fi
[ -d "${HOST_XDG_RUNTIME_DIR:-}" ] || HOST_XDG_RUNTIME_DIR="$(placeholder xdg_runtime)"

if [ -d /tmp/.X11-unix ]; then
    HOST_X11_DIR="/tmp/.X11-unix"
elif [ "$IS_WSL" = "true" ] && [ -d /mnt/wslg/.X11-unix ]; then
    HOST_X11_DIR="/mnt/wslg/.X11-unix"
else
    HOST_X11_DIR="$(placeholder x11_unix)"
fi

HOST_XAUTHORITY="${XAUTHORITY:-${HOST_HOME}/.Xauthority}"
[ -f "$HOST_XAUTHORITY" ] || HOST_XAUTHORITY="$(placeholder xauthority --file)"

# ssh-agent forwarding & host git identity (mounted read-only into the container)
if [ -S "${SSH_AUTH_SOCK:-}" ]; then
    HOST_SSH_AUTH_SOCK="${SSH_AUTH_SOCK}"
else
    HOST_SSH_AUTH_SOCK=""
fi

if [ -f "${HOST_HOME}/.gitconfig" ]; then
    HOST_GITCONFIG="${HOST_HOME}/.gitconfig"
else
    HOST_GITCONFIG="$(placeholder gitconfig --file)"
fi

# 6. ROS distro → base image. make's `export` does not reach $(shell …), so
# every caller must read .env itself or the detector caches the humble/22.04
# default. Read, never source: .env is data, not code.
# Two layers, in the order make reads them: the local .env wins, .env.example
# carries the committed project answer. This is the ONLY place they are
# resolved — the cache written here is what every later stage reads, so a second
# resolution point could only ever disagree with it.
DEVKIT_ENV_FILE="${DEVKIT_ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env}"
DEVKIT_ENV_DEFAULTS="${DEVKIT_ENV_DEFAULTS:-${DEVKIT_ENV_FILE}.example}"
env_setting() {
    local value; value="$(devkit_env_value "$1" "$DEVKIT_ENV_FILE")"
    [ -n "$value" ] || value="$(devkit_env_value "$1" "$DEVKIT_ENV_DEFAULTS")"
    printf '%s' "$value"
}
ROS_DISTRO="${ROS_DISTRO:-$(env_setting ROS_DISTRO)}"
BASE_IMAGE="${BASE_IMAGE:-$(env_setting BASE_IMAGE)}"
UV_PYTHON="${UV_PYTHON:-$(env_setting UV_PYTHON)}"
ROS_DISTRO="${ROS_DISTRO:-humble}"
# One distro fixes BOTH the Ubuntu release and its Python: apt installs rclpy and
# rospy into the SYSTEM interpreter, so a venv on any other version imports
# neither. Derived together — pinning BASE_IMAGE by digest must not silently
# leave the interpreter behind.
case "$ROS_DISTRO" in
    noetic|foxy)          distro_base="ubuntu:20.04"; distro_python="3.8"  ;;
    jazzy|kilted|rolling) distro_base="ubuntu:24.04"; distro_python="3.12" ;;
    humble|iron)          distro_base="ubuntu:22.04"; distro_python="3.10" ;;
    *)                    distro_base="";             distro_python=""     ;;
esac
if [ -z "${BASE_IMAGE:-}" ]; then
    [ -n "$distro_base" ] || {
        log_error "Unsupported ROS_DISTRO '${ROS_DISTRO}'. Each distro is bound to one Ubuntu release:"
        log_detail "20.04: noetic, foxy | 22.04: humble, iron | 24.04: jazzy, kilted, rolling" >&2
        log_detail "Set BASE_IMAGE yourself to build against a pairing DevKit does not know." >&2
        exit 2; }
    BASE_IMAGE="$distro_base"
fi
UV_PYTHON="${UV_PYTHON:-${distro_python:-3.10}}"

# An explicit value WINS — DEPLOY.md tells you to pin BASE_IMAGE by digest — but
# a .env written before ROS_DISTRO changed pins the OLD pairing and nothing says
# so until apt fails deep in the build. Say it here, once, and keep going.
if [ -n "$distro_base" ]; then
    case "$BASE_IMAGE" in
        "$distro_base"|*"${distro_base#ubuntu:}"*) ;;
        *) log_warn "ROS_DISTRO=${ROS_DISTRO} expects ${distro_base}, but BASE_IMAGE is '${BASE_IMAGE}'." >&2
           log_detail "Comment BASE_IMAGE out in .env to follow ROS_DISTRO, or ignore this if the pin is deliberate." >&2 ;;
    esac
    [ "$UV_PYTHON" = "$distro_python" ] \
        || { log_warn "ROS_DISTRO=${ROS_DISTRO} ships Python ${distro_python}, but UV_PYTHON is '${UV_PYTHON}'." >&2
             log_detail "The venv will not import the apt-installed rclpy/rospy. Comment UV_PYTHON out in .env." >&2; }
fi

# 7. Output key-value pairs
# NOTE: every key below is consumed by docker-compose*.yml. Keep this list and
#       scripts/verify_repo.sh check [host-detect-contract] in sync when adding a compose variable.
emit_env "ROS_DISTRO" "$ROS_DISTRO"
emit_env "BASE_IMAGE" "$BASE_IMAGE"
emit_env "UV_PYTHON" "$UV_PYTHON"
emit_env "HOST_WORKSPACE_PATH" "$HOST_WORKSPACE_PATH"
emit_env "WORKSPACE_PATH" "$WORKSPACE_PATH"
emit_env "IS_WSL" "$IS_WSL"
emit_env "IS_MACOS" "$IS_MACOS"
emit_env "HOST_ARCH" "$HOST_ARCH"
emit_env "HOST_UID" "$HOST_UID"
emit_env "HOST_GID" "$HOST_GID"
emit_env "HAS_NVIDIA" "$HAS_NVIDIA"
emit_env "HAS_TOOLKIT" "$HAS_TOOLKIT"
emit_env "HAS_DRI" "$HAS_DRI"
emit_env "HOST_DRI_MOUNT" "$HOST_DRI_MOUNT"
emit_env "HOST_DXG_MOUNT" "$HOST_DXG_MOUNT"
emit_env "WSL_LIB_DIR_MOUNT" "$WSL_LIB_DIR_MOUNT"
emit_env "DISPLAY_TYPE" "$DISPLAY_TYPE"
emit_env "HOST_DISPLAY" "$HOST_DISPLAY"
emit_env "HOST_WAYLAND_DISPLAY" "$HOST_WAYLAND_DISPLAY"
emit_env "HOST_X11_DIR" "$HOST_X11_DIR"
emit_env "HOST_XAUTHORITY" "$HOST_XAUTHORITY"
emit_env "HOST_XDG_RUNTIME_DIR" "$HOST_XDG_RUNTIME_DIR"
emit_env "HOST_SSH_AUTH_SOCK" "$HOST_SSH_AUTH_SOCK"
emit_env "HOST_GITCONFIG" "$HOST_GITCONFIG"
emit_env "HOST_CACHE_DIR" "$HOST_CACHE_DIR"
emit_env "HOST_HOME" "$HOST_HOME"
