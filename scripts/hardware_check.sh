#!/bin/bash
# =============================================================================
# scripts/hardware_check.sh
# In-container hardware acceleration and environment diagnostic tool
#
# Usage: hardware_check.sh [--brief]
#   --brief   Compact output (warnings/errors only) for CI/CD pipelines.
#             Exit code: 0 = all pass, 1 = warnings, 2 = errors
#
# Output Strategy:
#   This script intentionally uses direct echo/printf for output rather than
#   the log_* API from utils_logging.sh. Diagnostic output requires section
#   headers, indented sub-items, and mixed inline coloring that don't conform
#   to the structured [TYPE] message format of log_*(). Only ANSI color
#   variables (RED, GREEN, YELLOW, BLUE, CYAN, NC) are imported.
#
# Sections:
#   [1/5] System & Storage    — OS, CPU, SIMD, RAM, Disk thresholds
#   [2/5] Network & Time Sync — IP, MTU, Clock sync, ROS context
#   [3/5] GPU Acceleration    — Hardware nodes, OpenGL, Vulkan
#   [4/5] Development Toolchain — uv, Python, ccache, CMake env
#   [5/5] I/O & Peripherals   — Video, Serial, CAN, Input
# =============================================================================

# --brief mode: compact warnings/errors only for CI/CD pipelines
BRIEF_MODE=false
[ "${1:-}" = "--brief" ] && BRIEF_MODE=true

# Load logging utility (color variables only — see Output Strategy above)
SOURCE_LOG="/docker_dev/scripts/utils_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"

# Fallback: ensure color variables exist even if utils_logging.sh is missing (P-9)
[ -z "${NC:-}" ] && RED='' GREEN='' YELLOW='' BLUE='' CYAN='' PURPLE='' NC=''

# Load shared GPU detection helpers (P-2)
SOURCE_GPU="/docker_dev/scripts/utils_gpu_detect.sh"
[ ! -f "$SOURCE_GPU" ] && SOURCE_GPU="$(dirname "${BASH_SOURCE[0]}")/utils_gpu_detect.sh"
[ -f "$SOURCE_GPU" ] && source "$SOURCE_GPU"

# --- Brief-mode output helpers & diagnostic counters (P-5) -------------------
DIAG_WARNINGS=0
DIAG_ERRORS=0
_hw_hdr()      { $BRIEF_MODE || echo -e "\n${BLUE}$1${NC}"; }
_hw_detail()   { $BRIEF_MODE || echo "$@"; }
_hw_detail_e() { $BRIEF_MODE || echo -e "$@"; }
_hw_printf()   { $BRIEF_MODE || printf "$@"; }
_hw_ok()       { $BRIEF_MODE || echo -e "  ${GREEN}✓${NC} $1"; }
_hw_warn()     { DIAG_WARNINGS=$((DIAG_WARNINGS + 1)); echo -e "  ${YELLOW}⚠${NC} $1"; }
_hw_err()      { DIAG_ERRORS=$((DIAG_ERRORS + 1)); echo -e "  ${RED}✗${NC} $1"; }
_hw_skip()     { $BRIEF_MODE || echo "  ○ $1"; }
# -----------------------------------------------------------------------------

if ! $BRIEF_MODE; then
    print_banner DIAG
fi

# =============================================================================
# [1/5] System & Storage
# =============================================================================
_hw_hdr "[1/5] System & Storage"

# Host/Virtualization Detection
if grep -qi "microsoft" /proc/version 2>/dev/null; then
    HOST_TYPE="WSL2"
elif [ -f /.dockerenv ]; then
    HOST_TYPE="Docker"
    PRIVILEGED=$(cat /proc/self/status 2>/dev/null | grep "^CapEff:" | awk '{print $2}')
    [ "$PRIVILEGED" = "0000003fffffffff" ] && HOST_TYPE="Docker (privileged)"
else
    HOST_TYPE="Native/BareMetal"
fi

_hw_detail "    Kernel: $(uname -r)"
_hw_detail "    OS:     $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
_hw_detail "    Arch:   $(uname -m)"
_hw_detail "    Host:   $HOST_TYPE"

# CPU Info
CPU_MODEL=$(lscpu 2>/dev/null | grep "Model name" | cut -d: -f2 | xargs \
    || grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs \
    || echo "Unknown CPU")
CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
_hw_detail "    CPU:    $CPU_MODEL ($CPU_CORES cores)"

