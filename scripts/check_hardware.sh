#!/bin/bash
# =============================================================================
# scripts/check_hardware.sh — the six-section readiness scan: system, network,
# GPU, display, identity/permissions, toolchain.
# Usage: check_hardware.sh [--brief]
# =============================================================================
set -euo pipefail

# WS_ROOT comes from the path SSOT, never from WORKSPACE_PATH directly: make
# exports the CONTAINER path to host recipes too, and util_paths.sh is the one
# place that knows to ignore it when it is not a DevKit tree here.
# It also stubs log_*, so no local fallbacks are needed; this script's own
# output goes through the _hw_* helpers below.
source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || { echo "  [ERROR] Cannot load config/util_paths.sh (broken checkout?)" >&2; exit 1; }
devkit_require "util_logging.sh"
devkit_require "util_gpu_detect.sh"
LOG_PREFIX="[HW Check]"

# Strip colour when piped/redirected or NO_COLOR is set (see util_logging.sh).
declare -F devkit_auto_color >/dev/null 2>&1 && devkit_auto_color

BRIEF_MODE=false
for arg in "$@"; do
    case "$arg" in
        --brief) BRIEF_MODE=true ;;
        -h|--help) echo "Usage: check_hardware.sh [--brief]"; exit 0 ;;
        *) log_error "Unknown option: $arg"; exit 2 ;;
    esac
done

DIAG_WARNINGS=0; DIAG_ERRORS=0
_hw_ok()     { $BRIEF_MODE || echo -e "  \033[32m✓\033[0m $*"; }
_hw_warn()   { DIAG_WARNINGS=$((DIAG_WARNINGS+1)); echo -e "  \033[33m⚠\033[0m $*"; }
_hw_err()    { DIAG_ERRORS=$((DIAG_ERRORS+1));    echo -e "  \033[31m✗\033[0m $*"; }
_hw_detail() { $BRIEF_MODE || echo "$*"; }
_hw_skip()   { $BRIEF_MODE || echo "  ○ $*"; }
_hw_section(){ $BRIEF_MODE || echo -e "\n\033[1;36m[$*]\033[0m"; }

# =============================================================================
# [1/6] System: CPU, RAM, Disk
# =============================================================================
_hw_section "1/6 System"

# CPU
CPU_MODEL=$(grep -m1 "model name\|Model name\|Hardware\|Processor" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
CPU_CORES=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "?")
_hw_ok "CPU: ${CPU_MODEL} (${CPU_CORES} cores)"

# SIMD flags
if uname -m | grep -q "aarch64\|arm"; then
    SIMD=$(grep -m1 "Features" /proc/cpuinfo | grep -woiE "neon|asimd|sve|sve2|fp16|bf16" | sort -u | tr '\n' ' ' 2>/dev/null || true)
else
    SIMD=$(grep -m1 "^flags" /proc/cpuinfo | grep -woiE "avx512f|avx2|avx|sse4_2|sse4_1|fma" | sort -u | tr '\n' ' ' 2>/dev/null || true)
fi
[ -n "$SIMD" ] && _hw_detail "    SIMD: ${SIMD^^}"

# RAM
if [ -f /proc/meminfo ]; then
    TOT_KB=0 AV_KB=0   # MemAvailable is absent on pre-3.14 kernels/cgroup views
    while read -r key val _; do
        case "$key" in MemTotal:) TOT_KB="$val" ;; MemAvailable:) AV_KB="$val" ;; esac
    done < /proc/meminfo
    PCT=$(( (TOT_KB - AV_KB) * 100 / (TOT_KB > 0 ? TOT_KB : 1) ))
    MSG="RAM: $((TOT_KB/1048576)).$((TOT_KB%1048576*10/1048576)) GB total, $((AV_KB/1048576)) GB free (${PCT}% used)"
    if   [ "$PCT" -ge 90 ]; then _hw_err "$MSG — OOM risk"
    elif [ "$PCT" -ge 75 ]; then _hw_warn "$MSG"
    else _hw_ok "$MSG"; fi
fi

