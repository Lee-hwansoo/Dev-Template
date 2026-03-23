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

# ── Stage 2: base-tools (Shared Utilities) ───────────────────────────────
FROM base AS base-tools
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    bash-completion ca-certificates curl gnupg2 htop iproute2 jq lsb-release net-tools nvtop software-properties-common tree unzip wget

# ── Stage 3: build-tools (Compilers & Libraries) ───────────────────────────
FROM base-tools AS build-tools
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential ccache cmake g++ gcc gdb git libasio-dev libboost-all-dev libeigen3-dev libtbb-dev libyaml-cpp-dev make ninja-build python3-dev

# ── Stage 4: gui-tools (Graphics & Display) ───────────────────────────────
FROM build-tools AS gui-tools
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    clinfo fontconfig libegl1-mesa-dev libgl1-mesa-dri libgl1-mesa-glx libglfw3-dev libglx-mesa0 libqt5waylandclient5 libvulkan-dev libwayland-client0 libxkbcommon0 mesa-utils mesa-vulkan-drivers qtwayland5 terminator vulkan-tools vulkan-validationlayers x11-apps x11-utils \
    intel-gpu-tools intel-opencl-icd || true

# D2Coding 폰트 (한국어 환경)
# 의존성 폴더에 폰트가 있으면 복사, 없으면 다운로드 (실패 허용)
RUN if [ -f /opt/dependencies/D2Coding.zip ]; then \
        unzip -q /opt/dependencies/D2Coding.zip -d /usr/share/fonts/truetype/d2coding; \
    else \
        curl -sfL https://github.com/naver/d2codingfont/releases/download/VER1.3.2/D2Coding-Ver1.3.2-20180524.zip -o /tmp/d2coding.zip && \
        unzip -q /tmp/d2coding.zip -d /usr/share/fonts/truetype/d2coding && rm -f /tmp/d2coding.zip; \
    fi; \
    fc-cache -f || true

# ── Stage 5: python-runtime ────────────────────────────────────────────────
FROM gui-tools AS python-runtime
ARG UV_VERSION
ARG UV_PYTHON
ARG TARGETARCH

RUN case "${TARGETARCH}" in \
    amd64) UV_ARCH="x86_64-unknown-linux-musl" ;; \
    arm64) UV_ARCH="aarch64-unknown-linux-musl" ;; \
    *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && curl -LsSf "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin --strip-components=1 "uv-${UV_ARCH}/uv" \
    && chmod +x /usr/local/bin/uv && uv python install ${UV_PYTHON}

# ── Stage 6: common (Dev Core Configuration) ───────────────────────────────
FROM python-runtime AS common
ARG CMAKE_CXX_STANDARD
ARG UV_PYTHON

ENV PATH="/usr/lib/ccache:/workspace/install/.venv/bin:$PATH" \
    CCACHE_DIR=/cache/ccache \
    UV_CACHE_DIR=/cache/uv \
    UV_PYTHON=${UV_PYTHON} \
    VIRTUAL_ENV=/workspace/install/.venv \
    CMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD}

RUN mkdir -p /cache/ccache /cache/uv /workspace/install

COPY config/  /docker_dev/config/
COPY scripts/ /docker_dev/scripts/
RUN chmod +x /docker_dev/scripts/*.sh && \
    cat /docker_dev/config/bashrc_common.sh >> /root/.bashrc && \
    mkdir -p /root/.config/terminator && cp /docker_dev/config/terminator_config /root/.config/terminator/config 2>/dev/null || true

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

# ── Stage 7: dev targets ──────────────────────────────────────────
FROM common AS dev
ARG ROS_DISTRO
ENV COLCON_HOME=/workspace
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages all
WORKDIR /workspace

FROM common AS ros-base
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
    cat /docker_dev/config/bashrc_ros.sh >> /root/.bashrc && \
    ln -sf /docker_dev/config/colcon.meta /workspace/colcon.meta
RUN SYNC_TARGET_DIR=/tmp/staging /docker_dev/scripts/sync_deps.sh --rosdep && \
    rm -rf /tmp/staging
WORKDIR /workspace

# ── Stage 8: Production Builds (Bake) ───────────────────────────────────────
FROM common AS builder-dev
ARG ROS_DISTRO
WORKDIR /workspace
COPY s[r]c/ src/
COPY pyproject.toml* uv.lock* ./
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages all
ENV UV_PROJECT_ENVIRONMENT="/workspace/install/.venv"
RUN --mount=type=cache,target=/cache/uv,sharing=locked \
    if [ -f uv.lock ]; then uv sync --frozen; \
    elif [ -f /opt/dependencies/requirements.txt ]; then uv pip install -r /opt/dependencies/requirements.txt; fi && \
    . /workspace/install/.venv/bin/activate
RUN --mount=type=cache,target=/cache/ccache,sharing=locked \
    mkdir -p build && cd build && \
    cmake ../src -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD} && \
    make -j$(nproc) && make install DESTDIR=/workspace/install

FROM ros-base AS builder-ros
WORKDIR /workspace
COPY s[r]c/ src/
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/internal_apt_helper.sh install-packages all ${ROS_DISTRO} && \
    rosdep update --rosdistro ${ROS_DISTRO} && \
    ln -s /opt/dependencies /workspace/dependencies && \
    SYNC_TARGET_DIR=src/thirdparty /docker_dev/scripts/sync_deps.sh --rosdep
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
