# =============================================================================
# docker/Dockerfile — one multi-stage file for both dev images (dev and ROS)
# and one production chain (builder → runtime) parameterised by PROD_ENV.
# =============================================================================

# ── Global Build Arguments ───────────────────────────────────────────────────
# Base images are TAG-pinned on purpose: reproducibility comes from
# APT_SNAPSHOT_DATE + SOURCE_DATE_EPOCH + GPG pins (check [reproducibility]).
# Pin BASE_IMAGE to a digest in .env if your compliance regime needs it.
ARG BASE_IMAGE=ubuntu:22.04
ARG WORKSPACE_PATH=/workspace
ARG ROS_DISTRO=humble
ARG APT_SNAPSHOT_DATE=latest
ARG APT_SNAPSHOT_FALLBACK=true
ARG ROS_SNAPSHOT_DATE=latest
ARG STRICT_GPG_CHECK=true
ARG UV_VERSION=0.10.10
ARG UV_PYTHON=3.10
ARG UV_EXTRA=""
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
ARG FULL_CUDA=false
ARG CUDA_VERSION=""
ARG CUDNN_VERSION=""
ARG IMAGE_TAG=latest
ARG GIT_COMMIT=unknown
ARG COMPOSE_PROJECT_NAME=unknown
ARG SOURCE_DATE_EPOCH=""
# Which production flavour `prod-builder`/`prod-runtime` build (dev|ros).
ARG PROD_ENV=dev

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
ARG APT_SNAPSHOT_FALLBACK
ARG ROS_SNAPSHOT_DATE
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
    APT_SNAPSHOT_FALLBACK="${APT_SNAPSHOT_FALLBACK}" \
        bash /tmp/util_apt_helper.sh configure-snapshot "${APT_SNAPSHOT_DATE}" && \
    if [ -n "$CUDA_VERSION" ]; then \
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

# Reuse numeric groups (macOS GID 20) and the Ubuntu 24.04 default UID. The group
# is named after the user — that is what `id` and `ls -l` show — falling back to a
# numeric name only when the base image already ships that group name at another
# gid. A CONTAINER_USER taken at another UID is fatal: renumbering it would orphan
# the files the base image gave it.
ARG CONTAINER_USER=user
ARG USER_UID=1000
ARG USER_GID=$USER_UID
RUN test "$USER_UID" -ge 500 && test "$USER_GID" -gt 0 && \
    if id "$CONTAINER_USER" >/dev/null 2>&1; then \
        test "$(id -u "$CONTAINER_USER")" = "$USER_UID" || { echo "[ERROR] CONTAINER_USER '$CONTAINER_USER' already exists at uid $(id -u "$CONTAINER_USER"), but USER_UID=$USER_UID. Choose another CONTAINER_USER in .env." >&2; exit 2; }; \
    fi && \
    { getent group "$USER_GID" >/dev/null \
        || groupadd --gid "$USER_GID" "$CONTAINER_USER" 2>/dev/null \
        || groupadd --gid "$USER_GID" "devkit-$USER_GID"; } && \
    existing="$(getent passwd "$USER_UID" | cut -d: -f1)" && \
    if [ -n "$existing" ] && [ "$existing" != "$CONTAINER_USER" ]; then \
        usermod --login "$CONTAINER_USER" --home "/home/$CONTAINER_USER" --move-home "$existing"; \
    fi && \
    if id "$CONTAINER_USER" >/dev/null 2>&1; then \
        usermod --gid "$USER_GID" --shell /bin/bash "$CONTAINER_USER"; \
    else useradd --uid "$USER_UID" --gid "$USER_GID" -m -s /bin/bash "$CONTAINER_USER"; fi

# ── Stage: build-core (Production-capable build toolchain) ───────────────────
FROM base AS build-core
ARG WORKSPACE_PATH
ARG SYS_PYTHON_EXE
ARG UV_VERSION
ARG UV_PYTHON
ARG UV_EXTRA
ARG UV_SYNC_FLAGS
ARG CMAKE_EXTRA_ARGS
ARG COLCON_EXTRA_FLAGS
ARG CUDA_VERSION
ARG CUDNN_VERSION
ARG FULL_CUDA
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
# (running as the invoking user) could not follow. Ownership goes to the
# container user IN THIS LAYER: a later chown -R rewrote the whole 90 MB tree
# into a second layer. The account exists since `base`.
ARG CONTAINER_USER=user
COPY --from=uv-binaries /uv /uvx /usr/local/bin/
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python
RUN --mount=type=cache,target=/root/.cache/uv,sharing=locked \
    uv python install ${UV_PYTHON} && \
    chown -R "${CONTAINER_USER}:$(id -g "${CONTAINER_USER}")" /opt/uv && \
    chmod -R a+rX /opt/uv

