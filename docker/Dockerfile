# =============================================================================
# ros2_docker_template/docker/Dockerfile
# 멀티스테이지 기반 고성능 개발 환경 이미지
# =============================================================================

# ── 전역 빌드 인자 (Global ARGs) ─────────────────────────────────────────────
ARG BASE_IMAGE=ubuntu:22.04
ARG ROS_DISTRO=humble
ARG APT_SNAPSHOT_DATE=latest
ARG UV_VERSION=0.10.10
ARG PYTHON_VERSION=3.10
ARG CMAKE_CXX_STANDARD=17

# ── Stage 1: base ─────────────────────────────────────────────────────────
FROM ${BASE_IMAGE} AS base

ARG DEBIAN_FRONTEND=noninteractive
ARG LANG=ko_KR.UTF-8
ARG APT_SNAPSHOT_DATE

# 공통 빌드 헬퍼 복사 및 초기화
COPY scripts/internal_apt_helper.sh /tmp/internal_apt_helper.sh
RUN chmod +x /tmp/internal_apt_helper.sh && \
    /tmp/internal_apt_helper.sh init-apt && \
    /tmp/internal_apt_helper.sh configure-snapshot ${APT_SNAPSHOT_DATE}

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends locales \
    && locale-gen ${LANG} \
    && update-locale LANG=${LANG}

ENV LANG=${LANG} \
    LC_ALL=${LANG}

# ── Stage 2: base-tools ────────────────────────────────────────────────────
# 필수 CLI 및 네트워크 유틸리티 (거의 변경되지 않는 기반)
FROM base AS base-tools

ARG DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    bash-completion \
    ca-certificates \
    curl \
    gnupg2 \
    htop \
    iproute2 \
    jq \
    lsb-release \
    net-tools \
    nvtop \
    software-properties-common \
    tree \
    unzip \
    wget

# ── Stage 3: build-tools ───────────────────────────────────────────────────
# 컴파일러, 빌드 시스템 및 시스템 라이브러리
FROM base-tools AS build-tools

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ccache \
    cmake \
    g++ \
    gcc \
    gdb \
    git \
    libasio-dev \
    libboost-all-dev \
    libeigen3-dev \
    libtbb-dev \
    libyaml-cpp-dev \
    make \
    ninja-build \
    python3-dev \
    python3-pip \
    python3-venv

# ── Stage 4: gui-tools ─────────────────────────────────────────────────────
# 그래픽 가속, 디스플레이 서버 및 폰트
FROM build-tools AS gui-tools

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    clinfo \
    fontconfig \
    libegl1-mesa-dev \
    libgl1-mesa-dri \
    libgl1-mesa-glx \
    libglfw3-dev \
    libglx-mesa0 \
    libqt5waylandclient5 \
    libvulkan-dev \
    libwayland-client0 \
    libxkbcommon0 \
    mesa-utils \
    mesa-vulkan-drivers \
    qtwayland5 \
    terminator \
    vulkan-tools \
    vulkan-validationlayers \
    x11-apps \
    x11-utils

# Intel GPU 기본 지원 패키지
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    intel-gpu-tools \
    intel-opencl-icd || true

# D2Coding 폰트 (한국어 환경)
RUN wget -q https://github.com/naver/d2codingfont/releases/download/VER1.3.2/D2Coding-Ver1.3.2-20180524.zip -O /tmp/d2coding.zip \
    && unzip -q /tmp/d2coding.zip -d /usr/share/fonts/truetype/d2coding \
    && rm /tmp/d2coding.zip \
    && fc-cache -f || true

# ── Stage 5: python-runtime ────────────────────────────────────────────────
# uv 설치 및 프로젝트 전용 Python 버전 사전 로드
FROM gui-tools AS python-runtime

ARG UV_VERSION
ARG ROS_DISTRO
ARG PYTHON_VERSION
ARG TARGETARCH

RUN case "${TARGETARCH}" in \
    amd64) UV_ARCH="x86_64-unknown-linux-musl" ;; \
    arm64) UV_ARCH="aarch64-unknown-linux-musl" ;; \
    *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && curl -LsSf "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin --strip-components=1 "uv-${UV_ARCH}/uv" \
    && chmod +x /usr/local/bin/uv

# 주입된 PYTHON_VERSION을 사용하여 uv가 관리하는 Python 설치
RUN uv python install ${PYTHON_VERSION}

# ── Stage 6: common ───────────────────────────────────────────────────────
# 공통 환경 설정
FROM python-runtime AS common

ARG DEBIAN_FRONTEND=noninteractive
ARG CMAKE_CXX_STANDARD
ARG ROS_DISTRO
ARG PYTHON_VERSION

# 캐시 디렉토리 (named volume 초기화용 — entrypoint.sh가 mkdir -p로 보완)
RUN mkdir -p /cache/ccache /cache/uv /workspace/install