# SIMD Features (P-4: architecture-aware detection)
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "armv8l" ]; then
    # ARM: Features field with NEON/SVE/crypto extensions
    SIMD_FLAGS=$(grep -m1 "Features" /proc/cpuinfo \
        | grep -woiE "neon|asimd|sve|sve2|fp16|bf16|i8mm|dotprod|aes|sha1|sha2|crc32|atomics" \
        | sort -u | tr '\n' ' ' | xargs 2>/dev/null || true)
else
    # x86: flags field with AVX/SSE extensions
    SIMD_FLAGS=$(grep -m1 "flags" /proc/cpuinfo \
        | grep -woiE "sse4_1|sse4_2|avx|avx2|avx512f|avx512bw|avx512cd|avx512dq|avx512er|avx512ifma|avx512pf|avx512vbmi|avx512vl|avx_vnni|fma" \
        | sort -u | tr '\n' ' ' | xargs 2>/dev/null || true)
fi
[ -n "$SIMD_FLAGS" ] && _hw_detail "    SIMD:   ${SIMD_FLAGS^^}"

# RAM — Total and Available with threshold warning
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
MEM_AVAIL_KB=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')
if [ -n "$MEM_TOTAL_KB" ] && [ -n "$MEM_AVAIL_KB" ]; then
    MEM_TOTAL=$(awk "BEGIN {printf \"%.1f GB\", $MEM_TOTAL_KB/1024/1024}")
    MEM_AVAIL=$(awk "BEGIN {printf \"%.1f GB\", $MEM_AVAIL_KB/1024/1024}")
    MEM_USED_PCT=$(awk "BEGIN {printf \"%d\", (1 - $MEM_AVAIL_KB/$MEM_TOTAL_KB)*100}")
    if [ "$MEM_USED_PCT" -ge 90 ]; then
        _hw_warn "RAM: $MEM_TOTAL total, $MEM_AVAIL free (${MEM_USED_PCT}% used — OOM risk)"
    elif [ "$MEM_USED_PCT" -ge 75 ]; then
        _hw_warn "RAM: $MEM_TOTAL total, $MEM_AVAIL free (${MEM_USED_PCT}% used)"
    else
        _hw_detail "    RAM:    $MEM_TOTAL total, $MEM_AVAIL free"
    fi
else
    MEM_TOTAL=$(free -h 2>/dev/null | awk '/^Mem:|^메모리:/ {print $2}' || echo "N/A")
    _hw_detail "    RAM:    $MEM_TOTAL"
fi

# Disk Usage — with threshold-based coloring
$BRIEF_MODE || echo "    Disk:"
while IFS= read -r line; do
    used_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')
    used=$(echo "$line" | awk '{print $5}')
    free_space=$(echo "$line" | awk '{print $4}')
    if [ "$used_pct" -ge 95 ] 2>/dev/null; then
        _hw_err "Disk ${mount}: ${used} used (${free_space} free) — CRITICAL"
    elif [ "$used_pct" -ge 80 ] 2>/dev/null; then
        _hw_warn "Disk ${mount}: ${used} used (${free_space} free)"
    else
        _hw_printf "      %-10s %s used (%s free)\n" "$mount:" "$used" "$free_space"
    fi
done < <(df -h / /workspace 2>/dev/null | awk 'NR>1' | sort -u)

# =============================================================================
# [2/5] Network & Time Sync
# =============================================================================
_hw_hdr "[2/5] Network & Time Sync"

# IP Address
IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -n "$IP_ADDR" ]; then
    _hw_detail "    IP:         $IP_ADDR"
else
    _hw_detail_e "    IP:         ${YELLOW}Not detected${NC}"
fi

# MTU per interface — warn if low (< 1500 common default; Jumbo Frame = 9000)
_hw_detail "    Interfaces:"
while read -r iface rest; do
    [ -z "$iface" ] && continue
    mtu=$(echo "$rest" | grep -oP 'mtu \K[0-9]+')
    iface_clean="${iface%:}"
    if [ -n "$mtu" ]; then
        if [ "$mtu" -lt 1500 ] 2>/dev/null; then
            _hw_warn "MTU: ${iface_clean} MTU ${mtu} (below standard 1500 — may affect sensor streams)"
        else
            _hw_detail "      ${iface_clean}: MTU ${mtu}"
        fi
    fi
done < <(ip addr show 2>/dev/null | awk '/^[0-9]+:/{iface=$2} /mtu/{print iface, $0}' | grep -v "^lo")

