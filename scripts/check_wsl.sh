#!/bin/bash
# =============================================================================
# scripts/check_wsl.sh
# Diagnostic check for WSL2 host environment, networking & GPU readiness
# =============================================================================
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || { echo "  [ERROR] Cannot load config/util_paths.sh (broken checkout?)" >&2; exit 1; }  # host-only: never fall back to world-writable /tmp
devkit_require "util_logging.sh"
LOG_PREFIX="[WSL Check]"

# Strip colour when piped/redirected or NO_COLOR is set (see util_logging.sh).
declare -F devkit_auto_color >/dev/null 2>&1 && devkit_auto_color

if ! grep -qi microsoft /proc/version 2>/dev/null; then
    log_info "Native Linux host detected (Not running inside WSL2)."
    exit 0
fi

log_ok "WSL2 environment detected."

# 1. Check systemd & Mirrored Networking
if [ -f "/etc/wsl.conf" ] && grep -qi "systemd[[:space:]]*=[[:space:]]*true" /etc/wsl.conf; then
    log_ok "WSL2 systemd enabled (/etc/wsl.conf)."
else
    log_warn "WSL2 systemd not enabled in /etc/wsl.conf. (Recommended for Docker service management)"
fi

# 2. Check GPU & GUI Acceleration
if [ -e "/dev/dxg" ]; then
    log_ok "DirectX / D3D12 GPU device node (/dev/dxg) present."
else
    log_warn "DirectX device node (/dev/dxg) not found. WSL2 GPU acceleration may be disabled."
fi

if [ -d "/mnt/wslg" ]; then
    log_ok "WSLg GUI subsystem available (/mnt/wslg)."
fi

# 3. Mirrored networking — required for ROS 2 DDS multicast to cross the
# WSL2/Windows boundary; its absence is a classic silent discovery failure.
# powershell.exe costs seconds and the Windows home never moves, so the
# resolved .wslconfig path is cached per-user (this runs on every `make check`).
# $HOME, not /tmp: a world-writable predictable path invites symlink games on
# shared machines. Only a SUCCESSFUL resolution is cached (-s guard + [ -n ]):
# a transient powershell timeout must not disable the audit until reboot.
WSLCONFIG_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/devkit_wslconfig"
if [ -s "$WSLCONFIG_CACHE" ]; then
    WSLCONFIG="$(cat "$WSLCONFIG_CACHE")"
else
    WIN_HOME_RAW="$(timeout 10 powershell.exe -NoProfile -Command '$env:USERPROFILE' 2>/dev/null | tr -d '\r' || true)"
    WSLCONFIG=""
    if [ -n "$WIN_HOME_RAW" ]; then
        WIN_HOME="$(wslpath "$WIN_HOME_RAW" 2>/dev/null || true)"
        [ -n "$WIN_HOME" ] && WSLCONFIG="${WIN_HOME}/.wslconfig"
    fi
    if [ -n "$WSLCONFIG" ]; then
        mkdir -p "$(dirname "$WSLCONFIG_CACHE")" 2>/dev/null || true
        printf '%s' "$WSLCONFIG" > "$WSLCONFIG_CACHE" 2>/dev/null || true
    fi
fi
if [ -n "$WSLCONFIG" ] && [ -f "$WSLCONFIG" ] && grep -qi 'networkingMode[[:space:]]*=[[:space:]]*mirrored' "$WSLCONFIG"; then
    log_ok "Mirrored networking enabled (.wslconfig) — DDS multicast reaches the Windows host."
elif [ -n "$WSLCONFIG" ]; then
    log_warn "networkingMode=mirrored not set in ${WSLCONFIG} — ROS 2 nodes on the Windows side will not be discovered."
    log_warn "Fix (Windows 11 22H2+): add '[wsl2]' + 'networkingMode=mirrored' there, then 'wsl --shutdown'."
    log_warn "On Windows 10 use ROS_LOCALHOST_ONLY=1 or a DDS discovery server instead."
else
    log_info "Could not locate Windows .wslconfig — skipping networking audit."
fi
