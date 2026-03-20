#!/bin/bash
# scripts/env_detector.sh
# 호스트 환경(GPU, 아키텍처, 툴킷, 디스플레이)을 정밀 진단하는 진단 엔진

# 1. GPU 및 툴킷 감지
HAS_NVIDIA="false"
HAS_TOOLKIT="false"
HAS_DRI="false"

if command -v nvidia-smi >/dev/null 2>&1; then
    HAS_NVIDIA="true"
fi

if docker info 2>/dev/null | grep -iq "Runtimes: .*nvidia"; then
    HAS_TOOLKIT="true"
fi

# /dev/dri 존재 감지 (Intel/AMD 소프트웨어 렌더링 디버깅 및 자동 마운트 선택에 활용)
if [ -d /dev/dri ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
    HAS_DRI="true"
fi

# 2. 아키텍처 감지
RAW_ARCH=$(uname -m)
case "${RAW_ARCH}" in
    x86_64)  HOST_ARCH="amd64" ;;
    aarch64) HOST_ARCH="arm64" ;;
    armv8*)  HOST_ARCH="arm64" ;;
    *)       HOST_ARCH="unknown" ;;
esac

# 3. 디스플레이 서버 감지 및 캐시 경로 확보
# DOCKER_DEV_CACHE_DIR이 설정되어 있으면 사용, 없으면 워크스페이스 내 .docker_cache 사용
if [ -z "${DOCKER_DEV_CACHE_DIR}" ]; then
    HOST_CACHE_DIR="${WORKSPACE_PATH:-$(pwd)}/.docker_cache"
else
    HOST_CACHE_DIR="${DOCKER_DEV_CACHE_DIR}"
fi
mkdir -p "${HOST_CACHE_DIR}"

DISPLAY_TYPE="X11"
HOST_XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}"
HOST_WAYLAND_DISPLAY="${WAYLAND_DISPLAY}"
# sudo 대응: sudo로 실행 시 SUDO_USER의 실제 홈 디렉토리를 참조하여 X11 인증 파일 경로를 정확히 찾습니다.
if [ -n "${SUDO_USER}" ]; then
    ORIGINAL_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
    HOST_HOME="${ORIGINAL_HOME}"
    HOST_XAUTHORITY="${XAUTHORITY:-${ORIGINAL_HOME}/.Xauthority}"
else
    HOST_HOME="${HOME}"
    HOST_XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
fi

if [ -n "$WAYLAND_DISPLAY" ]; then
    DISPLAY_TYPE="Wayland"
    # 실제 소켓 파일 존재 확인 및 경로 정규화
    if [ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]; then
        HOST_WAYLAND_DISPLAY="${WAYLAND_DISPLAY}"
    elif [ -S "/run/user/$(id -u)/${WAYLAND_DISPLAY}" ]; then
        HOST_XDG_RUNTIME_DIR="/run/user/$(id -u)"
    fi
fi

if [ -z "${HOST_XDG_RUNTIME_DIR}" ] || [ ! -d "${HOST_XDG_RUNTIME_DIR}" ]; then
    mkdir -p "${HOST_CACHE_DIR}/dummy_xdg_runtime"
    HOST_XDG_RUNTIME_DIR="${HOST_CACHE_DIR}/dummy_xdg_runtime"
fi

# X11 소켓 디렉토리 감지 (자동 생성 포함)
if [ -d /tmp/.X11-unix ]; then
    HOST_X11_DIR="/tmp/.X11-unix"
else
    # X11이 없거나 특수한 환경인 경우를 대비한 가상 경로 생성
    mkdir -p "${HOST_CACHE_DIR}/dummy_x11_unix"
    HOST_X11_DIR="${HOST_CACHE_DIR}/dummy_x11_unix"
fi

# 4. 호스트 파일 더미 매핑 (SSOT & Headless 대비)
if [ -d "${HOST_HOME}/.ssh" ]; then
    HOST_SSH_DIR="${HOST_HOME}/.ssh"
else
    mkdir -p "${HOST_CACHE_DIR}/dummy_ssh"
    HOST_SSH_DIR="${HOST_CACHE_DIR}/dummy_ssh"
fi

if [ -f "${HOST_HOME}/.gitconfig" ]; then
    HOST_GITCONFIG="${HOST_HOME}/.gitconfig"
else
    touch "${HOST_CACHE_DIR}/dummy_gitconfig"
    HOST_GITCONFIG="${HOST_CACHE_DIR}/dummy_gitconfig"
fi

if [ ! -f "${HOST_XAUTHORITY}" ]; then
    touch "${HOST_CACHE_DIR}/dummy_xauthority"
    HOST_XAUTHORITY="${HOST_CACHE_DIR}/dummy_xauthority"
fi

# 5. 결과 출력 (Makefile 등에서 활용 가능한 KEY=VALUE 형식)
echo "HAS_NVIDIA=${HAS_NVIDIA}"
echo "HAS_TOOLKIT=${HAS_TOOLKIT}"
echo "HAS_DRI=${HAS_DRI}"
echo "HOST_ARCH=${HOST_ARCH}"
echo "DISPLAY_TYPE=${DISPLAY_TYPE}"
echo "HOST_XDG_RUNTIME_DIR=${HOST_XDG_RUNTIME_DIR}"
echo "HOST_WAYLAND_DISPLAY=${HOST_WAYLAND_DISPLAY}"
echo "HOST_XAUTHORITY=${HOST_XAUTHORITY}"
echo "HOST_HOME=${HOST_HOME}"
echo "HOST_CACHE_DIR=${HOST_CACHE_DIR}"
echo "HOST_X11_DIR=${HOST_X11_DIR}"
echo "HOST_GITCONFIG=${HOST_GITCONFIG}"
echo "HOST_SSH_DIR=${HOST_SSH_DIR}"
