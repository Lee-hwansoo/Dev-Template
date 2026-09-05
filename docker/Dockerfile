# =============================================================================
# docker/Dockerfile — one multi-stage file for both images (dev and ROS) and
# both production chains (builder → runtime).
# =============================================================================

# ── Global Build Arguments ───────────────────────────────────────────────────
# Base images are TAG-pinned on purpose: reproducibility comes from
# APT_SNAPSHOT_DATE + SOURCE_DATE_EPOCH + GPG pins (check [reproducibility]).
# Pin BASE_IMAGE to a digest in .env if your compliance regime needs it.
ARG BASE_IMAGE=ubuntu:22.04
ARG WORKSPACE_PATH=/workspace
ARG ROS_DISTRO=humble
ARG APT_SNAPSHOT_DATE=latest
ARG STRICT_GPG_CHECK=true
ARG UV_VERSION=0.10.10
ARG UV_PYTHON=3.10
ARG CMAKE_C_STANDARD=11
ARG CMAKE_CXX_STANDARD=17
ARG LANG=C.UTF-8
ARG TZ=UTC
ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH=amd64
ARG SYS_PYTHON_EXE=/usr/bin/python3
ARG UV_SYNC_FLAGS=""
ARG CMAKE_EXTRA_ARGS=""
ARG COLCON_EXTRA_FLAGS=""
ARG HAS_NVIDIA=false
ARG FULL_CUDA=false
ARG CUDA_VERSION=""
ARG CUDNN_VERSION=""
ARG IMAGE_TAG=latest
ARG GIT_COMMIT=unknown
ARG COMPOSE_PROJECT_NAME=unknown
ARG SOURCE_DATE_EPOCH=""

# ── Stage: uv-binaries (Dependency Management Engine) ────────────────────────
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-binaries

# ── Stage: base (Canonical OS Foundation) ────────────────────────────────────
FROM ${BASE_IMAGE} AS base
ARG LANG
ARG TZ
ARG DEBIAN_FRONTEND
ARG WORKSPACE_PATH
ARG ROS_DISTRO
ARG APT_SNAPSHOT_DATE
ARG HAS_NVIDIA
ARG CUDA_VERSION
# Without this re-declaration the pre-FROM default is invisible here and the
# CUDA GPG pin's documented STRICT_GPG_CHECK=false escape hatch does nothing.
ARG STRICT_GPG_CHECK
ENV LANG=${LANG} \
    LC_ALL=${LANG} \
    TZ=${TZ} \
    DEBIAN_FRONTEND=${DEBIAN_FRONTEND} \
    WORKSPACE_PATH=${WORKSPACE_PATH} \
    ROS_DISTRO=${ROS_DISTRO}

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    bash /tmp/util_apt_helper.sh init-apt && \
    bash /tmp/util_apt_helper.sh configure-snapshot "${APT_SNAPSHOT_DATE}" && \
    if [ "$HAS_NVIDIA" = "true" ] && [ -n "$CUDA_VERSION" ]; then \
    bash /tmp/util_apt_helper.sh setup-cuda-repo ${CUDA_VERSION}; \
    fi

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    locales tzdata && \
    if [ "${LANG}" = "C.UTF-8" ]; then \
    printf 'LANG=C.UTF-8\nLC_ALL=C.UTF-8\n' > /etc/default/locale; \
    else \
    locale-gen "${LANG}" && update-locale LANG="${LANG}"; \
    fi && \
    ln -snf /usr/share/zoneinfo/${TZ:-UTC} /etc/localtime && echo ${TZ:-UTC} > /etc/timezone