# Disk
while read -r _ _ _ free pct mount; do
    [[ "$pct" == *%* ]] || continue
    n="${pct%\%}"
    if   [ "$n" -ge 95 ] 2>/dev/null; then _hw_err  "Disk ${mount}: ${pct} used (${free} free) — CRITICAL"
    elif [ "$n" -ge 80 ] 2>/dev/null; then _hw_warn "Disk ${mount}: ${pct} used (${free} free)"
    else _hw_detail "    Disk ${mount}: ${pct} used (${free} free)"; fi
done < <(df -h / "${WS_ROOT}" 2>/dev/null | awk 'NR>1' | sort -u)

# =============================================================================
# [2/6] Network & ROS
# =============================================================================
_hw_section "2/6 Network & ROS"

# `read` returns 1 on EOF; under `set -e` an unguarded read of empty output
# aborts the whole diagnostic silently. Every read below is guarded with `|| true`.
read -r IP_ADDR _ < <(hostname -I 2>/dev/null || true) || true
[ -n "${IP_ADDR:-}" ] && _hw_detail "    IP: $IP_ADDR" || _hw_detail "    IP: Not detected"

# MTU check
while read -r iface mtu; do
    [ "$mtu" -lt 1500 ] 2>/dev/null && _hw_warn "MTU: ${iface} = ${mtu} (below 1500 — may affect sensor streams)" \
        || _hw_detail "    ${iface}: MTU ${mtu}"
done < <(ip link show 2>/dev/null | awk '/^[0-9]+:/{iface=$2} /mtu/{for(i=1;i<=NF;i++) if($i=="mtu") print substr(iface,1,length(iface)-1), $(i+1)}' | grep -v "^lo ")

# Clock sync. timedatectl fails inside a container (no systemd bus), and under
# pipefail an unguarded assignment aborts the whole scan — hence `|| true`.
SYNC=""
if command -v timedatectl >/dev/null 2>&1; then
    SYNC=$(timedatectl status 2>/dev/null | awk -F: '/synchronized/{gsub(/ /,"",$2); print $2}' || true)
fi
if [ -n "$SYNC" ]; then
    [ "$SYNC" = "yes" ] && _hw_ok "Clock: synchronized" || _hw_err "Clock: NOT synchronized (run: sudo hwclock -s)"
elif command -v chronyc >/dev/null 2>&1 && chronyc tracking 2>/dev/null | grep -q "System time"; then
    _hw_ok "Clock: chrony active"
else
    _hw_skip "Clock: not verifiable here (no systemd bus / chrony inside containers)"
fi

# ROS
# ROS_DISTRO reaches every service through compose, so its presence proves
# nothing — only an installed distro does.
if [ ! -d "/opt/ros/${ROS_DISTRO:-}" ]; then
    _hw_skip "ROS: not installed in this image${ROS_DISTRO:+ (ROS_DISTRO=${ROS_DISTRO} comes from compose)}"
elif [ -n "${ROS_DISTRO:-}" ]; then
    case "$ROS_DISTRO" in noetic) ROS_VER="ROS 1" ;; *) ROS_VER="ROS 2" ;; esac
    _hw_ok "ROS: ${ROS_VER} ${ROS_DISTRO}"
    if [ "$ROS_VER" = "ROS 1" ]; then
        [ -z "${ROS_MASTER_URI:-}" ] && _hw_err "ROS_MASTER_URI not set — roscore will not start" \
            || _hw_detail "    Master: ${ROS_MASTER_URI}"
    else
        _hw_detail "    RMW: ${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp (default)}"
        _hw_detail "    Domain ID: ${ROS_DOMAIN_ID:-0}"
        [ "${ROS_LOCALHOST_ONLY:-0}" = "1" ] && _hw_warn "ROS_LOCALHOST_ONLY=1 (multi-machine discovery disabled)"
    fi
else
    _hw_detail "    ROS: not set"
fi

# =============================================================================
# [3/6] GPU Acceleration
# =============================================================================
_hw_section "3/6 GPU Acceleration"

GPU_FOUND=false
[ -e "/dev/nvidiactl" ]             && GPU_FOUND=true && _hw_ok "/dev/nvidiactl (NVIDIA)"
[ -e "/dev/dxg" ]                   && GPU_FOUND=true && _hw_ok "/dev/dxg (WSL2 D3D12)"
compgen -G "/dev/nvhost-*" >/dev/null 2>&1 && GPU_FOUND=true && _hw_ok "Tegra GPU nodes detected"

