#!/bin/bash
# =============================================================================
# scripts/gpu_setup.sh
# Automatic detection and setup switching for GPU hardware acceleration environment
#
# Supported devices: NVIDIA, Intel, AMD, CPU (Software)
# Features:
#   - Automatic fallback for Wayland/X11 displays
#   - Optimized setup for NVIDIA hybrid graphics (PRIME)
#   - Automatic fallback to software rendering (llvmpipe) upon acceleration failure
# =============================================================================

# Load logging utility
SOURCE_LOG="/docker_dev/scripts/utils_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"
LOG_PREFIX="[GPU]"

# Load shared GPU detection helpers (P-2: SSOT for GPU detection functions)
SOURCE_GPU="/docker_dev/scripts/utils_gpu_detect.sh"
[ ! -f "$SOURCE_GPU" ] && SOURCE_GPU="$(dirname "${BASH_SOURCE[0]}")/utils_gpu_detect.sh"
[ ! -f "$SOURCE_GPU" ] && SOURCE_GPU="/opt/scripts/utils_gpu_detect.sh"
if [ -f "$SOURCE_GPU" ]; then
    source "$SOURCE_GPU"
else
    echo "${LOG_PREFIX:-[GPU]} FATAL: utils_gpu_detect.sh not found. GPU detection unavailable." >&2
    exit 1
fi

# =============================================================================
# Detection Helpers
# =============================================================================
# GPU vendor detection functions (has_nvidia, has_intel_dri, has_amd_dri,
# has_any_dri, has_tegra, has_rocm) are provided by utils_gpu_detect.sh above.

# Detects the active display server (Wayland vs X11) with fallback logic
detect_display_server() {
    if [ -n "${DISPLAY_TYPE:-}" ]; then
        echo "${DISPLAY_TYPE}"
        return
    fi

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
    # Persists GPU-specific environment variables for use in future shell sessions
    local env_file="${HOME}/.gpu_env.sh"
    cat > "$env_file" << EOF
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
    # Avoid redundant configuration if NVIDIA environment is already active
    if [ "${__GLX_VENDOR_LIBRARY_NAME:-}" = "nvidia" ] && [ "${__NV_PRIME_RENDER_OFFLOAD:-}" = "1" ]; then
        log_info "NVIDIA environment already active. Skipping redundant setup."
        return
    fi

    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=0
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __GLX_VENDOR_LIBRARY_NAME="nvidia"

    local ds=$(detect_display_server)
    log_info "Detected Display Server: $ds"

    # NVIDIA Settings exclusive to Wayland/XWayland
    if [[ "$ds" == *"Wayland"* ]]; then
        [ -z "${QT_QPA_PLATFORM:-}" ] && export QT_QPA_PLATFORM="wayland;xcb"
        [ -z "${GDK_BACKEND:-}" ] && export GDK_BACKEND="wayland,x11"
        [ -z "${GBM_BACKEND:-}" ] && export GBM_BACKEND="nvidia-drm"
        export __GL_GSYNC_ALLOWED=0
        export __GL_VRR_ALLOWED=0
        log_ok "NVIDIA Wayland optimizations applied"
    fi

    write_gpu_env
    log_ok "NVIDIA GPU configured"
}

setup_intel() {
    if [ -d /sys/module/xe ]; then
        reset_gpu_env
        export LIBGL_ALWAYS_SOFTWARE=0
        write_gpu_env
        log_ok "Intel GPU configured (xe driver for Arc)"
        return
    fi

    if [ "${MESA_LOADER_DRIVER_OVERRIDE:-}" = "iris" ]; then return; fi
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=0
    export MESA_LOADER_DRIVER_OVERRIDE=iris
    write_gpu_env
    log_ok "Intel GPU configured (Mesa/iris driver)"
}

setup_amd() {
    if [ "${MESA_LOADER_DRIVER_OVERRIDE:-}" = "radeonsi" ]; then return; fi
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=0
    export MESA_LOADER_DRIVER_OVERRIDE=radeonsi
    write_gpu_env
    log_ok "AMD GPU configured (Mesa/radeonsi driver)"
}

setup_tegra() {
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=0
    write_gpu_env
    log_ok "NVIDIA Tegra GPU configured (Jetson/Embedded)"
}

