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
# [1] GPU 설정 — gpu_setup.sh에 위임 (SSOT)
# =============================================================================
# GPU_MODE는 .env → docker-compose environment → 여기서 읽힘
# 값: auto (기본) | nvidia | intel | amd | cpu
log_info "GPU mode: ${GPU_MODE:-auto}"
source /docker_dev/scripts/gpu_setup.sh "${GPU_MODE:-auto}"

# GPU env를 /root/.gpu_env.sh에 기록하여 .bashrc에서 source 하도록 유지
# (다중 터미널 접속 시 활용 — gpu_setup.sh의 일부 코드 경로에서 write_gpu_env 미호출 방지)
cat > /root/.gpu_env.sh << EOF
# __GPU_ENV_START (managed by entrypoint.sh)
export LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE:-0}
$([ -n "${GALLIUM_DRIVER:-}" ] && echo "export GALLIUM_DRIVER=${GALLIUM_DRIVER}")
$([ -n "${MESA_LOADER_DRIVER_OVERRIDE:-}" ] && echo "export MESA_LOADER_DRIVER_OVERRIDE=${MESA_LOADER_DRIVER_OVERRIDE}")
$([ -n "${__NV_PRIME_RENDER_OFFLOAD:-}" ] && echo "export __NV_PRIME_RENDER_OFFLOAD=${__NV_PRIME_RENDER_OFFLOAD}")
$([ -n "${__GLX_VENDOR_LIBRARY_NAME:-}" ] && echo "export __GLX_VENDOR_LIBRARY_NAME=${__GLX_VENDOR_LIBRARY_NAME}")
# __GPU_ENV_END
EOF

# root로 실행되므로 DEV_HOME=/root
DEV_HOME=$(eval echo "~${SUDO_USER:-${USER:-root}}")

# =============================================================================
# [2] Display / X11 / Wayland 체크
# =============================================================================
if [ -n "${DISPLAY:-}" ]; then
    DISPLAY_NUM="${DISPLAY#:}"
    DISPLAY_NUM="${DISPLAY_NUM%%.*}"
    if [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ] 2>/dev/null; then
        log_ok "X11 display ${DISPLAY} available"
    else
        log_warn "DISPLAY=${DISPLAY} set but X11 socket not found."
    fi
    if [ ! -f "${XAUTHORITY:-/root/.Xauthority}" ]; then
        log_warn "Xauthority file not found at ${XAUTHORITY:-/root/.Xauthority}. GUI apps may fail."
    fi
elif [ -n "${WAYLAND_DISPLAY:-}" ]; then
    log_ok "Wayland display ${WAYLAND_DISPLAY} set"
    export QT_QPA_PLATFORM="wayland;xcb"
    export GDK_BACKEND="wayland,x11"
    log_ok "Exported Wayland GUI variables (QT_QPA_PLATFORM, GDK_BACKEND)"

    cat >> /root/.gpu_env.sh << EOF
export QT_QPA_PLATFORM="wayland;xcb"
export GDK_BACKEND="wayland,x11"
EOF

    if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
        log_warn "WAYLAND_DISPLAY is set but XDG_RUNTIME_DIR is empty."
    fi
else
    log_warn "No DISPLAY or WAYLAND_DISPLAY set — GUI apps will not work."
fi

# =============================================================================
# [3] 캐시 디렉토리 초기화
# =============================================================================
# named volume이 처음 마운트될 때 디렉토리 생성
mkdir -p /cache/ccache /cache/uv /cache/apt
log_ok "Cache dirs ready: /cache/{ccache,uv,apt}"

# =============================================================================
# [4] Git safe.directory 설정
# =============================================================================
# 호스트 마운트 디렉토리는 소유자가 달라 git이 거부할 수 있음
# '*'로 설정해 컨테이너 내 모든 경로를 안전하게 허용
if command -v git &>/dev/null; then
    git config --global --add safe.directory '*' 2>/dev/null || true
    log_ok "Git safe.directory configured"
fi

# =============================================================================
# [5] SSH 키 권한 확인
# =============================================================================
# 호스트 .ssh는 read-only bind mount이므로 chmod 불가
# 권한 문제가 있으면 호스트에서 수정 필요
if [ -d "${DEV_HOME}/.ssh" ]; then
    BAD_PERMS=$(find "${DEV_HOME}/.ssh" -name "id_*" ! -perm 600 2>/dev/null | head -1)
    if [ -n "${BAD_PERMS}" ]; then
        log_warn "SSH key permissions may cause issues (read-only mount)."
        log_warn "On host: chmod 600 ~/.ssh/id_*"
    else
        log_ok "SSH keys OK"
    fi
fi

# =============================================================================
# [6] 워크스페이스 상태 안내
# =============================================================================
if [ ! -f /workspace/install/setup.bash ] && [ ! -d /workspace/install/.venv ]; then
    log_warn "Workspace not yet built or environment not set up."
    if [ -f "/opt/ros/${ROS_DISTRO:-humble}/setup.bash" ]; then
        log_warn "  Run: cb     (colcon build for ROS)"
    else
        log_warn "  Run: mbuild (for C++) or mkenv (for Python)"
    fi
fi

# =============================================================================
# [7] SocketCAN (선택적)
# =============================================================================
if ip link show can0 >/dev/null 2>&1; then
    log_ok "SocketCAN can0 available"
elif ip link show 2>/dev/null | grep -q ": can"; then
    log_info "SocketCAN interfaces detected (not can0)"
fi

# =============================================================================
# [8] 환경 소스 (ROS 및 Python venv)
# =============================================================================
# ROS2 환경 소스
if [ -f "/opt/ros/${ROS_DISTRO:-humble}/setup.bash" ]; then
    source "/opt/ros/${ROS_DISTRO:-humble}/setup.bash"
    log_ok "ROS2 ${ROS_DISTRO:-humble} sourced"

    if [ -f /workspace/install/setup.bash ]; then
        source /workspace/install/setup.bash
        log_ok "Workspace overlay sourced"
    fi
else
    log_info "dev target — ROS2 not installed, skipping ROS2 setup"
fi

# Python 가상환경 자동 활성화 및 심볼릭 링크 (IDE 호환)
if [ -f "/workspace/install/.venv/bin/activate" ]; then
    ln -sf /workspace/install/.venv /workspace/.venv
    source "/workspace/install/.venv/bin/activate"
    log_ok "Python virtualenv activated (/workspace/install/.venv) and linked to root"
fi

# =============================================================================
# [9] 의존성 자동 동기화 (sync_deps.sh)
# =============================================================================
# 컨테이너 시작 시 호스트의 서드파티 폴더가 비어있다면 자동 다운로드 수행
TARGET_DIR="src/thirdparty"
if [ "$PWD" == "/workspace" ]; then
    if [ ! -d "$TARGET_DIR" ] || [ -z "$(ls -A $TARGET_DIR 2>/dev/null)" ]; then
        log_info "Thirdparty directory is empty. Running sync_deps.sh..."
        bash /docker_dev/scripts/sync_deps.sh
    fi
fi

# =============================================================================
# Execute
# =============================================================================
exec "$@"
