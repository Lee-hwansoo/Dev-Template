# =============================================================================
# ros2_docker_template/docker/Dockerfile
# 멀티스테이지 기반 통합 Dockerfile (Dev & Prod)
# =============================================================================

# ── 전역 빌드 인자 (Global ARGs - SSOT) ──────────────────────────────────────
ARG BASE_IMAGE=ubuntu:22.04
ARG ROS_DISTRO=humble
ARG APT_SNAPSHOT_DATE=latest
ARG UV_VERSION=0.10.10
ARG UV_PYTHON=3.10
ARG CMAKE_CXX_STANDARD=17
ARG LANG=C.UTF-8
ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH=amd64

# ── Stage 1: base (Shared OS Context) ───────────────────────────────────────
FROM ${BASE_IMAGE} AS base
ARG LANG
ARG ROS_DISTRO
ARG APT_SNAPSHOT_DATE
ARG DEBIAN_FRONTEND
ENV LANG=${LANG} \
    LC_ALL=${LANG} \
    ROS_DISTRO=${ROS_DISTRO} \
    DEBIAN_FRONTEND=${DEBIAN_FRONTEND}

# 공통 빌드 헬퍼 및 의존성 정의 파일 중앙화
COPY scripts/internal_apt_helper.sh /tmp/internal_apt_helper.sh
COPY scripts/utils_logging.sh /tmp/utils_logging.sh
COPY dependencies/ /opt/dependencies/

RUN chmod +x /tmp/internal_apt_helper.sh && \
    /tmp/internal_apt_helper.sh init-apt && \
    /tmp/internal_apt_helper.sh configure-snapshot ${APT_SNAPSHOT_DATE}

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends locales tzdata \
    && locale-gen ${LANG} \
    && update-locale LANG=${LANG}

# ── Stage: runtime-common (Shared Runtime Context) ─────────────────────────
FROM base AS runtime-common
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    libegl1-mesa libgl1-mesa-dri libglx-mesa0 mesa-utils

COPY docker/entrypoint.sh /entrypoint.sh
COPY scripts/gpu_setup.sh /opt/scripts/gpu_setup.sh
RUN chmod +x /entrypoint.sh /opt/scripts/gpu_setup.sh

# ── Stage 2: dev-base-tools (Utilities, Compilers & GUI) ──────────────────────
FROM base AS dev-base-tools
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    # base-tools
    bash-completion ca-certificates curl gnupg2 htop iproute2 jq lsb-release net-tools nvtop software-properties-common tree unzip wget \
    # build-tools
    build-essential ccache cmake g++ gcc gdb git libasio-dev libboost-all-dev libeigen3-dev libtbb-dev libyaml-cpp-dev make ninja-build python3-dev \
    # gui-tools
    clinfo fontconfig libegl1-mesa-dev libgl1-mesa-dri libgl1-mesa-glx libglfw3-dev libglx-mesa0 libqt5waylandclient5 libvulkan-dev libwayland-client0 libxkbcommon0 mesa-utils mesa-vulkan-drivers qtwayland5 terminator vulkan-tools vulkan-validationlayers x11-apps x11-utils \
    intel-gpu-tools intel-opencl-icd || true

# D2Coding 폰트
RUN if [ -f /opt/dependencies/D2Coding.zip ]; then \
        unzip -q /opt/dependencies/D2Coding.zip -d /usr/share/fonts/truetype/d2coding; \
    else \
        curl -sfL https://github.com/naver/d2codingfont/releases/download/VER1.3.2/D2Coding-Ver1.3.2-20180524.zip -o /tmp/d2coding.zip && \
        unzip -q /tmp/d2coding.zip -d /usr/share/fonts/truetype/d2coding && rm -f /tmp/d2coding.zip; \
    fi; \
    fc-cache -f || true

# ── Stage 3: dev-core (Python & Core Config) ───────────────────────────────
FROM dev-base-tools AS dev-core
ARG UV_VERSION
ARG UV_PYTHON
ARG CMAKE_CXX_STANDARD

# uv 설치 및 파이썬 세팅
COPY --from=ghcr.io/astral-sh/uv:${UV_VERSION} /uv /uvx /usr/local/bin/
RUN uv python install ${UV_PYTHON}

ENV PATH="/usr/lib/ccache:/workspace/install/.venv/bin:$PATH" \
    CCACHE_DIR=/cache/ccache \
    UV_CACHE_DIR=/cache/uv \
    UV_PYTHON=${UV_PYTHON} \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    VIRTUAL_ENV=/workspace/install/.venv \
    CMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD}

