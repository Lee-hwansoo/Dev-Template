#!/bin/bash
# =============================================================================
# scripts/check_env.sh
# Diagnostic engine for host environment detection (Linux, macOS, WSL2, GPU)
# =============================================================================
set -euo pipefail

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
    *) echo "check_env.sh: unknown option: $OUTPUT_MODE" >&2; usage >&2; exit 2 ;;
esac

emit_env() {
    local key="$1"
    local value="$2"
    if [ "$OUTPUT_MODE" = "--makefile" ]; then
        # Escape make metacharacters: an unescaped '#' truncates the line into
        # a comment and '$' gets re-expanded by make (host paths can contain
        # both). Newlines would inject arbitrary make lines — strip them; the
        # env-mode branch below is inherently newline-safe via %q.
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
# ponytail: macOS uses CPU LLVMpipe rendering (Ceiling: CUDA/DRI unavailable inside macOS Docker Desktop)
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
# Honour sudo: bind the invoking user's HOME and ids, not root's.
# macOS has no `getent`; fall back to dscl, then to the passwd file. Every branch
# is `|| true`-guarded because this script runs under `set -euo pipefail` and a
# missing lookup tool must degrade, not abort the whole detection.
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
        *)  echo "check_env.sh: DOCKER_DEV_CACHE_DIR must be an absolute path: ${DOCKER_DEV_CACHE_DIR}" >&2; exit 2 ;;
    esac
    if [ -z "$_cache_root" ] || [ "$_cache_root" = "${HOST_WORKSPACE_PATH%/}" ]; then
        echo "check_env.sh: DOCKER_DEV_CACHE_DIR must not be '/' or the workspace root." >&2
        exit 2
    fi
    HOST_CACHE_DIR="$_cache_root"
fi
# The placeholder mechanism below depends on this directory existing; emitting
# nonexistent paths would let Docker recreate them root-owned — the exact
# failure placeholders were built to prevent. Fatal for --makefile (compose
# consumes the placeholders), warn-only otherwise: the apptainer/SIF path only
# reads ROS/GPU facts and must keep working from a read-only CWD.
if ! mkdir -p "$HOST_CACHE_DIR" 2>/dev/null; then
    if [ "$OUTPUT_MODE" = "--makefile" ]; then
        echo "check_env.sh: cannot create cache directory: ${HOST_CACHE_DIR}" >&2
        exit 2
    fi
    echo "check_env.sh: warning: cannot create ${HOST_CACHE_DIR}; placeholder mounts unavailable." >&2
fi

# placeholder <name> [--file] : a stable stand-in path for an absent host resource.
# Docker auto-creates missing bind-mount sources as root-owned directories, which
# breaks a later real mount and pollutes the host — so every optional mount below
# resolves to a real, user-owned placeholder inside .docker_cache instead.
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
    HOST_DISPLAY="${DISPLAY:-host.docker.internal:0}"
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

# 6. ROS Distro to Ubuntu Base Image Auto-Resolver
# .env is the single source of truth, but make's `export` does NOT reach
# $(shell ...), so the Makefile cannot hand these two down: every caller
# (make, apptainer_*.sh, a manual run) has to read the file itself or the
# detector silently falls back to the humble/22.04 default and that wrong
# value gets cached in .docker_cache/detected-env.mk.
# Read, never source: .env is data, not code.
DEVKIT_ENV_FILE="${DEVKIT_ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env}"
env_file_value() {
    [ -f "$DEVKIT_ENV_FILE" ] || return 0
    sed -n "s/^[[:space:]]*$1=//p" "$DEVKIT_ENV_FILE" | tail -n 1 | tr -d '"'"'"'\r'
}
ROS_DISTRO="${ROS_DISTRO:-$(env_file_value ROS_DISTRO)}"
BASE_IMAGE="${BASE_IMAGE:-$(env_file_value BASE_IMAGE)}"
ROS_DISTRO="${ROS_DISTRO:-humble}"
if [ -z "${BASE_IMAGE:-}" ]; then
    case "$ROS_DISTRO" in
        noetic)               BASE_IMAGE="ubuntu:20.04" ;;
        jazzy|kilted|rolling) BASE_IMAGE="ubuntu:24.04" ;;
        humble|iron|*)        BASE_IMAGE="ubuntu:22.04" ;;
    esac
fi

# 7. Output key-value pairs
# NOTE: every key below is consumed by docker-compose*.yml. Keep this list and
#       scripts/verify_repo.sh check [host-detect-contract] in sync when adding a compose variable.
emit_env "ROS_DISTRO" "$ROS_DISTRO"
emit_env "BASE_IMAGE" "$BASE_IMAGE"
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