# Clock Sync — critical for multi-device ROS TF (H-1 fix: pattern match instead of echo|grep)
if [[ "$HOST_TYPE" == *"Docker"* ]]; then
    if command -v chronyc >/dev/null 2>&1; then
        TRACKING=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4, $5}')
        if [ -n "$TRACKING" ]; then
            _hw_ok "Clock Sync: chrony active (offset: $TRACKING)"
        else
            _hw_skip "Clock Sync: chrony present but no data"
        fi
    elif command -v ntpq >/dev/null 2>&1; then
        NTP_SYNC=$(ntpq -pn 2>/dev/null | grep -E "^\*" | head -1)
        if [ -n "$NTP_SYNC" ]; then
            _hw_ok "Clock Sync: ntpq active"
        else
            _hw_skip "Clock Sync: Cannot determine (container env — check host NTP)"
        fi
    else
        _hw_skip "Clock Sync: Not verifiable inside container (host NTP assumed)"
    fi
elif command -v timedatectl >/dev/null 2>&1; then
    TD_OUT=$(timedatectl status 2>/dev/null)
    SYNC_STATUS=$(echo "$TD_OUT" | grep -i "System clock synchronized" | cut -d: -f2 | xargs)
    NTP_SERVICE=$(echo "$TD_OUT" | grep -i "NTP service" | cut -d: -f2 | xargs)
    if [ "$SYNC_STATUS" = "yes" ]; then
        _hw_ok "Clock Sync: synchronized"
    else
        _hw_err "Clock Sync: NOT synchronized"
        _hw_detail_e "    ${YELLOW}→ TF timestamp errors may occur.${NC}"
        _hw_detail_e "    ${YELLOW}  Run: sudo systemctl restart systemd-timesyncd${NC}"
    fi
    [ -n "$NTP_SERVICE" ] && _hw_detail "    NTP:        $NTP_SERVICE"
else
    _hw_skip "Clock Sync: Cannot determine (no timedatectl/chronyc/ntpq)"
fi

# --- ROS Context ---
if [ -n "$ROS_DISTRO" ]; then
    if [[ "$ROS_DISTRO" =~ ^(noetic|melodic|kinetic|lunar|indigo|jade|groovy|hydro|fuerte)$ ]]; then
        ROS_VER="ROS 1"
    else
        ROS_VER="ROS 2"
    fi
    _hw_detail "    $ROS_VER:       $ROS_DISTRO"

    if [ "$ROS_VER" = "ROS 1" ]; then
        if [ -z "${ROS_MASTER_URI}" ]; then
            _hw_err "Master: not set — roscore will not start"
        else
            _hw_detail "    Master:     $ROS_MASTER_URI"
        fi
        [ -n "$ROS_HOSTNAME" ] && _hw_detail "    Hostname:   $ROS_HOSTNAME"
        [ -n "$ROS_IP" ]       && _hw_detail "    ROS_IP:     $ROS_IP"
    else
        if [ -z "${RMW_IMPLEMENTATION}" ]; then
            _hw_detail_e "    RMW:        ${YELLOW}not set (defaulting to rmw_fastrtps_cpp)${NC}"
        else
            _hw_detail "    RMW:        $RMW_IMPLEMENTATION"
        fi
        _hw_detail "    Domain ID:  ${ROS_DOMAIN_ID:-0}"
        if [ "${ROS_LOCALHOST_ONLY:-0}" = "1" ]; then
            _hw_warn "ROS: ROS_LOCALHOST_ONLY=1 (multi-machine discovery disabled)"
        fi
    fi
else
    _hw_detail_e "    ROS:        ${YELLOW}not set${NC}"
fi

# =============================================================================
# [3/5] GPU Acceleration
# =============================================================================
_hw_hdr "[3/5] GPU Acceleration"

GPU_FOUND=false

# NVIDIA — kernel device node (P-2: prefer shared helper)
if type has_nvidia &>/dev/null && has_nvidia; then
    GPU_FOUND=true
    _hw_ok "/dev/nvidiactl (NVIDIA)"
elif [ -e "/dev/nvidiactl" ]; then
    GPU_FOUND=true
    _hw_ok "/dev/nvidiactl (NVIDIA)"
fi