RUN mkdir -p /cache/ccache /cache/uv /workspace/install

COPY config/  /docker_dev/config/
COPY scripts/ /docker_dev/scripts/
RUN chmod +x /docker_dev/scripts/*.sh && \
    cat /docker_dev/config/bash_init.sh >> /root/.bashrc && \
    mkdir -p /root/.config/terminator && cp /docker_dev/config/terminator_config /root/.config/terminator/config 2>/dev/null || true

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

# ── Stage 7: dev targets ──────────────────────────────────────────
FROM dev-core AS dev
ARG ROS_DISTRO
ENV COLCON_HOME=/workspace
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages all
WORKDIR /workspace

FROM dev-core AS ros-base
ARG ROS_DISTRO
ENV ROS_DISTRO=${ROS_DISTRO}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh setup-ros-repo ${ROS_DISTRO}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages all ${ROS_DISTRO} && \
    rosdep init || true && \
    rosdep update --rosdistro ${ROS_DISTRO}

FROM ros-base AS ros
ENV COLCON_HOME=/workspace
RUN mkdir -p /workspace/src && \
RUN mkdir -p /workspace/src && \
    ln -sf /docker_dev/config/colcon.meta /workspace/colcon.meta
RUN SYNC_TARGET_DIR=/tmp/staging /docker_dev/scripts/sync_deps.sh --rosdep && \
    rm -rf /tmp/staging
WORKDIR /workspace

# ── Stage 8a: 공유 Python 의존성 레이어 ──────────────────────────────────────
FROM dev-core AS python-deps
WORKDIR /workspace
COPY pyproject.toml* uv.lock* ./
ENV UV_PROJECT_ENVIRONMENT="/workspace/install/.venv"
RUN --mount=type=cache,target=/cache/uv,sharing=locked \
    uv venv ${UV_PROJECT_ENVIRONMENT} && \
    if [ -f /opt/dependencies/requirements.txt ]; then \
        uv pip install -r /opt/dependencies/requirements.txt; \
    fi && \
    if [ -f pyproject.toml ] && [ -f uv.lock ]; then \
        uv sync --frozen --no-install-project; \
    fi

# ── Stage 8b: C++/Python 빌드 (builder-dev) ──────────────────────────────────
FROM python-deps AS builder-dev
ARG ROS_DISTRO
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages all
COPY s[r]c/ src/
RUN --mount=type=cache,target=/cache/uv,sharing=locked \
    if [ -f pyproject.toml ] && [ -f uv.lock ]; then uv sync --frozen; fi
RUN --mount=type=cache,target=/cache/ccache,sharing=locked \
    mkdir -p build && cd build && \
    cmake ../src -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD} && \
    make -j$(nproc) && make install DESTDIR=/workspace/install

# ── Stage 8c: ROS 빌드 (builder-ros) ─────────────────────────────────────────
FROM ros-base AS builder-ros
WORKDIR /workspace
COPY --from=python-deps /workspace/install/.venv /workspace/install/.venv
COPY pyproject.toml* uv.lock* ./
COPY s[r]c/ src/
ENV UV_PROJECT_ENVIRONMENT="/workspace/install/.venv"
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages all ${ROS_DISTRO} && \
    rosdep update --rosdistro ${ROS_DISTRO} && \
    ln -s /opt/dependencies /workspace/dependencies && \
    SYNC_TARGET_DIR=src/thirdparty /docker_dev/scripts/sync_deps.sh --rosdep
RUN --mount=type=cache,target=/cache/uv,sharing=locked \
    if [ -f pyproject.toml ] && [ -f uv.lock ]; then uv sync --frozen; fi
RUN --mount=type=cache,target=/cache/ccache,sharing=locked \
    . /opt/ros/${ROS_DISTRO}/setup.sh && \
    colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD} --install-base /workspace/install

# ── Stage 9: Final Runtime Images (Switch) ──────────────────────────────────
FROM runtime-common AS dev-runtime
WORKDIR /workspace
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages runtime && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder-dev /workspace/install /workspace/install
ENV PATH="/workspace/install/.venv/bin:/workspace/install/bin:$PATH" VIRTUAL_ENV="/workspace/install/.venv"
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

FROM runtime-common AS ros-runtime
WORKDIR /workspace
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh setup-ros-repo ${ROS_DISTRO}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages runtime ${ROS_DISTRO} && \
    apt-get update && apt-get install -y --no-install-recommends \
    ros-${ROS_DISTRO}-ros-base \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder-ros /workspace/install /workspace/install
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