if [ -d "/dev/dri" ]; then
    # A /dev/dri without render nodes is normal (e.g. card0-only); `ls` would
    # fail the pipeline and abort under `set -o pipefail`.
    DRI=$(list_glob_basenames "/dev/dri/renderD*" 2>/dev/null || true)
    [ -n "$DRI" ] && GPU_FOUND=true && _hw_ok "/dev/dri (${DRI})"
    DRM_DRV="$(get_drm_driver 2>/dev/null || true)"
    [ -n "$DRM_DRV" ] && _hw_detail "    DRM driver: ${DRM_DRV}"
fi
if ! $GPU_FOUND; then
    # Docker Desktop (macOS / Windows non-WSL) runs a linuxkit VM with no GPU
    # passthrough at all — that is a platform ceiling, not a misconfiguration,
    # so report it as such instead of as a fault the user could fix.
    if uname -r 2>/dev/null | grep -qi "linuxkit"; then
        _hw_skip "GPU: none — Docker Desktop VM has no GPU passthrough (expected)"
        _hw_detail "      Apple Silicon: Metal/MPS is unavailable inside Linux containers."
        _hw_detail "      For MPS-accelerated PyTorch, run natively on macOS (uv venv on the host)."
        _hw_detail "      The container remains fully usable for CPU builds, ROS and CI."
    elif [ "${GPU_MODE:-auto}" = "cpu" ]; then
        # cpu is a first-class, documented mode (CI runners, GPU-less servers):
        # reporting the absence as an ERROR would fail `hwcheck` by design.
        _hw_skip "GPU: none — GPU_MODE=cpu (expected)"
    else
        _hw_warn "No GPU device nodes found (/dev/nvidiactl, /dev/dri, /dev/dxg)"
        _hw_detail "      Set GPU_MODE=cpu for a GPU-less host, or check the driver / device passthrough."
    fi
fi

if command -v nvidia-smi >/dev/null 2>&1; then
    # A driverless/stub nvidia-smi (common on WSL2) prints nothing — guard the read.
    GPU_NAME=""; GPU_MEM=""
    IFS=, read -r GPU_NAME GPU_MEM < <(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1) || true
    GPU_NAME="${GPU_NAME//  / }"; GPU_NAME="${GPU_NAME# }"; GPU_MEM="${GPU_MEM// /}"
    [ -n "${GPU_NAME:-}" ] && _hw_ok "NVIDIA: ${GPU_NAME} ($((${GPU_MEM:-0}/1024)) GB VRAM)"
fi
if command -v rocm-smi >/dev/null 2>&1 || [ -d "/opt/rocm" ]; then
    ROCM_VER=$(cat /opt/rocm/.info/version 2>/dev/null || echo "detected")
    _hw_ok "AMD ROCm: $ROCM_VER"
fi

# =============================================================================
# [4/6] Display & GUI
# =============================================================================
_hw_section "4/6 Display & GUI"

if [ -n "${DISPLAY:-}" ]; then
    NUM="${DISPLAY#:}"; NUM="${NUM%%.*}"
    [ -S "/tmp/.X11-unix/X${NUM}" ] && _hw_ok "X11: ${DISPLAY}" || _hw_warn "X11: DISPLAY=${DISPLAY} but socket not found"
    XAUTH="${XAUTHORITY:-$HOME/.Xauthority}"
    [ -s "$XAUTH" ] && _hw_ok "Xauthority: $XAUTH" || _hw_warn "Xauthority missing ($XAUTH) — run: make xauth"
else
    _hw_skip "X11: DISPLAY not set"
fi

[ -n "${WAYLAND_DISPLAY:-}" ] && _hw_ok "Wayland: ${WAYLAND_DISPLAY}" || _hw_skip "Wayland: not set"
[ -n "${XDG_RUNTIME_DIR:-}" ] && _hw_detail "    XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR}" || _hw_skip "XDG_RUNTIME_DIR: not set"