# ── Stage: build-core (Production-capable build toolchain) ───────────────────
FROM base AS build-core
ARG WORKSPACE_PATH
ARG SYS_PYTHON_EXE
ARG UV_VERSION
ARG UV_PYTHON
ARG CMAKE_C_STANDARD
ARG CMAKE_CXX_STANDARD
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl file git gnupg2 \
    build-essential ccache cmake g++ gcc libasio-dev libboost-dev libboost-chrono-dev libboost-filesystem-dev libboost-program-options-dev libboost-regex-dev libboost-serialization-dev libboost-system-dev libboost-thread-dev libeigen3-dev libtbb-dev libyaml-cpp-dev make ninja-build python3-dev && \
    apt-get autoremove -y && \
    rm -rf /tmp/* /var/tmp/*

# uv and its interpreter, once for the dev images and the prod builders.
# UV_PYTHON_INSTALL_DIR, not uv's default: the default is the calling user's XDG
# dir, so a root build hid the interpreter in /root (0700) — the container user
# re-resolved one on every mksync, and a prod venv symlinked where Apptainer
# (running as the invoking user) could not follow. The dev stages take
# ownership below so a runtime `uv python install` still works.
COPY --from=uv-binaries /uv /uvx /usr/local/bin/
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python
RUN --mount=type=cache,target=/root/.cache/uv,sharing=locked \
    uv python install ${UV_PYTHON} && \
    chmod -R a+rX /opt/uv

ENV PATH="/usr/lib/ccache:${WORKSPACE_PATH}/install/.venv/bin:$PATH" \
    CCACHE_DIR=/cache/ccache \
    UV_CACHE_DIR=/cache/uv \
    UV_PYTHON=${UV_PYTHON} \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    VIRTUAL_ENV=${WORKSPACE_PATH}/install/.venv \
    CMAKE_C_STANDARD=${CMAKE_C_STANDARD} \
    CMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD} \
    SYS_PYTHON_EXE=${SYS_PYTHON_EXE} \
    BASH_ENV=/etc/devkit/shell-env.sh

RUN mkdir -p ${CCACHE_DIR} ${UV_CACHE_DIR} ${WORKSPACE_PATH}/install

# ── Stage: dev-base-tools (Interactive CLI, GUI & Diagnostics) ────────────────
FROM build-core AS dev-base-tools
ARG WORKSPACE_PATH
ARG TARGETARCH
ARG INSTALL_INTEL_GPU_TOOLS=false
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=dependencies/,target=${WORKSPACE_PATH}/dependencies/ \
    apt-get update && apt-get install -y --no-install-recommends \
    # cli-tools
    sudo bash-completion gdb htop iproute2 lsb-release net-tools nvtop tree unzip wget \
    fonts-noto-color-emoji fonts-font-awesome \
    # gui-tools
    dbus-x11 clinfo fontconfig libegl1-mesa-dev libgl1-mesa-dri libgl1-mesa-glx libglfw3-dev libglx-mesa0 libqt5waylandclient5 libvulkan-dev libwayland-client0 libxkbcommon0 mesa-utils mesa-vulkan-drivers qtwayland5 terminator vulkan-tools vulkan-validationlayers x11-apps x11-utils && \
    # Install D2Coding Font
    if [ -f ${WORKSPACE_PATH}/dependencies/D2Coding.zip ]; then \
    unzip -q ${WORKSPACE_PATH}/dependencies/D2Coding.zip -d /usr/share/fonts/truetype/d2coding; \
    else \
    curl -sfL --retry 3 --retry-delay 2 https://github.com/naver/d2codingfont/releases/download/VER1.3.2/D2Coding-Ver1.3.2-20180524.zip -o /tmp/d2coding.zip && \
    echo "0f1c9192eac7d56329dddc620f9f1666b707e9c8ed38fe1f988d0ae3e30b24e6  /tmp/d2coding.zip" | sha256sum -c --quiet && \
    unzip -q /tmp/d2coding.zip -d /usr/share/fonts/truetype/d2coding && rm -f /tmp/d2coding.zip; \
    fi; \
    fc-cache -f && \
    apt-get autoremove -y && \
    rm -rf /tmp/* /var/tmp/*

# Create a non-root user with UID/GID and passwordless sudo
ARG CONTAINER_USER=user
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupadd --gid $USER_GID $CONTAINER_USER \
    && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $CONTAINER_USER \
    && echo $CONTAINER_USER ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$CONTAINER_USER \
    && chmod 0440 /etc/sudoers.d/$CONTAINER_USER

# CUDA Toolkit Installation (Conditional)
ARG CUDA_VERSION
ARG CUDNN_VERSION
ARG HAS_NVIDIA
ARG FULL_CUDA

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_cuda_apt.sh,target=/tmp/util_cuda_apt.sh \
    bash /tmp/util_cuda_apt.sh dev

ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64
ENV CUDA_HOME=/usr/local/cuda

# iGPU-only diagnostics. Keep CPU/NVIDIA images lighter by avoiding Intel OpenCL.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "$TARGETARCH" = "amd64" ] && [ "$INSTALL_INTEL_GPU_TOOLS" = "true" ]; then \
    apt-get update && apt-get install -y --no-install-recommends intel-gpu-tools intel-opencl-icd; \
    else \
    echo "Skipping Intel GPU diagnostics (TARGETARCH=${TARGETARCH}, INSTALL_INTEL_GPU_TOOLS=${INSTALL_INTEL_GPU_TOOLS})"; \
    fi

# ── Stage: dev-core (Python Runtime & Environment Orchestration) ─────────────
FROM dev-base-tools AS dev-core
ARG WORKSPACE_PATH
ARG CONTAINER_USER=user
ENV BASH_ENV=/etc/devkit/shell-env.sh

COPY docker/entrypoint.sh /entrypoint.sh
COPY config/  ${WORKSPACE_PATH}/config/
COPY scripts/ ${WORKSPACE_PATH}/scripts/
RUN chmod +x /entrypoint.sh ${WORKSPACE_PATH}/scripts/*.sh ${WORKSPACE_PATH}/config/*.sh && \
    printf '\n# DevKit: single environment definition (see config/init_bash.sh)\n[ -r /etc/devkit/shell-env.sh ] && . /etc/devkit/shell-env.sh\n' \
        | tee -a /root/.bashrc >> /home/${CONTAINER_USER}/.bashrc && \
    mkdir -p /root/.config/terminator /home/${CONTAINER_USER}/.config/terminator && \
    if [ -f ${WORKSPACE_PATH}/config/terminator_config ]; then \
    cp ${WORKSPACE_PATH}/config/terminator_config /root/.config/terminator/config && \
    cp ${WORKSPACE_PATH}/config/terminator_config /home/${CONTAINER_USER}/.config/terminator/config; \
    fi && \
    chown -R ${CONTAINER_USER}:${CONTAINER_USER} /home/${CONTAINER_USER} /opt/uv
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

# ── Stage: dev targets (Interactive Developer Environments) ─────────────────
FROM dev-core AS dev
ARG WORKSPACE_PATH
ENV COLCON_HOME=${WORKSPACE_PATH}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    --mount=type=bind,source=dependencies/,target=${WORKSPACE_PATH}/dependencies/ \
    bash /tmp/util_apt_helper.sh install-packages all && \
    bash /tmp/util_apt_helper.sh restore-docker-clean
WORKDIR ${WORKSPACE_PATH}

FROM dev-core AS ros-base
ARG WORKSPACE_PATH
ARG ROS_DISTRO
ARG STRICT_GPG_CHECK
ENV ROS_DISTRO=${ROS_DISTRO}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    bash /tmp/util_apt_helper.sh setup-ros-repo ${ROS_DISTRO}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    --mount=type=bind,source=dependencies/,target=${WORKSPACE_PATH}/dependencies/ \
    bash /tmp/util_apt_helper.sh install-packages all ${ROS_DISTRO} && \
    bash /tmp/util_apt_helper.sh update-rosdep ${ROS_DISTRO} && \
    cp -r /root/.ros /opt/ros_cache && \
    chmod -R 755 /opt/ros_cache

FROM ros-base AS ros
ARG WORKSPACE_PATH
ENV COLCON_HOME=${WORKSPACE_PATH}
WORKDIR ${WORKSPACE_PATH}

RUN mkdir -p src && ${WORKSPACE_PATH}/scripts/util_setup_links.sh
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    SYNC_TARGET_DIR=/tmp/staging ${WORKSPACE_PATH}/scripts/setup_sync_deps.sh --rosdep && \
    rm -rf /tmp/staging && \
    bash ${WORKSPACE_PATH}/scripts/util_apt_helper.sh restore-docker-clean

# ── Stage: production ROS build base (No desktop/GUI tooling) ────────────────
FROM build-core AS ros-builder-base
ARG WORKSPACE_PATH
ARG ROS_DISTRO
ARG STRICT_GPG_CHECK
ENV ROS_DISTRO=${ROS_DISTRO} \
    COLCON_HOME=${WORKSPACE_PATH}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    bash /tmp/util_apt_helper.sh setup-ros-repo ${ROS_DISTRO}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    --mount=type=bind,source=dependencies/,target=${WORKSPACE_PATH}/dependencies/ \
    bash /tmp/util_apt_helper.sh install-packages builder ${ROS_DISTRO} && \
    bash /tmp/util_apt_helper.sh update-rosdep ${ROS_DISTRO}
WORKDIR ${WORKSPACE_PATH}

# ── Stage: production builders (Build and validate install artifacts) ───────
FROM build-core AS prod-dev-builder
ARG WORKSPACE_PATH
ARG ROS_DISTRO
ARG CUDA_VERSION
ARG CUDNN_VERSION
ARG BASE_IMAGE
ARG APT_SNAPSHOT_DATE
ARG IMAGE_TAG=latest
ARG GIT_COMMIT=unknown
ARG COMPOSE_PROJECT_NAME=unknown
ARG DEVKIT_STRIP_SOURCE=""
ARG DEVKIT_FAIL_ON_SOURCE=""
ARG SOURCE_DATE_EPOCH=""
ENV IMAGE_TAG=${IMAGE_TAG} \
    GIT_COMMIT=${GIT_COMMIT} \
    COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME} \
    SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    --mount=type=bind,source=dependencies/,target=${WORKSPACE_PATH}/dependencies/ \
    bash /tmp/util_apt_helper.sh install-packages builder
COPY src ${WORKSPACE_PATH}/src
COPY dependencies ${WORKSPACE_PATH}/dependencies
COPY config ${WORKSPACE_PATH}/config
COPY scripts ${WORKSPACE_PATH}/scripts
# VERSION is the template revision util_release_metadata.sh stamps into the
# release manifest; without it here the shipped artifact says "unknown".
COPY VERSION ${WORKSPACE_PATH}/VERSION
WORKDIR ${WORKSPACE_PATH}
RUN DEVKIT_BUILD_TYPE=prod bash -lc "source ${WORKSPACE_PATH}/config/util_aliases.sh && mksync" && \
    DEVKIT_STRIP_SOURCE=${DEVKIT_STRIP_SOURCE} DEVKIT_FAIL_ON_SOURCE=${DEVKIT_FAIL_ON_SOURCE} \
    bash ${WORKSPACE_PATH}/scripts/check_deps.sh ${WORKSPACE_PATH}/install && \
    DEVKIT_BUILD_TYPE=prod bash ${WORKSPACE_PATH}/scripts/util_release_metadata.sh ${WORKSPACE_PATH}/release/devkit-release.json

FROM ros-builder-base AS prod-ros-builder
ARG WORKSPACE_PATH
ARG ROS_DISTRO
ARG CUDA_VERSION
ARG CUDNN_VERSION
ARG BASE_IMAGE
ARG APT_SNAPSHOT_DATE
ARG IMAGE_TAG=latest
ARG GIT_COMMIT=unknown
ARG COMPOSE_PROJECT_NAME=unknown
ARG DEVKIT_STRIP_SOURCE=""
ARG DEVKIT_FAIL_ON_SOURCE=""
ARG SOURCE_DATE_EPOCH=""
ENV IMAGE_TAG=${IMAGE_TAG} \
    GIT_COMMIT=${GIT_COMMIT} \
    COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME} \
    SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}
COPY src ${WORKSPACE_PATH}/src
COPY dependencies ${WORKSPACE_PATH}/dependencies
COPY config ${WORKSPACE_PATH}/config
COPY scripts ${WORKSPACE_PATH}/scripts
# VERSION is the template revision util_release_metadata.sh stamps into the
# release manifest; without it here the shipped artifact says "unknown".
COPY VERSION ${WORKSPACE_PATH}/VERSION
WORKDIR ${WORKSPACE_PATH}
RUN DEVKIT_BUILD_TYPE=prod bash -lc "source ${WORKSPACE_PATH}/config/util_aliases.sh && mksync --share" && \
    DEVKIT_STRIP_SOURCE=${DEVKIT_STRIP_SOURCE} DEVKIT_FAIL_ON_SOURCE=${DEVKIT_FAIL_ON_SOURCE} \
    bash ${WORKSPACE_PATH}/scripts/check_deps.sh ${WORKSPACE_PATH}/install && \
    DEVKIT_BUILD_TYPE=prod bash ${WORKSPACE_PATH}/scripts/util_release_metadata.sh ${WORKSPACE_PATH}/release/devkit-release.json

# ── Stage: production runtime (Minimal user-facing artifacts) ────────────────
FROM base AS prod-base
ARG WORKSPACE_PATH
ARG CUDA_VERSION
ARG CUDNN_VERSION
ARG HAS_NVIDIA
ARG FULL_CUDA
ARG CONTAINER_USER=user
ARG USER_UID=1000
ARG USER_GID=$USER_UID
# The runtime uid: created here, switched to at the END of each runtime stage
# (the apt layers between need root). The artifact only reads install/ and
# /etc/devkit, and k8s runAsNonRoot rejects a root image. Apptainer ignores
# USER — it runs as the invoking user.
RUN groupadd --gid ${USER_GID} ${CONTAINER_USER} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${CONTAINER_USER}
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_cuda_apt.sh,target=/tmp/util_cuda_apt.sh \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates bash && \
    bash /tmp/util_cuda_apt.sh runtime && \
    apt-get autoremove -y && \
    rm -rf /var/tmp/*
COPY docker/prod_entrypoint.sh /entrypoint.sh
RUN --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    chmod +x /entrypoint.sh && mkdir -p ${WORKSPACE_PATH}/install /etc/devkit && \
    bash /tmp/util_apt_helper.sh restore-docker-clean
WORKDIR ${WORKSPACE_PATH}
ENTRYPOINT ["/entrypoint.sh"]

FROM prod-base AS prod-dev-runtime
ARG WORKSPACE_PATH
ARG CONTAINER_USER=user
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    --mount=type=bind,source=dependencies/,target=${WORKSPACE_PATH}/dependencies/ \
    bash /tmp/util_apt_helper.sh install-packages runtime && \
    if command -v sudo >/dev/null 2>&1; then chmod a-s "$(command -v sudo)"; fi
COPY --from=prod-dev-builder ${WORKSPACE_PATH}/install ${WORKSPACE_PATH}/install
COPY --from=prod-dev-builder /opt/uv/python /opt/uv/python
COPY --from=prod-dev-builder ${WORKSPACE_PATH}/release/ /etc/devkit/
ENV PATH="${WORKSPACE_PATH}/install/.venv/bin:${WORKSPACE_PATH}/install/bin:$PATH" \
    VIRTUAL_ENV="${WORKSPACE_PATH}/install/.venv"
USER ${CONTAINER_USER}
CMD []

FROM prod-base AS prod-ros-runtime
ARG WORKSPACE_PATH
ARG CONTAINER_USER=user
ARG ROS_DISTRO
ARG STRICT_GPG_CHECK
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    --mount=type=bind,source=dependencies/,target=${WORKSPACE_PATH}/dependencies/ \
    bash /tmp/util_apt_helper.sh setup-ros-repo ${ROS_DISTRO} && \
    bash /tmp/util_apt_helper.sh install-packages runtime ${ROS_DISTRO} && \
    apt-get purge -y --auto-remove curl gnupg2 dirmngr && \
    if command -v sudo >/dev/null 2>&1; then chmod a-s "$(command -v sudo)"; fi
COPY --from=prod-ros-builder ${WORKSPACE_PATH}/install ${WORKSPACE_PATH}/install
COPY --from=prod-ros-builder /opt/uv/python /opt/uv/python
COPY --from=prod-ros-builder ${WORKSPACE_PATH}/release/ /etc/devkit/
ENV PATH="${WORKSPACE_PATH}/install/.venv/bin:${WORKSPACE_PATH}/install/bin:$PATH" \
    VIRTUAL_ENV="${WORKSPACE_PATH}/install/.venv"
USER ${CONTAINER_USER}
CMD []
