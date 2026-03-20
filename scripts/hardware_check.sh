#!/bin/bash
# =============================================================================
# scripts/hardware_check.sh
# 컨테이너 내부 하드웨어 가속 및 환경 진단 도구
#
# 체크 항목:
#   - GPU 렌더러 상태 (Hardware vs Software)
#   - OpenGL/Vulkan 드라이버 정보
#   - Python/uv 및 ccache 상태
#   - 주요 환경 변수 및 디바이스 노드(/dev) 접근성
# =============================================================================

# 로깅 유틸리티 로드
SOURCE_LOG="/docker_dev/scripts/utils_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║          ROS2 Docker Dev — Hardware Diagnostics              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# [1] 컨테이너 환경
# =============================================================================
echo -e "${BLUE}[1/6] Environment${NC}"
echo "    Kernel: $(uname -r)"
echo "    OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
echo "    ROS2: ${ROS_DISTRO:-not set}"
echo "    RMW: ${RMW_IMPLEMENTATION:-not set}"
echo "    GPU_MODE: ${GPU_MODE:-not set}"
echo "    CMAKE_CXX_STANDARD: ${CMAKE_CXX_STANDARD:-not set}"
echo "    UV_PYTHON: ${UV_PYTHON:-not set}"

# =============================================================================
# [2] GPU 디바이스
# =============================================================================
echo -e "\n${BLUE}[2/6] GPU Devices${NC}"

# NVIDIA
if [ -e "/dev/nvidiactl" ]; then
    echo -e "  ${GREEN}✓${NC} /dev/nvidiactl (NVIDIA GPU)"
fi
if [ -e "/dev/nvidia0" ]; then
    echo -e "  ${GREEN}✓${NC} /dev/nvidia0"
fi

# Intel/AMD (DRI)
if [ -d "/dev/dri" ]; then
    DRI_LIST=$(ls /dev/dri/renderD* 2>/dev/null | xargs -n1 basename | tr '\n' ' ')
    if [ -n "$DRI_LIST" ]; then
        echo -e "  ${GREEN}✓${NC} /dev/dri ($DRI_LIST)"
    fi
fi

# nvidia-smi (NVIDIA)
if command -v nvidia-smi &>/dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    if [ -n "$GPU_NAME" ]; then
        echo -e "  ${GREEN}✓${NC} NVIDIA: $GPU_NAME"
        # 툴킷 확인 (이미 실행 중이면 툴킷이 있는 것임)
        echo -e "    Status: NVIDIA Container Toolkit is active"
    fi
fi

# =============================================================================
# [3] OpenGL Renderer
# =============================================================================
echo -e "\n${BLUE}[3/6] OpenGL Renderer${NC}"
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo -e "  ${YELLOW}○${NC} No display set (DISPLAY/WAYLAND_DISPLAY). GUI apps disabled."
elif command -v glxinfo &>/dev/null; then
    GLX_OUT=$(glxinfo 2>/dev/null || true)
    if [ -n "$GLX_OUT" ]; then
        RENDERER=$(echo "$GLX_OUT" | grep "OpenGL renderer" | cut -d: -f2 | xargs)
        VENDOR=$(echo "$GLX_OUT" | grep "OpenGL vendor" | cut -d: -f2 | xargs)

        if [ -n "$RENDERER" ]; then
            if echo "$RENDERER" | grep -qi "llvmpipe"; then
                echo -e "  ${RED}⚠${NC} Renderer: $RENDERER ${RED}(Software — CPU Rendering)${NC}"
            else
                echo -e "  ${GREEN}✓${NC} Renderer: $RENDERER ${GREEN}(Hardware Accelerated)${NC}"
            fi
            echo "    Vendor: $VENDOR"
        else
            echo -e "  ${YELLOW}○${NC} No OpenGL renderer detected"
        fi
    else
        echo -e "  ${RED}✗${NC} Cannot connect to Display (Check xhost permissions)"
    fi
fi

# =============================================================================
# [4] Vulkan
# =============================================================================
echo -e "\n${BLUE}[4/6] Vulkan Support${NC}"
if command -v vulkaninfo &>/dev/null; then
    VK_GPU=$(vulkaninfo --summary 2>/dev/null | grep "deviceName" | head -1 | cut -d= -f2 | xargs)
    if [ -n "$VK_GPU" ]; then
        echo -e "  ${GREEN}✓${NC} Vulkan GPU: $VK_GPU"
    else
        echo -e "  ${YELLOW}⚠${NC} Vulkan installed but no GPU device found"
    fi
else
    echo "  ○ vulkaninfo not installed"
fi

# =============================================================================
# [5] Python / uv 환경
# =============================================================================
echo -e "\n${BLUE}[5/6] Python / uv Environment${NC}"
if command -v uv &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} uv: $(uv --version)"
    echo "    Python versions available:"
    uv python list 2>/dev/null | head -5 | sed 's/^/    /'
else
    echo -e "  ${RED}✗${NC} uv not found"
fi

if command -v python3 &>/dev/null; then
    echo "    System Python3: $(python3 --version)"
fi

# ccache
if command -v ccache &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} ccache: $(ccache --version | head -1)"
    CCACHE_STATS=$(ccache -s 2>/dev/null | grep "cache hit" | head -1)
    [ -n "$CCACHE_STATS" ] && echo "    $CCACHE_STATS"
fi

# =============================================================================
# [6] SocketCAN
# =============================================================================
echo -e "\n${BLUE}[6/6] SocketCAN${NC}"
if ip link show can0 >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} can0 interface available"
elif ip link show 2>/dev/null | grep -q "can"; then
    CAN_IFACES=$(ip link show 2>/dev/null | grep "can" | awk '{print $2}' | tr -d ':')
    echo -e "  ${GREEN}✓${NC} CAN interfaces: $CAN_IFACES"
else
    echo "  ○ No CAN interfaces found (normal if no robot hardware)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Diagnostics complete.${NC}"
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
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