# DRI — Intel / AMD / Mesa
if [ -d "/dev/dri" ]; then
    DRI_LIST=$(ls /dev/dri/renderD* 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')
    if [ -n "$DRI_LIST" ]; then
        GPU_FOUND=true
        _hw_ok "/dev/dri ($DRI_LIST)"
    fi
fi

# Jetson / Tegra — embedded NVIDIA without nvidiactl (P-2)
if type has_tegra &>/dev/null && has_tegra; then
    GPU_FOUND=true
    TEGRA_DEVS=$(ls /dev/nvhost-* 2>/dev/null | xargs -n1 basename | tr '\n' ' ')
    _hw_ok "Tegra GPU nodes: $TEGRA_DEVS"
elif ls /dev/nvhost-* 2>/dev/null | grep -q .; then
    GPU_FOUND=true
    TEGRA_DEVS=$(ls /dev/nvhost-* 2>/dev/null | xargs -n1 basename | tr '\n' ' ')
    _hw_ok "Tegra GPU nodes: $TEGRA_DEVS"
fi

if ! $GPU_FOUND; then
    _hw_err "No GPU device nodes found (/dev/nvidiactl, /dev/dri, /dev/nvhost-*)"
fi

# NVIDIA nvidia-smi
if command -v nvidia-smi &>/dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [ -n "$GPU_NAME" ]; then
        MEM_GB=$(awk "BEGIN {printf \"%.0f GB\", ${GPU_MEM:-0}/1024}" 2>/dev/null || echo "${GPU_MEM} MiB")
        _hw_ok "NVIDIA: $GPU_NAME ($MEM_GB)"
    fi
fi

# AMD ROCm (P-2)
if type has_rocm &>/dev/null && has_rocm; then
    if command -v rocm-smi &>/dev/null; then
        AMD_GPU=$(rocm-smi --showproductname 2>/dev/null | grep -i "card\|gpu" | head -1 | xargs)
        [ -n "$AMD_GPU" ] \
            && _hw_ok "AMD:    $AMD_GPU" \
            || _hw_ok "AMD:    ROCm detected (rocm-smi present)"
    elif [ -d "/opt/rocm" ]; then
        ROCM_VER=$(cat /opt/rocm/.info/version 2>/dev/null || echo "unknown")
        _hw_ok "AMD:    ROCm $ROCM_VER (/opt/rocm)"
    fi
elif command -v rocm-smi &>/dev/null; then
    _hw_ok "AMD:    ROCm detected (rocm-smi present)"
elif [ -d "/opt/rocm" ]; then
    ROCM_VER=$(cat /opt/rocm/.info/version 2>/dev/null || echo "unknown")
    _hw_ok "AMD:    ROCm $ROCM_VER (/opt/rocm)"
fi

# OpenGL — GPU_MODE-aware interpretation (P-6: added else branch for missing glxinfo)
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    _hw_skip "OpenGL: No display set (DISPLAY/WAYLAND_DISPLAY)"
elif command -v glxinfo &>/dev/null; then
    GLX_OUT=$(glxinfo 2>/dev/null || true)
    if [ -n "$GLX_OUT" ]; then
        RENDERER=$(echo "$GLX_OUT" | grep "OpenGL renderer" | cut -d: -f2 | xargs)
        VENDOR=$(echo "$GLX_OUT" | grep "OpenGL vendor" | cut -d: -f2 | xargs)
        GL_VER=$(echo "$GLX_OUT" | grep "OpenGL version string" | cut -d: -f2 | xargs)
        if echo "$RENDERER" | grep -qi "llvmpipe"; then
            if [[ "${GPU_MODE:-auto}" =~ ^(cpu|software)$ ]]; then
                _hw_skip "OpenGL: $RENDERER (Software — GPU_MODE=${GPU_MODE}, expected)"
            else
                _hw_warn "OpenGL: $RENDERER (Software Rendering — performance impact)"
                _hw_detail_e "    ${YELLOW}→${NC} GPU_MODE=${GPU_MODE:-auto}. Run 'gpu_setup' or check GPU drivers."
            fi
        else
            _hw_ok "OpenGL: $RENDERER ${GREEN}(Hardware Accelerated)${NC}"
        fi
        _hw_detail "    Vendor:  $VENDOR"
        [ -n "$GL_VER" ] && _hw_detail "    GL Ver:  $GL_VER"
    else
        _hw_err "OpenGL: Display connection failed"
        _hw_detail_e "    ${YELLOW}→${NC} On host: xhost +local:root"
    fi
else
    # P-6: Explicit message when glxinfo is not installed but display is set
    _hw_skip "OpenGL: glxinfo not installed (apt: mesa-utils)"
fi

# Vulkan — name + API version
if command -v vulkaninfo &>/dev/null; then
    VK_OUT=$(vulkaninfo --summary 2>/dev/null || true)
    VK_GPU=$(echo "$VK_OUT" | grep "deviceName" | head -1 | cut -d= -f2 | xargs)
    VK_API=$(echo "$VK_OUT" | grep "apiVersion" | head -1 | cut -d= -f2 | xargs)
    if [ -n "$VK_GPU" ]; then
        _hw_ok "Vulkan:  $VK_GPU"
        [ -n "$VK_API" ] && _hw_detail "    API:     $VK_API"
    else
        _hw_warn "Vulkan: Installed but no device found"
    fi
else
    _hw_skip "Vulkan: vulkaninfo not installed"
fi

# =============================================================================
# [4/5] Development Toolchain
# =============================================================================
_hw_hdr "[4/5] Development Toolchain"

# Build env variables
if [ -z "${CMAKE_CXX_STANDARD:-}" ]; then
    _hw_warn "CMAKE_CXX_STANDARD: not set (may cause build failures)"
else
    _hw_detail "    CMAKE_CXX_STANDARD: ${CMAKE_CXX_STANDARD}"
fi
[ -n "${GPU_MODE:-}" ]   && _hw_detail "    GPU_MODE:           ${GPU_MODE}"
[ -n "${UV_PYTHON:-}" ]  && _hw_detail "    UV_PYTHON:          ${UV_PYTHON}"

# uv + active venv
if command -v uv &>/dev/null; then
    _hw_ok "uv:      $(uv --version)"
    ACTIVE_VENV="${VIRTUAL_ENV:-${UV_PROJECT_ENVIRONMENT:-}}"
    if [ -n "$ACTIVE_VENV" ] && [ -d "$ACTIVE_VENV" ]; then
        _hw_detail "    venv:    $ACTIVE_VENV"
    else
        _hw_detail_e "    venv:    ${YELLOW}No active virtualenv detected${NC}"
    fi
    _hw_detail "    Python versions (uv):"
    if ! $BRIEF_MODE; then
        uv python list 2>/dev/null | head -3 | sed 's/^/      /'
    fi
else
    _hw_err "uv: Not found"
fi

# System Python
command -v python3 &>/dev/null && _hw_detail "    Python3: $(python3 --version)"

# ccache with hit rate calculation (P-7: JSON-first with whitespace tolerance)
# Parsing strategy: try JSON format first (ccache ≥4.0, stable schema),
# then fall back to legacy text parsing for older versions.
if command -v ccache &>/dev/null; then
    CCACHE_VER=$(ccache --version | head -1)
    _hw_ok "ccache: $CCACHE_VER"
    HITS=""
    MISSES=""
    # JSON-first: ccache ≥4.0 supports --show-stats --format=json
    if ccache --show-stats --format=json &>/dev/null 2>&1; then
        JSON_STATS=$(ccache --show-stats --format=json 2>/dev/null)
        # P-7: whitespace-tolerant parsing for pretty-printed JSON
        HITS=$(echo "$JSON_STATS" | grep -oP '"direct_cache_hit"\s*:\s*\K[0-9]+' || true)
        MISSES=$(echo "$JSON_STATS" | grep -oP '"cache_miss"\s*:\s*\K[0-9]+' || true)
    fi
    # Fallback: ccache ≤3.x text format
    if [ -z "$HITS" ] || [ -z "$MISSES" ]; then
        STATS=$(ccache -s 2>/dev/null)
        HITS=$(echo "$STATS" | grep -E "^cache hit \(direct\)" | awk '{print $NF}' | tr -d ',')
        MISSES=$(echo "$STATS" | grep -E "^cache miss" | awk '{print $NF}' | tr -d ',')
    fi
    if [ -n "$HITS" ] && [ -n "$MISSES" ]; then
        TOTAL=$((HITS + MISSES))
        if [ "$TOTAL" -gt 0 ]; then
            HIT_RATE=$(awk "BEGIN {printf \"%d\", ($HITS/$TOTAL)*100}")
            if [ "$HIT_RATE" -ge 70 ]; then
                _hw_detail_e "    Hit rate: ${GREEN}${HIT_RATE}%${NC} (${HITS} hits / ${TOTAL} total)"
            elif [ "$HIT_RATE" -ge 30 ]; then
                _hw_detail_e "    Hit rate: ${YELLOW}${HIT_RATE}%${NC} (${HITS} hits / ${TOTAL} total)"
            else
                _hw_warn "ccache hit rate: ${HIT_RATE}% — cache warming up or misses high"
            fi
        fi
    fi
fi

# =============================================================================
# [5/5] I/O & Peripherals
# =============================================================================
_hw_hdr "[5/5] I/O & Peripherals"

# Video Devices (Cameras) — safe glob handling via process substitution
VIDEO_FOUND=false
if compgen -G "/dev/video*" > /dev/null 2>&1; then
    while IFS= read -r vdev; do
        VIDEO_FOUND=true
        if command -v v4l2-ctl &>/dev/null; then
            DEV_NAME=$(v4l2-ctl --device="$vdev" --info 2>/dev/null | grep "Card type" | cut -d: -f2 | xargs)
            [ -n "$DEV_NAME" ] \
                && _hw_ok "Video:  $vdev — $DEV_NAME" \
                || _hw_ok "Video:  $vdev"
        else
            _hw_ok "Video:  $vdev"
        fi
    done < <(ls /dev/video* 2>/dev/null)
fi
if ! $VIDEO_FOUND; then
    _hw_skip "Video:  No devices (/dev/video*)"
fi

# Serial/Controller Devices
SERIAL_DEVICES=$(ls /dev/ttyUSB* /dev/ttyACM* /dev/ttyTHS* 2>/dev/null | xargs 2>/dev/null)
if [ -n "$SERIAL_DEVICES" ]; then
    _hw_ok "Serial: $SERIAL_DEVICES"
else
    _hw_skip "Serial: No devices (/dev/ttyUSB*, /dev/ttyACM*, /dev/ttyTHS*)"
fi

# Input Devices (Joysticks)
INPUT_DEVICES=$(ls /dev/input/js* 2>/dev/null | xargs 2>/dev/null)
[ -n "$INPUT_DEVICES" ] && _hw_ok "Input:  $INPUT_DEVICES"

# SocketCAN — detect interface and check link state (P-8: use `ip link show type can`)
CAN_FOUND=false
if ip link show type can 2>/dev/null | grep -q .; then
    while IFS= read -r can_iface; do
        [ -z "$can_iface" ] && continue
        CAN_FOUND=true
        if ip link show "$can_iface" 2>/dev/null | grep -q "UP"; then
            _hw_ok "CAN:    $can_iface ${GREEN}(UP)${NC}"
        else
            _hw_warn "CAN: $can_iface (DOWN — run: ip link set $can_iface up)"
        fi
    done < <(ip link show type can 2>/dev/null | awk -F': ' '/^[0-9]+:/{print $2}' | awk '{print $1}')
fi
if ! $CAN_FOUND; then
    _hw_skip "CAN:    No interfaces found"
fi

# =============================================================================
# Summary (P-5: exit code support for --brief mode)
# =============================================================================
if $BRIEF_MODE; then
    echo ""
    echo "--- Diagnostics: ${DIAG_ERRORS} error(s), ${DIAG_WARNINGS} warning(s)"
    [ "$DIAG_ERRORS" -gt 0 ] && exit 2
    [ "$DIAG_WARNINGS" -gt 0 ] && exit 1
    exit 0
fi

echo ""
if [ "$DIAG_ERRORS" -gt 0 ]; then
    echo -e "${RED}Diagnostics complete: ${DIAG_ERRORS} error(s), ${DIAG_WARNINGS} warning(s)${NC}"
elif [ "$DIAG_WARNINGS" -gt 0 ]; then
    echo -e "${YELLOW}Diagnostics complete: ${DIAG_WARNINGS} warning(s)${NC}"
else
    echo -e "${GREEN}Diagnostics complete. All checks passed.${NC}"
fi
echo ""
echo "Quick commands:"
echo "  gpu_status       — Detailed GPU & Display info"
echo "  gpu_check        — OpenGL renderer info (glxinfo)"
echo "  gpu_test         — Quick performance test (glxgears)"
echo "  vulkan_check     — Vulkan device info"
echo "  gpu_setup        — Auto-configure GPU mode"
echo "  use_cpu/nvidia   — Force Software / NVIDIA rendering"
echo "  use_intel/amd    — Force Intel / AMD Mesa rendering"
echo "  mkenv / activate — Create & Activate Python venv"
echo "  cb / cbm / cbr   — colcon build (standard / metas / release)"
echo "  ccache-stat      — Show compiler cache statistics"
