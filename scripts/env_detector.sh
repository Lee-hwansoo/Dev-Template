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
HOST_ARCH=$(uname -m)
case "${HOST_ARCH}" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv8*)  ARCH="arm64" ;;
    *)       ARCH="unknown" ;;
esac

# 3. 디스플레이 서버 감지
DISPLAY_TYPE="X11"
HOST_XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}"
HOST_WAYLAND_DISPLAY="${WAYLAND_DISPLAY}"
# sudo 대응: sudo로 실행 시 SUDO_USER의 실제 홈 디렉토리를 참조하여 X11 인증 파일 경로를 정확히 찾습니다.
if [ -n "${SUDO_USER}" ]; then
    ORIGINAL_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
    HOST_XAUTHORITY="${XAUTHORITY:-${ORIGINAL_HOME}/.Xauthority}"
else
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

# 4. 결과 출력 (Makefile 등에서 활용 가능한 KEY=VALUE 형식)
echo "HAS_NVIDIA=${HAS_NVIDIA}"
echo "HAS_TOOLKIT=${HAS_TOOLKIT}"
echo "HAS_DRI=${HAS_DRI}"
echo "HOST_ARCH=${ARCH}"
echo "DISPLAY_TYPE=${DISPLAY_TYPE}"
echo "HOST_XDG_RUNTIME_DIR=${HOST_XDG_RUNTIME_DIR}"
echo "HOST_WAYLAND_DISPLAY=${HOST_WAYLAND_DISPLAY}"
echo "HOST_XAUTHORITY=${HOST_XAUTHORITY}"