# Rendering stack: OpenGL/GLX, EGL and Vulkan. Probes come from util_gpu_detect.sh
# (timeout-guarded) so a set-but-unreachable DISPLAY cannot hang the diagnostic.
GL_RENDERER=""; GL_MESA=""; GL_ACCEL=""
while IFS='=' read -r k v; do
    case "$k" in gl_renderer) GL_RENDERER="$v" ;; gl_mesa) GL_MESA="$v" ;; gl_accelerated) GL_ACCEL="$v" ;; esac
done < <(probe_gl 2>/dev/null || true)

case "${GL_RENDERER,,}" in
    "")                    _hw_skip "OpenGL: no renderer reported (glxinfo missing, or DISPLAY unreachable)" ;;
    *llvmpipe*|*softpipe*|*swrast*)
        _hw_warn "OpenGL: ${GL_RENDERER} — SOFTWARE rendering (no GPU acceleration)" ;;
    *)                     _hw_ok   "OpenGL: ${GL_RENDERER}${GL_MESA:+ (Mesa ${GL_MESA})}${GL_ACCEL:+, accelerated=${GL_ACCEL}}" ;;
esac

# EGL is deliberately NOT probed here: eglinfo initializes every platform and
# costs ~1.8s, which would triple this scan. `gpus` reports the full stack.
if ! $BRIEF_MODE; then
    VK_DEVICE=""; VK_API=""
    while IFS='=' read -r k v; do
        case "$k" in vk_device) VK_DEVICE="$v" ;; vk_api) VK_API="$v" ;; esac
    done < <(probe_vulkan 2>/dev/null || true)
    [ -n "$VK_DEVICE" ] && _hw_ok "Vulkan: ${VK_DEVICE}${VK_API:+ (API ${VK_API})}" \
                        || _hw_skip "Vulkan: no device (vulkan-tools missing or no ICD)"

    while IFS='=' read -r n p; do [ -n "$n" ] && printf "    %-16s %s\n" "$n" "$p"; done < <(probe_gl_libs 2>/dev/null || true)
    _hw_detail "    Full GL/EGL/Vulkan/D3D12 stack: run 'gpus'"
fi

# =============================================================================
# [5/6] Identity & Permissions — the two most common container failures: a
# UID/GID mismatch against the bind mount, and missing video/render groups.
# =============================================================================
_hw_section "5/6 Identity & Permissions"

IS_CONTAINER=false; [ -f /.dockerenv ] && IS_CONTAINER=true
MY_UID="$(id -u)"; MY_GID="$(id -g)"
_hw_ok "User: $(id -un) (uid=${MY_UID} gid=${MY_GID}$([ "$IS_CONTAINER" = true ] && echo ", in container" || echo ", on host"))"
_hw_detail "    Groups: $(id -Gn 2>/dev/null | tr ' ' ',')"

# Bind-mount ownership: a mismatch is what produces "Permission denied" on writes.
for _p in "${WS_ROOT}" "${WS_ROOT}/build" "${WS_ROOT}/install" /cache; do
    [ -e "$_p" ] || continue
    _owner_uid="$(stat -c %u "$_p" 2>/dev/null || echo '?')"
    _owner_gid="$(stat -c %g "$_p" 2>/dev/null || echo '?')"
    if [ "$_owner_uid" = "$MY_UID" ]; then
        [ -w "$_p" ] && _hw_ok "$_p → ${_owner_uid}:${_owner_gid} (owned, writable)" \
                     || _hw_warn "$_p → ${_owner_uid}:${_owner_gid} (owned but NOT writable — check mode bits)"
    elif [ -w "$_p" ]; then
        _hw_detail "    $_p → ${_owner_uid}:${_owner_gid} (writable via group/other)"
    else
        _hw_err "$_p → owned by ${_owner_uid}:${_owner_gid}, you are ${MY_UID}:${MY_GID} — NOT writable"
        _hw_detail "      Fix: rebuild with HOST_UID/HOST_GID matching the host owner (make clean-cache && make build)"
    fi
done
unset _p _owner_uid _owner_gid

# GPU device access needs both the node and group membership.
for _dev in /dev/dri/renderD* /dev/dxg /dev/nvidiactl; do
    [ -e "$_dev" ] || continue
    _dev_grp="$(stat -c %G "$_dev" 2>/dev/null || echo '?')"
    if [ -r "$_dev" ] && [ -w "$_dev" ]; then
        _hw_ok "$_dev (group ${_dev_grp}, rw)"
    else
        _hw_err "$_dev (group ${_dev_grp}) is not accessible — add the container user to '${_dev_grp}'"
    fi
