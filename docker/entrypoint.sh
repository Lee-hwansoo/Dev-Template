#!/bin/bash
# docker/entrypoint.sh
# 컨테이너 시작 시 실행 — 빌드 타임에 결정할 수 없는 런타임 환경 설정

set -e

# 로깅 유틸리티 로드
SOURCE_LOG="/docker_dev/scripts/utils_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"
LOG_PREFIX="[Entrypoint]"

# =============================================================================
# [0] Clean up empty environment variables
# =============================================================================
# Docker Compose V2 with ${VAR:-} injects "" if VAR is not set.
# We unset these so they don't interfere with logic or ROS nodes.
for var in ROS_IP WAYLAND_DISPLAY HOST_WAYLAND_DISPLAY; do
    if [ -n "${!var+x}" ] && [ -z "${!var}" ]; then
        unset "$var"
    fi
done

# 워크스페이스 루트로 이동
[ -d "/workspace" ] && cd /workspace

# =============================================================================
# [1] GPU 설정 — gpu_setup.sh에 위임
# =============================================================================
# GPU_MODE는 .env → docker-compose environment → 여기서 읽힘
# 값: auto (기본) | nvidia | intel | amd | cpu
log_info "GPU mode: ${GPU_MODE:-auto}"

if [ -f "/docker_dev/scripts/gpu_setup.sh" ]; then
    source /docker_dev/scripts/gpu_setup.sh "${GPU_MODE:-auto}"
elif [ -f "/opt/scripts/gpu_setup.sh" ]; then
    source /opt/scripts/gpu_setup.sh "${GPU_MODE:-auto}"
else
    log_warn "gpu_setup.sh not found. Skipping GPU configuration."
fi

# root로 실행되므로 DEV_HOME=/root
DEV_HOME=$(eval echo "~${SUDO_USER:-${USER:-root}}")

# =============================================================================
# [2] Environment Detection (Dev vs Prod)
# =============================================================================
# if /docker_dev exists, it's a dev environment
if [ -d "/docker_dev" ]; then
    IS_DEV=true
    log_info "Environment: Development"
else
    IS_DEV=false
    log_info "Environment: Production"
fi

# =============================================================================
# [3] Display / X11 / Wayland 체크 (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ]; then
    if [ -n "${DISPLAY:-}" ]; then
        DISPLAY_NUM="${DISPLAY#:}"
        DISPLAY_NUM="${DISPLAY_NUM%%.*}"
        if [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ] 2>/dev/null; then
            log_ok "X11 display ${DISPLAY} available"
        else
            log_warn "DISPLAY=${DISPLAY} set but X11 socket not found."
        fi
        if [ ! -f "${XAUTHORITY:-$HOME/.Xauthority}" ]; then
            log_warn "Xauthority file not found. GUI apps may fail."
        fi
    elif [ -n "${WAYLAND_DISPLAY:-}" ]; then
        log_ok "Wayland display ${WAYLAND_DISPLAY} set"
        export QT_QPA_PLATFORM="wayland;xcb"
        export GDK_BACKEND="wayland,x11"
        log_ok "Exported Wayland GUI variables"

        # Ensure XDG_RUNTIME_DIR exists with correct permissions (SSOT: /tmp/runtime-root)
        XDG_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
        export XDG_RUNTIME_DIR="$XDG_DIR"
        if [ ! -d "$XDG_DIR" ]; then
            mkdir -p "$XDG_DIR" && chmod 700 "$XDG_DIR"
            log_ok "XDG_RUNTIME_DIR created: $XDG_DIR"
        fi
    else
        log_warn "No DISPLAY or WAYLAND_DISPLAY set — GUI apps will not work."
    fi
fi

# =============================================================================
# [4] 캐시 및 기타 설정 (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ]; then
    mkdir -p /cache/ccache /cache/uv /cache/apt
    log_ok "Cache dirs ready: /cache/{ccache,uv,apt}"
fi

# =============================================================================
# [5] Git safe.directory 설정 (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ] && command -v git &>/dev/null; then
    git config --global --add safe.directory /workspace 2>/dev/null || true
    log_ok "Git safe.directory configured"
fi

# =============================================================================
# [6] SSH 키 권한 확인 (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ] && [ -d "${DEV_HOME}/.ssh" ]; then
    BAD_PERMS=$(find "${DEV_HOME}/.ssh" -name "id_*" ! -perm 600 2>/dev/null | head -1)
    if [ -n "${BAD_PERMS}" ]; then
        log_warn "SSH key permissions may cause issues (read-only mount)."
        log_warn "On host: chmod 600 ~/.ssh/id_*"
    else
        log_ok "SSH keys OK"
    fi
fi

# =============================================================================
# [7] 워크스페이스 상태 안내 (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ]; then
    if [ ! -f /workspace/install/setup.bash ] && [ ! -d /workspace/install/.venv ]; then
        log_warn "Workspace not yet built or environment not set up."
        if [ -f "$ROS_SETUP" ]; then
            log_warn "  Run: cb     (colcon build for ROS)"
        else
            log_warn "  Run: mbuild (for C++) or mkenv (for Python)"
        fi
    fi
fi

# =============================================================================
# [8] SocketCAN (선택적)
# =============================================================================
if ip link show can0 >/dev/null 2>&1; then
    log_ok "SocketCAN can0 available"
elif ip link show 2>/dev/null | grep -q ": can"; then
    log_info "SocketCAN interfaces detected (not can0)"
fi

# =============================================================================
# [9] 환경 소스 (ROS 및 Python venv)
# =============================================================================
# ROS 환경 소스
ROS_SETUP="/opt/ros/${ROS_DISTRO:-humble}/setup.bash"
if [ -f "$ROS_SETUP" ]; then
    source "$ROS_SETUP"
    log_ok "ROS ${ROS_DISTRO:-humble} sourced"

    if [ -f /workspace/install/setup.bash ]; then
        source /workspace/install/setup.bash
        log_ok "Workspace overlay sourced"
    fi
else
    log_info "ROS2 not installed or not in /opt/ros, skipping ROS2 setup"
fi

# Python 가상환경 자동 활성화
if [ -f "/workspace/install/.venv/bin/activate" ]; then
    if [ "$IS_DEV" = true ]; then
        ln -sf /workspace/install/.venv /workspace/.venv
    fi
    source "/workspace/install/.venv/bin/activate"
    log_ok "Python virtualenv activated (/workspace/install/.venv)"
fi

# =============================================================================
# [10] 의존성 자동 동기화 (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ]; then
    # 기본값으로 src/thirdparty를 유지하되 의존성 파일이 있는 경우만 동작
    TARGET_DIR="${SYNC_TARGET_DIR:-src/thirdparty}"
    if [ "$PWD" == "/workspace" ] && [ -f "dependencies/dependencies.repos" ]; then
        if [ ! -d "$TARGET_DIR" ] || [ -z "$(ls -A $TARGET_DIR 2>/dev/null)" ]; then
            log_info "Dependency directory ($TARGET_DIR) is empty. Running sync_deps.sh..."
            bash /docker_dev/scripts/sync_deps.sh
        fi
    fi
fi

# Execute
exec "$@"