ENV PATH="/usr/lib/ccache:${WORKSPACE_PATH}/install/.venv/bin:$PATH" \
    CCACHE_DIR=/cache/ccache \
    UV_CACHE_DIR=/cache/uv \
    UV_PYTHON=${UV_PYTHON} \
    UV_EXTRA=${UV_EXTRA} \
    UV_SYNC_FLAGS=${UV_SYNC_FLAGS} \
    CMAKE_EXTRA_ARGS=${CMAKE_EXTRA_ARGS} \
    COLCON_EXTRA_FLAGS=${COLCON_EXTRA_FLAGS} \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    VIRTUAL_ENV=${WORKSPACE_PATH}/install/.venv \
    CMAKE_C_STANDARD=${CMAKE_C_STANDARD} \
    CMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD} \
    SYS_PYTHON_EXE=${SYS_PYTHON_EXE} \
    BASH_ENV=/etc/devkit/shell-env.sh

RUN mkdir -p ${CCACHE_DIR} ${UV_CACHE_DIR} ${WORKSPACE_PATH}/install /etc/devkit && \
    printf '[ ! -r "${WORKSPACE_PATH}/config/init_bash.sh" ] || . "${WORKSPACE_PATH}/config/init_bash.sh"\n' > /etc/devkit/shell-env.sh

# CUDA compilation needs no GPU on the builder. Both dev and prod inherit this.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_cuda_apt.sh,target=/tmp/util_cuda_apt.sh \
    bash /tmp/util_cuda_apt.sh dev