# 설정 파일 복사 (/docker_dev — 컨테이너 내 설정 루트)
COPY config/  /docker_dev/config/
COPY scripts/ /docker_dev/scripts/
RUN chmod +x /docker_dev/scripts/*.sh

# 환경 변수 (root 실행 기준)
ENV PATH="/usr/lib/ccache:/workspace/install/.venv/bin:$PATH" \
    CCACHE_DIR=/cache/ccache \
    CCACHE_MAXSIZE=5G \
    UV_CACHE_DIR=/cache/uv \
    UV_TOOL_DIR=/cache/uv/tools \
    UV_LINK_MODE=copy \
    UV_PYTHON=${PYTHON_VERSION} \
    VIRTUAL_ENV=/workspace/install/.venv \
    CMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD}

# /root/.bashrc — 컨테이너가 root로 실행되므로 root 홈에 공통 환경 설정
RUN cat /docker_dev/config/bashrc_common.sh >> /root/.bashrc

# terminator 설정 (root 홈)
RUN mkdir -p /root/.config/terminator \
    && cp /docker_dev/config/terminator_config /root/.config/terminator/config 2>/dev/null || true

# Entrypoint
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

# ── Stage 4a: dev ─────────────────────────────────────────────────────────
# 순수 C++/Python 개발환경 — ROS2 없음, 경량
# make build-dev → --target dev
FROM common AS dev

ARG ROS_DISTRO
RUN mkdir -p /workspace/src

ENV COLCON_HOME=/workspace

# 사용자 정의 apt 패키지 지연 설치 (캐시 무효화 최소화)
COPY dependencies/apt.txt /tmp/apt.txt
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages all ${ROS_DISTRO}

WORKDIR /workspace

# ── Stage 4b: ros-base (Dynamic ROS1 / ROS2) ──────────────────────────────
FROM common AS ros-base

ARG DEBIAN_FRONTEND=noninteractive
ARG ROS_DISTRO

# ROS 1 (noetic) vs ROS 2 (humble) 리포지토리 설정 및 필수 패키지 설치
RUN /tmp/internal_apt_helper.sh setup-ros-repo ${ROS_DISTRO} && \
    if [ "${ROS_DISTRO}" = "noetic" ]; then \
        apt-get install -y --no-install-recommends \
            ros-${ROS_DISTRO}-desktop-full \
            python3-rosdep python3-rosinstall python3-rosinstall-generator python3-wstool build-essential \
            python3-catkin-tools python3-osrf-pycommon python3-colcon-common-extensions python3-vcstool; \
    else \
        apt-get install -y --no-install-recommends \
            ros-${ROS_DISTRO}-desktop \
            ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
            ros-${ROS_DISTRO}-gazebo-ros-pkgs \
            ros-${ROS_DISTRO}-xacro ros-${ROS_DISTRO}-cv-bridge ros-${ROS_DISTRO}-tf2-ros \
            python3-colcon-common-extensions python3-rosdep python3-argcomplete python3-vcstool; \
    fi

RUN rosdep init && rosdep update --rosdistro ${ROS_DISTRO}

# ── Stage 4c: ros (Target Env) ────────────────────────────────────────────
FROM ros-base AS ros

ARG DEBIAN_FRONTEND=noninteractive
ARG CMAKE_CXX_STANDARD
ARG ROS_DISTRO

# 워크스페이스 디렉토리 (표준 경로 /workspace 통합)
RUN mkdir -p /workspace/src

# 동적 ROS 환경변수 스크립트 주입
RUN cat /docker_dev/config/bashrc_ros.sh >> /root/.bashrc

RUN ln -sf /docker_dev/config/colcon.meta /workspace/colcon.meta

# 사용자 정의 apt 패키지 지연 설치 (ROS 1/2 공용)
COPY dependencies/apt.txt /tmp/apt.txt
COPY dependencies/apt_ros.txt* /tmp/apt_ros.txt
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages all ${ROS_DISTRO}

# 서드파티 의존성 빌드 타임 패키징 (오버레이 포함)
COPY dependencies/ /tmp/dependencies/
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    mkdir -p /tmp/staging && \
    if [ -f /tmp/dependencies/dependencies.repos ]; then vcs import /tmp/staging < /tmp/dependencies/dependencies.repos 2>/dev/null || true; fi && \
    if [ -d /tmp/dependencies/overlay ]; then cp -a /tmp/dependencies/overlay/. /tmp/staging/ 2>/dev/null || true; fi && \
    apt-get update && \
    (rosdep install --from-paths /tmp/staging --ignore-src -r -y --rosdistro ${ROS_DISTRO} || true) && \
    rm -rf /tmp/staging /tmp/dependencies

ENV ROS_DISTRO=${ROS_DISTRO} \
    COLCON_HOME=/workspace

WORKDIR /workspace
