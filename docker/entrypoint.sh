#!/bin/bash
# docker/entrypoint.sh
# 컨테이너 시작 시 실행 — 빌드 타임에 결정할 수 없는 런타임 환경 설정
#
# dev 타겟 (ROS2 없음)과 ros2 타겟 공용
# ROS2 관련 로직은 /opt/ros 존재 여부로 조건 분기

set -e

LOG_PREFIX="[Entrypoint]"
log_info()  { echo -e "\033[0;36m${LOG_PREFIX} [INFO] $1\033[0m"; }
log_ok()    { echo -e "\033[0;32m${LOG_PREFIX} [OK]   $1\033[0m"; }
log_warn()  { echo -e "\033[0;33m${LOG_PREFIX} [WARN] $1\033[0m"; }

# =============================================================================
# [0] Clean up empty environment variables (Suppresses ROS/GUI issues)
# =============================================================================
# Docker Compose V2 with ${VAR:-} injects "" if VAR is not set.
# We unset these so they don't interfere with logic or ROS nodes.
for var in ROS_IP WAYLAND_DISPLAY HOST_WAYLAND_DISPLAY; do
    if [ -n "${!var+x}" ] && [ -z "${!var}" ]; then
        unset "$var"
    fi
done

# =============================================================================
# [1] Clean Workspace (Volume Linking)
# =============================================================================
# Named Volume 사용 시 호스트에 빈 폴더가 생기는 것을 방지하기 위해
# /opt/dockervol에 마운트된 볼륨을 /workspace로 심볼릭 링크합니다.
setup_link() {
    local src=$1
    local dest=$2
    if [ -d "$src" ]; then
        # 목적지에 이미 폴더가 있으면 (호스트에서 수동 생성 등) 링크를 위해 삭제 시도
        if [ ! -L "$dest" ] && [ -d "$dest" ]; then
            rmdir "$dest" 2>/dev/null || true
        fi
        # 링크 생성 (이미 존재하면 무시)
        if [ ! -e "$dest" ]; then
            ln -s "$src" "$dest"
        fi
    fi
}

# 워크스페이스 루트로 이동하여 링크 생성
cd /workspace
setup_link /opt/dockervol/ros/build build
setup_link /opt/dockervol/ros/install install
setup_link /opt/dockervol/ros/log log
setup_link /opt/dockervol/dev/build build
setup_link /opt/dockervol/dev/install install
setup_link /opt/dockervol/dev/log log
setup_link /opt/dockervol/prod/log log

# =============================================================================
# [2] GPU 설정 — gpu_setup.sh에 위임 (SSOT)
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

        if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
            log_warn "WAYLAND_DISPLAY is set but XDG_RUNTIME_DIR is empty. Attempting to set default..."
            export XDG_RUNTIME_DIR="/tmp/runtime-root"
            mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
        fi
    else
        log_warn "No DISPLAY or WAYLAND_DISPLAY set — GUI apps will not work."
    fi
fi

# =============================================================================
# [4] 캐시 디렉토리 초기화 (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ]; then
    mkdir -p /cache/ccache /cache/uv /cache/apt
    log_ok "Cache dirs ready: /cache/{ccache,uv,apt}"
fi

# =============================================================================
# [5] Git safe.directory 설정 (Dev Only)
# =============================================================================
if [ "$IS_DEV" = true ] && command -v git &>/dev/null; then
    git config --global --add safe.directory '*' 2>/dev/null || true
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
# ROS2 환경 소스
ROS_SETUP="/opt/ros/${ROS_DISTRO:-humble}/setup.bash"
if [ -f "$ROS_SETUP" ]; then
    source "$ROS_SETUP"
    log_ok "ROS2 ${ROS_DISTRO:-humble} sourced"

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
    TARGET_DIR="src/thirdparty"
    if [ "$PWD" == "/workspace" ]; then
        if [ ! -d "$TARGET_DIR" ] || [ -z "$(ls -A $TARGET_DIR 2>/dev/null)" ]; then
            log_info "Thirdparty directory is empty. Running sync_deps.sh..."
            bash /docker_dev/scripts/sync_deps.sh
        fi
    fi
fi

# Execute
exec "$@"