ENV PATH=/usr/local/cuda/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64 \
    CUDA_HOME=/usr/local/cuda

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
    dbus-x11 clinfo fontconfig libegl1-mesa-dev libgl1 libgl1-mesa-dri libglfw3-dev libglx-mesa0 libqt5waylandclient5 libvulkan-dev libwayland-client0 libxkbcommon0 mesa-utils mesa-vulkan-drivers qtwayland5 vulkan-tools vulkan-validationlayers x11-apps x11-utils && \
    # Opt-in terminal font: a D2Coding.zip dropped into dependencies/ is
    # installed; nothing is downloaded from GitHub into every image any more.
    if [ -f ${WORKSPACE_PATH}/dependencies/D2Coding.zip ]; then \
    unzip -q ${WORKSPACE_PATH}/dependencies/D2Coding.zip -d /usr/share/fonts/truetype/d2coding; \
    fi; \
    fc-cache -f && \
    apt-get autoremove -y && \
    rm -rf /tmp/* /var/tmp/*

# Passwordless sudo for the container user (created in `base`).
ARG CONTAINER_USER=user
RUN echo $CONTAINER_USER ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$CONTAINER_USER \
    && chmod 0440 /etc/sudoers.d/$CONTAINER_USER

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
# The terminator layout (opt-in, dependencies/apt.txt) is not copied into a
# HOME: `make term` passes it with -g from the bind-mounted config/.
RUN chmod +x /entrypoint.sh ${WORKSPACE_PATH}/scripts/*.sh ${WORKSPACE_PATH}/config/*.sh && \
    printf '\n# DevKit: single environment definition (see config/init_bash.sh)\n[ -r /etc/devkit/shell-env.sh ] && . /etc/devkit/shell-env.sh\n' \
        | tee -a /root/.bashrc >> /home/${CONTAINER_USER}/.bashrc && \
    chown -R ${CONTAINER_USER}:$(id -g ${CONTAINER_USER}) /home/${CONTAINER_USER}
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
# A host `export` does not cross into a build. Without this ARG the pin policy
# a prod bake sets was read as its default (0) by the sync inside the image.
ARG DEVKIT_REQUIRE_PINNED=0
ENV COLCON_HOME=${WORKSPACE_PATH}
WORKDIR ${WORKSPACE_PATH}

RUN mkdir -p src
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    SYNC_TARGET_DIR=/tmp/staging DEVKIT_REQUIRE_PINNED=${DEVKIT_REQUIRE_PINNED} \
        ${WORKSPACE_PATH}/scripts/setup_sync_deps.sh --rosdep && \
    rm -rf /tmp/staging && \
    bash ${WORKSPACE_PATH}/scripts/util_apt_helper.sh restore-docker-clean

# ── Stage: production build bases, one per ENV ───────────────────────────────
# `prod-builder` and `prod-runtime` below are parameterised by PROD_ENV
# (dev|ros): they used to be two near-identical copies per flavour, and a knob
# added to one was missed on the other (OPENCV_CUDA reached a single builder).
# These two stages hold the only lines that differ.
FROM build-core AS builder-base-dev
ARG WORKSPACE_PATH
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    --mount=type=bind,source=dependencies/,target=${WORKSPACE_PATH}/dependencies/ \
    bash /tmp/util_apt_helper.sh install-packages builder
WORKDIR ${WORKSPACE_PATH}

FROM build-core AS builder-base-ros
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

# ── Stage: production builder (Build and validate install artifacts) ─────────
FROM builder-base-${PROD_ENV} AS prod-builder
ARG PROD_ENV
ARG WORKSPACE_PATH
# mksync below runs setup_sync_deps.sh: a release must not float on a branch.
ARG DEVKIT_REQUIRE_PINNED=0
# OPENCV_CUDA decides CMake flags inside mksync; without this ARG the builder
# read its default and the image was compiled for the wrong target.
ARG OPENCV_CUDA=auto
# What the release manifest records.
ARG CUDA_VERSION
ARG CUDNN_VERSION
ARG BASE_IMAGE
ARG APT_SNAPSHOT_DATE
ARG ROS_SNAPSHOT_DATE
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
# A ROS venv shares the SYSTEM interpreter (mkenv forces --share under
# /opt/ros), so the managed one is emptied — the runtime COPYs the directory
# either way, and shipping it to a ROS artifact was 90 MB nothing referenced.
RUN DEVKIT_BUILD_TYPE=prod DEVKIT_REQUIRE_PINNED=${DEVKIT_REQUIRE_PINNED} OPENCV_CUDA=${OPENCV_CUDA} bash -lc "source ${WORKSPACE_PATH}/config/util_aliases.sh && mksync" && \
    DEVKIT_STRIP_SOURCE=${DEVKIT_STRIP_SOURCE} DEVKIT_FAIL_ON_SOURCE=${DEVKIT_FAIL_ON_SOURCE} \
    bash ${WORKSPACE_PATH}/scripts/check_deps.sh ${WORKSPACE_PATH}/install && \
    DEVKIT_BUILD_TYPE=prod bash ${WORKSPACE_PATH}/scripts/util_release_metadata.sh ${WORKSPACE_PATH}/release/devkit-release.json && \
    if [ "$PROD_ENV" = ros ]; then find /opt/uv/python -mindepth 1 -delete; fi

# ── Stage: production runtime (Minimal user-facing artifacts) ────────────────
FROM base AS prod-base
ARG WORKSPACE_PATH
ARG CUDA_VERSION
ARG CUDNN_VERSION
ARG FULL_CUDA
ARG CONTAINER_USER=user
ARG USER_UID=1000
ARG USER_GID=$USER_UID
# The runtime uid: created here, switched to at the END of the runtime stage
# (the apt layers between need root). The artifact only reads install/ and
# /etc/devkit, and k8s runAsNonRoot rejects a root image. Apptainer ignores
# USER — it runs as the invoking user.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_cuda_apt.sh,target=/tmp/util_cuda_apt.sh \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates bash file libstdc++6 && \
    bash /tmp/util_cuda_apt.sh runtime && \
    apt-get autoremove -y && \
    rm -rf /var/tmp/*
COPY docker/prod_entrypoint.sh /entrypoint.sh
RUN --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    chmod +x /entrypoint.sh && mkdir -p ${WORKSPACE_PATH}/install /etc/devkit && \
    bash /tmp/util_apt_helper.sh restore-docker-clean
WORKDIR ${WORKSPACE_PATH}
ENTRYPOINT ["/entrypoint.sh"]

# The tools `base` needed to bootstrap apt (init-apt: curl, gnupg, lsb-release)
# go once the last repository is set up: a shipped artifact has no key to
# fetch. purge-bootstrap keeps whatever an installed package still depends on.
FROM prod-base AS prod-runtime
ARG PROD_ENV
ARG WORKSPACE_PATH
ARG CONTAINER_USER=user
ARG ROS_DISTRO
ARG STRICT_GPG_CHECK
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,source=scripts/util_apt_helper.sh,target=/tmp/util_apt_helper.sh \
    --mount=type=bind,source=dependencies/,target=${WORKSPACE_PATH}/dependencies/ \
    if [ "$PROD_ENV" = ros ]; then \
        bash /tmp/util_apt_helper.sh setup-ros-repo ${ROS_DISTRO} && \
        bash /tmp/util_apt_helper.sh install-packages runtime ${ROS_DISTRO}; \
    else \
        bash /tmp/util_apt_helper.sh install-packages runtime; \
    fi && \
    bash /tmp/util_apt_helper.sh purge-bootstrap && \
    if command -v sudo >/dev/null 2>&1; then chmod a-s "$(command -v sudo)"; fi
COPY --from=prod-builder ${WORKSPACE_PATH}/install ${WORKSPACE_PATH}/install
COPY --from=prod-builder /opt/uv/python /opt/uv/python
COPY --from=prod-builder ${WORKSPACE_PATH}/release/ /etc/devkit/build/
ENV PATH="${WORKSPACE_PATH}/install/.venv/bin:${WORKSPACE_PATH}/install/bin:$PATH" \
    VIRTUAL_ENV="${WORKSPACE_PATH}/install/.venv"
RUN --mount=type=bind,source=scripts,target=${WORKSPACE_PATH}/scripts \
    --mount=type=bind,source=config,target=${WORKSPACE_PATH}/config \
    --mount=type=bind,from=uv-binaries,source=/uv,target=/usr/local/bin/uv \
    /entrypoint.sh bash ${WORKSPACE_PATH}/scripts/check_deps.sh --runtime
USER ${CONTAINER_USER}
CMD []
