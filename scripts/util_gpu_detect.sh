#!/bin/bash
# =============================================================================
# scripts/util_gpu_detect.sh — GPU vendor and device-node detection.
# Sourced by setup_gpu.sh and check_hardware.sh.
# =============================================================================

trim_ws() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

has_glob_match() {
    compgen -G "$1" >/dev/null
}

has_drm_vendor() {
    local expected="$1"
    local vendor_file
    local vendor_id

    [ -d /dev/dri ] || return 1
    for vendor_file in /sys/class/drm/*/device/vendor; do
        [ -f "$vendor_file" ] || continue
        vendor_id="$(trim_ws "$(cat "$vendor_file" 2>/dev/null || true)")"
        [ "$vendor_id" = "$expected" ] && return 0
    done
    return 1
}

list_glob_basenames() {
    local pattern="$1"
    local item
    local names=()
    local had_nullglob=false
    shopt -q nullglob && had_nullglob=true
    shopt -s nullglob
    for item in $pattern; do
        [ -e "$item" ] || continue
        names+=( "${item##*/}" )
    done
    [ "$had_nullglob" = true ] || shopt -u nullglob
    printf '%s' "${names[*]}"
}

# NVIDIA: kernel device node + driver tool
has_nvidia() {
    # Memoize: the device-node check is cheap, but the nvidia-smi probe below can
    # be slow (esp. on WSL2), and this is called several times per boot.
    if [ -n "${__DEVKIT_HAS_NVIDIA:-}" ]; then
        [ "$__DEVKIT_HAS_NVIDIA" = "1" ]
        return
    fi
    # Native Linux: a real kernel device node is authoritative.
    if [ -e /dev/nvidiactl ] || [ -e /dev/nvidia0 ]; then
        __DEVKIT_HAS_NVIDIA=1
        return 0
    fi
    # WSL2 / no device node: require a *functional* nvidia-smi. Presence of the
    # binary alone is not enough — a stub or a driver-less install would misdetect
    # NVIDIA on native/headless hosts and force a CUDA wheel + broken GLX/EGL.
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        __DEVKIT_HAS_NVIDIA=1
        return 0
    fi
    __DEVKIT_HAS_NVIDIA=0
    return 1
}

# CUDA build capability: NVIDIA runtime plus compiler/toolkit availability
can_build_cuda() {
    has_nvidia && command -v nvcc >/dev/null 2>&1
}

# Intel iGPU: DRI device with vendor ID 0x8086
has_intel_dri() {
    has_drm_vendor "0x8086"
}

# AMD GPU: DRI device with vendor ID 0x1002 (Discrete) or 0x1022 (APU/SoC)
has_amd_dri() {
    has_drm_vendor "0x1002" || has_drm_vendor "0x1022"
}

# Generic DRI: any render node present
has_any_dri() {
    [ -d /dev/dri ] && has_glob_match "/dev/dri/renderD*"
}

