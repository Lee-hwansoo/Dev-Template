#!/bin/bash
# =============================================================================
# scripts/gpu_setup.sh
# GPU 하드웨어 가속 환경 자동 감지 및 설정 스위칭
#
# 지원 장치: NVIDIA, Intel, AMD, CPU(Software)
# 특징:
#   - Wayland/X11 디스플레이 자동 대응
#   - NVIDIA 하이브리드 그래픽(PRIME) 최적화 설정
#   - 가속 실패 시 소프트웨어 렌더링(llvmpipe) 자동 전환
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_PREFIX="[GPU]"
log_info()  { echo -e "${BLUE}${LOG_PREFIX}${NC} $1"; }
log_ok()    { echo -e "${GREEN}${LOG_PREFIX}${NC} ✓ $1"; }
log_warn()  { echo -e "${YELLOW}${LOG_PREFIX}${NC} ⚠ $1"; }

# =============================================================================
# Detection Helpers
# =============================================================================
has_nvidia() {
    [ -e /dev/nvidiactl ] && command -v nvidia-smi >/dev/null 2>&1
}

# 디스플레이 서버 정밀 감지
detect_display_server() {
    if [ -n "$WAYLAND_DISPLAY" ]; then
        if [ "$XDG_SESSION_TYPE" = "x11" ] || [ -n "$DISPLAY" ]; then
            echo "XWayland"
        else
            echo "Wayland"
        fi
    elif [ -n "$DISPLAY" ]; then
        echo "X11"
    else
        echo "None"
    fi
}

# Intel 벤더 ID: 0x8086
has_intel_dri() {
    [ -d /dev/dri ] && grep -rl "0x8086" /sys/class/drm/*/device/vendor 2>/dev/null | grep -q .
}

# AMD 벤더 ID: 0x1002
has_amd_dri() {
    [ -d /dev/dri ] && grep -rl "0x1002" /sys/class/drm/*/device/vendor 2>/dev/null | grep -q .
}

# 제조사 불명 DRI 장치 (Intel/AMD 감지 불가 시 fallback)
has_any_dri() {
    [ -d /dev/dri ] && ls /dev/dri/renderD* >/dev/null 2>&1
}

# =============================================================================
# Reset
# =============================================================================
reset_gpu_env() {
    unset MESA_LOADER_DRIVER_OVERRIDE
    unset GALLIUM_DRIVER
    unset LIBGL_ALWAYS_SOFTWARE
    unset __NV_PRIME_RENDER_OFFLOAD
    unset __GLX_VENDOR_LIBRARY_NAME
    unset MESA_D3D12_DEFAULT_ADAPTER_NAME
}

# =============================================================================
# GPU Setup Functions
# =============================================================================
write_gpu_env() {
    # root 사용자를 기본으로 하여 환경변수 기록
    cat > /root/.gpu_env.sh << EOF
# __GPU_ENV_START
export LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE:-0}
$([ -n "${GALLIUM_DRIVER:-}" ] && echo "export GALLIUM_DRIVER=${GALLIUM_DRIVER}")
$([ -n "${MESA_LOADER_DRIVER_OVERRIDE:-}" ] && echo "export MESA_LOADER_DRIVER_OVERRIDE=${MESA_LOADER_DRIVER_OVERRIDE}")
$([ -n "${__NV_PRIME_RENDER_OFFLOAD:-}" ] && echo "export __NV_PRIME_RENDER_OFFLOAD=${__NV_PRIME_RENDER_OFFLOAD}")
$([ -n "${__GLX_VENDOR_LIBRARY_NAME:-}" ] && echo "export __GLX_VENDOR_LIBRARY_NAME=${__GLX_VENDOR_LIBRARY_NAME}")
# __GPU_ENV_END
EOF
}

setup_nvidia() {
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=0
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __GLX_VENDOR_LIBRARY_NAME="nvidia"

    local ds=$(detect_display_server)
    log_info "Detected Display Server: $ds"

    # Wayland/XWayland 전용 NVIDIA 설정
    if [[ "$ds" == *"Wayland"* ]]; then
        export QT_QPA_PLATFORM="wayland;xcb"
        export GDK_BACKEND="wayland,x11"
        export GBM_BACKEND="nvidia-drm"
        export __GL_GSYNC_ALLOWED=0
        export __GL_VRR_ALLOWED=0
        log_ok "NVIDIA Wayland optimizations applied"
    fi

    write_gpu_env
    log_ok "NVIDIA GPU configured"
}

setup_intel() {
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=0
    export MESA_LOADER_DRIVER_OVERRIDE=iris
    write_gpu_env
    log_ok "Intel GPU configured (Mesa/iris driver)"
}

setup_amd() {
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=0
    export MESA_LOADER_DRIVER_OVERRIDE=radeonsi
    write_gpu_env
    log_ok "AMD GPU configured (Mesa/radeonsi driver)"
}