done
unset _dev _dev_grp

if [ "$IS_CONTAINER" = true ]; then
    _hw_detail "    CONTAINER_USER=${CONTAINER_USER:-unset}  HOME=${HOME:-unset}  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-unset}"
    [ "$MY_UID" = "0" ] && _hw_warn "Running as root inside the container — files created here will be root-owned on the host."
fi

# =============================================================================
# [6/6] Development Toolchain
# =============================================================================
_hw_section "6/6 Dev Toolchain"

SYS_PY="${SYS_PYTHON_EXE:-/usr/bin/python3}"
if [ -x "$SYS_PY" ]; then
    _hw_ok "Python: $($SYS_PY --version 2>&1) ($SYS_PY)"
else
    _hw_err "Python: not found at $SYS_PY"
fi

for tool in uv colcon rosdep ccache vcs; do
    if command -v "$tool" >/dev/null 2>&1; then
        _hw_ok "${tool}: $(${tool} --version 2>/dev/null | head -1 || echo 'found')"
    else
        _hw_skip "${tool}: not installed"
    fi
done

VENV="${VIRTUAL_ENV:-${WS_ROOT}/install/.venv}"
[ -d "$VENV" ] && _hw_ok "venv: $VENV" || _hw_detail "    venv: not yet created (run: mksync)"

# USB / Serial peripherals (ttyTHS* = Jetson onboard UART)
SERIAL=""
for pat in "/dev/ttyUSB*" "/dev/ttyACM*" "/dev/ttyTHS*"; do
    part=$(list_glob_basenames "$pat" 2>/dev/null || true)
    [ -n "$part" ] && SERIAL="${SERIAL}${SERIAL:+ }${part}"
done
[ -n "$SERIAL" ] && _hw_ok "Serial: $SERIAL" || _hw_skip "Serial: no /dev/ttyUSB*, ttyACM* or ttyTHS*"

# Cameras (v4l2-ctl adds device names when available)
CAMS=$(list_glob_basenames "/dev/video*" 2>/dev/null || true)
if [ -n "$CAMS" ]; then
    _hw_ok "Camera: $CAMS"
    command -v v4l2-ctl >/dev/null 2>&1 && \
        timeout 5 v4l2-ctl --list-devices 2>/dev/null | sed '/^$/d; s/^/    /' | head -8 || true
else
    _hw_skip "Camera: no /dev/video*"
fi

# Joysticks / gamepads
JOY=$(list_glob_basenames "/dev/input/js*" 2>/dev/null || true)
[ -n "$JOY" ] && _hw_ok "Joystick: $JOY" || _hw_skip "Joystick: no /dev/input/js*"

# SocketCAN — an interface that exists but is DOWN is the classic trap: the
# node opens the socket fine and simply never sees a frame.
if CAN_LINKS=$(ip -br link show type can 2>/dev/null) && [ -n "$CAN_LINKS" ]; then
    while read -r name state _; do
        if [ "$state" = "UP" ]; then
            _hw_ok "CAN: ${name} (UP)"
        else
            _hw_warn "CAN: ${name} is ${state} — bring it up: sudo ip link set ${name} up type can bitrate 500000"
        fi
    done <<< "$CAN_LINKS"
else
    _hw_skip "CAN: no SocketCAN interfaces"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
if   [ "$DIAG_ERRORS" -gt 0 ];   then echo -e "  \033[31mDiagnostics: ${DIAG_ERRORS} error(s), ${DIAG_WARNINGS} warning(s)\033[0m"
elif [ "$DIAG_WARNINGS" -gt 0 ]; then echo -e "  \033[33mDiagnostics: ${DIAG_WARNINGS} warning(s)\033[0m"
else echo -e "  \033[32mDiagnostics complete. All checks passed.\033[0m"; fi

echo -e "\n  Next: \033[36mmksync\033[0m (initialize) · \033[36mcbuild\033[0m (build) · \033[36mh\033[0m (help)"
exit $((DIAG_ERRORS > 0 ? 1 : 0))