# Kernel DRM driver name(s), e.g. i915 amdgpu nvidia panfrost v3d. Works for SoC
# GPUs too: they are platform devices with no PCI vendor file for has_drm_vendor.
get_drm_driver() {
    local uevent names=""
    for uevent in /sys/class/drm/*/device/uevent; do
        [ -f "$uevent" ] || continue
        while IFS='=' read -r key value; do
            [ "$key" = "DRIVER" ] || continue
            case " $names " in *" $value "*) ;; *) names="${names:+$names }$value" ;; esac
        done < "$uevent"
    done
    printf '%s' "$names"
}

# NVIDIA Jetson / Tegra embedded GPU (no nvidiactl)
has_tegra() {
    has_glob_match "/dev/nvhost-*"
}

# AMD ROCm runtime
has_rocm() {
    command -v rocm-smi >/dev/null 2>&1 || [ -d "/opt/rocm" ]
}

# WSL2 Paravirtualized Graphics (D3D12 / DirectX)
has_dxg() {
    [ -e /dev/dxg ] || return 1
    grep -qi microsoft /proc/version 2>/dev/null
}

# =============================================================================
# Rendering probes (OpenGL / GLX / EGL / Vulkan / D3D12). Each prints key=value
# and stays silent without its tool, so callers need no branching. All are
# timeout-guarded: these block forever on a set-but-unreachable DISPLAY.
# =============================================================================
GPU_PROBE_TIMEOUT="${GPU_PROBE_TIMEOUT:-3}"

__gpu_probe_run() {
    local tool="$1"; shift
    command -v "$tool" >/dev/null 2>&1 || return 1
    if command -v timeout >/dev/null 2>&1; then
        timeout "$GPU_PROBE_TIMEOUT" "$tool" "$@" 2>/dev/null
        # 124 = timed out. Callers must not retry: a second attempt costs the
        # same wall-clock again and cannot succeed where the first one hung.
        return $?
    fi
    "$tool" "$@" 2>/dev/null
}

# display_reachable: cheap precondition for every GL/EGL probe. A DISPLAY that
# points at a missing socket makes glxinfo/eglinfo burn the full timeout for a
# guaranteed failure — skip them outright instead.
display_reachable() {
    [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "${XDG_RUNTIME_DIR:-}/${WAYLAND_DISPLAY}" ] && return 0
    [ -n "${DISPLAY:-}" ] || return 1
    case "$DISPLAY" in
        :*) local n="${DISPLAY#:}"; n="${n%%.*}"; [ -S "/tmp/.X11-unix/X${n}" ] ;;
        *)  return 0 ;;   # remote/TCP display: cannot check locally, let it try
    esac
}

# probe_gl → gl_vendor, gl_renderer, gl_version, gl_mesa, gl_accelerated,
#            gl_direct, gl_vram, gl_max_core  (from a single `glxinfo -B` call)
probe_gl() {
    local out
    display_reachable || return 1
    # Gate on output, never on exit status: these tools routinely exit non-zero
    # after printing perfectly usable data (e.g. one platform of several failed).
    out="$(__gpu_probe_run glxinfo -B || true)"
    [ -n "$out" ] || return 1
    awk -F': *' '
        /^OpenGL vendor string/           { print "gl_vendor="   $2 }
        /^OpenGL renderer string/         { print "gl_renderer=" $2 }
        /^OpenGL core profile version/    { print "gl_version="  $2 }
        /^direct rendering/               { print "gl_direct="   $2 }
        /^ *Accelerated:/                 { print "gl_accelerated=" $2 }
        /^ *Video memory:/                { print "gl_vram="     $2 }
        /^ *Version:/                     { print "gl_mesa="     $2 }
        /^ *Max core profile version:/    { print "gl_max_core=" $2 }
    ' <<< "$out"
}

# probe_egl → egl_vendor, egl_version, egl_apis, egl_renderer (X11 platform)
probe_egl() {
    local out rc=0
    display_reachable || return 1
    out="$(__gpu_probe_run eglinfo -B)" || rc=$?
    # Retry the legacy invocation only when -B failed fast (unsupported flag),
    # never after a timeout (rc 124) — that would double the stall.
    if [ -z "$out" ] && [ "$rc" != "124" ]; then out="$(__gpu_probe_run eglinfo || true)"; fi
    [ -n "$out" ] || return 1
    awk -F': *' '
        /platform:/ { plat = $0 }
        plat ~ /X11|Wayland/ {
            if ($0 ~ /^EGL vendor string/)              print "egl_vendor="   $2
            if ($0 ~ /^EGL version string/)             print "egl_version="  $2
            if ($0 ~ /^EGL client APIs/)                print "egl_apis="     $2
            if ($0 ~ /^OpenGL core profile renderer/)   print "egl_renderer=" $2
        }
    ' <<< "$out" | awk '!seen[substr($0,1,index($0,"=")-1)]++'
}

# probe_vulkan → vk_device, vk_type, vk_api, vk_driver
probe_vulkan() {
    local out
    out="$(__gpu_probe_run vulkaninfo --summary || true)"
    [ -n "$out" ] || return 1
    awk -F'= *' '
        /deviceName/  && !d { print "vk_device=" $2; d = 1 }
        /deviceType/  && !t { sub(/PHYSICAL_DEVICE_TYPE_/, "", $2); print "vk_type=" $2; t = 1 }
        /apiVersion/  && !a { print "vk_api="    $2; a = 1 }
        /driverName/  && !n { print "vk_driver=" $2; n = 1 }
    ' <<< "$out"
}

# probe_gl_libs → resolved paths of the loader libraries that actually matter.
# A GL/Vulkan stack usually breaks because the loader resolves to the wrong
# library (host driver missing from the image, or /usr/lib/wsl not on the path).
probe_gl_libs() {
    command -v ldconfig >/dev/null 2>&1 || return 1
    ldconfig -p 2>/dev/null | awk '
        /libGL\.so\.1|libEGL\.so\.1|libvulkan\.so\.1|libGLX\.so\.0|libcuda\.so\.1/ {
            name = $1; path = $NF
            if (!seen[name]++) printf "%s=%s\n", name, path
        }'
}

# =============================================================================
# get_cuda_metadata <key> — one source for CUDA-related version strings.
# =============================================================================
get_cuda_metadata() {
    local key="$1"
    case "$key" in
        cuda_ver)
            if command -v nvcc >/dev/null 2>&1; then
                local nvcc_out
                nvcc_out=$(nvcc --version 2>/dev/null)
                while read -r line; do
                    if [[ "$line" == *release* ]]; then
                        read -r -a parts <<< "$line"
                        local raw_ver="${parts[${#parts[@]}-1]}"
                        raw_ver="${raw_ver#V}"
                        raw_ver="${raw_ver%,}"
                        echo "$raw_ver"
                        break
                    fi
                done <<< "$nvcc_out"
            elif [ -f /usr/local/cuda/version.json ]; then
                while read -r line; do
                    if [[ "$line" == *"version"* ]]; then
                        if [[ "$line" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                            echo "${BASH_REMATCH[1]}"
                            break
                        fi
                    fi
                done < /usr/local/cuda/version.json
            fi
            ;;
        cudnn_ver)
            local header="/usr/include/cudnn_version.h"
            [ ! -f "$header" ] && header="/usr/local/cuda/include/cudnn_version.h"
            if [ -f "$header" ]; then
                local maj="" min="" pat=""
                while read -r _name ckey val; do
                    case "$ckey" in
                        CUDNN_MAJOR) maj="$val" ;;
                        CUDNN_MINOR) min="$val" ;;
                        CUDNN_PATCHLEVEL) pat="$val" ;;
                    esac
                done < "$header"
                if [ -n "$maj" ]; then
                    printf "%s.%s.%s" "$maj" "$min" "$pat"
                fi
            fi
            ;;
    esac
}