setup_software() {
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=1
    export GALLIUM_DRIVER="llvmpipe"
    write_gpu_env
    log_warn "Software rendering (CPU/llvmpipe) configured"
}

# =============================================================================
# Auto Detection
# =============================================================================
setup_auto() {
    local detected=false
    local ds=$(detect_display_server)

    if has_nvidia && has_intel_dri; then
        if [[ "$ds" == *"Wayland"* ]]; then
            log_warn "Auto-detected: Hybrid (Intel+NVIDIA) on Wayland."
            log_warn "Defaulting to Intel GPU for stability. Set GPU_MODE=nvidia in .env to override."
            setup_intel
        else
            setup_nvidia
            log_warn "Auto-detected: Hybrid (Intel+NVIDIA) on X11. Using NVIDIA PRIME."
        fi
        detected=true
    elif has_nvidia; then
        setup_nvidia
        log_ok "Auto-detected: NVIDIA GPU"
        detected=true
    elif has_intel_dri; then
        setup_intel
        log_ok "Auto-detected: Intel GPU"
        detected=true
    elif has_amd_dri; then
        setup_amd
        log_ok "Auto-detected: AMD GPU"
        detected=true
    elif has_any_dri; then
        reset_gpu_env
        export LIBGL_ALWAYS_SOFTWARE=0
        log_ok "Auto-detected: GPU (DRI/Mesa, driver auto-selected)"
        detected=true
    fi

    # 검증: 실제 렌더러가 동작하는지 확인 (DISPLAY가 있을 때만)
    if [ "$detected" = true ] && [ "$ds" != "None" ]; then
        if command -v glxinfo &>/dev/null; then
            local renderer
            renderer=$(glxinfo 2>/dev/null | grep "OpenGL renderer" | cut -d: -f2 | xargs || true)
            if [[ "$renderer" == *"llvmpipe"* ]] || [ -z "$renderer" ]; then
                log_warn "!!! GPU detected but renderer is SOFTWARE ($renderer) !!!"
                log_warn "Check host X11 permissions (xhost +local:root) or NVIDIA toolkit."
                setup_software
            fi
        else
            log_warn "glxinfo not found. Skipping hardware renderer validation."
            log_warn "To enable validation, add 'mesa-utils' to dependencies/apt.txt."
        fi
    fi

    if [ "$detected" = false ]; then
        setup_software
        log_warn "Auto-detected: No GPU device. Using software rendering."
    fi
}

# =============================================================================
# Status
# =============================================================================
gpu_status() {
    log_info "=== GPU Status ==="
    log_info "GPU_MODE env: ${GPU_MODE:-not set}"

    if has_nvidia; then
        log_ok "NVIDIA: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
    fi
    if has_intel_dri; then
        log_ok "Intel GPU: $(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')"
    fi
    if has_amd_dri; then
        log_ok "AMD GPU: $(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')"
    fi

    local renderer
    local GLX_OUT
    if command -v glxinfo &>/dev/null; then
        GLX_OUT=$(glxinfo 2>/dev/null || true)
        if [ -n "$GLX_OUT" ]; then
            renderer=$(echo "$GLX_OUT" | grep "OpenGL renderer" | cut -d: -f2 | xargs)
            if [ -n "$renderer" ]; then
                if echo "$renderer" | grep -qi "llvmpipe"; then
                    log_warn "Renderer: $renderer (Software)"
                else
                    log_ok "Renderer: $renderer"
                fi
            else
                log_warn "Renderer: Unable to detect"
            fi
        else
            log_warn "Renderer: Display connection failed. Check host X11/xhost."
        fi
    else
        log_warn "Renderer: glxinfo not installed."
    fi

    log_info "=== Environment Variables ==="
    log_info "DISPLAY=${DISPLAY:-not set}"
    log_info "LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE:-not set}"
    log_info "MESA_LOADER_DRIVER_OVERRIDE=${MESA_LOADER_DRIVER_OVERRIDE:-not set}"
    log_info "GALLIUM_DRIVER=${GALLIUM_DRIVER:-not set}"
    log_info "__NV_PRIME_RENDER_OFFLOAD=${__NV_PRIME_RENDER_OFFLOAD:-not set}"
}

# =============================================================================
# Main Entry
# =============================================================================
case "${1:-auto}" in
    intel)              setup_intel ;;
    amd)                setup_amd ;;
    nvidia)             setup_nvidia ;;
    cpu|software)       setup_software ;;
    status)             gpu_status ;;
    auto|"")            setup_auto ;;
    *)
        echo "Usage: source gpu_setup.sh {auto|intel|amd|nvidia|cpu|status}"
        ;;
esac

# ROS2 환경 복구 (GPU 설정 후 PATH가 깨지는 경우 방지)
if [ -f "/opt/ros/${ROS_DISTRO:-humble}/setup.bash" ]; then
    source "/opt/ros/${ROS_DISTRO:-humble}/setup.bash" 2>/dev/null || true
fi