setup_rocm() {
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=0
    write_gpu_env
    log_ok "AMD ROCm environment configured"
}

setup_software() {
    if [ "${LIBGL_ALWAYS_SOFTWARE:-0}" = "1" ] && [ "${GALLIUM_DRIVER:-}" = "llvmpipe" ]; then return; fi
    reset_gpu_env
    export LIBGL_ALWAYS_SOFTWARE=1
    export GALLIUM_DRIVER="llvmpipe"
    write_gpu_env
    log_warn "Software rendering (CPU/llvmpipe) configured"
}

# =============================================================================
# Automated environment-based GPU setup selection
# =============================================================================
setup_auto() {
    # If LIBGL_ALWAYS_SOFTWARE is already 1 (e.g. from docker-compose), respect it.
    if [ "${LIBGL_ALWAYS_SOFTWARE:-0}" = "1" ]; then
        log_info "LIBGL_ALWAYS_SOFTWARE=1 detected from environment. Using software rendering."
        setup_software
        return
    fi

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
    elif has_tegra; then
        setup_tegra
        log_ok "Auto-detected: NVIDIA Tegra GPU"
        detected=true
    elif has_rocm; then
        setup_rocm
        log_ok "Auto-detected: AMD ROCm (Compute)"
        detected=true
    elif has_any_dri; then
        reset_gpu_env
        export LIBGL_ALWAYS_SOFTWARE=0
        write_gpu_env
        log_ok "Auto-detected: GPU (DRI/Mesa, driver auto-selected)"
        detected=true
    fi

    # Verification: Validates that the selected hardware renderer is active
    if [ "$detected" = true ]; then
        if [ "$ds" != "None" ] && command -v glxinfo &>/dev/null; then
            local renderer
            renderer=$(glxinfo 2>/dev/null | grep "OpenGL renderer" | cut -d: -f2 | xargs || true)
            if [[ "$renderer" == *"llvmpipe"* ]] || [ -z "$renderer" ]; then
                log_warn "!!! GPU detected but renderer is SOFTWARE ($renderer) !!!"
                log_warn "Check host X11 permissions (xhost +local:root) or NVIDIA toolkit."
                setup_software
            fi
        elif command -v vulkaninfo &>/dev/null; then
            local vk_dev=$(vulkaninfo --summary 2>/dev/null | grep "deviceName" | head -1 || true)
            if [ -z "$vk_dev" ]; then
                log_warn "!!! Vulkan device not found. Headless verification failed !!!"
                setup_software
            fi
        elif command -v vainfo &>/dev/null; then
            if ! vainfo --display drm 2>/dev/null | grep -qi "Driver version"; then
                log_warn "!!! VA-API DRM device not found. Headless verification failed !!!"
                setup_software
            fi
        else
            if [ "$ds" != "None" ]; then
                log_warn "Validation tools (glxinfo/vulkaninfo/vainfo) not found."
                log_warn "To enable validation, add 'mesa-utils' or 'vulkan-tools' to apt.txt."
            fi
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
__gpu_status_impl() {
    print_banner SETUP
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
# Integrated GPU (iGPU) Setup (Excludes NVIDIA)
# =============================================================================
setup_igpu() {
    # Auto-determine Intel/AMD based on DRI device (Excluding NVIDIA)
    if has_intel_dri; then
        setup_intel
    elif has_amd_dri; then
        setup_amd
    elif has_any_dri; then
        reset_gpu_env
        export LIBGL_ALWAYS_SOFTWARE=0
        write_gpu_env
        log_ok "Generic DRI GPU configured"
    else
        setup_software
        log_warn "igpu mode requested but no DRI device found. Falling back to software."
    fi
}

# =============================================================================
# Main Entry
# =============================================================================
case "${1:-auto}" in
    intel)              setup_intel ;;
    amd)                setup_amd ;;
    nvidia)             setup_nvidia ;;
    igpu)               setup_igpu ;;
    cpu|software)       setup_software ;;
    status)             __gpu_status_impl ;;
    auto|"")            setup_auto ;;
    *)
        echo "Usage: source gpu_setup.sh {auto|intel|amd|nvidia|igpu|cpu|status}"
        ;;
esac
